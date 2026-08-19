"""TDD tests for the Todo 20 guarded-merge audit recovery executor."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/execute-floorp-notes-sync-merge-recovery.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


RECOVERY = load_module(SCRIPT, "floorp_notes_sync_merge_recovery_test")


class MergeRecoveryTests(unittest.TestCase):
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
            "repository": RECOVERY.REPOSITORY,
            "schema_version": 1,
            "status": "GO",
            "subagent_review_commit_sha": "3" * 40,
            "subagent_review_sha256": "d" * 64,
            "terminal_ci": True,
        }

    @staticmethod
    def merged_pr() -> dict[str, object]:
        return {
            "base": {"ref": "main", "sha": "1" * 40},
            "head": {"ref": "agent/floorp-t20-enable-runtime-compat", "sha": "2" * 40},
            "merge_commit_sha": "4" * 40,
            "merged": True,
            "merged_at": "2026-08-15T01:00:00Z",
            "number": 106,
        }

    @staticmethod
    def source_run() -> dict[str, object]:
        return {
            "id": 1001,
            "path": ".github/workflows/ci.yml",
            "event": "workflow_dispatch",
            "head_branch": "agent/floorp-plan-t20-live-executor",
            "head_sha": "2" * 40,
        }

    @staticmethod
    def source_jobs() -> dict[str, object]:
        return {
            "jobs": [
                {
                    "name": "Todo 20 protected OID-guarded merge and audit receipt",
                    "steps": [
                        {
                            "name": "Execute repository-owned OID-guarded merge",
                            "conclusion": "success",
                        },
                        {"name": "Capture protected organization audit response", "conclusion": "failure"},
                    ],
                }
            ]
        }

    def invoke(self, directory: Path, responses: list[bytes]) -> tuple[list[list[str]], int, Path, Path]:
        output = Path(directory) / "merge-operation-receipt.json"
        evidence = Path(directory) / "merge-recovery-evidence.json"
        admission = Path(directory) / "merge-admission.json"
        admission.write_bytes(RECOVERY.canonical(self.admission_receipt()))
        calls: list[list[str]] = []
        iterator = iter(responses)

        def fake_run_gh(arguments: list[str]) -> bytes:
            calls.append(arguments)
            return next(iterator)

        with patch.dict(
            "os.environ",
            {"GITHUB_RUN_ID": "2002", "GITHUB_SHA": "7" * 40},
        ), patch.object(RECOVERY, "run_gh", side_effect=fake_run_gh), patch.object(
            RECOVERY, "verify_recovery_head"
        ):
            code = RECOVERY.main(
                [
                    "--pr-number", "106",
                    "--expected-head-sha", "2" * 40,
                    "--expected-merged-oid", "4" * 40,
                    "--source-run-id", "1001",
                    "--admission-receipt", str(admission),
                    "--output", str(output),
                    "--recovery-evidence", str(evidence),
                ]
            )
        return calls, code, output, evidence

    def test_recovery_records_receipt_from_observed_merged_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            responses = [
                json.dumps(self.merged_pr()).encode(),
                json.dumps(self.source_run()).encode(),
                json.dumps(self.source_jobs()).encode(),
            ]
            calls, code, output, evidence = self.invoke(Path(directory), responses)
            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 3)
            self.assertNotIn("PUT", calls[0])
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["merge_response_source"], "github-api-put-merge-executor")
            self.assertEqual(value["merged_oid"], "4" * 40)
            self.assertEqual(value["server_merged_at"], "2026-08-15T01:00:00Z")
            self.assertEqual(value["server_merged"], True)
            self.assertEqual(value["oid_guarded"], True)
            self.assertEqual(value["merge_method"], "squash")
            self.assertEqual(value["merge_response"], {"merged": True, "sha": "4" * 40})
            self.assertEqual(
                value["merge_admission_receipt_sha256"],
                RECOVERY.sha256(Path(directory, "merge-admission.json").read_bytes()),
            )
            evidence_value = json.loads(evidence.read_text(encoding="utf-8"))
            self.assertEqual(evidence_value["source_executor_step_success"], True)
            self.assertEqual(evidence_value["source_run_id"], 1001)
            self.assertEqual(evidence_value["recovery_run_id"], 2002)
            self.assertEqual(evidence_value["recovery_head_sha"], "7" * 40)
            self.assertEqual(evidence_value["expected_merged_oid"], "4" * 40)

    def test_not_merged_pr_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pr = self.merged_pr()
            pr["merged"] = False
            code, output = 0, Path(directory, "out")
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(RECOVERY.canonical(self.admission_receipt()))
            with patch.object(
                RECOVERY, "run_gh", return_value=json.dumps(pr).encode(),
            ) as run, patch.object(RECOVERY, "verify_recovery_head"):
                code = RECOVERY.main(
                    [
                        "--pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                        "--source-run-id", "1001",
                        "--admission-receipt", str(admission),
                        "--output", str(output),
                        "--recovery-evidence", str(Path(directory, "merge-recovery-evidence.json")),
                    ]
                )
                self.assertEqual(run.call_count, 1)
            self.assertNotEqual(code, 0)
            self.assertFalse(output.exists())

    def test_merge_commit_mismatch_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pr = self.merged_pr()
            pr["merge_commit_sha"] = "9" * 40
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(RECOVERY.canonical(self.admission_receipt()))
            with patch.object(RECOVERY, "run_gh", return_value=json.dumps(pr).encode()), patch.object(
                RECOVERY, "verify_recovery_head"
            ):
                code = RECOVERY.main(
                    [
                        "--pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                        "--source-run-id", "1001",
                        "--admission-receipt", str(admission),
                        "--output", str(output),
                        "--recovery-evidence", str(Path(directory, "merge-recovery-evidence.json")),
                    ]
                )
            self.assertNotEqual(code, 0)
            self.assertFalse(output.exists())

    def test_source_run_provenance_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run = self.source_run()
            run["event"] = "pull_request"
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(RECOVERY.canonical(self.admission_receipt()))
            responses = iter(
                [
                    json.dumps(self.merged_pr()).encode(),
                    json.dumps(run).encode(),
                ]
            )
            with patch.object(RECOVERY, "run_gh", side_effect=lambda _a: next(responses)), patch.object(
                RECOVERY, "verify_recovery_head"
            ):
                code = RECOVERY.main(
                    [
                        "--pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                        "--source-run-id", "1001",
                        "--admission-receipt", str(admission),
                        "--output", str(output),
                        "--recovery-evidence", str(Path(directory, "merge-recovery-evidence.json")),
                    ]
                )
            self.assertNotEqual(code, 0)
            self.assertFalse(output.exists())

    def test_source_executor_step_failure_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            jobs = self.source_jobs()
            jobs["jobs"][0]["steps"][0]["conclusion"] = "failure"
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            admission.write_bytes(RECOVERY.canonical(self.admission_receipt()))
            responses = iter(
                [
                    json.dumps(self.merged_pr()).encode(),
                    json.dumps(self.source_run()).encode(),
                    json.dumps(jobs).encode(),
                ]
            )
            with patch.object(RECOVERY, "run_gh", side_effect=lambda _a: next(responses)), patch.object(
                RECOVERY, "verify_recovery_head"
            ):
                code = RECOVERY.main(
                    [
                        "--pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                        "--source-run-id", "1001",
                        "--admission-receipt", str(admission),
                        "--output", str(output),
                        "--recovery-evidence", str(Path(directory, "merge-recovery-evidence.json")),
                    ]
                )
            self.assertNotEqual(code, 0)
            self.assertFalse(output.exists())

    def test_tampered_admission_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "merge-operation-receipt.json"
            admission = Path(directory) / "merge-admission.json"
            receipt = self.admission_receipt()
            receipt["head_sha"] = "9" * 40
            admission.write_bytes(RECOVERY.canonical(receipt))
            with patch.object(RECOVERY, "run_gh") as run, patch.object(
                RECOVERY, "verify_recovery_head"
            ):
                code = RECOVERY.main(
                    [
                        "--pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                        "--source-run-id", "1001",
                        "--admission-receipt", str(admission),
                        "--output", str(output),
                        "--recovery-evidence", str(Path(directory, "merge-recovery-evidence.json")),
                    ]
                )
                run.assert_not_called()
            self.assertNotEqual(code, 0)
            self.assertFalse(output.exists())

    def test_verify_recovery_head_uses_server_side_compare(self) -> None:
        with patch.object(
            RECOVERY,
            "run_gh",
            return_value=json.dumps(
                {"status": "ahead", "behind_by": 0, "ahead_by": 2}
            ).encode(),
        ) as run:
            RECOVERY.verify_recovery_head("2" * 40, "7" * 40)
            self.assertIn("compare/", " ".join(run.call_args.args[0]))

    def test_verify_recovery_head_rejects_diverged_or_identical(self) -> None:
        for response in (
            {"status": "diverged", "behind_by": 1, "ahead_by": 2},
            {"status": "behind", "behind_by": 2, "ahead_by": 0},
            {"status": "identical", "behind_by": 0, "ahead_by": 0},
        ):
            with self.subTest(response=response), patch.object(
                RECOVERY,
                "run_gh",
                return_value=json.dumps(response).encode(),
            ):
                with self.assertRaises(RECOVERY.MergeRecoveryError):
                    RECOVERY.verify_recovery_head("2" * 40, "7" * 40)

    def test_verify_recovery_head_rejects_identical_shas(self) -> None:
        with patch.object(RECOVERY, "run_gh") as run:
            with self.assertRaises(RECOVERY.MergeRecoveryError):
                RECOVERY.verify_recovery_head("2" * 40, "2" * 40)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
