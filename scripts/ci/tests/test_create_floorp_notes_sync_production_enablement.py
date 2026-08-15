"""TDD tests for the post-QA, non-distributed enablement record."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/create-floorp-notes-sync-production-enablement.py"
QA_VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


CREATE = load_module(SCRIPT, "floorp_notes_sync_enablement_creation_test")
QA = load_module(QA_VALIDATOR, "floorp_notes_sync_enablement_creation_qa_test")


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


def secret_scan_receipt() -> dict[str, Any]:
    return {
        "job_name": "notes-sync-production-qa",
        "marker_set_sha256": CREATE.SECRET_SCAN.MARKER_SET_SHA256,
        "passed": True,
        "repository": QA.REPOSITORY,
        "schema_version": 1,
        "scope": [
            "qa-summary",
            "cleanup-receipt",
            "xcresult",
            "xcodebuild-log",
            "process-argv-environment-markers",
        ],
        "target_digests": [
            {"byte_count": 1, "file_count": 1, "name": name, "sha256": "0" * 64}
            for name in (
                "qa-summary.json",
                "cleanup-receipt.json",
                "floorp-notes-sync-two-client.xcresult",
                "xcodebuild.log",
            )
        ],
        "source": {
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "workflow_path": ".github/workflows/ci.yml",
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def cleanup_receipt() -> dict[str, Any]:
    return {
        "accounts": True,
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


class CreateProductionEnablementTests(unittest.TestCase):
    def environment(self) -> dict[str, str]:
        return {
            "FLOORP_NOTES_SYNC_ENABLEMENT_APPROVED": "1",
            "GITHUB_ACTOR": "operator",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_JOB": "notes-sync-production-enablement",
            "GITHUB_REPOSITORY": QA.REPOSITORY,
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "123456",
            "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
            "GITHUB_WORKFLOW_REF": f"{QA.REPOSITORY}/.github/workflows/ci.yml@0123456789abcdef0123456789abcdef01234567",
        }

    def test_phase1_summary_produces_non_distributed_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phase1 = root / "summary.json"
            cleanup = root / "cleanup.json"
            scan = root / "secret-scan.json"
            output = root / "enablement.json"
            cleanup_raw = canonical(cleanup_receipt())
            summary_value = summary()
            summary_value["cleanup_receipt_sha256"] = hashlib.sha256(cleanup_raw).hexdigest()
            phase1.write_bytes(canonical(summary_value))
            cleanup.write_bytes(cleanup_raw)
            scan.write_bytes(canonical(secret_scan_receipt()))
            with patch.dict(os.environ, self.environment(), clear=False):
                self.assertEqual(
                    CREATE.main(
                        [
                            "--phase1-summary",
                            str(phase1),
                            "--cleanup-receipt",
                            str(cleanup),
                            "--secret-scan-receipt",
                            str(scan),
                            "--output",
                            str(output),
                        ]
                    ),
                    0,
                )
            record = json.loads(output.read_text())
            self.assertEqual(record["configuration"], "production-sync-enabled-qa")
            self.assertFalse(record["public_release"])
            self.assertFalse(record["app_store_submission"])
            self.assertFalse(record["testflight_distribution"])

    def test_missing_protected_approval_blocks_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phase1 = root / "summary.json"
            cleanup = root / "cleanup.json"
            scan = root / "secret-scan.json"
            output = root / "enablement.json"
            cleanup_raw = canonical(cleanup_receipt())
            summary_value = summary()
            summary_value["cleanup_receipt_sha256"] = hashlib.sha256(cleanup_raw).hexdigest()
            phase1.write_bytes(canonical(summary_value))
            cleanup.write_bytes(cleanup_raw)
            scan.write_bytes(canonical(secret_scan_receipt()))
            environment = self.environment()
            environment.pop("FLOORP_NOTES_SYNC_ENABLEMENT_APPROVED")
            with patch.dict(os.environ, environment, clear=False):
                self.assertEqual(
                    CREATE.main(
                        [
                            "--phase1-summary",
                            str(phase1),
                            "--cleanup-receipt",
                            str(cleanup),
                            "--secret-scan-receipt",
                            str(scan),
                            "--output",
                            str(output),
                        ]
                    ),
                    78,
                )
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
