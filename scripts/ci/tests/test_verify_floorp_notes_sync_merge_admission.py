"""TDD tests for the pre-merge Todo 20 admission gate."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/verify-floorp-notes-sync-merge-admission.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


ADMISSION = load_module(SCRIPT, "floorp_notes_sync_merge_admission_test")


class MergeAdmissionTests(unittest.TestCase):
    def write_inputs(self, root: Path) -> dict[str, Path | str]:
        head = "2" * 40
        base = "1" * 40
        owner = {
            "amendment_sha256": "b" * 64,
            "attestation_statement": "Todo 20 bounded owner self-review recorded.",
            "base_oid": base,
            "checklist": {"exact_head": True, "scope": True, "security": True},
            "combined_plan_hash": "c" * 64,
            "diff_sha256": "d" * 64,
            "desktop_sha": "5" * 40,
            "head_sha": head,
            "independence": False,
            "operator_id": "operator",
            "plan_sha256": "a" * 64,
            "pr_number": 106,
            "public_release": False,
            "repository": ADMISSION.REPOSITORY,
            "reviewed_at_utc": "2026-08-15T00:00:00Z",
            "schema_version": 1,
            "self_review_exception": True,
            "unresolved_blocking_findings": [],
        }
        owner_path = root / "owner-review.json"
        owner_path.write_bytes(ADMISSION.canonical(owner))

        subagent = {
            "desktop_sha": "5" * 40,
            "findings": [],
            "head_sha": head,
            "independence": True,
            "repository": ADMISSION.REPOSITORY,
            "reviewer_id": "01234567-89ab-cdef-0123-456789abcdef",
            "review_method": "codex-read-only-diff",
            "reviewed_at_utc": "2026-08-15T00:00:00Z",
            "schema_version": 1,
            "status": "GO",
        }
        subagent_path = root / "docs/floorp-notes-sync-todo20-subagent-review.json"
        subagent_path.parent.mkdir()
        subagent_path.write_bytes(ADMISSION.canonical(subagent))
        subprocess.run(["/usr/bin/git", "-C", str(root), "init", "--quiet"], check=True)
        subprocess.run(["/usr/bin/git", "-C", str(root), "add", str(subagent_path.relative_to(root))], check=True)
        subprocess.run(
            [
                "/usr/bin/git", "-C", str(root), "-c", "user.name=Test", "-c",
                "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "review",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subagent_commit = subprocess.check_output(
            ["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()

        run_id = 1001
        repository_url = "https://api.github.com/repos/Floorp-Projects/floorp-ios"
        pr_association = {
            "base": {"ref": "main", "sha": base, "repo": {"url": repository_url}},
            "head": {
                "ref": "agent/floorp-plan-t20-live-executor",
                "sha": head,
                "repo": {"url": repository_url},
            },
            "number": 106,
            "url": f"{repository_url}/pulls/106",
        }
        check_specs = [
            ("Validate workflows", "pass", "SUCCESS", "success", 2001),
            ("Build and unit test", "pass", "SUCCESS", "success", 2002),
            ("Release-disabled wrapper build", "pass", "SUCCESS", "success", 2003),
            ("Todo 20 protected OID-guarded merge and audit receipt", "skipping", "SKIPPED", "skipped", 2004),
        ]
        checks = [
            {
                "bucket": bucket,
                "completedAt": "2026-08-15T00:00:00Z",
                "event": "pull_request",
                "link": f"https://github.com/Floorp-Projects/floorp-ios/actions/runs/{run_id}/job/{job_id}",
                "name": name,
                "state": state,
                "workflow": "Floorp iOS CI",
            }
            for name, bucket, state, conclusion, job_id in check_specs
        ]
        checks_path = root / "checks.json"
        checks_path.write_text(json.dumps(checks) + "\n", encoding="utf-8")
        check_runs_path = root / "check-runs.json"
        check_runs_path.write_text(
            json.dumps(
                {
                    "total_count": len(check_specs),
                    "check_runs": [
                        {
                            "id": job_id,
                            "name": name,
                            "head_sha": head,
                            "status": "completed",
                            "conclusion": conclusion,
                            "pull_requests": [pr_association],
                        }
                        for name, _bucket, _state, conclusion, job_id in check_specs
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        workflow_runs_path = root / "workflow-runs.json"
        workflow_runs_path.write_text(
            json.dumps(
                {
                    "total_count": 1,
                    "workflow_runs": [
                        {
                            "id": run_id,
                            "name": "Floorp iOS CI",
                            "path": ".github/workflows/ci.yml",
                            "event": "pull_request",
                            "head_branch": "agent/floorp-plan-t20-live-executor",
                            "head_sha": head,
                            "status": "completed",
                            "conclusion": "success",
                            "pull_requests": [pr_association],
                        }
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        binding_path = root / "plan-binding.json"
        binding_path.write_bytes(
            ADMISSION.canonical(
                {
                    "amendment_sha256": "b" * 64,
                    "combined_plan_hash": "c" * 64,
                    "plan_sha256": "a" * 64,
                    "schema_version": 1,
                    "task_id": 20,
                }
            )
        )
        output_path = root / "admission.json"
        return {
            "owner": owner_path,
            "subagent": subagent_path,
            "checks": checks_path,
            "check_runs": check_runs_path,
            "workflow_runs": workflow_runs_path,
            "binding": binding_path,
            "output": output_path,
            "commit": subagent_commit,
            "head": head,
        }

    def args(self, values: dict[str, Path | str]) -> list[str]:
        return [
            "--repository-root", str(values["owner"].parent),
            "--owner-review", str(values["owner"]),
            "--subagent-review", str(values["subagent"]),
            "--subagent-review-commit", str(values["commit"]),
            "--checks-json", str(values["checks"]),
            "--check-runs-json", str(values["check_runs"]),
            "--workflow-runs-json", str(values["workflow_runs"]),
            "--plan-binding", str(values["binding"]),
            "--pr-number", "106",
            "--expected-head-sha", str(values["head"]),
            "--output", str(values["output"]),
        ]

    def test_exact_head_owner_subagent_and_terminal_ci_admit_merge(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            self.assertEqual(ADMISSION.main(self.args(values)), 0)
            value = json.loads(Path(values["output"]).read_text(encoding="utf-8"))
            self.assertEqual(value["status"], "GO")
            self.assertEqual(value["head_sha"], values["head"])

    def test_pending_ci_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            Path(values["checks"]).write_text(
                json.dumps([{
                    "bucket": "pending",
                    "completedAt": "0001-01-01T00:00:00Z",
                    "event": "pull_request",
                    "link": "https://github.com/Floorp-Projects/floorp-ios/actions/runs/1001/job/2002",
                    "name": "Build and unit test",
                    "state": "IN_PROGRESS",
                    "workflow": "Floorp iOS CI",
                }]) + "\n",
                encoding="utf-8",
            )
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)

    def test_check_run_head_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            check_runs_path = Path(values["check_runs"])
            check_runs = json.loads(check_runs_path.read_text(encoding="utf-8"))
            check_runs["check_runs"][0]["head_sha"] = "9" * 40
            check_runs_path.write_text(json.dumps(check_runs) + "\n", encoding="utf-8")
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)

    def test_workflow_branch_provenance_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            workflow_runs_path = Path(values["workflow_runs"])
            workflow_runs = json.loads(workflow_runs_path.read_text(encoding="utf-8"))
            workflow_runs["workflow_runs"][0]["head_branch"] = "main"
            workflow_runs_path.write_text(json.dumps(workflow_runs) + "\n", encoding="utf-8")
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)

    def test_workflow_path_provenance_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            workflow_runs_path = Path(values["workflow_runs"])
            workflow_runs = json.loads(workflow_runs_path.read_text(encoding="utf-8"))
            workflow_runs["workflow_runs"][0]["path"] = ".github/workflows/notes-ui.yml"
            workflow_runs_path.write_text(json.dumps(workflow_runs) + "\n", encoding="utf-8")
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)

    def test_pull_request_association_head_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            check_runs_path = Path(values["check_runs"])
            check_runs = json.loads(check_runs_path.read_text(encoding="utf-8"))
            check_runs["check_runs"][0]["pull_requests"][0]["head"]["sha"] = "9" * 40
            check_runs_path.write_text(json.dumps(check_runs) + "\n", encoding="utf-8")
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)

    def test_owner_head_drift_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            values = self.write_inputs(Path(directory))
            owner_path = Path(values["owner"])
            owner = json.loads(owner_path.read_text(encoding="utf-8"))
            owner["head_sha"] = "9" * 40
            owner_path.write_bytes(ADMISSION.canonical(owner))
            self.assertNotEqual(ADMISSION.main(self.args(values)), 0)


if __name__ == "__main__":
    unittest.main()
