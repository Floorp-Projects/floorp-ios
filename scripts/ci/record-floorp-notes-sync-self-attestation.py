#!/usr/bin/python3 -I
"""Record the single-operator Todo 20 approval in an append-only JSONL file."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
JOB = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVIEW_ROLES = ["owner", "operations", "executor", "reviewer"]


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--cleanup-receipt", type=Path, required=True)
    parser.add_argument("--secret-scan", type=Path, required=True)
    parser.add_argument("--review-receipt", type=Path, required=True)
    return parser.parse_args(arguments)


def read_evidence(path: Path) -> bytes:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=evidence_unavailable_{path.name}") from error
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=evidence_not_regular_{path.name}")
    return raw


def digest(path: Path) -> str:
    return hashlib.sha256(read_evidence(path)).hexdigest()


def load_review_receipt(path: Path, source: dict[str, Any]) -> tuple[dict[str, Any], str]:
    raw = read_evidence(path)
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_not_canonical")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_invalid_json") from error
    expected = {
        "admin_bypass_used", "amendment_sha256", "base_oid", "combined_plan_hash",
        "bypass_requested", "merge_audit_commit_sha", "merge_endpoint", "merge_response_sha256", "server_merge_sha", "server_merged",
        "contract_sha256", "diff_sha256", "environment", "head_sha",
        "desktop_sha", "independence", "local_test_accounts_accessed", "merged_oid",
        "native_github_approval", "operator_id", "owner_review_receipt_sha256",
        "merge_audit_sha256", "plan_binding_sha256", "plan_sha256", "pr_number",
        "pr_api_sha256", "reviews_api_sha256", "ruleset_api_sha256",
        "public_release", "repository", "review_scope", "reviewed_at_utc",
        "roles", "ruleset_required_review_count", "reviews_count", "schema_version",
        "self_review_exception", "subagent_review_digests",
        "subagent_review_receipt_sha256", "two_disposable_accounts_only",
        "unresolved_blocking_findings", "pr_projection_sha256", "reviews_projection_sha256",
        "ruleset_projection_sha256", "subagent_review_commit_sha",
    }
    if not isinstance(value, dict) or set(value) != expected or raw != canonical(value):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_fields_invalid")
    if (
        value["environment"] != ENVIRONMENT
        or value["repository"] != REPOSITORY
        or value["merged_oid"] != source["head_sha"]
        or value["operator_id"] != source["actor"]
        or value["roles"] != REVIEW_ROLES
        or value["self_review_exception"] is not True
        or value["independence"] is not False
        or value["native_github_approval"] is not False
        or value["admin_bypass_used"] is not False
        or value["bypass_requested"] is not False
        or value["merge_endpoint"] != f"PUT /repos/{REPOSITORY}/pulls/{value['pr_number']}/merge"
        or value["server_merged"] is not True
        or value["server_merge_sha"] != value["merged_oid"]
        or value["ruleset_required_review_count"] != 0
        or value["reviews_count"] != 0
        or value["two_disposable_accounts_only"] is not True
        or value["local_test_accounts_accessed"] is not False
        or value["public_release"] is not False
        or value["unresolved_blocking_findings"] != []
        or value["review_scope"] != "todo-20-pr-and-production-qa"
        or not isinstance(value["pr_number"], int)
        or value["pr_number"] <= 0
        or not isinstance(value["reviewed_at_utc"], str)
        or not value["reviewed_at_utc"].endswith("Z")
        or not SHA1.fullmatch(value["base_oid"])
        or not SHA1.fullmatch(value["head_sha"])
        or not SHA1.fullmatch(value["desktop_sha"])
        or not SHA1.fullmatch(value["merged_oid"])
        or not SHA1.fullmatch(value["merge_audit_commit_sha"])
        or not SHA1.fullmatch(value["subagent_review_commit_sha"])
        or not isinstance(value["subagent_review_digests"], list)
        or not value["subagent_review_digests"]
    ):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_binding_invalid")
    for field in (
        "amendment_sha256", "combined_plan_hash", "contract_sha256", "diff_sha256",
        "owner_review_receipt_sha256", "merge_audit_sha256", "plan_binding_sha256",
        "plan_sha256", "subagent_review_receipt_sha256",
        "pr_api_sha256", "reviews_api_sha256", "ruleset_api_sha256",
        "pr_projection_sha256", "reviews_projection_sha256", "ruleset_projection_sha256",
        "merge_response_sha256",
    ):
        if not SHA256.fullmatch(value[field]):
            raise RuntimeError(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_{field}_invalid")
    if any(not SHA256.fullmatch(item) for item in value["subagent_review_digests"]):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_subagent_digest_invalid")
    if value["subagent_review_receipt_sha256"] not in value["subagent_review_digests"]:
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_subagent_binding_invalid")
    return value, hashlib.sha256(raw).hexdigest()

def context() -> dict[str, Any]:
    required = (
        "GITHUB_ACTOR", "GITHUB_EVENT_NAME", "GITHUB_JOB", "GITHUB_REF",
        "GITHUB_REPOSITORY", "GITHUB_RUN_ATTEMPT", "GITHUB_RUN_ID", "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    if any(not os.environ.get(name) for name in required):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=self_attestation_context_missing")
    if (
        os.environ["GITHUB_EVENT_NAME"] != "workflow_dispatch"
        or os.environ["GITHUB_JOB"] != JOB
        or os.environ["GITHUB_REF"] != "refs/heads/main"
        or os.environ["GITHUB_REPOSITORY"] != REPOSITORY
        or not os.environ["GITHUB_WORKFLOW_REF"].startswith(f"{REPOSITORY}/{WORKFLOW_PATH}@")
    ):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=self_attestation_workflow_invalid")
    source = {
        "actor": os.environ["GITHUB_ACTOR"],
        "head_sha": os.environ["GITHUB_SHA"],
        "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
    }
    return source


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        source = context()
        review, review_receipt_sha256 = load_review_receipt(args.review_receipt, source)
        manifest_sha256 = digest(args.manifest)
        summary_sha256 = digest(args.summary)
        cleanup_sha256 = digest(args.cleanup_receipt)
        secret_scan_sha256 = digest(args.secret_scan)
        event = {
            "accounts": 2,
            "admin_bypass_used": review["admin_bypass_used"],
            "bypass_requested": review["bypass_requested"],
            "merge_audit_commit_sha": review["merge_audit_commit_sha"],
            "amendment_sha256": review["amendment_sha256"],
            "base_oid": review["base_oid"],
            "cleanup": {
                "accounts": True,
                "coordination_root": True,
                "local_cache": True,
                "runner_temp": True,
                "simulator_keychain": True,
            },
            "environment": ENVIRONMENT,
            "event": "self-attestation",
            "evidence_manifest_sha256": manifest_sha256,
            "manifest_sha256": manifest_sha256,
            "head_sha": review["head_sha"],
            "merged_oid": review["merged_oid"],
            "desktop_sha": review["desktop_sha"],
            "native_github_approval": review["native_github_approval"],
            "merge_endpoint": review["merge_endpoint"],
            "merge_response_sha256": review["merge_response_sha256"],
            "server_merge_sha": review["server_merge_sha"],
            "server_merged": review["server_merged"],
            "operator_id": review["operator_id"],
            "previous_event_sha256": "0" * 64,
            "public_release": False,
            "cleanup_receipt_sha256": cleanup_sha256,
            "qa_summary_sha256": summary_sha256,
            "repository": review["repository"],
            "pr_number": review["pr_number"],
            "pr_api_sha256": review["pr_api_sha256"],
            "reviews_api_sha256": review["reviews_api_sha256"],
            "ruleset_api_sha256": review["ruleset_api_sha256"],
            "pr_projection_sha256": review["pr_projection_sha256"],
            "reviews_projection_sha256": review["reviews_projection_sha256"],
            "ruleset_projection_sha256": review["ruleset_projection_sha256"],
            "review_scope": review["review_scope"],
            "reviewed_at_utc": review["reviewed_at_utc"],
            "roles": review["roles"],
            "ruleset_required_review_count": review["ruleset_required_review_count"],
            "reviews_count": review["reviews_count"],
            "schema_version": 2,
            "secret_scan_sha256": secret_scan_sha256,
            "secret_scan_scope": "pre-attestation",
            "sequence": 1,
            "self_review_exception": review["self_review_exception"],
            "independence": review["independence"],
            "subagent_review_digests": review["subagent_review_digests"],
            "two_disposable_accounts_only": review["two_disposable_accounts_only"],
            "local_test_accounts_accessed": review["local_test_accounts_accessed"],
            "unresolved_blocking_findings": review["unresolved_blocking_findings"],
            "diff_sha256": review["diff_sha256"],
            "plan_sha256": review["plan_sha256"],
            "combined_plan_hash": review["combined_plan_hash"],
            "contract_sha256": review["contract_sha256"],
            "plan_binding_sha256": review["plan_binding_sha256"],
            "owner_review_receipt_sha256": review["owner_review_receipt_sha256"],
            "merge_audit_sha256": review["merge_audit_sha256"],
            "subagent_review_receipt_sha256": review["subagent_review_receipt_sha256"],
            "subagent_review_commit_sha": review["subagent_review_commit_sha"],
            "review_receipt_sha256": review_receipt_sha256,
            "validator_sha256": hashlib.sha256(
                Path(__file__).with_name("validate-floorp-notes-sync-self-attestation.py").read_bytes()
            ).hexdigest(),
            "workflow_job": JOB,
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": source["run_attempt"],
            "workflow_run_id": source["run_id"],
        }
        record = {**event, "event_sha256": hashlib.sha256(canonical(event)).hexdigest()}
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(canonical(record))
            handle.flush()
            os.fsync(handle.fileno())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 78 if str(error).startswith("[blocked]") else 2
    print('{"status":"self-attestation-ledger-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
