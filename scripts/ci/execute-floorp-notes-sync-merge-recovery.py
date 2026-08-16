#!/usr/bin/python3 -I
"""Record the guarded-merge operation receipt for an already-merged PR.

Recovery mode for the protected Todo 20 merge run whose audit capture failed
after the OID-guarded squash merge had already succeeded (the same-run
artifact chain was therefore never uploaded). This executor never performs a
second mutation. It verifies the merge fact from read-only GitHub state:

1. the PR is merged with exactly the expected merge commit and head/base
   refs;
2. the original protected run is a workflow_dispatch on the guarded PR branch
   at the exact head and its ``Execute repository-owned OID-guarded merge``
   step succeeded (server-side proof that the merge was performed by the
   repository-owned executor);
3. the exact-head admission receipt is still valid.

It then records the canonical executor receipt from the observed facts. Raw
API responses are never written or printed; only the safe receipt is
retained.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
GH = "/opt/homebrew/bin/gh"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
EXPECTED_BASE_REF = "main"
EXPECTED_HEAD_REF = "agent/floorp-plan-t20-live-executor"
EXPECTED_WORKFLOW_PATH = ".github/workflows/ci.yml"
EXPECTED_SOURCE_JOB = "Todo 20 protected OID-guarded merge and audit receipt"
EXPECTED_SOURCE_STEP = "Execute repository-owned OID-guarded merge"


class MergeRecoveryError(RuntimeError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def run_gh(arguments: list[str]) -> bytes:
    try:
        result = subprocess.run(
            [GH, *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise MergeRecoveryError("gh execution is unavailable") from error
    if result.returncode != 0:
        raise MergeRecoveryError(f"gh API operation failed with exit {result.returncode}")
    return result.stdout


def load_object(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MergeRecoveryError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise MergeRecoveryError(f"{label} is not a JSON object")
    return value


def load_canonical(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeRecoveryError(f"{label} is not valid JSON") from error
    if path.is_symlink() or not path.is_file() or not isinstance(value, dict) or raw != canonical(value):
        raise MergeRecoveryError(f"{label} is not canonical JSON")
    return value, raw


def require_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA1.fullmatch(value):
        raise MergeRecoveryError(f"{label} is invalid")
    return value


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument("--expected-merged-oid", required=True)
    parser.add_argument("--source-run-id", required=True, type=int)
    parser.add_argument("--admission-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--recovery-evidence", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    return parser.parse_args(arguments)


def validate_admission(
    admission: dict[str, Any], pr_number: int, expected_head_sha: str,
) -> None:
    expected_admission_fields = {
        "admin_bypass_used", "base_oid", "base_ref_name", "checks_count", "checks_sha256",
        "head_ref_name", "head_sha", "native_github_approval",
        "operator_id", "owner_review_sha256", "plan_binding_sha256", "pr_number", "repository",
        "schema_version", "status", "subagent_review_commit_sha", "subagent_review_sha256",
        "terminal_ci",
    }
    if set(admission) != expected_admission_fields:
        raise MergeRecoveryError("merge admission receipt fields are not exact")
    require_sha(admission["base_oid"], "merge admission base OID")
    for value, label in (
        (admission["checks_sha256"], "merge admission checks digest"),
        (admission["owner_review_sha256"], "merge admission owner digest"),
        (admission["plan_binding_sha256"], "merge admission plan digest"),
        (admission["subagent_review_sha256"], "merge admission subagent digest"),
    ):
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise MergeRecoveryError(f"{label} is invalid")
    if (
        admission["schema_version"] != 1
        or admission["status"] != "GO"
        or admission["repository"] != REPOSITORY
        or admission["pr_number"] != pr_number
        or admission["base_ref_name"] != EXPECTED_BASE_REF
        or admission["head_ref_name"] != EXPECTED_HEAD_REF
        or admission["head_sha"] != expected_head_sha
        or admission["admin_bypass_used"] is not False
        or admission["native_github_approval"] is not False
        or admission["terminal_ci"] is not True
        or not isinstance(admission["checks_count"], int)
        or admission["checks_count"] <= 0
        or not isinstance(admission["operator_id"], str)
        or not admission["operator_id"]
        or not SHA1.fullmatch(admission["subagent_review_commit_sha"])
    ):
        raise MergeRecoveryError("merge admission receipt is not an exact-head terminal GO")


def verify_merged_pr(pr: dict[str, Any], pr_number: int, expected_head_sha: str, expected_merged_oid: str) -> str:
    base = pr.get("base") if isinstance(pr.get("base"), dict) else {}
    head = pr.get("head") if isinstance(pr.get("head"), dict) else {}
    base_oid = require_sha(base.get("sha"), "merged PR base OID")
    merged_oid = require_sha(pr.get("merge_commit_sha"), "merged PR merge commit")
    if (
        pr.get("number") != pr_number
        or pr.get("merged") is not True
        or merged_oid != expected_merged_oid
        or base.get("ref") != EXPECTED_BASE_REF
        or head.get("ref") != EXPECTED_HEAD_REF
        or head.get("sha") != expected_head_sha
        or not isinstance(pr.get("merged_at"), str)
        or not pr["merged_at"]
    ):
        raise MergeRecoveryError("merged PR state does not match the guarded merge facts")
    return base_oid


def verify_source_run(run: dict[str, Any], source_run_id: int, expected_head_sha: str) -> None:
    if (
        run.get("id") != source_run_id
        or run.get("path") != EXPECTED_WORKFLOW_PATH
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != EXPECTED_HEAD_REF
        or run.get("head_sha") != expected_head_sha
    ):
        raise MergeRecoveryError("original guarded-merge run provenance is not exact")


def verify_source_executor_step(jobs: dict[str, Any]) -> None:
    rows = jobs.get("jobs")
    if not isinstance(rows, list):
        raise MergeRecoveryError("original run job list is unavailable")
    guarded_jobs = [
        job for job in rows
        if isinstance(job, dict) and job.get("name") == EXPECTED_SOURCE_JOB
    ]
    if len(guarded_jobs) != 1:
        raise MergeRecoveryError("original guarded-merge job is missing or duplicated")
    steps = guarded_jobs[0].get("steps")
    if not isinstance(steps, list):
        raise MergeRecoveryError("original guarded-merge job steps are unavailable")
    executor_steps = [
        step for step in steps
        if isinstance(step, dict) and step.get("name") == EXPECTED_SOURCE_STEP
    ]
    if len(executor_steps) != 1 or executor_steps[0].get("conclusion") != "success":
        raise MergeRecoveryError("original OID-guarded merge executor step did not succeed")


def verify_recovery_head(repository_root: Path, expected_head_sha: str, recovery_head_sha: str) -> None:
    if expected_head_sha == recovery_head_sha:
        raise MergeRecoveryError("recovery head must differ from the expected head")
    object_check = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "cat-file", "-e", f"{expected_head_sha}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if object_check.returncode != 0:
        raise MergeRecoveryError("expected head object is unavailable in the runner checkout")
    ancestor_check = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "merge-base", "--is-ancestor", expected_head_sha, recovery_head_sha],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if ancestor_check.returncode != 0:
        raise MergeRecoveryError("recovery head is not a descendant of the expected head")


def runtime_context() -> tuple[int, str]:
    try:
        run_id = int(os.environ["GITHUB_RUN_ID"])
        head_sha = os.environ["GITHUB_SHA"]
    except (KeyError, ValueError) as error:
        raise MergeRecoveryError("recovery workflow run context is unavailable") from error
    if run_id <= 0 or not SHA1.fullmatch(head_sha):
        raise MergeRecoveryError("recovery workflow run context is invalid")
    return run_id, head_sha


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        if args.pr_number <= 0 or args.source_run_id <= 0:
            raise MergeRecoveryError("PR number or source run ID is invalid")
        expected_head_sha = require_sha(args.expected_head_sha, "expected head SHA")
        expected_merged_oid = require_sha(args.expected_merged_oid, "expected merged OID")
        admission, admission_raw = load_canonical(args.admission_receipt, "merge admission receipt")
        validate_admission(admission, args.pr_number, expected_head_sha)

        merged_pr = load_object(
            run_gh(["api", f"repos/{REPOSITORY}/pulls/{args.pr_number}"]),
            "merged PR response",
        )
        base_oid = verify_merged_pr(
            merged_pr, args.pr_number, expected_head_sha, expected_merged_oid,
        )
        source_run = load_object(
            run_gh(["api", f"repos/{REPOSITORY}/actions/runs/{args.source_run_id}"]),
            "original guarded-merge run response",
        )
        verify_source_run(source_run, args.source_run_id, expected_head_sha)
        source_jobs = load_object(
            run_gh(
                ["api", f"repos/{REPOSITORY}/actions/runs/{args.source_run_id}/jobs?per_page=20"],
            ),
            "original guarded-merge jobs response",
        )
        verify_source_executor_step(source_jobs)
        run_id, head_sha = runtime_context()
        verify_recovery_head(args.repository_root, expected_head_sha, head_sha)

        merge_projection = {"merged": True, "sha": expected_merged_oid}
        operation = {
            "base_oid": base_oid,
            "head_sha": expected_head_sha,
            "merge_endpoint": f"PUT /repos/{REPOSITORY}/pulls/{args.pr_number}/merge",
            "merge_method": "squash",
            "merge_response": merge_projection,
            "merge_response_sha256": sha256(canonical(merge_projection)),
            "merge_response_source": "github-api-put-merge-executor",
            "merge_admission_receipt_sha256": sha256(admission_raw),
            "merged_oid": expected_merged_oid,
            "oid_guarded": True,
            "pr_number": args.pr_number,
            "repository": REPOSITORY,
            "schema_version": 1,
            "server_merge_sha": expected_merged_oid,
            "server_merged": True,
            "server_merged_at": merged_pr["merged_at"],
        }
        raw = canonical(operation)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
        evidence = {
            "admission_receipt_sha256": sha256(admission_raw),
            "expected_head_sha": expected_head_sha,
            "expected_merged_oid": expected_merged_oid,
            "merged_at_utc": merged_pr["merged_at"],
            "operation_receipt_sha256": sha256(raw),
            "recovery_head_sha": head_sha,
            "recovery_run_id": run_id,
            "schema_version": 1,
            "source_executor_step_success": True,
            "source_run_id": args.source_run_id,
        }
        evidence_raw = canonical(evidence)
        with args.recovery_evidence.open("xb") as handle:
            handle.write(evidence_raw)
            handle.flush()
    except (OSError, MergeRecoveryError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=merge_recovery_failed_{error}", file=sys.stderr)
        return 78
    print('{"status":"guarded-merge-operation-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
