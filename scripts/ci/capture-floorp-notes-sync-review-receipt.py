#!/usr/bin/python3 -I
"""Create a metadata-only, source-bound Todo 20 review receipt."""

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
ENVIRONMENT = "floorp-notes-sync-production-qa"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SENSITIVE_MARKERS = ("password", "authorization", "notes_payload", "private_key", "token")


class ReviewReceiptError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def reject_sensitive(value: Any, label: str) -> None:
    serialized = json.dumps(value, ensure_ascii=False, sort_keys=True).lower()
    if any(marker in serialized for marker in SENSITIVE_MARKERS):
        raise ReviewReceiptError(f"{label} contains a forbidden sensitive marker")


def load_json(path: Path) -> tuple[Any, bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReviewReceiptError(f"{path.name} is not valid JSON") from error
    if path.is_symlink() or not path.is_file():
        raise ReviewReceiptError(f"{path.name} is not a regular file")
    return value, raw


def load_canonical(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    value, raw = load_json(path)
    if not isinstance(value, dict) or raw != canonical(value):
        raise ReviewReceiptError(f"{label} is not canonical JSON")
    return value, raw


def require_sha(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ReviewReceiptError(f"{label} is invalid")
    return value


def require_exact(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ReviewReceiptError(f"{label} fields are not exact")
    return value


def contract_safety(contract: dict[str, Any]) -> dict[str, Any]:
    approval = require_exact(
        contract.get("approval_model"),
        {
            "environment",
            "global_governance_unchanged",
            "independence",
            "native_github_approval",
            "required_approving_review_count",
            "reviews_count",
            "self_attestation",
            "self_review_exception",
        },
        "operation contract approval model",
    )
    if approval != {
        "environment": ENVIRONMENT,
        "global_governance_unchanged": True,
        "independence": False,
        "native_github_approval": False,
        "required_approving_review_count": 0,
        "reviews_count": 0,
        "self_attestation": "owner-operations-executor-reviewer",
        "self_review_exception": True,
    }:
        raise ReviewReceiptError("operation contract approval model is not the amended model")
    boundary = contract.get("boundary")
    if not isinstance(boundary, dict) or boundary.get("credential_delivery") != "protected-environment-secrets-only" or boundary.get("public_release") != "forbidden":
        raise ReviewReceiptError("operation contract safety boundary is invalid")
    matrix = contract.get("integrity_matrix")
    isolation = contract.get("isolation_contract")
    participant = contract.get("participant_contract")
    if (
        not isinstance(matrix, dict)
        or matrix.get("accounts") != 2
        or matrix.get("payload_observation") != "forbidden"
        or not isinstance(isolation, dict)
        or isolation.get("accounts") != 2
        or isolation.get("payload_retained") is not False
        or not isinstance(participant, dict)
        or participant.get("test_attachments") != "forbidden"
    ):
        raise ReviewReceiptError("operation contract account or payload boundary is invalid")
    safety = require_exact(
        contract.get("safety_boundary"),
        {"admin_bypass_allowed", "local_test_accounts_accessed", "native_github_approval", "public_release", "two_disposable_accounts_only"},
        "operation contract safety boundary",
    )
    if safety != {
        "admin_bypass_allowed": False,
        "local_test_accounts_accessed": False,
        "native_github_approval": False,
        "public_release": False,
        "two_disposable_accounts_only": True,
    }:
        raise ReviewReceiptError("operation contract safety boundary is not fail-closed")
    return {
        "independence": approval["independence"],
        "native_github_approval": safety["native_github_approval"],
        "self_review_exception": approval["self_review_exception"],
        "two_disposable_accounts_only": safety["two_disposable_accounts_only"],
        "local_test_accounts_accessed": safety["local_test_accounts_accessed"],
        "public_release": safety["public_release"],
    }


def validate_plan_binding(binding: dict[str, Any]) -> None:
    require_exact(binding, {"amendment_sha256", "combined_plan_hash", "plan_sha256", "schema_version", "task_id"}, "plan binding")
    if binding["schema_version"] != 1 or binding["task_id"] != 20:
        raise ReviewReceiptError("plan binding identity is invalid")
    for field in ("plan_sha256", "amendment_sha256", "combined_plan_hash"):
        require_sha(binding[field], SHA256, f"plan binding {field}")


def validate_owner_review(owner: dict[str, Any], pr: dict[str, Any], binding: dict[str, Any], diff_sha256: str) -> None:
    expected = {
        "amendment_sha256", "attestation_statement", "base_oid", "checklist",
        "combined_plan_hash", "diff_sha256", "head_sha", "independence",
        "operator_id", "plan_sha256", "pr_number", "public_release",
        "repository", "reviewed_at_utc", "schema_version",
        "self_review_exception", "unresolved_blocking_findings",
    }
    require_exact(owner, expected, "owner review")
    if (
        owner["schema_version"] != 1
        or owner["repository"] != REPOSITORY
        or owner["pr_number"] != pr["number"]
        or owner["base_oid"] != pr["base"]["sha"]
        or owner["head_sha"] != pr["head"]["sha"]
        or owner["diff_sha256"] != diff_sha256
        or owner["plan_sha256"] != binding["plan_sha256"]
        or owner["amendment_sha256"] != binding["amendment_sha256"]
        or owner["combined_plan_hash"] != binding["combined_plan_hash"]
        or owner["self_review_exception"] is not True
        or owner["independence"] is not False
        or owner["public_release"] is not False
        or not isinstance(owner["operator_id"], str)
        or not owner["operator_id"]
        or not isinstance(owner["attestation_statement"], str)
        or not owner["attestation_statement"]
        or owner["unresolved_blocking_findings"] != []
        or not isinstance(owner["checklist"], dict)
        or not owner["checklist"]
        or not all(value is True for value in owner["checklist"].values())
        or not isinstance(owner["reviewed_at_utc"], str)
        or not owner["reviewed_at_utc"].endswith("Z")
    ):
        raise ReviewReceiptError("owner review is stale or incomplete")


def validate_merge_audit(merge: dict[str, Any], pr: dict[str, Any], merged_oid: str) -> None:
    require_exact(
        merge,
        {"admin_bypass_used", "base_oid", "head_sha", "merge_method", "merged_oid", "oid_guarded", "pr_number", "repository", "schema_version"},
        "merge audit",
    )
    if (
        merge["schema_version"] != 1
        or merge["repository"] != REPOSITORY
        or merge["pr_number"] != pr["number"]
        or merge["base_oid"] != pr["base"]["sha"]
        or merge["head_sha"] != pr["head"]["sha"]
        or merge["merged_oid"] != merged_oid
        or merge["merge_method"] != "squash"
        or merge["oid_guarded"] is not True
        or merge["admin_bypass_used"] is not False
    ):
        raise ReviewReceiptError("merge audit is not bound to the guarded squash merge")


def validate_subagent_review(subagent: dict[str, Any], pr: dict[str, Any]) -> None:
    require_exact(subagent, {"findings", "head_sha", "repository", "reviewed_at_utc", "schema_version", "status"}, "subagent review")
    if (
        subagent["schema_version"] != 1
        or subagent["repository"] != REPOSITORY
        or subagent["head_sha"] != pr["head"]["sha"]
        or subagent["status"] != "GO"
        or subagent["findings"] != []
        or not isinstance(subagent["reviewed_at_utc"], str)
        or not subagent["reviewed_at_utc"].endswith("Z")
    ):
        raise ReviewReceiptError("subagent review is stale or not a clean GO")


def validate_pr(pr: dict[str, Any], pr_number: int, merged_oid: str) -> None:
    if (
        pr.get("number") != pr_number
        or pr.get("state") != "closed"
        or pr.get("merged") is not True
        or not pr.get("merged_at")
        or pr.get("merge_commit_sha") != merged_oid
        or not isinstance(pr.get("base"), dict)
        or not isinstance(pr.get("head"), dict)
    ):
        raise ReviewReceiptError("PR metadata is not a merged exact-head record")
    require_sha(pr["base"].get("sha"), SHA1, "PR base OID")
    require_sha(pr["head"].get("sha"), SHA1, "PR head OID")
    require_sha(merged_oid, SHA1, "merged OID")


def validate_ruleset(ruleset: dict[str, Any]) -> int:
    if ruleset.get("id") != 20229460 or ruleset.get("enforcement") != "active":
        raise ReviewReceiptError("ruleset identity or enforcement is invalid")
    for rule in ruleset.get("rules", []):
        if rule.get("type") == "pull_request":
            parameters = rule.get("parameters", {})
            if parameters.get("required_reviewers") != []:
                raise ReviewReceiptError("ruleset has unexpected required reviewers")
            required = parameters.get("required_approving_review_count")
            if required == 0:
                return required
    raise ReviewReceiptError("active ruleset review requirement is unavailable")


def build_receipt(
    pr: dict[str, Any],
    reviews: list[Any],
    ruleset: dict[str, Any],
    contract: dict[str, Any],
    binding: dict[str, Any],
    owner: dict[str, Any],
    merge: dict[str, Any],
    subagent: dict[str, Any],
    diff_sha256: str,
    merged_oid: str,
    contract_sha256: str,
    binding_sha256: str,
    owner_sha256: str,
    merge_sha256: str,
    subagent_sha256: str,
) -> dict[str, Any]:
    validate_pr(pr, owner["pr_number"], merged_oid)
    if not isinstance(reviews, list):
        raise ReviewReceiptError("review API result is not a list")
    required_review_count = validate_ruleset(ruleset)
    if reviews:
        raise ReviewReceiptError("native GitHub reviews are not empty for the self-review exception")
    safety = contract_safety(contract)
    validate_plan_binding(binding)
    validate_owner_review(owner, pr, binding, diff_sha256)
    validate_merge_audit(merge, pr, merged_oid)
    validate_subagent_review(subagent, pr)
    for value, label in (
        (diff_sha256, "diff digest"),
        (contract_sha256, "contract digest"),
        (binding_sha256, "plan binding digest"),
        (owner_sha256, "owner review digest"),
        (merge_sha256, "merge audit digest"),
        (subagent_sha256, "subagent review digest"),
    ):
        require_sha(value, SHA256, label)
    return {
        "admin_bypass_used": merge["admin_bypass_used"],
        "amendment_sha256": binding["amendment_sha256"],
        "base_oid": pr["base"]["sha"],
        "combined_plan_hash": binding["combined_plan_hash"],
        "contract_sha256": contract_sha256,
        "diff_sha256": diff_sha256,
        "environment": ENVIRONMENT,
        "head_sha": pr["head"]["sha"],
        "independence": owner["independence"],
        "local_test_accounts_accessed": safety["local_test_accounts_accessed"],
        "merged_oid": merged_oid,
        "native_github_approval": safety["native_github_approval"],
        "operator_id": owner["operator_id"],
        "plan_binding_sha256": binding_sha256,
        "plan_sha256": binding["plan_sha256"],
        "pr_number": pr["number"],
        "public_release": safety["public_release"],
        "repository": REPOSITORY,
        "review_scope": "todo-20-pr-and-production-qa",
        "reviewed_at_utc": owner["reviewed_at_utc"],
        "roles": ["owner", "operations", "executor", "reviewer"],
        "ruleset_required_review_count": required_review_count,
        "reviews_count": len(reviews),
        "schema_version": 2,
        "self_review_exception": owner["self_review_exception"],
        "subagent_review_digests": [subagent_sha256],
        "subagent_review_receipt_sha256": subagent_sha256,
        "owner_review_receipt_sha256": owner_sha256,
        "merge_audit_sha256": merge_sha256,
        "two_disposable_accounts_only": safety["two_disposable_accounts_only"],
        "unresolved_blocking_findings": owner["unresolved_blocking_findings"],
    }


def git_diff_sha256(repository_root: Path, base_oid: str, head_oid: str) -> str:
    try:
        check = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_root), "cat-file", "-e", f"{base_oid}^{{commit}}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if check.returncode != 0:
            raise ReviewReceiptError("Git base OID is unavailable")
        check = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_root), "cat-file", "-e", f"{head_oid}^{{commit}}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if check.returncode != 0:
            raise ReviewReceiptError("Git head OID is unavailable")
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_root), "diff", "--binary", base_oid, head_oid],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise ReviewReceiptError("Git diff could not be observed") from error
    if result.returncode != 0:
        raise ReviewReceiptError("Git diff failed")
    return sha256_bytes(result.stdout)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-json", type=Path, required=True)
    parser.add_argument("--reviews-json", type=Path, required=True)
    parser.add_argument("--ruleset-json", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--merged-oid", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--plan-binding", type=Path, required=True)
    parser.add_argument("--owner-review", type=Path, required=True)
    parser.add_argument("--merge-audit", type=Path, required=True)
    parser.add_argument("--subagent-review", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        pr, _ = load_json(args.pr_json)
        reviews, _ = load_json(args.reviews_json)
        ruleset, _ = load_json(args.ruleset_json)
        contract, contract_raw = load_canonical(args.contract, "operation contract")
        binding, binding_raw = load_canonical(args.plan_binding, "plan binding")
        owner, owner_raw = load_canonical(args.owner_review, "owner review")
        merge, merge_raw = load_canonical(args.merge_audit, "merge audit")
        subagent, subagent_raw = load_canonical(args.subagent_review, "subagent review")
        reject_sensitive(owner, "owner review")
        reject_sensitive(merge, "merge audit")
        reject_sensitive(subagent, "subagent review")
        if not isinstance(pr, dict) or not isinstance(ruleset, dict):
            raise ReviewReceiptError("API metadata is malformed")
        if not isinstance(reviews, list):
            raise ReviewReceiptError("review API metadata is malformed")
        diff_sha256 = git_diff_sha256(args.repository_root, pr["base"]["sha"], pr["head"]["sha"])
        receipt = build_receipt(
            pr,
            reviews,
            ruleset,
            contract,
            binding,
            owner,
            merge,
            subagent,
            diff_sha256,
            args.merged_oid,
            sha256_bytes(contract_raw),
            sha256_bytes(binding_raw),
            sha256_bytes(owner_raw),
            sha256_bytes(merge_raw),
            sha256_bytes(subagent_raw),
        )
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(canonical(receipt))
            handle.flush()
    except (OSError, UnicodeError, json.JSONDecodeError, ReviewReceiptError, KeyError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"source-bound-review-receipt-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
