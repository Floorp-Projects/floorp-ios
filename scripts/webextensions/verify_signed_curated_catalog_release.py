#!/usr/bin/env python3
"""Verify the public, source-bound inputs for a curated-catalog release."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from ingest_extension import (
    FWEA1_MAGIC,
    IngestionError,
    canonical_json,
    sha256,
    strict_json_loads,
    validate_path,
)
from sign_catalog import (
    CURRENT_SCHEMA,
    CatalogSigningError,
    base64url,
    load_records_bytes,
    parse_timestamp,
    safe_id,
)


MAX_CATALOG_VALIDITY = timedelta(days=14)
MAX_LEAF_VALIDITY = timedelta(days=90)
MAX_ARTIFACT_HEADER_BYTES = 1024 * 1024
MAX_ARTIFACT_FILES = 2048
MAX_ARTIFACT_FILE_BYTES = 8 * 1024 * 1024
SEMANTIC_VERSION = re.compile(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){1,3}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
ARTIFACT_FILENAME = re.compile(r"[a-z0-9][a-z0-9._-]{2,127}\.fwea1\Z")


class SignedCatalogReleaseError(RuntimeError):
    """A release candidate does not meet the curated-catalog contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SignedCatalogReleaseError(message)


def _object(value: Any, *, keys: set[str], label: str) -> dict[str, Any]:
    _require(isinstance(value, dict) and set(value) == keys, f"{label} has unexpected fields")
    return value


def _base64url(value: Any, *, byte_count: int, label: str) -> bytes:
    _require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]+", value) is not None, f"{label} is not base64url")
    try:
        decoded = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except (ValueError, TypeError) as error:
        raise SignedCatalogReleaseError(f"{label} is not base64url") from error
    _require(len(decoded) == byte_count and base64url(decoded) == value, f"{label} has an invalid length or encoding")
    return decoded


def _timestamp(value: Any, *, label: str) -> datetime:
    _require(isinstance(value, str), f"{label} is not a timestamp")
    try:
        return parse_timestamp(value)
    except CatalogSigningError as error:
        raise SignedCatalogReleaseError(f"{label} is not a strict RFC3339 UTC timestamp") from error


def _safe_identifier(value: Any, *, label: str, maximum_length: int = 96) -> str:
    _require(isinstance(value, str), f"{label} is not an identifier")
    try:
        return safe_id(value, maximum_length)
    except CatalogSigningError as error:
        raise SignedCatalogReleaseError(f"{label} is not a safe identifier") from error


def _marketing_version(path: Path) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot read release configuration: {error}") from error
    matches = []
    for line in lines:
        match = re.fullmatch(r"\s*FLOORP_MARKETING_VERSION\s*=\s*([^\s#]+)\s*(?:#.*)?", line)
        if match:
            matches.append(match.group(1))
    _require(len(matches) == 1 and SEMANTIC_VERSION.fullmatch(matches[0]) is not None, "release configuration has no unique semantic FLOORP_MARKETING_VERSION")
    return matches[0]


def _read_root_public_key(path: Path) -> bytes:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot read root public key: {error}") from error
    _require(re.fullmatch(rb"[A-Za-z0-9_-]{43}\n", raw) is not None, "root public key is not canonical base64url")
    return _base64url(raw[:-1].decode("ascii"), byte_count=32, label="root public key")


