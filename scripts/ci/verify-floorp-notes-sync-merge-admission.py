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
SUBAGENT_REVIEW_PATH = "docs/floorp-notes-sync-todo20-subagent-review.json"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
AGENT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
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


def verify_immutable_subagent_commit(repository_root: Path, commit_sha: str, raw: bytes) -> None:
    require_sha(commit_sha, SHA1, "subagent review commit")
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
            "/usr/bin/git", "-C", str(repository_root), "diff-tree", "--root", "--no-commit-id",
            "--name-only", "-r", commit_sha,
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


def validate_checks(checks: Any) -> int:
    if not isinstance(checks, list) or not checks:
        raise MergeAdmissionError("GitHub check response is empty or malformed")
    names: set[str] = set()
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("name"), str):
            raise MergeAdmissionError("GitHub check response contains malformed rows")
        name = check["name"]
        names.add(name)
        state = str(check.get("state", "")).upper()
        conclusion = str(check.get("conclusion", "")).upper()
        if state == "COMPLETED" and conclusion == "SUCCESS":
            continue
        if state == "COMPLETED" and conclusion == "SKIPPED" and (
            name.startswith("Todo 20 ") or name.startswith("Protected Notes Sync")
        ):
            continue
        raise MergeAdmissionError(f"GitHub check is not terminal success: {name}")
    if not REQUIRED_CHECKS.issubset(names):
        raise MergeAdmissionError("required terminal CI checks are missing")
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
    parser.add_argument("--plan-binding", type=Path, required=True)
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--expected-head-sha", required=True)
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
        binding, binding_raw = load_canonical(args.plan_binding, "plan binding")
        validate_owner(owner, args.pr_number, args.expected_head_sha)
        validate_subagent(subagent, args.pr_number, args.expected_head_sha)
        check_count = validate_checks(checks)
        validate_plan_binding(binding)
        if (
            owner["plan_sha256"] != binding["plan_sha256"]
            or owner["amendment_sha256"] != binding["amendment_sha256"]
            or owner["combined_plan_hash"] != binding["combined_plan_hash"]
        ):
            raise MergeAdmissionError("owner review is not bound to the checked-in plan binding")
        verify_immutable_subagent_commit(args.repository_root, args.subagent_review_commit, subagent_raw)
        receipt = {
            "admin_bypass_used": False,
            "checks_count": check_count,
            "checks_sha256": sha256(checks_raw),
            "head_sha": args.expected_head_sha,
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
