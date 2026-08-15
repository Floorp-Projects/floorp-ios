"""TDD tests for the single-operator append-only attestation boundary."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
RECORD_PATH = ROOT / "scripts/ci/record-floorp-notes-sync-self-attestation.py"
VALIDATE_PATH = ROOT / "scripts/ci/validate-floorp-notes-sync-self-attestation.py"


def load(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


RECORD = load(RECORD_PATH, "floorp_notes_sync_attestation_record_test")
VALIDATE = load(VALIDATE_PATH, "floorp_notes_sync_attestation_validate_test")


class SelfAttestationTests(unittest.TestCase):
    def environment(self) -> dict[str, str]:
        return {
            "GITHUB_ACTOR": "operator",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_JOB": "notes-sync-production-qa",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": RECORD.REPOSITORY,
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "123",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": f"{RECORD.REPOSITORY}/{RECORD.WORKFLOW_PATH}@{'a' * 40}",
        }

    def test_record_and_validate_one_append_only_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            with patch.dict(os.environ, self.environment(), clear=True):
                self.assertEqual(RECORD.main(["--output", str(path)]), 0)
            value, raw = VALIDATE.load(path)
            VALIDATE.validate(value, "a" * 40, 123, 1)
            self.assertEqual(raw.count(b"\n"), 1)

    def test_event_hash_or_run_binding_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            with patch.dict(os.environ, self.environment(), clear=True):
                RECORD.main(["--output", str(path)])
            value, _ = VALIDATE.load(path)
            value["public_release"] = True
            with self.assertRaises(VALIDATE.AttestationError):
                VALIDATE.validate(value, "a" * 40, 123, 1)
            value, _ = VALIDATE.load(path)
            with self.assertRaises(VALIDATE.AttestationError):
                VALIDATE.validate(value, "b" * 40, 123, 1)


if __name__ == "__main__":
    unittest.main()
