"""TDD tests for the immutable Todo 20 merge-audit artifact."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/create-floorp-notes-sync-merge-audit.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


AUDIT = load_module(SCRIPT, "floorp_notes_sync_merge_audit_test")


class MergeAuditTests(unittest.TestCase):
    def write_inputs(self, root: Path) -> tuple[Path, Path]:
        merge_response = root / "merge-response.json"
        merge_response.write_text(json.dumps({"merged": True, "sha": "4" * 40}) + "\n", encoding="utf-8")
        audit_log = root / "audit-log.json"
        audit_log.write_text(
            json.dumps(
                [
                    {
                        "action": "pull_request.merge",
                        "repo": AUDIT.REPOSITORY,
                        "@timestamp": 123,
                        "data": {"url": "https://github.com/Floorp-Projects/floorp-ios/pull/106/merge"},
                    }
                ],
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        return merge_response, audit_log

    def arguments(self, root: Path, merge_response: Path, audit_log: Path, output: Path) -> list[str]:
        return [
            "--merge-response", str(merge_response),
            "--audit-json", str(audit_log),
            "--base-oid", "1" * 40,
            "--head-sha", "2" * 40,
            "--merged-oid", "4" * 40,
            "--pr-number", "106",
            "--output", str(output),
        ]

    def test_actual_put_projection_and_audit_projection_are_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merge_response, audit_log = self.write_inputs(root)
            output = root / "docs/floorp-notes-sync-todo20-merge-audit.json"
            self.assertEqual(AUDIT.main(self.arguments(root, merge_response, audit_log, output)), 0)
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schema_version"], 2)
            self.assertEqual(value["merge_response"], {"merged": True, "sha": "4" * 40})
            self.assertEqual(value["merge_response_source"], "github-api-put-merge")
            self.assertEqual(value["audit_event_count"], 1)
            self.assertEqual(value["audit_bypass_event_count"], 0)
            self.assertTrue(output.read_bytes().endswith(b"\n"))

    def test_bypass_event_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merge_response, audit_log = self.write_inputs(root)
            audit_log.write_text(
                json.dumps(
                    [{"action": "protected_branch.policy_override", "repo": AUDIT.REPOSITORY}]
                )
                + "\n",
                encoding="utf-8",
            )
            output = root / "merge-audit.json"
            self.assertNotEqual(AUDIT.main(self.arguments(root, merge_response, audit_log, output)), 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
