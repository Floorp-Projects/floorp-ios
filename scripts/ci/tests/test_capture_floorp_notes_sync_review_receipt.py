"""TDD tests for source-bound Todo 20 review receipts."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/capture-floorp-notes-sync-review-receipt.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


CAPTURE = load_module(SCRIPT, "floorp_notes_sync_review_receipt_capture_test")


def contract() -> dict[str, Any]:
    return {
        "approval_model": {
            "environment": CAPTURE.ENVIRONMENT,
            "global_governance_unchanged": True,
            "independence": False,
            "native_github_approval": False,
            "required_approving_review_count": 0,
            "reviews_count": 0,
            "self_attestation": "owner-operations-executor-reviewer",
            "self_review_exception": True,
        },
        "boundary": {
            "credential_delivery": "protected-environment-secrets-only",
            "execution_authorization": "single-operator-protected-qa",
            "phase_1_result": "data-integrity-qa-required",
            "public_release": "forbidden",
        },
        "integrity_matrix": {"accounts": 2, "payload_observation": "forbidden"},
        "isolation_contract": {"accounts": 2, "payload_retained": False},
        "participant_contract": {"test_attachments": "forbidden"},
        "safety_boundary": {
            "admin_bypass_allowed": False,
            "local_test_accounts_accessed": False,
            "native_github_approval": False,
            "public_release": False,
            "two_disposable_accounts_only": True,
        },
    }


def plan_binding() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "task_id": 20,
        "plan_sha256": "a" * 64,
        "amendment_sha256": "b" * 64,
        "combined_plan_hash": "c" * 64,
    }


def owner_review() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "repository": CAPTURE.REPOSITORY,
        "pr_number": 106,
        "base_oid": "1" * 40,
        "head_sha": "2" * 40,
        "desktop_sha": "5" * 40,
        "diff_sha256": "d" * 64,
        "plan_sha256": "a" * 64,
        "amendment_sha256": "b" * 64,
        "combined_plan_hash": "c" * 64,
        "self_review_exception": True,
        "independence": False,
        "operator_id": "operator",
        "public_release": False,
        "unresolved_blocking_findings": [],
        "reviewed_at_utc": "2026-08-15T00:00:00Z",
        "checklist": {"exact_head": True, "scope": True, "security": True},
        "attestation_statement": "Todo 20 bounded owner self-review recorded.",
    }


def merge_audit() -> dict[str, Any]:
    merge_response = {"merged": True, "sha": "4" * 40}
    audit_projection = {
        "merge_events": [
            {
                "action": "pull_request.merge",
                "event_id_sha256": CAPTURE.sha256_bytes(b"event-1"),
                "pull_request_path": "/pull/106/merge",
                "repository": CAPTURE.REPOSITORY,
                "timestamp": "2026-08-15T00:00:00Z",
            }
        ]
    }
    return {
        "schema_version": 2,
        "repository": CAPTURE.REPOSITORY,
        "pr_number": 106,
        "base_oid": "1" * 40,
        "head_sha": "2" * 40,
        "merged_oid": "4" * 40,
        "bypass_requested": False,
        "merge_endpoint": "PUT /repos/Floorp-Projects/floorp-ios/pulls/106/merge",
        "merge_method": "squash",
        "merge_response": merge_response,
        "merge_response_sha256": CAPTURE.sha256_bytes(CAPTURE.canonical(merge_response)),
        "merge_response_source": "github-api-put-merge-executor",
        "audit_bypass_event_count": 0,
        "audit_event_count": 1,
        "audit_event_id_sha256": CAPTURE.sha256_bytes(b"event-1"),
        "audit_event_timestamp": "2026-08-15T00:00:00Z",
        "audit_projection_sha256": CAPTURE.sha256_bytes(CAPTURE.canonical(audit_projection)),
        "audit_source": "github-org-audit-log",
        "oid_guarded": True,
        "admin_bypass_used": False,
        "server_merge_sha": "4" * 40,
        "server_merged": True,
        "server_merged_at": "2026-08-15T00:00:00Z",
        "operation_receipt_sha256": "6" * 64,
    }


def subagent_review() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "repository": CAPTURE.REPOSITORY,
        "head_sha": "2" * 40,
        "desktop_sha": "5" * 40,
        "independence": True,
        "reviewer_id": "01234567-89ab-cdef-0123-456789abcdef",
        "review_method": "codex-read-only-diff",
        "status": "GO",
        "findings": [],
        "reviewed_at_utc": "2026-08-15T00:00:00Z",
    }


def pr() -> dict[str, Any]:
    return {
        "number": 106,
        "state": "closed",
        "merged": True,
        "merged_at": "2026-08-15T00:00:00Z",
        "merge_commit_sha": "4" * 40,
        "base": {"sha": "1" * 40, "ref": "main", "repo": {"full_name": CAPTURE.REPOSITORY}},
        "head": {"sha": "2" * 40, "repo": {"full_name": CAPTURE.REPOSITORY}},
    }


class CaptureReceiptTests(unittest.TestCase):
    def test_receipt_uses_api_git_and_artifact_bound_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = CAPTURE.build_receipt(
                pr(),
                [],
                {
                    "id": 20229460,
                    "name": "Protect Floorp iOS main",
                    "target": "branch",
                    "source_type": "Repository",
                    "source": CAPTURE.REPOSITORY,
                    "enforcement": "active",
                    "conditions": {"ref_name": {"exclude": [], "include": ["refs/heads/main"]}},
                    "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
                    "rules": [
                        {
                            "type": "pull_request",
                            "parameters": {
                                "required_approving_review_count": 0,
                                "required_reviewers": [],
                            },
                        },
                        {
                            "type": "required_status_checks",
                            "parameters": {
                                "required_status_checks": [
                                    {"context": "Validate workflows"},
                                    {"context": "Build and unit test"},
                                ]
                            },
                        },
                    ],
                },
                contract(),
                plan_binding(),
                owner_review(),
                merge_audit(),
                subagent_review(),
                "d" * 64,
                "4" * 40,
                "5" * 40,
                "7" * 40,
                CAPTURE.sha256_bytes(b"contract"),
                CAPTURE.sha256_bytes(b"binding"),
                CAPTURE.sha256_bytes(b"owner"),
                CAPTURE.sha256_bytes(b"merge"),
                CAPTURE.sha256_bytes(b"subagent"),
                "3" * 40,
                CAPTURE.sha256_bytes(b"pr"),
                CAPTURE.sha256_bytes(b"reviews"),
                CAPTURE.sha256_bytes(b"ruleset"),
                CAPTURE.sha256_bytes(b"pr-projection"),
                CAPTURE.sha256_bytes(b"reviews-projection"),
                CAPTURE.sha256_bytes(b"ruleset-projection"),
            )
            self.assertEqual(receipt["base_oid"], "1" * 40)
            self.assertEqual(receipt["head_sha"], "2" * 40)
            self.assertEqual(receipt["merged_oid"], "4" * 40)
            self.assertEqual(receipt["diff_sha256"], "d" * 64)
            self.assertEqual(receipt["reviews_count"], 0)
            self.assertEqual(receipt["subagent_review_digests"], [CAPTURE.sha256_bytes(b"subagent")])
            self.assertFalse(receipt["admin_bypass_used"])

    def test_stale_server_merged_at_is_rejected(self) -> None:
        later_pr = pr()
        later_pr["merged_at"] = "2026-08-16T00:00:00Z"
        with self.assertRaises(CAPTURE.ReviewReceiptError):
            CAPTURE.build_receipt(
                later_pr,
                [],
                {
                    "id": 20229460,
                    "name": "Protect Floorp iOS main",
                    "target": "branch",
                    "source_type": "Repository",
                    "source": CAPTURE.REPOSITORY,
                    "enforcement": "active",
                    "conditions": {"ref_name": {"exclude": [], "include": ["refs/heads/main"]}},
                    "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
                    "rules": [
                        {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "required_reviewers": []}},
                        {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Validate workflows"}, {"context": "Build and unit test"}]}},
                    ],
                },
                contract(),
                plan_binding(),
                owner_review(),
                merge_audit(),
                subagent_review(),
                "d" * 64,
                "4" * 40,
                "5" * 40,
                "7" * 40,
                "a" * 64,
                "b" * 64,
                "c" * 64,
                "d" * 64,
                "e" * 64,
                "3" * 40,
                "0" * 64,
                "1" * 64,
                "2" * 64,
                "3" * 64,
                "4" * 64,
                "5" * 64,
            )

    def test_stale_owner_receipt_is_rejected(self) -> None:
        with self.assertRaises(CAPTURE.ReviewReceiptError):
            stale = owner_review()
            stale["head_sha"] = "9" * 40
            CAPTURE.build_receipt(
                pr(),
                [],
                {
                    "id": 20229460,
                    "name": "Protect Floorp iOS main",
                    "target": "branch",
                    "source_type": "Repository",
                    "source": CAPTURE.REPOSITORY,
                    "enforcement": "active",
                    "conditions": {"ref_name": {"exclude": [], "include": ["refs/heads/main"]}},
                    "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
                    "rules": [
                        {
                            "type": "pull_request",
                            "parameters": {
                                "required_approving_review_count": 0,
                                "required_reviewers": [],
                            },
                        },
                        {
                            "type": "required_status_checks",
                            "parameters": {
                                "required_status_checks": [
                                    {"context": "Validate workflows"},
                                    {"context": "Build and unit test"},
                                ]
                            },
                        },
                    ],
                },
                contract(),
                plan_binding(),
                stale,
                merge_audit(),
                subagent_review(),
                "d" * 64,
                "4" * 40,
                "5" * 40,
                "7" * 40,
                "a" * 64,
                "b" * 64,
                "c" * 64,
                "d" * 64,
                "e" * 64,
                "f" * 64,
                "3" * 40,
                "0" * 64,
                "1" * 64,
                "2" * 64,
                "3" * 64,
                "4" * 64,
            )

    def test_non_main_ruleset_target_is_rejected(self) -> None:
        ruleset = {
            "id": 20229460,
            "name": "Protect Floorp iOS main",
            "target": "branch",
            "source_type": "Repository",
            "source": CAPTURE.REPOSITORY,
            "enforcement": "active",
            "conditions": {"ref_name": {"exclude": [], "include": ["refs/heads/release"]}},
            "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
            "rules": [],
        }
        with self.assertRaises(CAPTURE.ReviewReceiptError):
            CAPTURE.validate_ruleset(ruleset)

    def test_multiple_pull_request_rules_are_rejected(self) -> None:
        ruleset = {
            "id": 20229460,
            "name": "Protect Floorp iOS main",
            "target": "branch",
            "source_type": "Repository",
            "source": CAPTURE.REPOSITORY,
            "enforcement": "active",
            "conditions": {"ref_name": {"exclude": [], "include": ["refs/heads/main"]}},
            "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
            "rules": [
                {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "required_reviewers": []}},
                {"type": "pull_request", "parameters": {"required_approving_review_count": 1, "required_reviewers": []}},
            ],
        }
        with self.assertRaises(CAPTURE.ReviewReceiptError):
            CAPTURE.validate_ruleset(ruleset)

    def test_audit_log_requires_exact_merge_event_and_rejects_bypass(self) -> None:
        audit = [
            {
                "action": "pull_request.merge",
                "repo": CAPTURE.REPOSITORY,
                "@timestamp": "2026-08-15T00:00:00Z",
                "_document_id": "event-1",
                "data": {"url": "https://github.com/Floorp-Projects/floorp-ios/pull/106/merge"},
            }
        ]
        projection = {
            "merge_events": [
                {
                    "action": "pull_request.merge",
                    "event_id_sha256": CAPTURE.sha256_bytes(b"event-1"),
                    "pull_request_path": "/pull/106/merge",
                    "repository": CAPTURE.REPOSITORY,
                    "timestamp": "2026-08-15T00:00:00Z",
                }
            ]
        }
        merge = merge_audit()
        merge["audit_projection_sha256"] = CAPTURE.sha256_bytes(CAPTURE.canonical(projection))
        merge["audit_event_count"] = 1
        audit_raw = json.dumps(audit, separators=(",", ":")).encode()
        self.assertEqual(
            CAPTURE.validate_github_audit_log(audit, audit_raw, merge, pr(), "4" * 40),
            (merge["audit_projection_sha256"], 1),
        )
        bypass = [
            *audit,
            {"action": "protected_branch.policy_override", "repo": CAPTURE.REPOSITORY},
        ]
        with self.assertRaises(CAPTURE.ReviewReceiptError):
            CAPTURE.validate_github_audit_log(
                bypass,
                json.dumps(bypass, separators=(",", ":")).encode(),
                merge,
                pr(),
                "4" * 40,
            )

    def test_subagent_artifact_is_bound_to_one_immutable_commit_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            raw = CAPTURE.canonical(subagent_review())
            artifact = root / "docs/floorp-notes-sync-todo20-subagent-review.json"
            artifact.write_bytes(raw)
            subprocess.run(["/usr/bin/git", "-C", str(root), "init", "--quiet"], check=True)
            subprocess.run(["/usr/bin/git", "-C", str(root), "add", "docs/floorp-notes-sync-todo20-subagent-review.json"], check=True)
            subprocess.run(
                ["/usr/bin/git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "attestation"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            commit = subprocess.check_output(["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            CAPTURE.verify_immutable_subagent_commit(root, commit, raw)
            with self.assertRaises(CAPTURE.ReviewReceiptError):
                CAPTURE.verify_immutable_subagent_commit(root, commit, raw + b" ")


if __name__ == "__main__":
    unittest.main()
