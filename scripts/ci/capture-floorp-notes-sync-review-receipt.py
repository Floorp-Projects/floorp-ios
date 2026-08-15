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
AGENT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
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


def project_pr_metadata(pr: dict[str, Any]) -> dict[str, Any]:
    """Project only review-binding fields; never retain API user or URL fields."""
    base = pr.get("base") if isinstance(pr.get("base"), dict) else {}
    head = pr.get("head") if isinstance(pr.get("head"), dict) else {}
    base_repo = base.get("repo") if isinstance(base.get("repo"), dict) else {}
    head_repo = head.get("repo") if isinstance(head.get("repo"), dict) else {}
    projection = {
        "base": {
            "ref": base.get("ref"),
            "repo": {"full_name": base_repo.get("full_name")},
            "sha": base.get("sha"),
        },
        "head": {
            "repo": {"full_name": head_repo.get("full_name")},
            "sha": head.get("sha"),
        },
        "merge_commit_sha": pr.get("merge_commit_sha"),
        "merged": pr.get("merged"),
        "merged_at": pr.get("merged_at"),
        "number": pr.get("number"),
        "state": pr.get("state"),
    }
    reject_sensitive(projection, "PR metadata projection")
    return projection


def project_reviews_metadata(reviews: list[Any]) -> dict[str, Any]:
    """Project review count and states without reviewer identities or bodies."""
    projection = {
        "count": len(reviews),
        "states": [item.get("state") if isinstance(item, dict) else None for item in reviews],
    }
    reject_sensitive(projection, "reviews metadata projection")
    return projection


def project_ruleset_metadata(ruleset: dict[str, Any]) -> dict[str, Any]:
    """Project policy shape without actor identities, URLs, or opaque parameters."""
    projected_rules: list[dict[str, Any]] = []
    for rule in ruleset.get("rules", []):
        if not isinstance(rule, dict):
            continue
        parameters = rule.get("parameters") if isinstance(rule.get("parameters"), dict) else {}
        if rule.get("type") == "pull_request":
            reviewers = parameters.get("required_reviewers")
            projected_rules.append(
                {
                    "parameters": {
                        "required_approving_review_count": parameters.get("required_approving_review_count"),
                        "required_reviewers_count": len(reviewers) if isinstance(reviewers, list) else None,
                    },
                    "type": "pull_request",
                }
            )
        elif rule.get("type") == "required_status_checks":
            checks = parameters.get("required_status_checks")
            if not isinstance(checks, list):
                checks = []
            contexts = sorted(
                item.get("context")
                for item in checks
                if isinstance(item, dict) and isinstance(item.get("context"), str)
            )
            projected_rules.append(
                {
                    "parameters": {"required_status_check_contexts": contexts},
                    "type": "required_status_checks",
                }
            )
    projection = {
        "bypass_actors": sorted(
            [
                {
                    "actor_type": item.get("actor_type"),
                    "bypass_mode": item.get("bypass_mode"),
                }
                for item in ruleset.get("bypass_actors", [])
                if isinstance(item, dict)
            ],
            key=lambda item: (str(item["actor_type"]), str(item["bypass_mode"])),
        ),
        "conditions": ruleset.get("conditions"),
        "enforcement": ruleset.get("enforcement"),
        "id": ruleset.get("id"),
        "name": ruleset.get("name"),
        "rules": projected_rules,
        "source": ruleset.get("source"),
        "source_type": ruleset.get("source_type"),
        "target": ruleset.get("target"),
    }
    reject_sensitive(projection, "ruleset metadata projection")
    return projection


