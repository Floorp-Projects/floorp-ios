"""TDD tests for the immutable Todo 20 merge-audit artifact."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


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
        operation = root / "merge-operation-receipt.json"
        operation.write_text(
            json.dumps(
                {
                    "base_oid": "1" * 40,
                    "head_sha": "2" * 40,
                    "merge_endpoint": "PUT /repos/Floorp-Projects/floorp-ios/pulls/106/merge",
                    "merge_method": "squash",
                    "merge_response": {"merged": True, "sha": "4" * 40},
                    "merge_response_sha256": AUDIT.sha256(AUDIT.canonical({"merged": True, "sha": "4" * 40})),
                    "merge_response_source": "github-api-put-merge-executor",
                    "merge_admission_receipt_sha256": "5" * 64,
                    "merged_oid": "4" * 40,
                    "oid_guarded": True,
                    "pr_number": 106,
                    "repository": AUDIT.REPOSITORY,
                    "schema_version": 1,
                    "server_merge_sha": "4" * 40,
                    "server_merged": True,
                    "server_merged_at": "2026-08-15T00:00:00Z",
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        audit_log = root / "audit-log.json"
        audit_log.write_text(
            json.dumps(
                [
                    {
                        "action": "pull_request.merge",
                        "repo": AUDIT.REPOSITORY,
                        "@timestamp": "2026-08-15T00:00:00Z",
                        "_document_id": "event-1",
                        "data": {"merge_commit_sha": "4" * 40, "url": "https://github.com/Floorp-Projects/floorp-ios/pull/106/merge"},
                    }
                ],
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        return operation, audit_log

    def arguments(self, root: Path, operation: Path, audit_log: Path, output: Path) -> list[str]:
        return [
            "--operation-receipt", str(operation),
            "--audit-json", str(audit_log),
            "--output", str(output),
        ]

    def test_actual_put_projection_and_audit_projection_are_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            operation, audit_log = self.write_inputs(root)
            output = root / "docs/floorp-notes-sync-todo20-merge-audit.json"
            with patch.dict(
                AUDIT.os.environ,
                {"GITHUB_REPOSITORY": AUDIT.REPOSITORY, "GITHUB_RUN_ID": "999", "GITHUB_SHA": "2" * 40},
                clear=False,
            ):
                self.assertEqual(AUDIT.main(self.arguments(root, operation, audit_log, output)), 0)
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schema_version"], 2)
            self.assertEqual(value["merge_response"], {"merged": True, "sha": "4" * 40})
            self.assertEqual(value["merge_response_source"], "github-api-put-merge-executor")
            self.assertEqual(value["audit_event_count"], 1)
            self.assertEqual(value["audit_bypass_event_count"], 0)
            self.assertTrue(output.read_bytes().endswith(b"\n"))

    def test_bypass_event_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            operation, audit_log = self.write_inputs(root)
            audit_log.write_text(
                json.dumps(
                    [{"action": "protected_branch.policy_override", "repo": AUDIT.REPOSITORY}]
                )
                + "\n",
                encoding="utf-8",
            )
            output = root / "merge-audit.json"
            with patch.dict(
                AUDIT.os.environ,
                {"GITHUB_REPOSITORY": AUDIT.REPOSITORY, "GITHUB_RUN_ID": "999", "GITHUB_SHA": "2" * 40},
                clear=False,
            ):
                self.assertNotEqual(AUDIT.main(self.arguments(root, operation, audit_log, output)), 0)
            self.assertFalse(output.exists())

    def test_waived_audit_records_owner_waiver_without_bypass_claim(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            operation, audit_log = self.write_inputs(root)
            output = root / "merge-audit.json"
            binding = json.loads(
                (ROOT / "docs/floorp-notes-sync-todo20-plan-binding.json").read_text(encoding="utf-8")
            )
            waiver = root / "owner-waiver.json"
            waiver.write_text(
                json.dumps(
                    {
                        "approved_at_utc": "2026-08-16T00:00:00Z",
                        "endpoint_unavailable": "org-audit-log-http-404-github-free-plan",
                        "operator_id": "Ryosuke-Asano",
                        "plan_hash": binding["combined_plan_hash"],
                        "schema_version": 1,
                        "statement": "The org audit-log endpoint is unavailable on the free plan; the no-bypass fact is not claimed.",
                    },
                    separators=(",", ":"),
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            args = self.arguments(root, operation, audit_log, output) + [
                "--waive-audit",
                "--owner-waiver", str(waiver),
            ]
            with patch.dict(
                AUDIT.os.environ,
                {
                    "GITHUB_REPOSITORY": AUDIT.REPOSITORY,
                    "GITHUB_RUN_ID": "999",
                    "GITHUB_SHA": "2" * 40,
                    "GITHUB_ACTOR": "Ryosuke-Asano",
                },
                clear=False,
            ):
                self.assertEqual(AUDIT.main(args), 0)
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schema_version"], 3)
            self.assertEqual(value["audit_source"], "github-org-audit-log-unavailable-owner-waived")
            self.assertEqual(value["audit_event_count"], 0)
            self.assertIsNone(value["audit_bypass_event_count"])
            self.assertIsNone(value["audit_event_id_sha256"])
            self.assertIsNone(value["audit_event_timestamp"])
            self.assertIsNone(value["audit_projection_sha256"])
            self.assertIsNone(value["admin_bypass_used"])
            self.assertIs(value["bypass_requested"], False)
            self.assertIs(value["audit_endpoint_unavailable"], True)
            self.assertEqual(value["waiver_operator_id"], "Ryosuke-Asano")
            self.assertEqual(value["waiver_plan_hash"], binding["combined_plan_hash"])

    def test_waived_audit_rejects_plan_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            operation, audit_log = self.write_inputs(root)
            output = root / "merge-audit.json"
            waiver = root / "owner-waiver.json"
            waiver.write_text(
                json.dumps(
                    {
                        "approved_at_utc": "2026-08-16T00:00:00Z",
                        "endpoint_unavailable": "org-audit-log-http-404-github-free-plan",
                        "operator_id": "Ryosuke-Asano",
                        "plan_hash": "f" * 64,
                        "schema_version": 1,
                        "statement": "stale",
                    },
                    separators=(",", ":"),
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            args = self.arguments(root, operation, audit_log, output) + [
                "--waive-audit",
                "--owner-waiver", str(waiver),
            ]
            with patch.dict(
                AUDIT.os.environ,
                {
                    "GITHUB_REPOSITORY": AUDIT.REPOSITORY,
                    "GITHUB_RUN_ID": "999",
                    "GITHUB_SHA": "2" * 40,
                    "GITHUB_ACTOR": "Ryosuke-Asano",
                },
                clear=False,
            ):
                self.assertNotEqual(AUDIT.main(args), 0)
            self.assertFalse(output.exists())

    def test_waived_audit_rejects_actor_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            operation, audit_log = self.write_inputs(root)
            output = root / "merge-audit.json"
            binding = json.loads(
                (ROOT / "docs/floorp-notes-sync-todo20-plan-binding.json").read_text(encoding="utf-8")
            )
            waiver = root / "owner-waiver.json"
            waiver.write_text(
                json.dumps(
                    {
                        "approved_at_utc": "2026-08-16T00:00:00Z",
                        "endpoint_unavailable": "org-audit-log-http-404-github-free-plan",
                        "operator_id": "someone-else",
                        "plan_hash": binding["combined_plan_hash"],
                        "schema_version": 1,
                        "statement": "wrong actor",
                    },
                    separators=(",", ":"),
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            args = self.arguments(root, operation, audit_log, output) + [
                "--waive-audit",
                "--owner-waiver", str(waiver),
            ]
            with patch.dict(
                AUDIT.os.environ,
                {
                    "GITHUB_REPOSITORY": AUDIT.REPOSITORY,
                    "GITHUB_RUN_ID": "999",
                    "GITHUB_SHA": "2" * 40,
                    "GITHUB_ACTOR": "Ryosuke-Asano",
                },
                clear=False,
            ):
                self.assertNotEqual(AUDIT.main(args), 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
