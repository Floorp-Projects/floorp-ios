"""TDD tests for the fail-closed protected production-QA entry point."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/run-floorp-notes-sync-production-qa.py"
QA_VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


RUN = load_module(SCRIPT, "floorp_notes_sync_production_qa_runner_test")
QA = load_module(QA_VALIDATOR, "floorp_notes_sync_production_qa_runner_validator_test")


def summary() -> dict[str, Any]:
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
            "operator_id": "operator",
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


class RunProductionQATests(unittest.TestCase):
    def environment(self) -> dict[str, str]:
        return {
            "FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL": "a",
            "FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD": "b",
            "FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL": "c",
            "FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD": "d",
            "GITHUB_ACTOR": "operator",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_JOB": "notes-sync-production-qa",
            "GITHUB_REPOSITORY": QA.REPOSITORY,
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "123456",
            "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
            "GITHUB_WORKFLOW_REF": f"{QA.REPOSITORY}/.github/workflows/ci.yml@0123456789abcdef0123456789abcdef01234567",
        }

    def test_missing_protected_secret_blocks_without_reading_a_local_account_path(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(RUN.main(["--summary", "/nonexistent/summary.json"]), 78)

    def test_exact_runtime_binding_is_required_before_acceptance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary_path = Path(directory) / "summary.json"
            summary_path.write_bytes(canonical(summary()))
            with patch.dict(os.environ, self.environment(), clear=False):
                self.assertEqual(RUN.main(["--summary", str(summary_path)]), 0)

            mismatched = self.environment()
            mismatched["GITHUB_SHA"] = "fedcba9876543210fedcba9876543210fedcba98"
            with patch.dict(os.environ, mismatched, clear=False):
                self.assertEqual(RUN.main(["--summary", str(summary_path)]), 78)


if __name__ == "__main__":
    unittest.main()