def _verify_signatures(
    *,
    catalog_data: bytes,
    root_public_key: bytes,
    expected_root_public_key_sha256: str,
    now: datetime,
) -> tuple[dict[str, Any], str]:
    _require(
        SHA256.fullmatch(expected_root_public_key_sha256) is not None,
        "expected root public-key SHA-256 must be lowercase hexadecimal",
    )
    _require(
        hashlib.sha256(root_public_key).hexdigest() == expected_root_public_key_sha256,
        "root public key does not match the protected release trust anchor",
    )
    try:
        root = strict_json_loads(catalog_data, label="signed catalog")
    except (ValueError, IngestionError) as error:
        raise SignedCatalogReleaseError(f"signed catalog is not strict JSON: {error}") from error
    _require(canonical_json(root) == catalog_data, "signed catalog is not canonical JSON")
    catalog = _object(
        root,
        keys={
            "schemaVersion", "catalogID", "sequence", "issuedAt", "expiresAt", "audience",
            "signingKey", "packages", "revocations", "signature",
        },
        label="signed catalog",
    )
    _require(catalog["schemaVersion"] == CURRENT_SCHEMA, "signed catalog schema is not current")
    _safe_identifier(catalog["catalogID"], label="catalog ID")
    _require(isinstance(catalog["sequence"], int) and not isinstance(catalog["sequence"], bool) and catalog["sequence"] > 0, "catalog sequence is invalid")
    issued_at = _timestamp(catalog["issuedAt"], label="catalog issuedAt")
    expires_at = _timestamp(catalog["expiresAt"], label="catalog expiresAt")
    _require(issued_at <= expires_at and expires_at - issued_at <= MAX_CATALOG_VALIDITY, "catalog validity interval is invalid")
    _require(issued_at <= now <= expires_at, "catalog is not currently valid")

    signing_key = _object(
        catalog["signingKey"],
        keys={"keyID", "publicKey", "notBefore", "notAfter", "signature"},
        label="catalog signing key",
    )
    leaf_key_id = _safe_identifier(signing_key["keyID"], label="leaf key ID")
    leaf_public_key = _base64url(signing_key["publicKey"], byte_count=32, label="leaf public key")
    leaf_not_before = _timestamp(signing_key["notBefore"], label="leaf notBefore")
    leaf_not_after = _timestamp(signing_key["notAfter"], label="leaf notAfter")
    _require(leaf_not_before < leaf_not_after and leaf_not_after - leaf_not_before <= MAX_LEAF_VALIDITY, "leaf key validity interval is invalid")
    _require(leaf_not_before <= issued_at and leaf_not_after >= expires_at and leaf_not_before <= now <= leaf_not_after, "leaf key does not cover the catalog validity interval")
    leaf_signature = _base64url(signing_key["signature"], byte_count=64, label="leaf certificate signature")
    unsigned_leaf = dict(signing_key)
    unsigned_leaf.pop("signature")
    try:
        Ed25519PublicKey.from_public_bytes(root_public_key).verify(leaf_signature, canonical_json(unsigned_leaf))
    except (InvalidSignature, ValueError) as error:
        raise SignedCatalogReleaseError("leaf certificate signature is invalid") from error

    catalog_signature = _base64url(catalog["signature"], byte_count=64, label="catalog signature")
    unsigned_catalog = dict(catalog)
    unsigned_catalog.pop("signature")
    try:
        Ed25519PublicKey.from_public_bytes(leaf_public_key).verify(catalog_signature, canonical_json(unsigned_catalog))
    except (InvalidSignature, ValueError) as error:
        raise SignedCatalogReleaseError("catalog signature is invalid") from error
    return catalog, leaf_key_id


def _verify_audience(
    catalog: dict[str, Any],
    *,
    bundle_id: str,
    channel: str,
    marketing_version: str,
    catalog_id: str,
) -> None:
    _require(catalog["catalogID"] == catalog_id, "catalog ID does not match the release contract")
    audience = _object(
        catalog["audience"],
        keys={"bundleIDs", "minimumAppVersion", "channel"},
        label="catalog audience",
    )
    _require(audience["bundleIDs"] == [bundle_id], "catalog audience does not target exactly this app bundle")
    _require(audience["channel"] == channel, "catalog audience channel does not match the release contract")
    _require(audience["minimumAppVersion"] == marketing_version, "catalog minimum app version does not match the release configuration")


