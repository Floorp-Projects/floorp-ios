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


class ValidateFloorpNotesSyncProductionEnablementTests(unittest.TestCase):
    def test_exact_phase1_binding_and_no_public_release_are_accepted(self) -> None:
        summary = phase1_summary()
        raw = canonical(summary)
        record = {
            "app_store_submission": False,
            "approved": True,
            "configuration": "production-sync-enabled-qa",
            "enablement_validator_sha256": hashlib.sha256(ENABLEMENT.ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
            "environment": ENABLEMENT.ENVIRONMENT,
            "fxa_configuration": "FxAConfig.Server.release",
            "operator_id": summary["self_attestation"]["operator_id"],
            "phase": "production-sync-enablement",
            "phase1_summary_sha256": hashlib.sha256(raw).hexdigest(),
            "production_qa_validator_sha256": hashlib.sha256(ENABLEMENT.VALIDATOR_PATH.read_bytes()).hexdigest(),
            "public_release": False,
            "repository": ENABLEMENT.REPOSITORY,
            "secret_scan_receipt_sha256": "b" * 64,
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
        self.assertEqual(ENABLEMENT.validate_enablement(record, summary, raw), record)

    def test_public_distribution_and_wrong_phase1_digest_are_rejected(self) -> None:
        summary = phase1_summary()
        raw = canonical(summary)
        record = {
            "app_store_submission": False,
            "approved": True,
            "configuration": "production-sync-enabled-qa",
            "enablement_validator_sha256": hashlib.sha256(ENABLEMENT.ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
            "environment": ENABLEMENT.ENVIRONMENT,
            "fxa_configuration": "FxAConfig.Server.release",
            "operator_id": summary["self_attestation"]["operator_id"],
            "phase": "production-sync-enablement",
            "phase1_summary_sha256": hashlib.sha256(raw).hexdigest(),
            "production_qa_validator_sha256": hashlib.sha256(ENABLEMENT.VALIDATOR_PATH.read_bytes()).hexdigest(),
            "public_release": False,
            "repository": ENABLEMENT.REPOSITORY,
            "secret_scan_receipt_sha256": "b" * 64,
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
        for field, value in (("public_release", True), ("app_store_submission", True), ("phase1_summary_sha256", "0" * 64)):
            with self.subTest(field=field):
                altered = dict(record)
                altered[field] = value
                with self.assertRaises(ENABLEMENT.EnablementError):
                    ENABLEMENT.validate_enablement(altered, summary, raw)

    def test_main_rechecks_phase1_summary_before_accepting_record(self) -> None:
        summary = phase1_summary()
        raw = canonical(summary)
        record = {
            "app_store_submission": False,
            "approved": True,
            "configuration": "production-sync-enabled-qa",
            "enablement_validator_sha256": hashlib.sha256(ENABLEMENT.ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
            "environment": ENABLEMENT.ENVIRONMENT,
            "fxa_configuration": "FxAConfig.Server.release",
            "operator_id": summary["self_attestation"]["operator_id"],
            "phase": "production-sync-enablement",
            "phase1_summary_sha256": hashlib.sha256(raw).hexdigest(),
            "production_qa_validator_sha256": hashlib.sha256(ENABLEMENT.VALIDATOR_PATH.read_bytes()).hexdigest(),
            "public_release": False,
            "repository": ENABLEMENT.REPOSITORY,
            "secret_scan_receipt_sha256": "b" * 64,
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
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phase1_path = root / "phase1.json"
            record_path = root / "enablement.json"
            phase1_path.write_bytes(raw)
            record_path.write_bytes(canonical(record))
            self.assertEqual(ENABLEMENT.main(["--phase1-summary", str(phase1_path), "--enablement-record", str(record_path)]), 0)


if __name__ == "__main__":
    unittest.main()
