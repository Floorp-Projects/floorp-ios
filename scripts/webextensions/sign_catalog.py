#!/usr/bin/env python3
"""Create a canonical, two-tier Ed25519-signed Floorp extension catalog.

Private keys are never generated, copied, or stored by this tool.  Callers
provide separately managed PKCS#8 Ed25519 PEM files; only the root public key
and signed catalog are output.  The iOS verifier checks the same wire format.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from ingest_extension import canonical_json, sha256, strict_json_loads


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
    value = strict_json_loads(path.read_bytes(), label="catalog records")
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
    root_key: Ed25519PrivateKey,
    leaf_key: Ed25519PrivateKey,
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

    leaf_public = leaf_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    root_public = root_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    unsigned_leaf = {
        "keyID": leaf_key_id,
        "notAfter": leaf_not_after,
        "notBefore": leaf_not_before,
        "publicKey": base64url(leaf_public),
    }
    signing_key = {**unsigned_leaf, "signature": base64url(root_key.sign(canonical_json(unsigned_leaf)))}
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
    catalog = {**unsigned_catalog, "signature": base64url(leaf_key.sign(canonical_json(unsigned_catalog)))}
    return canonical_json(catalog), root_public


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--records", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--root-public-key-output", required=True, type=Path)
    result.add_argument("--root-private-key", required=True, type=Path)
    result.add_argument("--leaf-private-key", required=True, type=Path)
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
            root_key=load_private_key(arguments.root_private_key),
            leaf_key=load_private_key(arguments.leaf_private_key),
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
