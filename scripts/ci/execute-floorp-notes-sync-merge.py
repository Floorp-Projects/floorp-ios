#!/usr/bin/python3 -I
"""Execute and record the guarded Todo 20 squash merge.

This is the only supported producer of the merge-operation receipt. It reads
the server head immediately before the mutation, performs the exact
OID-guarded ``PUT /merge`` request through the absolute ``gh`` binary, and
then reads the merged PR state. Raw API responses are never written or
printed; only the safe operation receipt is retained.
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
GH = "/opt/homebrew/bin/gh"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
EXPECTED_BASE_REF = "main"


class MergeExecutionError(RuntimeError):
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
        raise MergeExecutionError("gh execution is unavailable") from error
    if result.returncode != 0:
        raise MergeExecutionError(f"gh API operation failed with exit {result.returncode}")
    return result.stdout


def load_object(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MergeExecutionError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise MergeExecutionError(f"{label} is not a JSON object")
    return value


def load_canonical(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeExecutionError(f"{label} is not valid JSON") from error
    if path.is_symlink() or not path.is_file() or not isinstance(value, dict) or raw != canonical(value):
        raise MergeExecutionError(f"{label} is not canonical JSON")
    return value, raw


def require_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA1.fullmatch(value):
        raise MergeExecutionError(f"{label} is invalid")
    return value


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument("--admission-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        if args.pr_number <= 0:
            raise MergeExecutionError("PR number is invalid")
        expected_head_sha = require_sha(args.expected_head_sha, "expected head SHA")
        admission, admission_raw = load_canonical(args.admission_receipt, "merge admission receipt")
        expected_admission_fields = {
            "admin_bypass_used", "base_oid", "base_ref_name", "checks_count", "checks_sha256", "head_ref_name", "head_sha", "native_github_approval",
            "operator_id", "owner_review_sha256", "plan_binding_sha256", "pr_number", "repository",
            "schema_version", "status", "subagent_review_commit_sha", "subagent_review_sha256", "terminal_ci",
        }
        if set(admission) != expected_admission_fields:
            raise MergeExecutionError("merge admission receipt fields are not exact")
        require_sha(admission["base_oid"], "merge admission base OID")
        for value, label in (
            (admission["checks_sha256"], "merge admission checks digest"),
            (admission["owner_review_sha256"], "merge admission owner digest"),
            (admission["plan_binding_sha256"], "merge admission plan digest"),
            (admission["subagent_review_sha256"], "merge admission subagent digest"),
        ):
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}\Z", value):
                raise MergeExecutionError(f"{label} is invalid")
        if (
            admission["schema_version"] != 1
            or admission["status"] != "GO"
            or admission["repository"] != REPOSITORY
            or admission["pr_number"] != args.pr_number
            or admission["base_ref_name"] != EXPECTED_BASE_REF
            or not isinstance(admission["head_ref_name"], str)
            or not admission["head_ref_name"]
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
            raise MergeExecutionError("merge admission receipt is not an exact-head terminal GO")
        current_pr = load_object(
            run_gh(
                [
                    "pr", "view", str(args.pr_number), "--repo", REPOSITORY,
                    "--json", "baseRefName,baseRefOid,headRefName,headRefOid",
                ]
            ),
            "PR ref response",
        )
        if (
            current_pr.get("baseRefName") != EXPECTED_BASE_REF
            or current_pr.get("baseRefOid") != admission["base_oid"]
            or current_pr.get("headRefName") != admission["head_ref_name"]
            or current_pr.get("headRefOid") != expected_head_sha
        ):
            raise MergeExecutionError("PR base/head refs drifted before the guarded merge")

        merge_response = load_object(
            run_gh(
                [
                    "api",
                    "-X",
                    "PUT",
                    f"repos/{REPOSITORY}/pulls/{args.pr_number}/merge",
                    "-f",
                    f"sha={expected_head_sha}",
                    "-f",
                    "merge_method=squash",
                ]
            ),
            "PUT merge response",
        )
        merge_projection = {
            "merged": merge_response.get("merged"),
            "sha": merge_response.get("sha"),
        }
        merged_oid = require_sha(merge_projection.get("sha"), "merge response SHA")
        if merge_projection != {"merged": True, "sha": merged_oid}:
            raise MergeExecutionError("guarded merge response is not a successful squash merge")

        merged_pr = load_object(
            run_gh(["api", f"repos/{REPOSITORY}/pulls/{args.pr_number}"]),
            "merged PR response",
        )
        base = merged_pr.get("base") if isinstance(merged_pr.get("base"), dict) else {}
        head = merged_pr.get("head") if isinstance(merged_pr.get("head"), dict) else {}
        base_oid = require_sha(base.get("sha"), "merged PR base OID")
        if (
            merged_pr.get("number") != args.pr_number
            or merged_pr.get("merged") is not True
            or merged_pr.get("merge_commit_sha") != merged_oid
            or base.get("ref") != EXPECTED_BASE_REF
            or head.get("ref") != admission["head_ref_name"]
            or head.get("sha") != expected_head_sha
            or not isinstance(merged_pr.get("merged_at"), str)
            or not merged_pr["merged_at"]
        ):
            raise MergeExecutionError("merged PR response does not match the guarded PUT result")
        operation = {
            "base_oid": base_oid,
            "head_sha": expected_head_sha,
            "merge_endpoint": f"PUT /repos/{REPOSITORY}/pulls/{args.pr_number}/merge",
            "merge_method": "squash",
            "merge_response": merge_projection,
            "merge_response_sha256": sha256(canonical(merge_projection)),
            "merge_response_source": "github-api-put-merge-executor",
            "merge_admission_receipt_sha256": sha256(admission_raw),
            "merged_oid": merged_oid,
            "oid_guarded": True,
            "pr_number": args.pr_number,
            "repository": REPOSITORY,
            "schema_version": 1,
            "server_merge_sha": merged_oid,
            "server_merged": True,
            "server_merged_at": merged_pr["merged_at"],
        }
        raw = canonical(operation)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
    except (OSError, MergeExecutionError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=guarded_merge_failed_{error}", file=sys.stderr)
        return 78
    print('{"status":"guarded-merge-operation-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