def write_exclusive(path: Path, raw: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as handle:
        handle.write(raw)
        handle.flush()


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


def validate_owner_review(
    owner: dict[str, Any],
    pr: dict[str, Any],
    binding: dict[str, Any],
    diff_sha256: str,
    desktop_sha: str,
) -> None:
    expected = {
        "amendment_sha256", "attestation_statement", "base_oid", "checklist",
        "combined_plan_hash", "diff_sha256", "head_sha", "independence",
        "desktop_sha", "operator_id", "plan_sha256", "pr_number", "public_release",
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
        or owner["desktop_sha"] != desktop_sha
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
        {
            "admin_bypass_used", "base_oid", "bypass_requested", "head_sha", "merge_endpoint",
            "merge_method", "merge_response_sha256", "merged_oid", "oid_guarded", "pr_number",
            "repository", "schema_version", "server_merge_sha", "server_merged",
        },
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
        or merge["bypass_requested"] is not False
        or merge["merge_endpoint"] != f"PUT /repos/{REPOSITORY}/pulls/{pr['number']}/merge"
        or merge["server_merged"] is not True
        or merge["server_merge_sha"] != merged_oid
    ):
        raise ReviewReceiptError("merge audit is not bound to the guarded squash merge")
    require_sha(merge["merge_response_sha256"], SHA256, "merge response digest")


def validate_subagent_review(
    subagent: dict[str, Any],
    pr: dict[str, Any],
    owner: dict[str, Any],
    desktop_sha: str,
) -> None:
    require_exact(
        subagent,
        {
            "desktop_sha", "findings", "head_sha", "independence", "repository", "reviewer_id",
            "review_method", "reviewed_at_utc", "schema_version", "status",
        },
        "subagent review",
    )
    if (
        subagent["schema_version"] != 1
        or subagent["repository"] != REPOSITORY
        or subagent["head_sha"] != pr["head"]["sha"]
        or subagent["desktop_sha"] != desktop_sha
        or subagent["independence"] is not True
        or not isinstance(subagent["reviewer_id"], str)
        or not AGENT_ID.fullmatch(subagent["reviewer_id"])
        or subagent["reviewer_id"] == owner["operator_id"]
        or subagent["review_method"] != "codex-read-only-diff"
        or subagent["status"] != "GO"
        or subagent["findings"] != []
        or not isinstance(subagent["reviewed_at_utc"], str)
        or not subagent["reviewed_at_utc"].endswith("Z")
    ):
        raise ReviewReceiptError("subagent review is stale or not a clean GO")


def verify_immutable_subagent_commit(repository_root: Path, commit_sha: str, subagent_raw: bytes) -> None:
    require_sha(commit_sha, SHA1, "subagent review commit")
    object_check = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "cat-file", "-e", f"{commit_sha}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if object_check.returncode != 0:
        raise ReviewReceiptError("subagent review commit is unavailable")
    path = "docs/floorp-notes-sync-todo20-subagent-review.json"
    content = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "show", f"{commit_sha}:{path}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if content.returncode != 0 or content.stdout != subagent_raw:
        raise ReviewReceiptError("subagent review artifact is not bound to its immutable commit")
    changed = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit_sha],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if changed.returncode != 0 or changed.stdout.splitlines() != [path]:
        raise ReviewReceiptError("subagent review commit contains unexpected files")


def validate_pr(pr: dict[str, Any], pr_number: int, merged_oid: str) -> None:
    base = pr.get("base")
    head = pr.get("head")
    if (
        pr.get("number") != pr_number
        or pr.get("state") != "closed"
        or pr.get("merged") is not True
        or not pr.get("merged_at")
        or pr.get("merge_commit_sha") != merged_oid
        or not isinstance(base, dict)
        or not isinstance(head, dict)
        or base.get("ref") != "main"
        or head.get("repo", {}).get("full_name") != REPOSITORY
        or base.get("repo", {}).get("full_name") != REPOSITORY
    ):
        raise ReviewReceiptError("PR metadata is not a merged exact-head record")
    require_sha(base.get("sha"), SHA1, "PR base OID")
    require_sha(head.get("sha"), SHA1, "PR head OID")
    require_sha(merged_oid, SHA1, "merged OID")