def _verify_revocations(value: Any, *, now: datetime) -> None:
    _require(isinstance(value, list) and len(value) <= 256, "catalog revocations are invalid")
    key_ids: set[str] = set()
    generations: set[tuple[str, str]] = set()
    for revocation in value:
        _require(isinstance(revocation, dict) and isinstance(revocation.get("kind"), str), "catalog revocation is invalid")
        if revocation["kind"] == "key":
            entry = _object(revocation, keys={"kind", "keyID", "effectiveAt"}, label="key revocation")
            key_id = _safe_identifier(entry["keyID"], label="revoked key ID")
            _require(key_id not in key_ids, "catalog revocations duplicate a key")
            key_ids.add(key_id)
        elif revocation["kind"] == "generation":
            entry = _object(
                revocation,
                keys={"kind", "extensionID", "generation", "effectiveAt"},
                label="generation revocation",
            )
            extension_id = entry["extensionID"]
            generation = entry["generation"]
            _require(isinstance(extension_id, str) and re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,127}", extension_id) is not None, "revoked extension ID is invalid")
            _require(isinstance(generation, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,47}", generation) is not None, "revoked generation is invalid")
            identity = (extension_id, generation)
            _require(identity not in generations, "catalog revocations duplicate a generation")
            generations.add(identity)
        else:
            raise SignedCatalogReleaseError("catalog revocation kind is unsupported")
        _require(_timestamp(entry["effectiveAt"], label="revocation effectiveAt") <= now, "catalog contains a future-dated revocation")


def _artifact_filename(record: dict[str, Any], *, artifact_origin: str) -> str:
    artifact_url = record["artifactURL"]
    _require(isinstance(artifact_url, str), "catalog artifact URL is invalid")
    try:
        parsed = urlsplit(artifact_url)
        expected = urlsplit(artifact_origin)
        parsed_port = parsed.port
        expected_port = expected.port
    except ValueError as error:
        raise SignedCatalogReleaseError("catalog artifact URL has an invalid port") from error
    _require(
        parsed.scheme == expected.scheme == "https"
        and parsed.hostname == expected.hostname
        and parsed_port == expected_port
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment,
        "catalog artifact URL is not the fixed bundled identity origin",
    )
    _require(expected.path.endswith("/"), "configured artifact origin must end in a slash")
    _require(parsed.path.startswith(expected.path), "catalog artifact URL is outside the fixed bundled identity path")
    filename = parsed.path[len(expected.path):]
    _require("/" not in filename and ARTIFACT_FILENAME.fullmatch(filename) is not None, "catalog artifact filename is unsafe")
    return filename


def _manifest_metadata_matches(manifest_data: bytes, record: dict[str, Any]) -> None:
    try:
        manifest = strict_json_loads(manifest_data, label="artifact manifest")
    except (ValueError, IngestionError) as error:
        raise SignedCatalogReleaseError(f"artifact manifest is not strict JSON: {error}") from error
    _require(isinstance(manifest, dict), "artifact manifest is not an object")
    metadata = record["metadata"]
    permissions: set[str] = set()
    hosts: set[str] = set()
    for field, destination in (
        ("permissions", permissions),
        ("optional_permissions", permissions),
        ("host_permissions", hosts),
        ("optional_host_permissions", hosts),
    ):
        values = manifest.get(field, [])
        _require(isinstance(values, list) and all(isinstance(value, str) for value in values), f"artifact manifest {field} is invalid")
        destination.update(values)
    _require(permissions == set(metadata["permissions"]), "catalog metadata permissions do not match the artifact manifest")
    _require(hosts == set(metadata["hostPermissions"]), "catalog metadata host permissions do not match the artifact manifest")


def _verify_artifact(path: Path, record: dict[str, Any]) -> None:
    _require(path.is_file() and not path.is_symlink(), f"artifact is missing or unsafe: {path.name}")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot read artifact {path.name}: {error}") from error
    _require(len(data) == record["artifactBytes"], f"artifact byte count does not match catalog: {path.name}")
    _require(sha256(data) == record["artifactSHA256"], f"artifact digest does not match catalog: {path.name}")
    _require(data.startswith(FWEA1_MAGIC) and len(data) >= len(FWEA1_MAGIC) + 4, f"artifact is not a complete FWEA1 envelope: {path.name}")
    header_size = struct.unpack(">I", data[len(FWEA1_MAGIC):len(FWEA1_MAGIC) + 4]
    )[0]
    header_start = len(FWEA1_MAGIC) + 4
    header_end = header_start + header_size
    _require(0 < header_size <= MAX_ARTIFACT_HEADER_BYTES and header_end <= len(data), f"artifact inventory length is invalid: {path.name}")
    header_data = data[header_start:header_end]
    try:
        header = strict_json_loads(header_data, label="artifact inventory")
    except ValueError as error:
        raise SignedCatalogReleaseError(f"artifact inventory is not strict JSON: {path.name}") from error
    _require(canonical_json(header) == header_data, f"artifact inventory is not canonical: {path.name}")
    inventory = _object(header, keys={"files"}, label="artifact inventory")
    files = inventory["files"]
    _require(isinstance(files, list) and 0 < len(files) <= MAX_ARTIFACT_FILES, f"artifact inventory file count is invalid: {path.name}")
    _require(sha256(header_data) == record["resourceInventorySHA256"], f"artifact inventory digest does not match catalog: {path.name}")
    offset = header_end
    paths: set[str] = set()
    prior_path: bytes | None = None
    manifest: bytes | None = None
    for entry in files:
        entry = _object(entry, keys={"path", "sha256", "size"}, label="artifact inventory entry")
        resource_path = entry["path"]
        _require(isinstance(resource_path, str), f"artifact inventory path is invalid: {path.name}")
        try:
            validate_path(resource_path)
        except RuntimeError as error:
            raise SignedCatalogReleaseError(f"artifact inventory path is unsafe: {path.name}") from error
        resource_path_bytes = resource_path.encode("utf-8")
        _require(resource_path not in paths and (prior_path is None or prior_path < resource_path_bytes), f"artifact inventory paths are duplicated or unsorted: {path.name}")
        paths.add(resource_path)
        prior_path = resource_path_bytes
        _require(isinstance(entry["size"], int) and not isinstance(entry["size"], bool) and 0 <= entry["size"] <= MAX_ARTIFACT_FILE_BYTES, f"artifact inventory size is invalid: {path.name}")
        _require(isinstance(entry["sha256"], str) and SHA256.fullmatch(entry["sha256"]) is not None, f"artifact inventory digest syntax is invalid: {path.name}")
        end = offset + entry["size"]
        _require(end <= len(data), f"artifact resource is truncated: {path.name}")
        resource = data[offset:end]
        _require(sha256(resource) == entry["sha256"], f"artifact resource digest is invalid: {path.name}")
        if resource_path == "manifest.json":
            manifest = resource
        offset = end
    _require(offset == len(data) and manifest is not None, f"artifact payload is incomplete: {path.name}")
    _require(sha256(manifest) == record["manifestSHA256"], f"artifact manifest digest does not match catalog: {path.name}")
    _manifest_metadata_matches(manifest, record)


def verify_release(
    *,
    catalog_root: Path,
    release_xcconfig: Path,
    expected_root_public_key_sha256: str,
    bundle_id: str,
    channel: str,
    catalog_id: str,
    expected_package_count: int,
    artifact_origin: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    _require(expected_package_count > 0, "expected package count must be positive")
    now = now or datetime.now(timezone.utc)
    _require(now.tzinfo is not None, "verification clock must be timezone-aware")
    catalog_root = catalog_root.resolve()
    artifact_directory = catalog_root / "Artifacts"
    signed_directory = artifact_directory / "Signed"
    try:
        catalog_data = (signed_directory / "catalog.json").read_bytes()
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot read signed catalog: {error}") from error
    root_public_key = _read_root_public_key(signed_directory / "root-public-key.txt")
    catalog, leaf_key_id = _verify_signatures(
        catalog_data=catalog_data,
        root_public_key=root_public_key,
        expected_root_public_key_sha256=expected_root_public_key_sha256,
        now=now,
    )
    marketing_version = _marketing_version(release_xcconfig)
    _verify_audience(
        catalog,
        bundle_id=bundle_id,
        channel=channel,
        marketing_version=marketing_version,
        catalog_id=catalog_id,
    )
    _verify_revocations(catalog["revocations"], now=now)
    try:
        catalog_records = load_records_bytes(canonical_json(catalog["packages"]), schema=CURRENT_SCHEMA)
        input_bytes = (catalog_root / "catalog-input.json").read_bytes()
        input_records = load_records_bytes(input_bytes, schema=CURRENT_SCHEMA)
    except (CatalogSigningError, IngestionError, OSError, ValueError) as error:
        raise SignedCatalogReleaseError(f"catalog records are invalid: {error}") from error
    _require(len(catalog_records) == expected_package_count, "signed catalog package count does not match the fixed release contract")
    _require(catalog_records == input_records, "signed catalog packages do not exactly match the reviewed catalog input")
    _require(all(record["metadata"]["minimumFloorpBuild"] == marketing_version for record in catalog_records), "package minimum build does not match the release configuration")

    expected_artifacts: set[str] = set()
    for record in catalog_records:
        filename = _artifact_filename(record, artifact_origin=artifact_origin)
        _require(filename not in expected_artifacts, "catalog maps multiple records to the same bundled artifact")
        expected_artifacts.add(filename)
        _verify_artifact(artifact_directory / filename, record)
    try:
        actual_artifacts = {
            path.name for path in artifact_directory.iterdir()
            if path.is_file() and path.suffix == ".fwea1"
        }
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot enumerate bundled artifacts: {error}") from error
    _require(actual_artifacts == expected_artifacts, "bundled artifact set does not exactly match the signed catalog")
    return {
        "catalogID": catalog["catalogID"],
        "catalogInputSHA256": sha256(input_bytes),
        "catalogSHA256": sha256(catalog_data),
        "catalogSchemaVersion": catalog["schemaVersion"],
        "expiresAt": catalog["expiresAt"],
        "issuedAt": catalog["issuedAt"],
        "leafKeyID": leaf_key_id,
        "marketingVersion": marketing_version,
        "packageCount": len(catalog_records),
        "rootPublicKeySHA256": sha256(root_public_key),
        "schema": 1,
        "sequence": catalog["sequence"],
        "status": "verified",
    }


def _write_new(path: Path, data: bytes) -> None:
    try:
        _require(path.is_absolute(), "release verification output must be an absolute path")
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as error:
        raise SignedCatalogReleaseError(f"cannot create release verification output: {error}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-root", required=True, type=Path)
    parser.add_argument("--release-xcconfig", required=True, type=Path)
    parser.add_argument("--expected-root-public-key-sha256", required=True)
    parser.add_argument("--bundle-id", default="app.floorp.Floorp")
    parser.add_argument("--channel", default="testflight")
    parser.add_argument("--catalog-id", default="floorp-ios-curated-testflight")
    parser.add_argument("--expected-package-count", default=1, type=int)
    parser.add_argument("--artifact-origin", default="https://catalog.floorp.invalid/fwea1/")
    parser.add_argument("--now")
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        now = _timestamp(arguments.now, label="verification clock") if arguments.now else None
        proof = verify_release(
            catalog_root=arguments.catalog_root,
            release_xcconfig=arguments.release_xcconfig,
            expected_root_public_key_sha256=arguments.expected_root_public_key_sha256,
            bundle_id=arguments.bundle_id,
            channel=arguments.channel,
            catalog_id=arguments.catalog_id,
            expected_package_count=arguments.expected_package_count,
            artifact_origin=arguments.artifact_origin,
            now=now,
        )
        encoded = canonical_json(proof)
        if arguments.output is not None:
            _write_new(arguments.output, encoded)
    except SignedCatalogReleaseError as error:
        print(f"signed curated catalog release verification failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(proof, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
