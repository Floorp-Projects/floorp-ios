"""TDD tests for protected Todo 20 merge-artifact provenance."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/verify-floorp-notes-sync-guarded-merge-artifact.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


VERIFY = load_module(SCRIPT, "floorp_notes_sync_guarded_merge_artifact_test")


class GuardedMergeArtifactTests(unittest.TestCase):
    def write_inputs(self, root: Path) -> tuple[Path, Path, Path, Path, Path, Path]:
        admission = {
            "admin_bypass_used": False,
            "base_oid": "1" * 40,
            "base_ref_name": "main",
            "checks_count": 4,
            "checks_sha256": "a" * 64,
            "head_sha": "2" * 40,
            "head_ref_name": "agent/floorp-plan-t20-live-executor",
            "native_github_approval": False,
            "operator_id": "operator",
            "owner_review_sha256": "b" * 64,
            "plan_binding_sha256": "c" * 64,
            "pr_number": 106,
            "repository": VERIFY.REPOSITORY,
            "schema_version": 1,
            "status": "GO",
            "subagent_review_commit_sha": "3" * 40,
            "subagent_review_sha256": "d" * 64,
            "terminal_ci": True,
        }
        admission_raw = VERIFY.canonical(admission)
        admission_path = root / "merge-admission.json"
        admission_path.write_bytes(admission_raw)
        operation = {
            "base_oid": "1" * 40,
            "head_sha": "2" * 40,
            "merge_endpoint": "PUT /repos/Floorp-Projects/floorp-ios/pulls/106/merge",
            "merge_method": "squash",
            "merge_response": {"merged": True, "sha": "4" * 40},
            "merge_response_sha256": VERIFY.sha256(VERIFY.canonical({"merged": True, "sha": "4" * 40})),
            "merge_response_source": "github-api-put-merge-executor",
            "merge_admission_receipt_sha256": VERIFY.sha256(admission_raw),
            "merged_oid": "4" * 40,
            "oid_guarded": True,
            "pr_number": 106,
            "repository": VERIFY.REPOSITORY,
            "schema_version": 1,
            "server_merge_sha": "4" * 40,
            "server_merged": True,
            "server_merged_at": "2026-08-15T00:00:00Z",
        }
        operation_raw = VERIFY.canonical(operation)
        operation_path = root / "merge-operation-receipt.json"
        operation_path.write_bytes(operation_raw)
        merge = {
            "admin_bypass_used": False,
            "audit_bypass_event_count": 0,
            "audit_event_count": 1,
            "audit_event_id_sha256": "a" * 64,
            "audit_event_timestamp": "2026-08-15T00:00:00Z",
            "audit_projection_sha256": "b" * 64,
            "audit_source": "github-org-audit-log",
            "base_oid": "1" * 40,
            "bypass_requested": False,
            "head_sha": "2" * 40,
            "merge_endpoint": "PUT /repos/Floorp-Projects/floorp-ios/pulls/106/merge",
            "merge_method": "squash",
            "merge_response": {"merged": True, "sha": "4" * 40},
            "merge_response_sha256": VERIFY.sha256(VERIFY.canonical({"merged": True, "sha": "4" * 40})),
            "merge_response_source": "github-api-put-merge-executor",
            "merge_admission_receipt_sha256": VERIFY.sha256(admission_raw),
            "merged_oid": "4" * 40,
            "oid_guarded": True,
            "operation_receipt_sha256": VERIFY.sha256(operation_raw),
            "pr_number": 106,
            "repository": VERIFY.REPOSITORY,
            "schema_version": 2,
            "server_merge_sha": "4" * 40,
            "server_merged": True,
            "server_merged_at": "2026-08-15T00:00:00Z",
            "source_workflow": "protected-guarded-merge-workflow",
            "source_workflow_run_id": 123,
            "source_workflow_sha": "2" * 40,
        }
        merge_path = root / "merge-audit.json"
        merge_path.write_bytes(VERIFY.canonical(merge))
        metadata_path = root / "merge-artifact-metadata.json"
        metadata_path.write_bytes(
            VERIFY.canonical(
                {
                    "artifact_digest": "e" * 64,
                    "artifact_id": 456,
                    "artifact_name": "floorp-notes-sync-guarded-merge-123",
                    "conclusion": "success",
                    "event": "workflow_dispatch",
                    "head_branch": "agent/floorp-plan-t20-live-executor",
                    "head_sha": "2" * 40,
                    "repository": VERIFY.REPOSITORY,
                    "run_id": 123,
                    "schema_version": 1,
                    "status": "completed",
                    "workflow_path": ".github/workflows/ci.yml",
                }
            )
        )
        run_path = root / "run.json"
        run_path.write_text(
            json.dumps(
                {
                    "id": 123,
                    "path": ".github/workflows/ci.yml",
                    "event": "workflow_dispatch",
                    "head_branch": "agent/floorp-plan-t20-live-executor",
                    "head_sha": "2" * 40,
                    "status": "completed",
                    "conclusion": "success",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        artifacts_path = root / "artifacts.json"
        artifacts_path.write_text(
            json.dumps(
                {
                    "artifacts": [
                        {
                            "id": 456,
                            "name": "floorp-notes-sync-guarded-merge-123",
                            "digest": "sha256:" + "e" * 64,
                            "expired": False,
                            "workflow_run": {"id": 123},
                        }
                    ]
                }
            )
            + "\n",
            encoding="utf-8",
        )
        return merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path

    def test_artifact_binds_run_head_oid_and_executor_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = self.write_inputs(Path(directory))
            self.assertEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def test_artifact_run_id_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = self.write_inputs(Path(directory))
            self.assertNotEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "999",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def test_operation_receipt_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = self.write_inputs(Path(directory))
            value = json.loads(merge_path.read_text(encoding="utf-8"))
            value["operation_receipt_sha256"] = "f" * 64
            merge_path.write_bytes(VERIFY.canonical(value))
            self.assertNotEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def write_recovery_state(
        self,
        root: Path,
        paths: tuple[Path, Path, Path, Path, Path, Path],
        with_evidence: bool,
    ) -> None:
        merge_path, _operation_path, _admission_path, metadata_path, run_path, _artifacts_path = paths
        recovery_head = "5" * 40
        run = json.loads(run_path.read_text(encoding="utf-8"))
        run["head_sha"] = recovery_head
        run_path.write_text(json.dumps(run) + "\n", encoding="utf-8")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["head_sha"] = recovery_head
        metadata_path.write_bytes(VERIFY.canonical(metadata))
        merge = json.loads(merge_path.read_text(encoding="utf-8"))
        merge["source_workflow_sha"] = recovery_head
        merge_path.write_bytes(VERIFY.canonical(merge))
        evidence_path = root / "merge-recovery-evidence.json"
        if with_evidence:
            evidence_path.write_bytes(
                VERIFY.canonical(
                    {
                        "admission_receipt_sha256": VERIFY.sha256(
                            (root / "merge-admission.json").read_bytes()
                        ),
                        "expected_head_sha": "2" * 40,
                        "expected_merged_oid": "4" * 40,
                        "merged_at_utc": "2026-08-15T00:00:00Z",
                        "operation_receipt_sha256": VERIFY.sha256(
                            (root / "merge-operation-receipt.json").read_bytes()
                        ),
                        "recovery_head_sha": recovery_head,
                        "recovery_run_id": 123,
                        "schema_version": 1,
                        "source_executor_step_success": True,
                        "source_run_id": 1001,
                    }
                )
            )

    def test_recovery_run_with_evidence_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self.write_inputs(root)
            self.write_recovery_state(root, paths, with_evidence=True)
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = paths
            self.assertEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def test_recovery_run_without_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self.write_inputs(root)
            self.write_recovery_state(root, paths, with_evidence=False)
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = paths
            self.assertNotEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def test_exact_head_run_with_recovery_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self.write_inputs(root)
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = paths
            evidence_path = root / "merge-recovery-evidence.json"
            evidence_path.write_bytes(
                VERIFY.canonical(
                    {
                        "admission_receipt_sha256": VERIFY.sha256(
                            (root / "merge-admission.json").read_bytes()
                        ),
                        "expected_head_sha": "2" * 40,
                        "expected_merged_oid": "4" * 40,
                        "merged_at_utc": "2026-08-15T00:00:00Z",
                        "operation_receipt_sha256": VERIFY.sha256(
                            (root / "merge-operation-receipt.json").read_bytes()
                        ),
                        "recovery_head_sha": "2" * 40,
                        "recovery_run_id": 123,
                        "schema_version": 1,
                        "source_executor_step_success": True,
                        "source_run_id": 1001,
                    }
                )
            )
            self.assertNotEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    @staticmethod
    def to_waived_v3(merge: dict[str, object]) -> dict[str, object]:
        value = dict(merge)
        value["schema_version"] = 3
        value["admin_bypass_used"] = None
        value["audit_bypass_event_count"] = None
        value["audit_endpoint_unavailable"] = True
        value["audit_event_count"] = 0
        value["audit_event_id_sha256"] = None
        value["audit_event_timestamp"] = None
        value["audit_projection_sha256"] = None
        value["audit_source"] = "github-org-audit-log-unavailable-owner-waived"
        value["waiver_approved_at_utc"] = "2026-08-16T00:00:00Z"
        value["waiver_operator_id"] = "operator"
        value["waiver_plan_hash"] = "c" * 64
        return value

    def test_waived_v3_merge_audit_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = self.write_inputs(Path(directory))
            value = json.loads(merge_path.read_text(encoding="utf-8"))
            merge_path.write_bytes(VERIFY.canonical(self.to_waived_v3(value)))
            self.assertEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )

    def test_waived_v3_with_bypass_claim_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            merge_path, operation_path, admission_path, metadata_path, run_path, artifacts_path = self.write_inputs(Path(directory))
            value = json.loads(merge_path.read_text(encoding="utf-8"))
            waived = self.to_waived_v3(value)
            waived["admin_bypass_used"] = False
            merge_path.write_bytes(VERIFY.canonical(waived))
            self.assertNotEqual(
                VERIFY.main(
                    [
                        "--merge-audit", str(merge_path),
                        "--operation-receipt", str(operation_path),
                        "--admission-receipt", str(admission_path),
                        "--run-json", str(run_path),
                        "--artifacts-json", str(artifacts_path),
                        "--artifact-metadata", str(metadata_path),
                        "--expected-run-id", "123",
                        "--expected-pr-number", "106",
                        "--expected-head-sha", "2" * 40,
                        "--expected-merged-oid", "4" * 40,
                    ]
                ),
                0,
            )


if __name__ == "__main__":
    unittest.main()
