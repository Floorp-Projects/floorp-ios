#!/usr/bin/env python3
"""Create a canonical, two-tier Ed25519-signed Floorp extension catalog.

Private keys are never generated, copied, or stored by this tool.  Callers
provide separately managed PKCS#8 Ed25519 PEM files; only the root public key
and signed catalog are output.  The iOS verifier checks the same wire format.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from ingest_extension import IngestionError, canonical_json, sha256, strict_json_loads


CURRENT_SCHEMA = 2
PACKAGE_KEYS_V1 = {
    "artifactBytes",
    "artifactSHA256",
    "artifactURL",
    "availability",
    "compatibilityProfiles",
    "extensionID",
    "generation",
    "manifestSHA256",
    "resourceInventorySHA256",
    "version",
}
PACKAGE_KEYS_V2 = PACKAGE_KEYS_V1 | {"metadata"}
METADATA_KEYS_V2 = {
    "category",
    "description",
    "displayName",
    "hostPermissions",
    "license",
    "minimumFloorpBuild",
    "modificationStatus",
    "noticesSHA256",
    "originalArtifactSHA256",
    "permissions",
    "privateProfileCapability",
    "sourceURL",
    "upstream",
    "upstreamRevision",
}
MANAGED_SIGNER_PROTOCOL_VERSION = 1
ROOT_CERTIFICATE_PURPOSE = "floorp-curated-catalog/root-leaf-certificate/v1"
CATALOG_SIGNATURE_PURPOSE = "floorp-curated-catalog/leaf-catalog/v1"
MANAGED_SIGNER_SHA256 = re.compile(r"[0-9a-f]{64}")
MANAGED_SIGNER_ENVIRONMENT_NAME = re.compile(r"[A-Z][A-Z0-9_]{0,127}")
MAX_MANAGED_SIGNER_BYTES = 32 * 1024 * 1024
SAFE_MANAGED_SIGNER_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
FORBIDDEN_MANAGED_SIGNER_ENVIRONMENT_NAMES = {
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "APPLE_DEVELOPER_API_KEY_JSON",
    "BASH_ENV",
    "ENV",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "PATH",
    "PYTHONHOME",
    "PYTHONINSPECT",
    "PYTHONPATH",
    "PYTHONSTARTUP",
}


class CatalogSigningError(RuntimeError):
    pass


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def parse_timestamp(value: str) -> datetime:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise CatalogSigningError(f"timestamp must use RFC3339 UTC seconds: {value!r}")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def safe_id(value: str, maximum_length: int = 96) -> str:
    if not re.fullmatch(rf"[A-Za-z0-9._-]{{1,{maximum_length}}}", value):
        raise CatalogSigningError(f"invalid identifier {value!r}")
    return value


def _base64url_bytes(value: Any, *, byte_count: int, label: str) -> bytes:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise CatalogSigningError(f"{label} must be canonical base64url")
    try:
        result = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except (ValueError, TypeError) as error:
        raise CatalogSigningError(f"{label} must be canonical base64url") from error
    if len(result) != byte_count or base64url(result) != value:
        raise CatalogSigningError(f"{label} has an invalid length or encoding")
    return result


def _managed_signer_environment(names: list[str]) -> dict[str, str]:
    """Pass only explicit runtime values to an external signing adapter.

    A managed signer must not inherit incidental CI, GitHub, or App Store
    credentials.  The adapter owner opts into every environment name it needs
    (for example an HSM socket location or KMS profile) without exposing its
    value in this tool's arguments or output.
    """

    environment = {"PATH": SAFE_MANAGED_SIGNER_PATH}
    for name in ("LANG", "LC_ALL"):
        if (value := os.environ.get(name)) is not None:
            environment[name] = value
    for name in names:
        if MANAGED_SIGNER_ENVIRONMENT_NAME.fullmatch(name) is None:
            raise CatalogSigningError(f"managed signer environment name is invalid: {name!r}")
        if name in FORBIDDEN_MANAGED_SIGNER_ENVIRONMENT_NAMES or name.startswith("DYLD_"):
            raise CatalogSigningError(f"managed signer environment is not allowed: {name}")
        if name not in os.environ:
            raise CatalogSigningError(f"managed signer environment is not set: {name}")
        environment[name] = os.environ[name]
    return environment


class ManagedEd25519Signer:
    """A pinned external adapter that exposes only Ed25519 public/sign calls.

    The executable receives a canonical JSON request on stdin and writes one
    canonical JSON response on stdout.  It is deliberately not a shell command
    and receives no arbitrary arguments, source paths, private keys, or
    inherited deployment credentials.  Its SHA-256 is supplied by the signing
    approval record, so an unreviewed checkout change cannot replace it.
    """

    def __init__(
        self,
        *,
        command: Path,
        command_sha256: str,
        key_id: str,
        environment_names: list[str],
        timeout_seconds: int,
    ) -> None:
        if not command.is_absolute():
            raise CatalogSigningError("managed signer command must be an absolute path")
        if MANAGED_SIGNER_SHA256.fullmatch(command_sha256) is None:
            raise CatalogSigningError("managed signer command SHA-256 must be lowercase hexadecimal")
        safe_id(key_id)
        if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 120:
            raise CatalogSigningError("managed signer timeout must be between 1 and 120 seconds")
        try:
            resolved = command.resolve(strict=True)
        except OSError as error:
            raise CatalogSigningError(f"cannot inspect managed signer command: {error}") from error
        self.command = resolved
        self.command_sha256 = command_sha256
        self._assert_command_integrity()
        self.key_id = key_id
        self.environment = _managed_signer_environment(environment_names)
        self.timeout_seconds = timeout_seconds
        self._public_key: bytes | None = None

    def _assert_command_integrity(self) -> None:
        try:
            metadata = self.command.stat()
        except OSError as error:
            raise CatalogSigningError(f"cannot inspect managed signer command: {error}") from error
        if not stat.S_ISREG(metadata.st_mode) or not os.access(self.command, os.X_OK):
            raise CatalogSigningError("managed signer command must be an executable regular file")
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise CatalogSigningError("managed signer command must not be group- or world-writable")
        if metadata.st_size <= 0 or metadata.st_size > MAX_MANAGED_SIGNER_BYTES:
            raise CatalogSigningError("managed signer command size is invalid")
        try:
            actual_sha256 = hashlib.sha256(self.command.read_bytes()).hexdigest()
        except OSError as error:
            raise CatalogSigningError(f"cannot hash managed signer command: {error}") from error
        if actual_sha256 != self.command_sha256:
            raise CatalogSigningError("managed signer command does not match its approved SHA-256")

    def require_outside(self, directory: Path) -> None:
        """Reject an adapter from the checkout whose content is being signed."""

        try:
            self.command.relative_to(directory.resolve())
        except ValueError:
            return
        raise CatalogSigningError("managed signer command must be outside the signing checkout")

    def _invoke(self, request: dict[str, Any], *, expected_keys: set[str]) -> dict[str, Any]:
        self._assert_command_integrity()
        try:
            completed = subprocess.run(
                [str(self.command)],
                check=False,
                cwd="/",
                env=self.environment,
                input=canonical_json(request),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=self.timeout_seconds,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CatalogSigningError(f"managed signer invocation failed: {type(error).__name__}") from error
        if completed.returncode != 0:
            raise CatalogSigningError(f"managed signer invocation failed with exit status {completed.returncode}")
        try:
            response = strict_json_loads(completed.stdout, label="managed signer response")
        except (ValueError, IngestionError) as error:
            raise CatalogSigningError("managed signer response is not strict JSON") from error
        if canonical_json(response) != completed.stdout:
            raise CatalogSigningError("managed signer response is not canonical JSON")
        if not isinstance(response, dict) or set(response) != expected_keys:
            raise CatalogSigningError("managed signer response has unexpected fields")
        if response.get("schemaVersion") != MANAGED_SIGNER_PROTOCOL_VERSION:
            raise CatalogSigningError("managed signer response schema is unsupported")
        if response.get("keyID") != self.key_id:
            raise CatalogSigningError("managed signer response key ID does not match the request")
        return response

    def public_key_bytes(self) -> bytes:
        if self._public_key is not None:
            return self._public_key
        request = {
            "keyID": self.key_id,
            "operation": "public-key",
            "schemaVersion": MANAGED_SIGNER_PROTOCOL_VERSION,
        }
        response = self._invoke(
            request,
            expected_keys={"keyID", "operation", "publicKey", "schemaVersion"},
        )
        if response.get("operation") != request["operation"]:
            raise CatalogSigningError("managed signer response operation does not match the request")
        self._public_key = _base64url_bytes(response.get("publicKey"), byte_count=32, label="managed signer public key")
        return self._public_key

    def sign(self, payload: bytes, *, purpose: str) -> bytes:
        if not isinstance(payload, bytes) or not payload:
            raise CatalogSigningError("managed signer payload must be non-empty bytes")
        if not isinstance(purpose, str) or re.fullmatch(r"[a-z0-9][a-z0-9/-]{2,127}", purpose) is None:
            raise CatalogSigningError("managed signer purpose is invalid")
        request = {
            "keyID": self.key_id,
            "operation": "sign",
            "payload": base64url(payload),
            "purpose": purpose,
            "schemaVersion": MANAGED_SIGNER_PROTOCOL_VERSION,
        }
        response = self._invoke(
            request,
            expected_keys={"keyID", "operation", "publicKey", "purpose", "schemaVersion", "signature"},
        )
        if response.get("operation") != request["operation"] or response.get("purpose") != purpose:
            raise CatalogSigningError("managed signer response does not match the requested operation")
        public_key = _base64url_bytes(response.get("publicKey"), byte_count=32, label="managed signer public key")
        if public_key != self.public_key_bytes():
            raise CatalogSigningError("managed signer public key changed during signing")
        signature = _base64url_bytes(response.get("signature"), byte_count=64, label="managed signer signature")
        try:
            Ed25519PublicKey.from_public_bytes(public_key).verify(signature, payload)
        except (InvalidSignature, ValueError) as error:
            raise CatalogSigningError("managed signer returned an invalid signature") from error
        return signature


def load_catalog_signer(arguments: argparse.Namespace, key_role: str) -> Ed25519PrivateKey | ManagedEd25519Signer:
    """Resolve a local test key or a non-exporting managed signing adapter."""

    if key_role not in {"root", "leaf"}:
        raise CatalogSigningError("catalog signer role is invalid")
    private_key = getattr(arguments, f"{key_role}_private_key")
    managed_signer = getattr(arguments, f"{key_role}_managed_signer")
    if private_key is not None:
        if getattr(arguments, f"{key_role}_managed_signer_sha256") is not None:
            raise CatalogSigningError(f"{key_role} managed signer SHA-256 requires a managed signer")
        return load_private_key(private_key)
    if managed_signer is None:
        raise CatalogSigningError(f"{key_role} signing authority is missing")
    command_sha256 = getattr(arguments, f"{key_role}_managed_signer_sha256")
    if command_sha256 is None:
        raise CatalogSigningError(f"{key_role} managed signer SHA-256 is required")
    return ManagedEd25519Signer(
        command=managed_signer,
        command_sha256=command_sha256,
        key_id=getattr(arguments, f"{key_role}_key_id"),
        environment_names=list(arguments.managed_signer_env),
        timeout_seconds=arguments.managed_signer_timeout_seconds,
    )


def _signer_public_key(signer: Ed25519PrivateKey | ManagedEd25519Signer) -> bytes:
    if isinstance(signer, Ed25519PrivateKey):
        return signer.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
    return signer.public_key_bytes()


def _sign_with_signer(signer: Ed25519PrivateKey | ManagedEd25519Signer, payload: bytes, *, purpose: str) -> bytes:
    if isinstance(signer, Ed25519PrivateKey):
        return signer.sign(payload)
    return signer.sign(payload, purpose=purpose)


def load_private_key(path: Path) -> Ed25519PrivateKey:
    try:
        key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    except (OSError, ValueError, TypeError) as error:
        raise CatalogSigningError(f"cannot load Ed25519 private key {path}: {error}") from error
    if not isinstance(key, Ed25519PrivateKey):
        raise CatalogSigningError(f"private key {path} is not Ed25519")
    return key


def validate_sha256(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise CatalogSigningError(f"{field} must be a lowercase SHA-256 digest")
    return value


def validate_string_list(value: Any, *, field: str, maximum_count: int = 128) -> list[str]:
    if not isinstance(value, list) or len(value) > maximum_count or not all(isinstance(item, str) and item for item in value):
        raise CatalogSigningError(f"{field} must be a bounded non-empty string list")
    if len(set(value)) != len(value):
        raise CatalogSigningError(f"{field} must not contain duplicates")
    return value


def validate_record(value: Any, *, schema: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CatalogSigningError("catalog record must be an object")
    expected = PACKAGE_KEYS_V2 if schema == 2 else PACKAGE_KEYS_V1
    if set(value) != expected:
        raise CatalogSigningError(f"catalog record has unexpected fields: {sorted(set(value) ^ expected)}")
    extension_id = value["extensionID"]
    generation = value["generation"]
    if not isinstance(extension_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,127}", extension_id):
        raise CatalogSigningError("catalog record extensionID is invalid")
    if not isinstance(generation, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,47}", generation):
        raise CatalogSigningError("catalog record generation is invalid")
    if not isinstance(value["version"], str) or not re.fullmatch(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){1,3}", value["version"]):
        raise CatalogSigningError("catalog record version is invalid")
    if not isinstance(value["artifactURL"], str) or not re.fullmatch(r"https://[^?#\s]+", value["artifactURL"]):
        raise CatalogSigningError("catalog record artifactURL must be an HTTPS URL without query/fragment")
    if not isinstance(value["artifactBytes"], int) or not 0 < value["artifactBytes"] <= 32 * 1024 * 1024:
        raise CatalogSigningError("catalog record artifactBytes is invalid")
    for field in ("artifactSHA256", "manifestSHA256", "resourceInventorySHA256"):
        validate_sha256(value[field], field=field)
    profiles = validate_string_list(value["compatibilityProfiles"], field="compatibilityProfiles", maximum_count=3)
    if not profiles or set(profiles) - {"content-script", "dnr", "action-storage"}:
        raise CatalogSigningError("catalog record compatibilityProfiles is invalid")
    if value["availability"] not in {"available", "updateAvailable", "withdrawn", "revoked"}:
        raise CatalogSigningError("catalog record availability is invalid")
    if schema == 2:
        metadata = value["metadata"]
        if not isinstance(metadata, dict) or set(metadata) != METADATA_KEYS_V2:
            raise CatalogSigningError("catalog record metadata has unexpected fields")
        for field in ("displayName", "description", "category", "upstream", "upstreamRevision", "license", "minimumFloorpBuild"):
            if not isinstance(metadata[field], str) or not metadata[field].strip() or len(metadata[field]) > 512:
                raise CatalogSigningError(f"catalog metadata {field} is invalid")
        if not re.fullmatch(r"https://[^\s]+", metadata["sourceURL"]):
            raise CatalogSigningError("catalog metadata sourceURL must be HTTPS")
        for field in ("originalArtifactSHA256", "noticesSHA256"):
            validate_sha256(metadata[field], field=f"metadata.{field}")
        validate_string_list(metadata["permissions"], field="metadata.permissions")
        validate_string_list(metadata["hostPermissions"], field="metadata.hostPermissions")
        if metadata["privateProfileCapability"] not in {"not-supported", "opt-in", "supported"}:
            raise CatalogSigningError("catalog metadata privateProfileCapability is invalid")
        if metadata["modificationStatus"] not in {"unmodified", "compatibility-patched", "floorp-managed"}:
            raise CatalogSigningError("catalog metadata modificationStatus is invalid")
    return value


def load_records(path: Path, *, schema: int) -> list[dict[str, Any]]:
    return load_records_bytes(path.read_bytes(), schema=schema)


def load_records_bytes(data: bytes, *, schema: int) -> list[dict[str, Any]]:
    """Validate catalog records from immutable caller-supplied bytes.

    The managed curated signer verifies its input file before private keys are
    accessed.  Keeping this byte-oriented form lets that caller sign the exact
    bytes it verified rather than re-opening a mutable path.
    """

    value = strict_json_loads(data, label="catalog records")
    if not isinstance(value, list) or not value:
        raise CatalogSigningError("catalog records must be a non-empty JSON array")
    if len(value) > 128:
        raise CatalogSigningError("catalog has too many records")
    records = [validate_record(record, schema=schema) for record in value]
    identities = {(record["extensionID"], record["generation"]) for record in records}
    if len(identities) != len(records):
        raise CatalogSigningError("catalog records duplicate an immutable extension generation")
    return sorted(records, key=lambda record: (record["extensionID"], record["generation"]))


def signed_catalog(
    *,
    records: list[dict[str, Any]],
    root_key: Ed25519PrivateKey | ManagedEd25519Signer,
    leaf_key: Ed25519PrivateKey | ManagedEd25519Signer,
    root_key_id: str,
    leaf_key_id: str,
    catalog_id: str,
    app_bundle_id: str,
    minimum_app_version: str,
    channel: str,
    sequence: int,
    issued_at: str,
    expires_at: str,
    leaf_not_before: str,
    leaf_not_after: str,
    schema: int = CURRENT_SCHEMA,
) -> tuple[bytes, bytes]:
    if schema not in {1, 2}:
        raise CatalogSigningError("unsupported schema")
    safe_id(root_key_id)
    safe_id(leaf_key_id)
    safe_id(catalog_id)
    safe_id(app_bundle_id, 255)
    safe_id(channel, 32)
    if not isinstance(sequence, int) or sequence <= 0:
        raise CatalogSigningError("catalog sequence must be positive")
    issued = parse_timestamp(issued_at)
    expires = parse_timestamp(expires_at)
    leaf_before = parse_timestamp(leaf_not_before)
    leaf_after = parse_timestamp(leaf_not_after)
    if not issued <= expires or expires - issued > __import__("datetime").timedelta(days=14):
        raise CatalogSigningError("catalog validity must be within 14 days")
    if not leaf_before < leaf_after or leaf_after - leaf_before > __import__("datetime").timedelta(days=90):
        raise CatalogSigningError("leaf validity must be within 90 days")
    if not leaf_before <= issued or leaf_after < expires:
        raise CatalogSigningError("leaf key must cover the catalog validity interval")
    if not re.fullmatch(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){1,3}", minimum_app_version):
        raise CatalogSigningError("minimum app version must be semantic")

    leaf_public = _signer_public_key(leaf_key)
    root_public = _signer_public_key(root_key)
    unsigned_leaf = {
        "keyID": leaf_key_id,
        "notAfter": leaf_not_after,
        "notBefore": leaf_not_before,
        "publicKey": base64url(leaf_public),
    }
    signing_key = {
        **unsigned_leaf,
        "signature": base64url(
            _sign_with_signer(
                root_key,
                canonical_json(unsigned_leaf),
                purpose=ROOT_CERTIFICATE_PURPOSE,
            )
        ),
    }
    unsigned_catalog = {
        "audience": {
            "bundleIDs": [app_bundle_id],
            "channel": channel,
            "minimumAppVersion": minimum_app_version,
        },
        "catalogID": catalog_id,
        "expiresAt": expires_at,
        "issuedAt": issued_at,
        "packages": records,
        "revocations": [],
        "schemaVersion": schema,
        "sequence": sequence,
        "signingKey": signing_key,
    }
    catalog = {
        **unsigned_catalog,
        "signature": base64url(
            _sign_with_signer(
                leaf_key,
                canonical_json(unsigned_catalog),
                purpose=CATALOG_SIGNATURE_PURPOSE,
            )
        ),
    }
    return canonical_json(catalog), root_public


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--records", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--root-public-key-output", required=True, type=Path)
    root_authority = result.add_mutually_exclusive_group(required=True)
    root_authority.add_argument("--root-private-key", type=Path)
    root_authority.add_argument("--root-managed-signer", type=Path)
    result.add_argument("--root-managed-signer-sha256")
    leaf_authority = result.add_mutually_exclusive_group(required=True)
    leaf_authority.add_argument("--leaf-private-key", type=Path)
    leaf_authority.add_argument("--leaf-managed-signer", type=Path)
    result.add_argument("--leaf-managed-signer-sha256")
    result.add_argument(
        "--managed-signer-env",
        action="append",
        default=[],
        metavar="NAME",
        help="explicit environment name inherited by an external signer adapter",
    )
    result.add_argument(
        "--managed-signer-timeout-seconds",
        type=int,
        default=30,
        help="external signer timeout (1-120 seconds)",
    )
    result.add_argument("--root-key-id", required=True)
    result.add_argument("--leaf-key-id", required=True)
    result.add_argument("--catalog-id", required=True)
    result.add_argument("--app-bundle-id", required=True)
    result.add_argument("--minimum-app-version", required=True)
    result.add_argument("--channel", required=True)
    result.add_argument("--sequence", required=True, type=int)
    result.add_argument("--issued-at", required=True)
    result.add_argument("--expires-at", required=True)
    result.add_argument("--leaf-not-before", required=True)
    result.add_argument("--leaf-not-after", required=True)
    result.add_argument("--schema", type=int, default=CURRENT_SCHEMA, choices=(1, 2))
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        records = load_records(arguments.records, schema=arguments.schema)
        catalog, root_public = signed_catalog(
            records=records,
            root_key=load_catalog_signer(arguments, "root"),
            leaf_key=load_catalog_signer(arguments, "leaf"),
            root_key_id=arguments.root_key_id,
            leaf_key_id=arguments.leaf_key_id,
            catalog_id=arguments.catalog_id,
            app_bundle_id=arguments.app_bundle_id,
            minimum_app_version=arguments.minimum_app_version,
            channel=arguments.channel,
            sequence=arguments.sequence,
            issued_at=arguments.issued_at,
            expires_at=arguments.expires_at,
            leaf_not_before=arguments.leaf_not_before,
            leaf_not_after=arguments.leaf_not_after,
            schema=arguments.schema,
        )
    except (CatalogSigningError, OSError) as error:
        print(f"catalog signing failed: {error}", file=sys.stderr)
        return 2
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(catalog)
    arguments.root_public_key_output.parent.mkdir(parents=True, exist_ok=True)
    arguments.root_public_key_output.write_text(base64url(root_public) + "\n", encoding="ascii")
    print(json.dumps({
        "catalog_sha256": sha256(catalog),
        "root_public_key": base64url(root_public),
        "schema": arguments.schema,
        "status": "signed",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
