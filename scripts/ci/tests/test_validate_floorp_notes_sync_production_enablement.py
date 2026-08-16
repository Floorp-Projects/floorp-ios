"""TDD tests for the gated, non-distributed Phase 2 enablement record."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-production-enablement.py"
QA_VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


ENABLEMENT = load_module(VALIDATOR, "floorp_notes_sync_enablement_validator_test")
QA = load_module(QA_VALIDATOR, "floorp_notes_sync_qa_validator_for_enablement_test")


def phase1_summary() -> dict[str, Any]:
    return {
        "accounts": 2,
        "cases": [{"name": name, "passed": True} for name in QA.REQUIRED_CASES],
        "cleanup": {"accounts": True, "local_cache": True, "runner_temp": True, "simulator_keychain": True},
        "cleanup_receipt_sha256": "a" * 64,
        "clients": ["desktop", "mobile"],
        "environment": QA.ENVIRONMENT,
        "invariants": {name: True for name in QA.REQUIRED_INVARIANTS},
        "network": {
            "direct_rest_used": False,
            "hosts": list(QA.APPROVED_HOSTS),
            "metadata_only": True,
            "tls_verified": True,
            "wire_protocol": "sync15",
        },
        "phase": "production-qa",
        "phase_2_enablement_ready": True,
        "public_release": False,
        "schema_version": 1,
        "self_attestation": {
            "approved": True,
            "environment": QA.ENVIRONMENT,
            "operator_id": "test-operator",
            "roles": ["owner", "operations", "executor"],
        },
        "source": {
            "event": "workflow_dispatch",
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "job_name": "notes-sync-production-qa",
            "repository": QA.REPOSITORY,
            "workflow_path": ".github/workflows/ci.yml",
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def cleanup_receipt() -> dict[str, Any]:
    return {
        "accounts": True,
        "coordination_root": True,
        "environment": QA.ENVIRONMENT,
        "local_cache": True,
        "phase": "production-qa",
        "runner_temp": True,
        "schema_version": 1,
        "simulator_keychain": True,
        "source": {
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "repository": QA.REPOSITORY,
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def secret_scan_receipt() -> dict[str, Any]:
    return {
        "job_name": "notes-sync-production-qa",
        "marker_set_sha256": ENABLEMENT.SECRET_SCAN.MARKER_SET_SHA256,
        "passed": True,
        "repository": QA.REPOSITORY,
        "scan_method": ENABLEMENT.SECRET_SCAN.SCAN_METHOD,
        "scan_passed": True,
        "secret_env_names": list(ENABLEMENT.SECRET_SCAN.SECRET_ENV_NAMES),
        "schema_version": 1,
        "scope": list(ENABLEMENT.SECRET_SCAN.SCOPE),
        "target_digests": [
            {"artifact_sha256": "0" * 64, "byte_count": 1, "file_count": 1, "name": name, "sha256": "0" * 64}
            for name in sorted(ENABLEMENT.SECRET_SCAN.REQUIRED_TARGETS)
        ],
        "source": {
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "workflow_path": ENABLEMENT.SECRET_SCAN.WORKFLOW_PATH,
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def materialize_targets(root: Path) -> list[Path]:
    targets = [
        root / "qa-summary.json",
        root / "cleanup-receipt.json",
        root / "floorp-notes-sync-two-client.xcresult",
        root / "xcodebuild.log",
        root / "desktop.log",
        root / "production-qa-capability.json",
        root / "production-qa.xcconfig",
        root / "self-attestation.jsonl",
        root / "review-receipt.json",
        root / "pr-metadata.json",
        root / "reviews-metadata.json",
        root / "ruleset-metadata.json",
    ]
    targets[2].mkdir()
    (targets[2] / "result").write_text("safe\n")
    for target in (*targets[:2], *targets[3:]):
        target.write_text("safe\n")
    return targets


def test_inputs(root: Path) -> tuple[dict[str, Any], bytes, bytes, bytes, list[Path]]:
    targets = materialize_targets(root)
    cleanup_raw = canonical(cleanup_receipt())
    summary = phase1_summary()
    summary["cleanup_receipt_sha256"] = hashlib.sha256(cleanup_raw).hexdigest()
    summary_raw = canonical(summary)
    scan = secret_scan_receipt()
    scan["target_digests"] = [ENABLEMENT.SECRET_SCAN.digest_target(target) for target in targets]
    secret_scan_raw = canonical(scan)
    return summary, summary_raw, cleanup_raw, secret_scan_raw, targets


def enablement_record(
    summary: dict[str, Any],
    summary_raw: bytes,
    cleanup_raw: bytes,
    secret_scan_raw: bytes,
) -> dict[str, Any]:
    return {
        "app_store_submission": False,
        "approved": True,
        "configuration": "production-sync-enabled-qa",
        "cleanup_receipt_sha256": hashlib.sha256(cleanup_raw).hexdigest(),
        "cleanup_validator_sha256": hashlib.sha256(ENABLEMENT.CLEANUP_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "enablement_validator_sha256": hashlib.sha256(ENABLEMENT.ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "environment": ENABLEMENT.ENVIRONMENT,
        "fxa_configuration": "FxAConfig.Server.release",
        "operator_id": summary["self_attestation"]["operator_id"],
        "phase": "production-sync-enablement",
        "phase1_summary_sha256": hashlib.sha256(summary_raw).hexdigest(),
        "production_qa_validator_sha256": hashlib.sha256(ENABLEMENT.VALIDATOR_PATH.read_bytes()).hexdigest(),
        "public_release": False,
        "repository": ENABLEMENT.REPOSITORY,
        "secret_scan_receipt_sha256": hashlib.sha256(secret_scan_raw).hexdigest(),
        "secret_scan_validator_sha256": hashlib.sha256(ENABLEMENT.SECRET_SCAN_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "schema_version": 1,
        "source_head_sha": summary["source"]["head_sha"],
        "testflight_distribution": False,
        "wire_protocol": "sync15",
        "workflow_event": "workflow_dispatch",
        "workflow_job": "notes-sync-production-enablement",
        "workflow_path": ".github/workflows/ci.yml",
        "workflow_run_attempt": summary["source"]["workflow_run_attempt"],
        "workflow_run_id": summary["source"]["workflow_run_id"],
    }


class ValidateFloorpNotesSyncProductionEnablementTests(unittest.TestCase):
    def waived_record(
        self, merge_audit_raw: bytes, review_receipt_raw: bytes
    ) -> dict[str, Any]:
        return {
            "app_store_submission": False,
            "approved": True,
            "audit_endpoint_unavailable": True,
            "audit_source": "github-org-audit-log-unavailable-owner-waived",
            "configuration": "production-sync-enabled-qa",
            "enablement_validator_sha256": hashlib.sha256(
                (ROOT / "scripts/ci/validate-floorp-notes-sync-production-enablement.py").read_bytes()
            ).hexdigest(),
            "environment": ENABLEMENT.ENVIRONMENT,
            "fxa_configuration": "FxAConfig.Server.release",
            "guarded_merge_run_id": 123,
            "live_qa": "owner-waived-not-performed",
            "live_qa_waiver_approved_at_utc": "2026-08-16T00:00:00Z",
            "live_qa_waiver_operator_id": "test-operator",
            "live_qa_waiver_plan_hash": "c" * 64,
            "merge_audit_sha256": hashlib.sha256(merge_audit_raw).hexdigest(),
            "no_data_loss_claim": False,
            "operator_id": "test-operator",
            "phase": "production-sync-enablement",
            "phase1_summary_sha256": None,
            "public_release": False,
            "repository": ENABLEMENT.REPOSITORY,
            "review_receipt_sha256": hashlib.sha256(review_receipt_raw).hexdigest(),
            "schema_version": 2,
            "source_head_sha": "1" * 40,
            "testflight_distribution": False,
            "wire_protocol": "sync15",
            "workflow_event": "workflow_dispatch",
            "workflow_job": "notes-sync-production-enablement-waived",
            "workflow_path": ".github/workflows/ci.yml",
            "workflow_run_attempt": 1,
            "workflow_run_id": 999,
        }

    def waived_inputs(self) -> tuple[bytes, bytes, bytes, bytes]:
        merge_audit = {
            "admin_bypass_used": None,
            "audit_bypass_event_count": None,
            "audit_endpoint_unavailable": True,
            "audit_event_count": 0,
            "audit_event_id_sha256": None,
            "audit_event_timestamp": None,
            "audit_projection_sha256": None,
            "audit_source": "github-org-audit-log-unavailable-owner-waived",
            "schema_version": 3,
        }
        merge_audit_raw = json.dumps(
            merge_audit, separators=(",", ":"), sort_keys=True
        ).encode() + b"\n"
        review_receipt_raw = json.dumps(
            {
                "merge_audit_sha256": hashlib.sha256(merge_audit_raw).hexdigest(),
                "source_workflow_run_id": 123,
                "audit_source": "github-org-audit-log-unavailable-owner-waived",
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode() + b"\n"
        live_qa_waiver_raw = json.dumps(
            {
                "approved_at_utc": "2026-08-16T00:00:00Z",
                "operator_id": "test-operator",
                "plan_hash": "c" * 64,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode() + b"\n"
        binding_raw = json.dumps(
            {"combined_plan_hash": "c" * 64},
            separators=(",", ":"),
            sort_keys=True,
        ).encode() + b"\n"
        return review_receipt_raw, merge_audit_raw, live_qa_waiver_raw, binding_raw

    def env(self) -> dict[str, str]:
        return {
            "FLOORP_TODO20_GUARDED_MERGE_RUN_ID": "123",
            "GITHUB_SHA": "1" * 40,
            "GITHUB_ACTOR": "test-operator",
        }

    def test_waived_enablement_record_is_valid(self) -> None:
        review_receipt_raw, merge_audit_raw, live_qa_waiver_raw, binding_raw = self.waived_inputs()
        with patch.dict(ENABLEMENT.os.environ, self.env(), clear=False):
            ENABLEMENT.validate_waived_enablement(
                self.waived_record(merge_audit_raw, review_receipt_raw),
                review_receipt_raw,
                merge_audit_raw,
                live_qa_waiver_raw,
                binding_raw,
            )

    def test_waived_enablement_rejects_phase1_summary_binding(self) -> None:
        review_receipt_raw, merge_audit_raw, live_qa_waiver_raw, binding_raw = self.waived_inputs()
        record = self.waived_record(merge_audit_raw, review_receipt_raw)
        record["phase1_summary_sha256"] = "a" * 64
        with patch.dict(ENABLEMENT.os.environ, self.env(), clear=False):
            with self.assertRaises(ENABLEMENT.EnablementError):
                ENABLEMENT.validate_waived_enablement(
                    record,
                    review_receipt_raw,
                    merge_audit_raw,
                    live_qa_waiver_raw,
                    binding_raw,
                )

    def test_waived_enablement_rejects_live_qa_waiver_plan_mismatch(self) -> None:
        review_receipt_raw, merge_audit_raw, live_qa_waiver_raw, binding_raw = self.waived_inputs()
        record = self.waived_record(merge_audit_raw, review_receipt_raw)
        record["live_qa_waiver_plan_hash"] = "f" * 64
        with patch.dict(ENABLEMENT.os.environ, self.env(), clear=False):
            with self.assertRaises(ENABLEMENT.EnablementError):
                ENABLEMENT.validate_waived_enablement(
                    record,
                    review_receipt_raw,
                    merge_audit_raw,
                    live_qa_waiver_raw,
                    binding_raw,
                )

    def test_waived_enablement_rejects_mismatched_review_receipt_digest(self) -> None:
        review_receipt_raw, merge_audit_raw, live_qa_waiver_raw, binding_raw = self.waived_inputs()
        record = self.waived_record(merge_audit_raw, review_receipt_raw)
        record["merge_audit_sha256"] = "e" * 64
        with patch.dict(ENABLEMENT.os.environ, self.env(), clear=False):
            with self.assertRaises(ENABLEMENT.EnablementError):
                ENABLEMENT.validate_waived_enablement(
                    record,
                    review_receipt_raw,
                    merge_audit_raw,
                    live_qa_waiver_raw,
                    binding_raw,
                )
    def test_exact_phase1_binding_and_no_public_release_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary, summary_raw, cleanup_raw, secret_scan_raw, targets = test_inputs(Path(directory))
            record = enablement_record(summary, summary_raw, cleanup_raw, secret_scan_raw)
            self.assertEqual(
                ENABLEMENT.validate_enablement(record, summary, summary_raw, cleanup_raw, secret_scan_raw, targets),
                record,
            )

    def test_public_distribution_and_wrong_phase1_digest_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary, summary_raw, cleanup_raw, secret_scan_raw, targets = test_inputs(Path(directory))
            record = enablement_record(summary, summary_raw, cleanup_raw, secret_scan_raw)
            for field, value in (("public_release", True), ("app_store_submission", True), ("phase1_summary_sha256", "0" * 64)):
                with self.subTest(field=field):
                    altered = dict(record)
                    altered[field] = value
                    with self.assertRaises(ENABLEMENT.EnablementError):
                        ENABLEMENT.validate_enablement(altered, summary, summary_raw, cleanup_raw, secret_scan_raw, targets)

    def test_main_rechecks_phase1_summary_before_accepting_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary, raw, cleanup_raw, secret_scan_raw, targets = test_inputs(root)
            phase1_path = root / "phase1.json"
            cleanup_path = root / "cleanup.json"
            secret_scan_path = root / "secret-scan.json"
            record_path = root / "enablement.json"
            record = enablement_record(summary, raw, cleanup_raw, secret_scan_raw)
            phase1_path.write_bytes(raw)
            cleanup_path.write_bytes(cleanup_raw)
            secret_scan_path.write_bytes(secret_scan_raw)
            record_path.write_bytes(canonical(record))
            self.assertEqual(
                ENABLEMENT.main(
                    [
                        "--phase1-summary", str(phase1_path),
                        "--cleanup-receipt", str(cleanup_path),
                        "--secret-scan-receipt", str(secret_scan_path),
                        "--secret-scan-target", str(targets[0]),
                        "--secret-scan-target", str(targets[1]),
                        "--secret-scan-target", str(targets[2]),
                        "--secret-scan-target", str(targets[3]),
                        "--secret-scan-target", str(targets[4]),
                        "--secret-scan-target", str(targets[5]),
                        "--secret-scan-target", str(targets[6]),
                        "--secret-scan-target", str(targets[7]),
                        "--secret-scan-target", str(targets[8]),
                        "--secret-scan-target", str(targets[9]),
                        "--secret-scan-target", str(targets[10]),
                        "--secret-scan-target", str(targets[11]),
                        "--enablement-record", str(record_path),
                    ]
                ),
                0,
            )


if __name__ == "__main__":
    unittest.main()
