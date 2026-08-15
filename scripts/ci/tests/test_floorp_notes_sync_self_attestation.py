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
            "FLOORP_TODO20_BASE_OID": "b" * 40,
            "FLOORP_TODO20_HEAD_SHA": "1" * 40,
            "FLOORP_TODO20_MERGED_OID": "a" * 40,
            "FLOORP_TODO20_PR_NUMBER": "106",
            "FLOORP_TODO20_DIFF_SHA256": "c" * 64,
            "FLOORP_TODO20_PLAN_SHA256": "d" * 64,
            "FLOORP_TODO20_AMENDMENT_SHA256": "e" * 64,
            "FLOORP_TODO20_COMBINED_PLAN_HASH": "f" * 64,
            "FLOORP_TODO20_SUBAGENT_REVIEW_DIGESTS": "1" * 64,
            "FLOORP_TODO20_REVIEWED_AT_UTC": "2026-08-15T00:00:00Z",
        }

    def evidence(self, root: Path) -> dict[str, Path]:
        paths = {
            "manifest": root / "qa-manifest.json",
            "summary": root / "qa-summary.json",
            "cleanup": root / "cleanup-receipt.json",
            "secret_scan": root / "secret-scan.json",
        }
        for name, path in paths.items():
            path.write_bytes(json.dumps({"artifact": name}, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        paths["manifest"].write_bytes(
            json.dumps(
                {
                    "accounts": 2,
                    "artifacts": [
                        {
                            "byte_count": 1,
                            "name": f"{role}.json",
                            "role": role,
                            "sha256": "0" * 64,
                        }
                        for role in (
                            "qa-summary",
                            "cleanup-receipt",
                            "xcresult",
                            "xcodebuild-log",
                            "desktop-log",
                            "production-qa-capability",
                            "production-qa-xcconfig",
                            "secret-scan",
                        )
                    ],
                    "desktop_sha": "b" * 40,
                    "environment": RECORD.ENVIRONMENT,
                    "head_sha": "a" * 40,
                    "public_release": False,
                    "repository": RECORD.REPOSITORY,
                    "schema_version": 1,
                    "workflow_path": RECORD.WORKFLOW_PATH,
                    "workflow_run_attempt": 1,
                    "workflow_run_id": 123,
                },
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
            + b"\n"
        )
        return paths

    def arguments(self, output: Path, paths: dict[str, Path]) -> list[str]:
        return [
            "--output", str(output),
            "--manifest", str(paths["manifest"]),
            "--summary", str(paths["summary"]),
            "--cleanup-receipt", str(paths["cleanup"]),
            "--secret-scan", str(paths["secret_scan"]),
        ]

    def test_record_and_validate_one_append_only_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            paths = self.evidence(Path(directory))
            with patch.dict(os.environ, self.environment(), clear=True):
                self.assertEqual(RECORD.main(self.arguments(path, paths)), 0)
            value, raw = VALIDATE.load(path)
            VALIDATE.validate(value, "1" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"])
            self.assertEqual(raw.count(b"\n"), 1)
            self.assertEqual(value["roles"], ["owner", "operations", "executor", "reviewer"])
            self.assertTrue(value["self_review_exception"])
            self.assertFalse(value["independence"])
            self.assertEqual(value["ruleset_required_review_count"], 0)
            self.assertEqual(value["reviews_count"], 0)
            self.assertFalse(value["admin_bypass_used"])
            self.assertEqual(value["head_sha"], "1" * 40)
            self.assertEqual(value["merged_oid"], "a" * 40)

    def test_event_hash_or_run_binding_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            paths = self.evidence(Path(directory))
            with patch.dict(os.environ, self.environment(), clear=True):
                RECORD.main(self.arguments(path, paths))
            value, _ = VALIDATE.load(path)
            value["public_release"] = True
            with self.assertRaises(VALIDATE.AttestationError):
                VALIDATE.validate(value, "1" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"])
            value, _ = VALIDATE.load(path)
            with self.assertRaises(VALIDATE.AttestationError):
                VALIDATE.validate(value, "b" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"])

    def test_missing_review_metadata_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            paths = self.evidence(Path(directory))
            environment = self.environment()
            environment.pop("FLOORP_TODO20_SUBAGENT_REVIEW_DIGESTS")
            with patch.dict(os.environ, environment, clear=True):
                self.assertEqual(RECORD.main(self.arguments(path, paths)), 78)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