def validate_ruleset(ruleset: dict[str, Any]) -> int:
    if (
        ruleset.get("id") != 20229460
        or ruleset.get("name") != "Protect Floorp iOS main"
        or ruleset.get("target") != "branch"
        or ruleset.get("source_type") != "Repository"
        or ruleset.get("source") != REPOSITORY
        or ruleset.get("enforcement") != "active"
        or ruleset.get("conditions") != {
            "ref_name": {"exclude": [], "include": ["refs/heads/main"]}
        }
    ):
        raise ReviewReceiptError("ruleset identity or enforcement is invalid")
    bypass_actors = ruleset.get("bypass_actors")
    if not isinstance(bypass_actors, list):
        raise ReviewReceiptError("ruleset bypass policy is unavailable")
    bypass_shape = sorted(
        (item.get("actor_type"), item.get("bypass_mode"))
        for item in bypass_actors
        if isinstance(item, dict)
    )
    if bypass_shape != [("OrganizationAdmin", "pull_request")]:
        raise ReviewReceiptError("ruleset bypass policy changed unexpectedly")
    rules = ruleset.get("rules")
    if not isinstance(rules, list):
        raise ReviewReceiptError("ruleset rules are unavailable")
    pull_request_rules = [rule for rule in rules if isinstance(rule, dict) and rule.get("type") == "pull_request"]
    if len(pull_request_rules) != 1:
        raise ReviewReceiptError("active ruleset must contain exactly one pull-request rule")
    pull_request_parameters = pull_request_rules[0].get("parameters")
    if (
        not isinstance(pull_request_parameters, dict)
        or pull_request_parameters.get("required_approving_review_count") != 0
        or pull_request_parameters.get("required_reviewers") != []
    ):
        raise ReviewReceiptError("pull-request rule must require zero approvals and no named reviewers")
    found_status_checks = False
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        if rule.get("type") == "required_status_checks":
            contexts = {
                item.get("context")
                for item in rule.get("parameters", {}).get("required_status_checks", [])
                if isinstance(item, dict)
            }
            if {"Validate workflows", "Build and unit test"}.issubset(contexts):
                found_status_checks = True
    if not found_status_checks:
        raise ReviewReceiptError("ruleset required status checks are unavailable")
    return 0


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
    desktop_sha: str,
    contract_sha256: str,
    binding_sha256: str,
    owner_sha256: str,
    merge_sha256: str,
    subagent_sha256: str,
    subagent_review_commit_sha: str,
    pr_api_sha256: str,
    reviews_api_sha256: str,
    ruleset_api_sha256: str,
    pr_projection_sha256: str,
    reviews_projection_sha256: str,
    ruleset_projection_sha256: str,
) -> dict[str, Any]:
    validate_pr(pr, owner["pr_number"], merged_oid)
    if not isinstance(reviews, list):
        raise ReviewReceiptError("review API result is not a list")
    required_review_count = validate_ruleset(ruleset)
    if reviews:
        raise ReviewReceiptError("native GitHub reviews are not empty for the self-review exception")
    safety = contract_safety(contract)
    validate_plan_binding(binding)
    validate_owner_review(owner, pr, binding, diff_sha256, desktop_sha)
    validate_merge_audit(merge, pr, merged_oid)
    validate_subagent_review(subagent, pr, owner, desktop_sha)
    require_sha(desktop_sha, SHA1, "Desktop commit")
    require_sha(subagent_review_commit_sha, SHA1, "subagent review commit")
    for value, label in (
        (diff_sha256, "diff digest"),
        (contract_sha256, "contract digest"),
        (binding_sha256, "plan binding digest"),
        (owner_sha256, "owner review digest"),
        (merge_sha256, "merge audit digest"),
        (subagent_sha256, "subagent review digest"),
        (pr_api_sha256, "PR API digest"),
        (reviews_api_sha256, "reviews API digest"),
        (ruleset_api_sha256, "ruleset API digest"),
        (pr_projection_sha256, "PR metadata projection digest"),
        (reviews_projection_sha256, "reviews metadata projection digest"),
        (ruleset_projection_sha256, "ruleset metadata projection digest"),
    ):
        require_sha(value, SHA256, label)
    return {
        "admin_bypass_used": merge["admin_bypass_used"],
        "amendment_sha256": binding["amendment_sha256"],
        "base_oid": pr["base"]["sha"],
        "combined_plan_hash": binding["combined_plan_hash"],
        "contract_sha256": contract_sha256,
        "diff_sha256": diff_sha256,
        "desktop_sha": desktop_sha,
        "environment": ENVIRONMENT,
        "head_sha": pr["head"]["sha"],
        "independence": owner["independence"],
        "local_test_accounts_accessed": safety["local_test_accounts_accessed"],
        "merged_oid": merged_oid,
        "bypass_requested": merge["bypass_requested"],
        "merge_endpoint": merge["merge_endpoint"],
        "merge_response_sha256": merge["merge_response_sha256"],
        "server_merged": merge["server_merged"],
        "server_merge_sha": merge["server_merge_sha"],
        "native_github_approval": safety["native_github_approval"],
        "operator_id": owner["operator_id"],
        "plan_binding_sha256": binding_sha256,
        "plan_sha256": binding["plan_sha256"],
        "pr_api_sha256": pr_api_sha256,
        "pr_projection_sha256": pr_projection_sha256,
        "pr_number": pr["number"],
        "public_release": safety["public_release"],
        "repository": REPOSITORY,
        "review_scope": "todo-20-pr-and-production-qa",
        "reviewed_at_utc": owner["reviewed_at_utc"],
        "roles": ["owner", "operations", "executor", "reviewer"],
        "ruleset_required_review_count": required_review_count,
        "reviews_api_sha256": reviews_api_sha256,
        "reviews_projection_sha256": reviews_projection_sha256,
        "reviews_count": len(reviews),
        "ruleset_api_sha256": ruleset_api_sha256,
        "ruleset_projection_sha256": ruleset_projection_sha256,
        "schema_version": 2,
        "self_review_exception": owner["self_review_exception"],
        "subagent_review_digests": [subagent_sha256],
        "subagent_review_commit_sha": subagent_review_commit_sha,
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


def verify_merged_parent(repository_root: Path, base_oid: str, merged_oid: str) -> None:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_root), "show", "-s", "--format=%P", merged_oid],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0 or result.stdout.strip().split() != [base_oid]:
        raise ReviewReceiptError("merged OID is not the guarded squash child of the PR base")


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-json", type=Path, required=True)
    parser.add_argument("--reviews-json", type=Path, required=True)
    parser.add_argument("--ruleset-json", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--merged-oid", required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--plan-binding", type=Path, required=True)
    parser.add_argument("--owner-review", type=Path, required=True)
    parser.add_argument("--merge-audit", type=Path, required=True)
    parser.add_argument("--subagent-review", type=Path, required=True)
    parser.add_argument("--subagent-review-commit", required=True)
    parser.add_argument("--pr-projection", type=Path, required=True)
    parser.add_argument("--reviews-projection", type=Path, required=True)
    parser.add_argument("--ruleset-projection", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        pr, pr_raw = load_json(args.pr_json)
        reviews, reviews_raw = load_json(args.reviews_json)
        ruleset, ruleset_raw = load_json(args.ruleset_json)
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
        verify_immutable_subagent_commit(args.repository_root, args.subagent_review_commit, subagent_raw)
        projections = (
            canonical(project_pr_metadata(pr)),
            canonical(project_reviews_metadata(reviews)),
            canonical(project_ruleset_metadata(ruleset)),
        )
        diff_sha256 = git_diff_sha256(args.repository_root, pr["base"]["sha"], pr["head"]["sha"])
        verify_merged_parent(args.repository_root, pr["base"]["sha"], args.merged_oid)
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
            args.desktop_sha,
            sha256_bytes(contract_raw),
            sha256_bytes(binding_raw),
            sha256_bytes(owner_raw),
            sha256_bytes(merge_raw),
            sha256_bytes(subagent_raw),
            args.subagent_review_commit,
            sha256_bytes(pr_raw),
            sha256_bytes(reviews_raw),
            sha256_bytes(ruleset_raw),
            sha256_bytes(projections[0]),
            sha256_bytes(projections[1]),
            sha256_bytes(projections[2]),
        )
        for path, raw in zip(
            (args.pr_projection, args.reviews_projection, args.ruleset_projection),
            projections,
            strict=True,
        ):
            write_exclusive(path, raw)
        write_exclusive(args.output, canonical(receipt))
    except (OSError, UnicodeError, json.JSONDecodeError, ReviewReceiptError, KeyError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=review_receipt_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"source-bound-review-receipt-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
