#!/usr/bin/python3 -I
"""Create a source-bound, pre-merge Todo 20 admission receipt.

This gate consumes only protected-run inputs and read-only GitHub check
results.  It is deliberately separate from the post-merge production-QA
validator: it proves that the exact reviewed head is eligible to enter the
guarded merge executor, while the later QA receipt still proves the actual
merged OID and two-client data-integrity result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
REPOSITORY_API_URL = "https://api.github.com/repos/Floorp-Projects/floorp-ios"
SUBAGENT_REVIEW_PATH = "docs/floorp-notes-sync-todo20-subagent-review.json"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
AGENT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
RUN_JOB_LINK = re.compile(r"/actions/runs/(?P<run_id>[0-9]+)/job/(?P<job_id>[0-9]+)(?:$|[?#])")
EXPECTED_BRANCH = "agent/floorp-plan-t20-live-executor"
EXPECTED_BASE_BRANCH = "main"
EXPECTED_WORKFLOW_PATHS = {
    "Floorp iOS CI": ".github/workflows/ci.yml",
    "Floorp Notes UI smoke": ".github/workflows/notes-ui.yml",
    "Floorp adaptive sidebar UI": ".github/workflows/adaptive-sidebar-ui.yml",
}
REQUIRED_CHECKS = {"Validate workflows", "Build and unit test", "Release-disabled wrapper build"}


class MergeAdmissionError(ValueError):
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


def load_canonical(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    if path.is_symlink() or not path.is_file():
        raise MergeAdmissionError(f"{label} is not a regular file")
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeAdmissionError(f"{label} is invalid JSON") from error
    if not isinstance(value, dict) or raw != canonical(value):
        raise MergeAdmissionError(f"{label} is not canonical JSON")
    return value, raw


def load_json(path: Path, label: str) -> tuple[Any, bytes]:
    if path.is_symlink() or not path.is_file():
        raise MergeAdmissionError(f"{label} is not a regular file")
    try:
        raw = path.read_bytes()
        return json.loads(raw.decode("utf-8")), raw
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeAdmissionError(f"{label} is invalid JSON") from error


def require_sha(value: Any, pattern: re.Pattern[str], label: str) -> None:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise MergeAdmissionError(f"{label} is invalid")


def verify_immutable_subagent_commit(
    repository_root: Path, commit_sha: str, raw: bytes, reference_sha: str,
) -> None:
    """Verify the review commit differs from the exact head tree only at the
    review path.

    The review tree is compared against the exact reviewed head tree instead
    of the commit parent: the protected runner fetches the review commit with
    ``--depth=1``, so the parent object is absent and ``diff-tree --root``
    would incorrectly treat the commit as a root commit and list the entire
    tree. Comparing trees keeps the one-file-scope check valid for shallow
    fetches and additionally enforces the exact-head binding.
    """
    require_sha(commit_sha, SHA1, "subagent review commit")
    require_sha(reference_sha, SHA1, "subagent review reference head")
    exists = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "cat-file", "-e", f"{commit_sha}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if exists.returncode != 0:
        raise MergeAdmissionError("subagent review commit is unavailable")
    content = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "show", f"{commit_sha}:{SUBAGENT_REVIEW_PATH}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if content.returncode != 0 or content.stdout != raw:
        raise MergeAdmissionError("subagent review is not bound to its immutable commit")
    changed = subprocess.run(
        [
            "/usr/bin/git", "-C", str(repository_root), "diff-tree", "--no-commit-id",
            "--name-only", "-r", reference_sha, commit_sha,
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if changed.returncode != 0 or changed.stdout.splitlines() != [SUBAGENT_REVIEW_PATH]:
        raise MergeAdmissionError("subagent review commit contains unexpected files")


def validate_owner(owner: dict[str, Any], pr_number: int, expected_head_sha: str) -> None:
    expected = {
        "amendment_sha256", "attestation_statement", "base_oid", "checklist",
        "combined_plan_hash", "diff_sha256", "desktop_sha", "head_sha", "independence",
        "operator_id", "plan_sha256", "pr_number", "public_release", "repository",
        "reviewed_at_utc", "schema_version", "self_review_exception",
        "unresolved_blocking_findings",
    }
    if set(owner) != expected:
        raise MergeAdmissionError("owner review fields are not exact")
    for value, label in (
        (owner["base_oid"], "owner base OID"),
        (owner["head_sha"], "owner head SHA"),
        (owner["desktop_sha"], "owner Desktop SHA"),
    ):
        require_sha(value, SHA1, label)
    for value, label in (
        (owner["amendment_sha256"], "owner amendment digest"),
        (owner["combined_plan_hash"], "owner combined plan digest"),
        (owner["diff_sha256"], "owner diff digest"),
        (owner["plan_sha256"], "owner plan digest"),
    ):
        require_sha(value, SHA256, label)
    if (
        owner["schema_version"] != 1
        or owner["repository"] != REPOSITORY
        or owner["pr_number"] != pr_number
        or owner["head_sha"] != expected_head_sha
        or owner["self_review_exception"] is not True
        or owner["independence"] is not False
        or owner["public_release"] is not False
        or not isinstance(owner["operator_id"], str)
        or not owner["operator_id"]
        or not isinstance(owner["reviewed_at_utc"], str)
        or not owner["reviewed_at_utc"].endswith("Z")
        or not isinstance(owner["attestation_statement"], str)
        or not owner["attestation_statement"]
        or not isinstance(owner["checklist"], dict)
        or not owner["checklist"]
        or not all(value is True for value in owner["checklist"].values())
        or owner["unresolved_blocking_findings"] != []
    ):
        raise MergeAdmissionError("owner review is stale or incomplete")


def validate_subagent(subagent: dict[str, Any], pr_number: int, expected_head_sha: str) -> None:
    expected = {
        "desktop_sha", "findings", "head_sha", "independence", "repository", "reviewer_id",
        "review_method", "reviewed_at_utc", "schema_version", "status",
    }
    if set(subagent) != expected:
        raise MergeAdmissionError("subagent review fields are not exact")
    require_sha(subagent["desktop_sha"], SHA1, "subagent Desktop SHA")
    require_sha(subagent["head_sha"], SHA1, "subagent head SHA")
    if (
        subagent["schema_version"] != 1
        or subagent["repository"] != REPOSITORY
        or subagent["head_sha"] != expected_head_sha
        or subagent["independence"] is not True
        or not isinstance(subagent["reviewer_id"], str)
        or not AGENT_ID.fullmatch(subagent["reviewer_id"])
        or subagent["review_method"] != "codex-read-only-diff"
        or subagent["status"] != "GO"
        or subagent["findings"] != []
        or not isinstance(subagent["reviewed_at_utc"], str)
        or not subagent["reviewed_at_utc"].endswith("Z")
    ):
        raise MergeAdmissionError("subagent review is not an exact-head independent GO")


def collection(value: Any, key: str, label: str) -> list[dict[str, Any]]:
    pages = value if isinstance(value, list) else [value]
    rows: list[dict[str, Any]] = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get(key), list):
            raise MergeAdmissionError(f"{label} is malformed")
        rows.extend(page[key])
    if not rows or not all(isinstance(row, dict) for row in rows):
        raise MergeAdmissionError(f"{label} is empty or malformed")
    return rows


def require_pull_request(
    rows: Any,
    pr_number: int,
    expected_head_sha: str,
    expected_base_sha: str,
    label: str,
) -> None:
    if not isinstance(rows, list):
        raise MergeAdmissionError(f"{label} is not bound to PR {pr_number}")
    expected_url = f"{REPOSITORY_API_URL}/pulls/{pr_number}"
    for row in rows:
        if not isinstance(row, dict) or row.get("number") != pr_number:
            continue
        base = row.get("base")
        head = row.get("head")
        if not isinstance(base, dict) or not isinstance(head, dict):
            continue
        base_repo = base.get("repo")
        head_repo = head.get("repo")
        if (
            row.get("url") == expected_url
            and base.get("ref") == EXPECTED_BASE_BRANCH
            and base.get("sha") == expected_base_sha
            and head.get("ref") == EXPECTED_BRANCH
            and head.get("sha") == expected_head_sha
            and isinstance(base_repo, dict)
            and base_repo.get("url") == REPOSITORY_API_URL
            and isinstance(head_repo, dict)
            and head_repo.get("url") == REPOSITORY_API_URL
        ):
            return
    raise MergeAdmissionError(f"{label} is not exactly bound to PR {pr_number}")


def validate_checks(
    checks: Any,
    check_runs_payload: Any,
    workflow_runs_payload: Any,
    pr_number: int,
    expected_head_sha: str,
    expected_base_sha: str,
    recovery: bool,
) -> int:
    if not isinstance(checks, list) or not checks:
        raise MergeAdmissionError("GitHub check response is empty or malformed")
    check_runs = collection(check_runs_payload, "check_runs", "GitHub check-runs response")
    workflow_runs = collection(workflow_runs_payload, "workflow_runs", "GitHub workflow-runs response")
    check_runs_by_id: dict[str, dict[str, Any]] = {}
    for check_run in check_runs:
        check_run_id = check_run.get("id")
        if not isinstance(check_run_id, int) or check_run_id <= 0:
            raise MergeAdmissionError("GitHub check-run id is invalid")
        key = str(check_run_id)
        if key in check_runs_by_id:
            raise MergeAdmissionError("GitHub check-run ids are duplicated")
        check_runs_by_id[key] = check_run
        if check_run.get("head_sha") != expected_head_sha:
            raise MergeAdmissionError("GitHub check-run head SHA is not exact")

    workflow_runs_by_id: dict[str, dict[str, Any]] = {}
    for workflow_run in workflow_runs:
        workflow_run_id = workflow_run.get("id")
        if not isinstance(workflow_run_id, int) or workflow_run_id <= 0:
            raise MergeAdmissionError("GitHub workflow-run id is invalid")
        key = str(workflow_run_id)
        if key in workflow_runs_by_id:
            raise MergeAdmissionError("GitHub workflow-run ids are duplicated")
        workflow_runs_by_id[key] = workflow_run
        if workflow_run.get("head_sha") != expected_head_sha:
            raise MergeAdmissionError("GitHub workflow-run head SHA is not exact")

    names: set[str] = set()
    referenced_workflow_run_ids: set[str] = set()
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("name"), str):
            raise MergeAdmissionError("GitHub check response contains malformed rows")
        name = check["name"]
        names.add(name)
        if check.get("event") != "pull_request" or not isinstance(check.get("workflow"), str):
            raise MergeAdmissionError(f"GitHub check provenance is invalid: {name}")
        completed_at = check.get("completedAt")
        if not isinstance(completed_at, str) or completed_at.startswith("0001-"):
            raise MergeAdmissionError(f"GitHub check is not terminal: {name}")
        link = check.get("link")
        if not isinstance(link, str):
            raise MergeAdmissionError(f"GitHub check link is missing: {name}")
        link_match = RUN_JOB_LINK.search(link)
        if link_match is None:
            raise MergeAdmissionError(f"GitHub check link is not an Actions job: {name}")
        run_id = link_match.group("run_id")
        job_id = link_match.group("job_id")
        check_run = check_runs_by_id.get(job_id)
        if check_run is None or check_run.get("name") != name:
            raise MergeAdmissionError(f"GitHub check is not bound to its check-run: {name}")
        if check_run.get("head_sha") != expected_head_sha:
            raise MergeAdmissionError(f"GitHub check-run head SHA is not exact: {name}")
        if check_run.get("status") != "completed":
            raise MergeAdmissionError(f"GitHub check-run is not completed: {name}")
        if not recovery:
            require_pull_request(
                check_run.get("pull_requests"),
                pr_number,
                expected_head_sha,
                expected_base_sha,
                f"GitHub check-run {name}",
            )
        workflow_run = workflow_runs_by_id.get(run_id)
        if workflow_run is None:
            raise MergeAdmissionError(f"GitHub workflow-run is missing: {name}")
        referenced_workflow_run_ids.add(run_id)
        workflow_path = workflow_run.get("path")
        expected_workflow_path = EXPECTED_WORKFLOW_PATHS.get(check["workflow"])
        if (
            expected_workflow_path is None
            or workflow_run.get("name") != check["workflow"]
            or not isinstance(workflow_path, str)
            or workflow_path != expected_workflow_path
            or workflow_run.get("event") != "pull_request"
            or workflow_run.get("head_branch") != EXPECTED_BRANCH
            or workflow_run.get("head_sha") != expected_head_sha
            or workflow_run.get("status") != "completed"
            or workflow_run.get("conclusion") != "success"
        ):
            raise MergeAdmissionError(f"GitHub workflow provenance is not exact: {name}")
        if not recovery:
            require_pull_request(
                workflow_run.get("pull_requests"),
                pr_number,
                expected_head_sha,
                expected_base_sha,
                f"GitHub workflow-run {name}",
            )
        state = str(check.get("state", "")).upper()
        bucket = check.get("bucket")
        check_conclusion = str(check_run.get("conclusion", "")).lower()
        if bucket == "pass" and state == "SUCCESS" and check_conclusion == "success":
            continue
        if bucket == "skipping" and state == "SKIPPED" and check_conclusion == "skipped" and (
            name.startswith("Todo 20 ") or name.startswith("Protected Notes Sync")
        ):
            continue
        raise MergeAdmissionError(f"GitHub check is not terminal success: {name}")
    if not REQUIRED_CHECKS.issubset(names):
        raise MergeAdmissionError("required terminal CI checks are missing")
    if not referenced_workflow_run_ids:
        raise MergeAdmissionError("GitHub workflow provenance is empty")
    return len(checks)


def validate_plan_binding(binding: dict[str, Any]) -> None:
    expected = {"amendment_sha256", "combined_plan_hash", "plan_sha256", "schema_version", "task_id"}
    if set(binding) != expected or binding["schema_version"] != 1 or binding["task_id"] != 20:
        raise MergeAdmissionError("Todo 20 plan binding is invalid")
    for field in ("amendment_sha256", "combined_plan_hash", "plan_sha256"):
        require_sha(binding[field], SHA256, f"plan binding {field}")


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--owner-review", type=Path, required=True)
    parser.add_argument("--subagent-review", type=Path, required=True)
    parser.add_argument("--subagent-review-commit", required=True)
    parser.add_argument("--checks-json", type=Path, required=True)
    parser.add_argument("--check-runs-json", type=Path, required=True)
    parser.add_argument("--workflow-runs-json", type=Path, required=True)
    parser.add_argument("--plan-binding", type=Path, required=True)
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument(
        "--recovery",
        action="store_true",
        help=(
            "admit an already-merged PR whose GitHub check/workflow-run "
            "pull-request associations have been cleared after the merge; "
            "the merged-PR verification is performed by the recovery executor"
        ),
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        require_sha(args.expected_head_sha, SHA1, "expected head SHA")
        if args.pr_number <= 0:
            raise MergeAdmissionError("PR number is invalid")
        owner, owner_raw = load_canonical(args.owner_review, "owner review")
        subagent, subagent_raw = load_canonical(args.subagent_review, "subagent review")
        checks, checks_raw = load_json(args.checks_json, "GitHub checks")
        check_runs, check_runs_raw = load_json(args.check_runs_json, "GitHub check-runs")
        workflow_runs, workflow_runs_raw = load_json(args.workflow_runs_json, "GitHub workflow-runs")
        binding, binding_raw = load_canonical(args.plan_binding, "plan binding")
        validate_owner(owner, args.pr_number, args.expected_head_sha)
        validate_subagent(subagent, args.pr_number, args.expected_head_sha)
        check_count = validate_checks(
            checks,
            check_runs,
            workflow_runs,
            args.pr_number,
            args.expected_head_sha,
            owner["base_oid"],
            args.recovery,
        )
        validate_plan_binding(binding)
        if (
            owner["plan_sha256"] != binding["plan_sha256"]
            or owner["amendment_sha256"] != binding["amendment_sha256"]
            or owner["combined_plan_hash"] != binding["combined_plan_hash"]
        ):
            raise MergeAdmissionError("owner review is not bound to the checked-in plan binding")
        verify_immutable_subagent_commit(
            args.repository_root, args.subagent_review_commit, subagent_raw,
            args.expected_head_sha,
        )
        receipt = {
            "admin_bypass_used": False,
            "base_oid": owner["base_oid"],
            "base_ref_name": EXPECTED_BASE_BRANCH,
            "checks_count": check_count,
            # The legacy field now binds the complete read-only check provenance
            # bundle, not only the gh-pr-checks projection.
            "checks_sha256": sha256(checks_raw + check_runs_raw + workflow_runs_raw),
            "head_sha": args.expected_head_sha,
            "head_ref_name": EXPECTED_BRANCH,
            "native_github_approval": False,
            "operator_id": owner["operator_id"],
            "owner_review_sha256": sha256(owner_raw),
            "plan_binding_sha256": sha256(binding_raw),
            "pr_number": args.pr_number,
            "repository": REPOSITORY,
            "schema_version": 1,
            "status": "GO",
            "subagent_review_commit_sha": args.subagent_review_commit,
            "subagent_review_sha256": sha256(subagent_raw),
            "terminal_ci": True,
        }
        raw = canonical(receipt)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
    except (OSError, MergeAdmissionError) as error:
        print(f"[blocked] EXTERNAL_REVIEW_PENDING owner=Operations reason=merge_admission_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"merge-admission-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
