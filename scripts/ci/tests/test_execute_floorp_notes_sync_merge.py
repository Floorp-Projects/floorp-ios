"""TDD tests for the OID-guarded GitHub merge executor."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/execute-floorp-notes-sync-merge.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


EXECUTOR = load_module(SCRIPT, "floorp_notes_sync_merge_executor_test")


class MergeExecutorTests(unittest.TestCase):
    @staticmethod
    def admission_receipt() -> dict[str, object]:
        return {
            "admin_bypass_used": False,
            "base_oid": "1" * 40,
            "base_ref_name": "main",
            "checks_count": 4,
            "checks_sha256": "a" * 64,
            "head_sha": "2" * 40,
            "head_ref_name": "agent/floorp-t20-enable-runtime-compat",
            "native_github_approval": False,
            "operator_id": "operator",
            "owner_review_sha256": "b" * 64,
            "plan_binding_sha256": "c" * 64,
            "pr_number": 106,
            "repository": EXECUTOR.REPOSITORY,
            "schema_version": 1,
            "status": "GO",
            "subagent_review_commit_sha": "3" * 40,
            "subagent_review_sha256": "d" * 64,
            "terminal_ci": True,
        }

    def test_executor_observes_head_then_executes_only_guarded_squash_put(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(EXECUTOR.canonical(self.admission_receipt()))
            responses = iter(
                [
                    json.dumps(
                        {
                            "baseRefName": "main",
                            "baseRefOid": "1" * 40,
                            "headRefName": "agent/floorp-t20-enable-runtime-compat",
                            "headRefOid": "2" * 40,
                        }
                    ).encode(),
                    json.dumps({"merged": True, "sha": "4" * 40}).encode(),
                    json.dumps(
                        {
                            "base": {"ref": "main", "sha": "1" * 40},
                            "head": {"ref": "agent/floorp-t20-enable-runtime-compat", "sha": "2" * 40},
                            "merge_commit_sha": "4" * 40,
                            "merged": True,
                            "merged_at": "2026-08-15T00:00:00Z",
                            "number": 106,
                        }
                    ).encode(),
                ]
            )
            calls: list[list[str]] = []

            def fake_run_gh(arguments: list[str]) -> bytes:
                calls.append(arguments)
                return next(responses)

            with patch.object(EXECUTOR, "run_gh", side_effect=fake_run_gh):
                self.assertEqual(
                    EXECUTOR.main(
                        [
                            "--pr-number", "106",
                            "--expected-head-sha", "2" * 40,
                            "--admission-receipt", str(admission),
                            "--output", str(output),
                        ]
                    ),
                    0,
                )
            self.assertEqual(calls[1][0:3], ["api", "-X", "PUT"])
            self.assertIn("-f", calls[1])
            self.assertIn("sha=" + "2" * 40, calls[1])
            self.assertIn("merge_method=squash", calls[1])
            self.assertNotIn("bypass", " ".join(calls[1]).lower())
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["merge_response_source"], "github-api-put-merge-executor")
            self.assertEqual(value["server_merged_at"], "2026-08-15T00:00:00Z")
            self.assertEqual(value["merge_admission_receipt_sha256"], EXECUTOR.sha256(admission.read_bytes()))

    def test_head_drift_stops_before_put(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(EXECUTOR.canonical(self.admission_receipt()))
            with patch.object(EXECUTOR, "run_gh", return_value=json.dumps({"headRefOid": "9" * 40}).encode()) as run:
                self.assertNotEqual(
                    EXECUTOR.main(
                        [
                            "--pr-number", "106",
                            "--expected-head-sha", "2" * 40,
                            "--admission-receipt", str(admission),
                            "--output", str(output),
                        ]
                    ),
                    0,
                )
                self.assertEqual(run.call_count, 1)
            self.assertFalse(output.exists())

    def test_base_ref_drift_stops_before_put(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(EXECUTOR.canonical(self.admission_receipt()))
            with patch.object(
                EXECUTOR,
                "run_gh",
                return_value=json.dumps(
                    {
                        "baseRefName": "release",
                        "baseRefOid": "1" * 40,
                        "headRefName": "agent/floorp-t20-enable-runtime-compat",
                        "headRefOid": "2" * 40,
                    }
                ).encode(),
            ) as run:
                self.assertNotEqual(
                    EXECUTOR.main(
                        [
                            "--pr-number", "106",
                            "--expected-head-sha", "2" * 40,
                            "--admission-receipt", str(admission),
                            "--output", str(output),
                        ]
                    ),
                    0,
                )
                self.assertEqual(run.call_count, 1)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
