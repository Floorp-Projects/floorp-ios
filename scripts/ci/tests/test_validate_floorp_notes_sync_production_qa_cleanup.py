"""TDD tests for client-pair cleanup receipt binding."""

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
SCRIPT = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa-cleanup.py"
QA_SCRIPT = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


CLEANUP = load_module(SCRIPT, "floorp_notes_sync_cleanup_receipt_validator_test")
QA = load_module(QA_SCRIPT, "floorp_notes_sync_cleanup_receipt_qa_validator_test")


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def summary(receipt_sha: str) -> dict[str, Any]:
    return {
        "accounts": 2,
        "cases": [{"name": name, "passed": True} for name in QA.REQUIRED_CASES],
        "cleanup": {"accounts": True, "local_cache": True, "runner_temp": True, "simulator_keychain": True},
        "cleanup_receipt_sha256": receipt_sha,
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
            "operator_id": "operator",
            "roles": ["owner", "operations", "executor"],
        },
        "source": {
            "event": "workflow_dispatch",
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "job_name": "notes-sync-production-qa",
            "repository": QA.REPOSITORY,
            "workflow_path": ".github/workflows/floorp-notes-sync-production-qa.yml",
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def receipt() -> dict[str, Any]:
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


class ValidateCleanupReceiptTests(unittest.TestCase):
    def test_receipt_is_digest_and_source_bound(self) -> None:
        receipt_raw = canonical(receipt())
        summary_value = summary(hashlib.sha256(receipt_raw).hexdigest())
        CLEANUP.validate_receipt(receipt(), summary_value, receipt_raw)

    def test_missing_account_cleanup_or_digest_is_rejected(self) -> None:
        receipt_value = receipt()
        receipt_value["accounts"] = False
        receipt_raw = canonical(receipt_value)
        with self.assertRaises(CLEANUP.CleanupReceiptError):
            CLEANUP.validate_receipt(receipt_value, summary(hashlib.sha256(receipt_raw).hexdigest()), receipt_raw)

    def test_cli_rejects_tampered_receipt(self) -> None:
        receipt_raw = canonical(receipt())
        summary_raw = canonical(summary(hashlib.sha256(receipt_raw).hexdigest()))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary_path = root / "summary.json"
            receipt_path = root / "cleanup.json"
            summary_path.write_bytes(summary_raw)
            receipt_path.write_bytes(receipt_raw.replace(b'"accounts":true', b'"accounts":false'))
            self.assertEqual(
                CLEANUP.main(["--summary", str(summary_path), "--receipt", str(receipt_path)]),
                2,
            )


if __name__ == "__main__":
    unittest.main()
