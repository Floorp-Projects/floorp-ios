#!/usr/bin/env python3
"""Verify the non-secret P0 approval record before an external beta mutation.

The record is deliberately a committed, canonical, candidate-bound artifact.
It identifies approvals by opaque evidence IDs rather than people or secrets.
Its raw digest is separately held in the protected GitHub environment, so a
repository-only change cannot silently substitute an approval after review.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


WEBEXTENSIONS = Path(__file__).resolve().parents[1] / "webextensions"
if str(WEBEXTENSIONS) not in sys.path:
    sys.path.insert(0, str(WEBEXTENSIONS))

from ingest_extension import IngestionError, canonical_json, strict_json_loads  # noqa: E402
from sign_catalog import CatalogSigningError, parse_timestamp, safe_id  # noqa: E402


SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SEMANTIC_VERSION = re.compile(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){1,3}\Z")
PENDING_KEYS = {"schema", "status", "notes"}
APPROVED_SOLE_MAINTAINER_KEYS = {
    "schema",
    "status",
    "catalogID",
    "catalogInputSHA256",
    "catalogSHA256",
    "catalogSchemaVersion",
    "rootPublicKeySHA256",
    "leafKeyID",
    "sequence",
    "marketingVersion",
    "packageCount",
    "issuedAt",
    "expiresAt",
    "maintainerApproval",
}
CATALOG_EVIDENCE_KEYS = {
    "catalogID",
    "catalogInputSHA256",
    "catalogSHA256",
    "catalogSchemaVersion",
    "expiresAt",
    "issuedAt",
    "leafKeyID",
    "marketingVersion",
    "packageCount",
    "rootPublicKeySHA256",
    "schema",
    "sequence",
    "status",
}


class CuratedCatalogReleaseApprovalError(RuntimeError):
    """An external submission does not have the required P0 approval."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CuratedCatalogReleaseApprovalError(message)


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _timestamp(value: Any, *, label: str) -> datetime:
    _require(isinstance(value, str), f"{label} must be a timestamp")
    try:
        return parse_timestamp(value)
    except CatalogSigningError as error:
        raise CuratedCatalogReleaseApprovalError(f"{label} must use RFC3339 UTC seconds") from error


def _digest(value: Any, *, label: str) -> str:
    _require(isinstance(value, str) and SHA256.fullmatch(value) is not None, f"{label} must be a SHA-256 digest")
    return value


def _identifier(value: Any, *, label: str, maximum_length: int = 128) -> str:
    _require(isinstance(value, str), f"{label} must be a safe identifier")
    try:
        return safe_id(value, maximum_length)
    except CatalogSigningError as error:
        raise CuratedCatalogReleaseApprovalError(f"{label} must be a safe identifier") from error


