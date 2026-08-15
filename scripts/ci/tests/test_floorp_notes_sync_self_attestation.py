"""TDD tests for the single-operator append-only attestation boundary."""

from __future__ import annotations

import importlib.util
import hashlib
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

    def evidence(self, root: Path) -> dict[str, Path]:
        paths = {
            "manifest": root / "qa-manifest.json",
            "summary": root / "qa-summary.json",
            "cleanup": root / "cleanup-receipt.json",
            "secret_scan": root / "secret-scan.json",
            "review_receipt": root / "review-receipt.json",
            "pr_metadata": root / "pr-metadata.json",
            "reviews_metadata": root / "reviews-metadata.json",
            "ruleset_metadata": root / "ruleset-metadata.json",
        }
        for name, path in paths.items():
            if name == "manifest":
                continue
            path.write_bytes(json.dumps({"artifact": name}, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        paths["review_receipt"].write_bytes(
            json.dumps(
                {
                    "admin_bypass_used": False,
                    "amendment_sha256": "e" * 64,
                    "base_oid": "b" * 40,
                    "bypass_requested": False,
                    "combined_plan_hash": "f" * 64,
                    "contract_sha256": "2" * 64,
                    "diff_sha256": "c" * 64,
                    "desktop_sha": "b" * 40,
                    "environment": RECORD.ENVIRONMENT,
                    "head_sha": "1" * 40,
                    "independence": False,
                    "local_test_accounts_accessed": False,
                    "merged_oid": "a" * 40,
                    "native_github_approval": False,
                    "operator_id": "operator",
                    "owner_review_receipt_sha256": "3" * 64,
                    "merge_audit_sha256": "4" * 64,
                    "merge_endpoint": "PUT /repos/Floorp-Projects/floorp-ios/pulls/106/merge",
                    "merge_response_sha256": "9" * 64,
                    "server_merge_sha": "a" * 40,
                    "server_merged": True,
                    "plan_binding_sha256": "5" * 64,
                    "plan_sha256": "d" * 64,
                    "pr_api_sha256": "6" * 64,
                    "pr_projection_sha256": hashlib.sha256(paths["pr_metadata"].read_bytes()).hexdigest(),
                    "pr_number": 106,
                    "public_release": False,
                    "repository": RECORD.REPOSITORY,
                    "review_scope": "todo-20-pr-and-production-qa",
                    "reviewed_at_utc": "2026-08-15T00:00:00Z",
                    "roles": ["owner", "operations", "executor", "reviewer"],
                    "ruleset_required_review_count": 0,
                    "reviews_count": 0,
                    "schema_version": 2,
                    "self_review_exception": True,
                    "subagent_review_digests": ["1" * 64],
                    "subagent_review_receipt_sha256": "1" * 64,
                    "subagent_review_commit_sha": "9" * 40,
                    "two_disposable_accounts_only": True,
                    "unresolved_blocking_findings": [],
                    "reviews_api_sha256": "7" * 64,
                    "reviews_projection_sha256": hashlib.sha256(paths["reviews_metadata"].read_bytes()).hexdigest(),
                    "ruleset_api_sha256": "8" * 64,
                    "ruleset_projection_sha256": hashlib.sha256(paths["ruleset_metadata"].read_bytes()).hexdigest(),
                },
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
            + b"\n"
        )
        roles = (
            "qa-summary",
            "cleanup-receipt",
            "xcresult",
            "xcodebuild-log",
            "desktop-log",
            "production-qa-capability",
            "production-qa-xcconfig",
            "review-receipt",
            "pr-metadata",
            "reviews-metadata",
            "ruleset-metadata",
            "secret-scan",
        )
        role_paths = {
            "review-receipt": paths["review_receipt"],
            "pr-metadata": paths["pr_metadata"],
            "reviews-metadata": paths["reviews_metadata"],
            "ruleset-metadata": paths["ruleset_metadata"],
        }
        artifacts = []
        for role in roles:
            target = role_paths.get(role)
            artifacts.append(
                {
                    "byte_count": target.stat().st_size if target else 1,
                    "name": target.name if target else f"{role}.json",
                    "role": role,
                    "sha256": hashlib.sha256(target.read_bytes()).hexdigest() if target else "0" * 64,
                }
            )
        paths["manifest"].write_bytes(
            json.dumps(
                {
                    "accounts": 2,
                    "artifacts": artifacts,
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
            "--review-receipt", str(paths["review_receipt"]),
        ]

    def test_record_and_validate_one_append_only_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            paths = self.evidence(Path(directory))
            with patch.dict(os.environ, self.environment(), clear=True):
                self.assertEqual(RECORD.main(self.arguments(path, paths)), 0)
            value, raw = VALIDATE.load(path)
            VALIDATE.validate(value, "1" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"], paths["review_receipt"])
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
                VALIDATE.validate(value, "1" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"], paths["review_receipt"])
            value, _ = VALIDATE.load(path)
            with self.assertRaises(VALIDATE.AttestationError):
                VALIDATE.validate(value, "b" * 40, "a" * 40, 123, 1, paths["manifest"], paths["summary"], paths["cleanup"], paths["secret_scan"], paths["review_receipt"])

    def test_missing_review_metadata_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "self-attestation.jsonl"
            paths = self.evidence(Path(directory))
            paths["review_receipt"].unlink()
            with patch.dict(os.environ, self.environment(), clear=True):
                self.assertEqual(RECORD.main(self.arguments(path, paths)), 78)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
