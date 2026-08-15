"""TDD tests for metadata-only Todo 20 production-QA evidence."""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_production_qa_validator_test",
        VALIDATOR,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load production-QA validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


QA = load_validator()


def valid_summary() -> dict[str, Any]:
    return {
        "accounts": 2,
        "cases": [{"name": name, "passed": True} for name in QA.REQUIRED_CASES],
        "cleanup": {
            "accounts": True,
            "local_cache": True,
            "runner_temp": True,
            "simulator_keychain": True,
        },
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


class ValidateFloorpNotesSyncProductionQATests(unittest.TestCase):
    def test_valid_metadata_summary_is_accepted(self) -> None:
        summary = valid_summary()
        self.assertEqual(QA.validate_summary(summary), summary)

    def test_sensitive_fields_and_payload_are_rejected(self) -> None:
        for field in ("password", "notes_payload", "authorization", "email"):
            with self.subTest(field=field):
                summary = valid_summary()
                summary[field] = "must-not-be-retained"
                with self.assertRaises(QA.ProductionQAError):
                    QA.validate_summary(summary)

    def test_missing_case_cleanup_network_or_confirmation_fails(self) -> None:
        mutations = (
            ("cases", []),
            ("cleanup", {"accounts": False}),
            ("network", {"direct_rest_used": True}),
            ("phase_2_enablement_ready", False),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                summary = valid_summary()
                if field in {"cleanup", "network"}:
                    summary[field].update(value)
                else:
                    summary[field] = value
                with self.assertRaises(QA.ProductionQAError):
                    QA.validate_summary(summary)

    def test_canonical_bytes_and_duplicate_keys_are_required(self) -> None:
        summary = valid_summary()
        raw = json.dumps(summary, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"
        self.assertEqual(QA.parse_bytes(raw), summary)
        with self.assertRaises(QA.ProductionQAError):
            QA.parse_bytes(raw + b" ")
        duplicate = raw.replace(b'"accounts":2', b'"accounts":2,"accounts":2', 1)
        with self.assertRaises(QA.ProductionQAError):
            QA.parse_bytes(duplicate)

    def test_file_loader_rejects_symlinks(self) -> None:
        summary = valid_summary()
        raw = json.dumps(summary, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "summary.json"
            source.write_bytes(raw)
            self.assertEqual(QA.load_and_validate(source), summary)
            link = root / "link.json"
            link.symlink_to(source)
            with self.assertRaises(QA.ProductionQAError):
                QA.load_and_validate(link)


if __name__ == "__main__":
    unittest.main()