def _read_canonical(path: Path, *, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        data = path.read_bytes()
        value = strict_json_loads(data, label=label)
    except (OSError, ValueError, IngestionError) as error:
        raise CuratedCatalogReleaseApprovalError(f"cannot read {label}: {error}") from error
    _require(isinstance(value, dict), f"{label} must be an object")
    _require(canonical_json(value) == data, f"{label} must be canonical JSON")
    return value, data


def _validate_approval(
    approval: dict[str, Any],
    *,
    catalog_evidence: dict[str, Any],
    expected_package_count: int,
    now: datetime,
) -> dict[str, Any]:
    _require(approval.get("schema") == 2, "approval record schema is unsupported")
    status = approval.get("status")
    if status == "pending":
        _require(set(approval) == PENDING_KEYS, "pending approval record has unexpected fields")
        _require(isinstance(approval.get("notes"), str) and approval["notes"].strip(), "pending approval record has no notes")
        raise CuratedCatalogReleaseApprovalError("approval record is pending")
    _require(status == "approved", "approval record is not approved")
    _require(set(approval) == APPROVED_SOLE_MAINTAINER_KEYS, "approved approval record has unexpected fields")
    _require(catalog_evidence.get("status") == "verified", "catalog evidence is not verified")
    _require(set(catalog_evidence) == CATALOG_EVIDENCE_KEYS, "catalog evidence has unexpected fields")

    for field in ("catalogInputSHA256", "catalogSHA256", "rootPublicKeySHA256"):
        _require(
            _digest(approval[field], label=f"approval {field}") == _digest(
                catalog_evidence[field], label=f"catalog evidence {field}"
            ),
            f"approval {field} does not match the verified catalog",
        )
    _require(
        _identifier(approval["catalogID"], label="approval catalogID", maximum_length=96)
        == _identifier(catalog_evidence["catalogID"], label="catalog evidence catalogID", maximum_length=96),
        "approval catalog ID does not match the verified catalog",
    )
    _require(
        _identifier(approval["leafKeyID"], label="approval leafKeyID", maximum_length=96)
        == _identifier(catalog_evidence["leafKeyID"], label="catalog evidence leafKeyID", maximum_length=96),
        "approval leaf key does not match the verified catalog",
    )
    _require(
        isinstance(approval["catalogSchemaVersion"], int)
        and approval["catalogSchemaVersion"] == 3
        and approval["catalogSchemaVersion"] == catalog_evidence["catalogSchemaVersion"],
        "approval catalog schema does not match the current verified catalog",
    )
    _require(
        isinstance(approval["sequence"], int)
        and approval["sequence"] > 0
        and approval["sequence"] == catalog_evidence["sequence"],
        "approval sequence does not match the verified catalog",
    )
    _require(
        isinstance(approval["packageCount"], int)
        and approval["packageCount"] == expected_package_count
        and approval["packageCount"] == catalog_evidence["packageCount"],
        "approval package count does not match the fixed release contract",
    )
    _require(
        isinstance(approval["marketingVersion"], str)
        and SEMANTIC_VERSION.fullmatch(approval["marketingVersion"]) is not None
        and approval["marketingVersion"] == catalog_evidence["marketingVersion"],
        "approval marketing version does not match the verified catalog",
    )
    issued_at = _timestamp(approval["issuedAt"], label="approval issuedAt")
    expires_at = _timestamp(approval["expiresAt"], label="approval expiresAt")
    _require(
        issued_at <= expires_at
        and approval["issuedAt"] == catalog_evidence["issuedAt"]
        and approval["expiresAt"] == catalog_evidence["expiresAt"]
        and issued_at <= now <= expires_at,
        "approval validity does not match the current verified catalog",
    )
    item = approval["maintainerApproval"]
    _require(
        isinstance(item, dict) and set(item) == {"approvalID", "approvedAt"},
        "sole-maintainer approval is invalid",
    )
    evidence_id = _identifier(item["approvalID"], label="sole-maintainer approval ID")
    approved_at = _timestamp(item["approvedAt"], label="sole-maintainer approval timestamp")
    _require(approved_at <= now and approved_at <= expires_at, "sole-maintainer approval is not currently valid")
    evidence_ids = {evidence_id}
    return {
        "approvalEvidenceIDs": sorted(evidence_ids),
        "catalogID": approval["catalogID"],
        "catalogSHA256": approval["catalogSHA256"],
        "sequence": approval["sequence"],
        "status": "approved",
    }


def verify_approval(
    *,
    approval_path: Path,
    expected_approval_sha256: str,
    catalog_evidence_path: Path,
    expected_package_count: int,
    now: datetime | None = None,
) -> dict[str, Any]:
    _require(SHA256.fullmatch(expected_approval_sha256) is not None, "expected approval SHA-256 is invalid")
    _require(expected_package_count > 0, "expected package count must be positive")
    current = now or datetime.now(timezone.utc)
    _require(current.tzinfo is not None, "verification clock must be timezone-aware")
    approval, approval_data = _read_canonical(approval_path, label="approval record")
    _require(_sha256(approval_data) == expected_approval_sha256, "approval record does not match the protected release digest")
    catalog_evidence, _ = _read_canonical(catalog_evidence_path, label="catalog evidence")
    result = _validate_approval(
        approval,
        catalog_evidence=catalog_evidence,
        expected_package_count=expected_package_count,
        now=current,
    )
    return {"approvalSHA256": expected_approval_sha256, **result}


def _write_new(path: Path, value: dict[str, Any]) -> None:
    _require(path.is_absolute(), "approval verification output must be an absolute path")
    data = canonical_json(value)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as error:
        raise CuratedCatalogReleaseApprovalError(f"cannot write approval evidence: {error}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approval", required=True, type=Path)
    parser.add_argument("--expected-approval-sha256", required=True)
    parser.add_argument("--catalog-evidence", required=True, type=Path)
    parser.add_argument("--expected-package-count", required=True, type=int)
    parser.add_argument("--now")
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        now = _timestamp(arguments.now, label="verification clock") if arguments.now else None
        evidence = verify_approval(
            approval_path=arguments.approval,
            expected_approval_sha256=arguments.expected_approval_sha256,
            catalog_evidence_path=arguments.catalog_evidence,
            expected_package_count=arguments.expected_package_count,
            now=now,
        )
        if arguments.output is not None:
            _write_new(arguments.output, evidence)
    except CuratedCatalogReleaseApprovalError as error:
        print(f"curated catalog P0 approval verification failed: {error}", file=sys.stderr)
        return 2
    print(canonical_json(evidence).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
