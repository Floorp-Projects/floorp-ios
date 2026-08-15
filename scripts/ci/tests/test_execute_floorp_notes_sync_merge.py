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
    def test_executor_observes_head_then_executes_only_guarded_squash_put(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            responses = iter(
                [
                    json.dumps({"headRefOid": "2" * 40}).encode(),
                    json.dumps({"merged": True, "sha": "4" * 40}).encode(),
                    json.dumps(
                        {
                            "base": {"sha": "1" * 40},
                            "head": {"sha": "2" * 40},
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

    def test_head_drift_stops_before_put(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            with patch.object(EXECUTOR, "run_gh", return_value=json.dumps({"headRefOid": "9" * 40}).encode()) as run:
                self.assertNotEqual(
                    EXECUTOR.main(
                        [
                            "--pr-number", "106",
                            "--expected-head-sha", "2" * 40,
                            "--output", str(output),
                        ]
                    ),
                    0,
                )
                self.assertEqual(run.call_count, 1)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
