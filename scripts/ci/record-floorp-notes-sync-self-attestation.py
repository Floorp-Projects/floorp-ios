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


def required_metadata(name: str, pattern: re.Pattern[str]) -> str:
    value = os.environ.get(name, "")
    if not pattern.fullmatch(value):
        raise RuntimeError(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_metadata_invalid_{name.lower()}")
    return value


def required_run_number(name: str) -> int:
    value = os.environ.get(name, "")
    try:
        parsed = int(value)
    except ValueError as error:
        raise RuntimeError(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_metadata_invalid_{name.lower()}") from error
    if parsed <= 0:
        raise RuntimeError(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_metadata_invalid_{name.lower()}")
    return parsed


def review_metadata(source: dict[str, Any]) -> dict[str, Any]:
    merged_oid = required_metadata("FLOORP_TODO20_MERGED_OID", SHA1)
    if merged_oid != source["head_sha"]:
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=merged_oid_not_bound_to_run_head")
    head_sha = required_metadata("FLOORP_TODO20_HEAD_SHA", SHA1)
    digests = [
        item.strip()
        for item in os.environ.get("FLOORP_TODO20_SUBAGENT_REVIEW_DIGESTS", "").split(",")
        if item.strip()
    ]
    if not digests or any(not SHA256.fullmatch(item) for item in digests):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=subagent_review_digest_missing")
    reviewed_at = os.environ.get("FLOORP_TODO20_REVIEWED_AT_UTC", "")
    if not reviewed_at.endswith("Z") or len(reviewed_at) < 11:
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_timestamp_missing")
    return {
        "admin_bypass_used": False,
        "base_oid": required_metadata("FLOORP_TODO20_BASE_OID", SHA1),
        "diff_sha256": required_metadata("FLOORP_TODO20_DIFF_SHA256", SHA256),
        "head_sha": head_sha,
        "independence": False,
        "merged_oid": merged_oid,
        "operator_id": source["actor"],
        "pr_number": required_run_number("FLOORP_TODO20_PR_NUMBER"),
        "reviewed_at_utc": reviewed_at,
        "review_scope": "todo-20-pr-and-production-qa",
        "subagent_review_digests": digests,
        "self_review_exception": True,
        "unresolved_blocking_findings": [],
        "plan_sha256": required_metadata("FLOORP_TODO20_PLAN_SHA256", SHA256),
        "amendment_sha256": required_metadata("FLOORP_TODO20_AMENDMENT_SHA256", SHA256),
        "combined_plan_hash": required_metadata("FLOORP_TODO20_COMBINED_PLAN_HASH", SHA256),
    }


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
    source["review"] = review_metadata(source)
    return source


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        source = context()
        manifest_sha256 = digest(args.manifest)
        summary_sha256 = digest(args.summary)
        cleanup_sha256 = digest(args.cleanup_receipt)
        secret_scan_sha256 = digest(args.secret_scan)
        event = {
            "accounts": 2,
            "admin_bypass_used": False,
            "amendment_sha256": source["review"]["amendment_sha256"],
            "base_oid": source["review"]["base_oid"],
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
            "head_sha": source["review"]["head_sha"],
            "merged_oid": source["review"]["merged_oid"],
            "operator_id": source["actor"],
            "previous_event_sha256": "0" * 64,
            "public_release": False,
            "cleanup_receipt_sha256": cleanup_sha256,
            "qa_summary_sha256": summary_sha256,
            "repository": REPOSITORY,
            "pr_number": source["review"]["pr_number"],
            "review_scope": source["review"]["review_scope"],
            "reviewed_at_utc": source["review"]["reviewed_at_utc"],
            "roles": REVIEW_ROLES,
            "ruleset_required_review_count": 0,
            "reviews_count": 0,
            "schema_version": 2,
            "secret_scan_sha256": secret_scan_sha256,
            "secret_scan_scope": "pre-attestation",
            "sequence": 1,
            "self_review_exception": source["review"]["self_review_exception"],
            "independence": source["review"]["independence"],
            "subagent_review_digests": source["review"]["subagent_review_digests"],
            "two_disposable_accounts_only": True,
            "local_test_accounts_accessed": False,
            "unresolved_blocking_findings": source["review"]["unresolved_blocking_findings"],
            "diff_sha256": source["review"]["diff_sha256"],
            "plan_sha256": source["review"]["plan_sha256"],
            "combined_plan_hash": source["review"]["combined_plan_hash"],
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
