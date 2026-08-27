"""Tests for the fail-closed P0 approval record used by external TestFlight."""

from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


MODULE_PATH = Path(__file__).parent.parent / "verify_curated_catalog_release_approval.py"
SPEC = importlib.util.spec_from_file_location("verify_curated_catalog_release_approval", MODULE_PATH)
assert SPEC and SPEC.loader
APPROVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPROVAL)


NOW = datetime(2026, 8, 27, 12, 0, tzinfo=timezone.utc)


def catalog_evidence() -> dict[str, object]:
    return {
        "catalogID": "floorp-ios-curated-testflight",
        "catalogInputSHA256": "a" * 64,
        "catalogSHA256": "b" * 64,
        "catalogSchemaVersion": 3,
        "expiresAt": "2026-08-28T00:00:00Z",
        "issuedAt": "2026-08-27T00:00:00Z",
        "leafKeyID": "catalog-leaf-2026-08",
        "marketingVersion": "0.3.0",
        "packageCount": 16,
        "rootPublicKeySHA256": "c" * 64,
        "schema": 1,
        "sequence": 9,
        "status": "verified",
    }


def approved_record() -> dict[str, object]:
    evidence = catalog_evidence()
    return {
        "schema": 1,
        "status": "approved",
        "catalogID": evidence["catalogID"],
        "catalogInputSHA256": evidence["catalogInputSHA256"],
        "catalogSHA256": evidence["catalogSHA256"],
        "catalogSchemaVersion": evidence["catalogSchemaVersion"],
        "rootPublicKeySHA256": evidence["rootPublicKeySHA256"],
        "leafKeyID": evidence["leafKeyID"],
        "sequence": evidence["sequence"],
        "marketingVersion": evidence["marketingVersion"],
        "packageCount": evidence["packageCount"],
        "issuedAt": evidence["issuedAt"],
        "expiresAt": evidence["expiresAt"],
        "approvals": {
            role: {
                "approvalID": f"evidence-{role}-20260827",
                "approvedAt": "2026-08-27T11:00:00Z",
            }
            for role in APPROVAL.APPROVAL_ROLES
        },
    }


class CuratedCatalogReleaseApprovalTests(unittest.TestCase):
    def write(self, directory: Path, name: str, value: dict[str, object]) -> Path:
        path = directory / name
        path.write_bytes(APPROVAL.canonical_json(value))
        return path

    def test_accepts_a_protected_digest_bound_approved_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            approval_path = self.write(root, "approval.json", approved_record())
            evidence_path = self.write(root, "catalog.json", catalog_evidence())
            result = APPROVAL.verify_approval(
                approval_path=approval_path,
                expected_approval_sha256=hashlib.sha256(approval_path.read_bytes()).hexdigest(),
                catalog_evidence_path=evidence_path,
                expected_package_count=16,
                now=NOW,
            )
            self.assertEqual(result["status"], "approved")
            self.assertEqual(result["sequence"], 9)
            self.assertEqual(len(result["approvalEvidenceIDs"]), 5)

    def test_rejects_pending_or_digest_substituted_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            pending = self.write(root, "pending.json", {
                "schema": 1,
                "status": "pending",
                "notes": "P0 owner records are not complete.",
            })
            evidence_path = self.write(root, "catalog.json", catalog_evidence())
            with self.assertRaisesRegex(APPROVAL.CuratedCatalogReleaseApprovalError, "pending"):
                APPROVAL.verify_approval(
                    approval_path=pending,
                    expected_approval_sha256=hashlib.sha256(pending.read_bytes()).hexdigest(),
                    catalog_evidence_path=evidence_path,
                    expected_package_count=16,
                    now=NOW,
                )
            approved = self.write(root, "approved.json", approved_record())
            with self.assertRaisesRegex(APPROVAL.CuratedCatalogReleaseApprovalError, "protected release digest"):
                APPROVAL.verify_approval(
                    approval_path=approved,
                    expected_approval_sha256="0" * 64,
                    catalog_evidence_path=evidence_path,
                    expected_package_count=16,
                    now=NOW,
                )

    def test_rejects_an_approval_for_a_different_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            record = approved_record()
            record["catalogSHA256"] = "d" * 64
            approval_path = self.write(root, "approval.json", record)
            evidence_path = self.write(root, "catalog.json", catalog_evidence())
            with self.assertRaisesRegex(APPROVAL.CuratedCatalogReleaseApprovalError, "catalogSHA256"):
                APPROVAL.verify_approval(
                    approval_path=approval_path,
                    expected_approval_sha256=hashlib.sha256(approval_path.read_bytes()).hexdigest(),
                    catalog_evidence_path=evidence_path,
                    expected_package_count=16,
                    now=NOW,
                )


if __name__ == "__main__":
    unittest.main()
