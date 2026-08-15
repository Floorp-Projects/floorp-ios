#!/usr/bin/python3 -I
"""Validate the append-only Todo 20 single-operator attestation record."""

from __future__ import annotations

import argparse
import hashlib
import json
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
MANIFEST_ROLES = {
    "qa-summary",
    "cleanup-receipt",
    "xcresult",
    "xcodebuild-log",
    "desktop-log",
    "production-qa-capability",
    "production-qa-xcconfig",
    "secret-scan",
}


class AttestationError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AttestationError("attestation contains a duplicate JSON member")
        result[key] = value
    return result


def load(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise AttestationError("attestation ledger must contain one newline-terminated event")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    if not isinstance(value, dict) or raw != canonical(value):
        raise AttestationError("attestation ledger is not canonical JSONL")
    return value, raw


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--merged-oid", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--cleanup-receipt", type=Path, required=True)
    parser.add_argument("--secret-scan", type=Path, required=True)
    parser.add_argument("--review-receipt", type=Path, required=True)
    return parser.parse_args(arguments)


def digest(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise AttestationError(f"attestation evidence is unavailable: {path.name}") from error
    if path.is_symlink() or not path.is_file():
        raise AttestationError(f"attestation evidence is not a regular file: {path.name}")
    return hashlib.sha256(raw).hexdigest()


def load_review_receipt(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AttestationError("review receipt is unavailable or invalid") from error
    if path.is_symlink() or not path.is_file() or raw != canonical(value) or not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise AttestationError("review receipt is not canonical JSON")
    if not isinstance(value, dict):
        raise AttestationError("review receipt is not an object")
    return value


def load_manifest(path: Path, head_sha: str, run_id: int, run_attempt: int) -> bytes:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AttestationError("evidence manifest is not canonical JSON") from error
    canonical_raw = canonical(value)
    if raw != canonical_raw or not isinstance(value, dict):
        raise AttestationError("evidence manifest is not canonical JSON")
    expected = {
        "accounts", "artifacts", "desktop_sha", "environment", "head_sha",
        "public_release", "repository", "schema_version", "workflow_path",
        "workflow_run_attempt", "workflow_run_id",
    }
    if set(value) != expected:
        raise AttestationError("evidence manifest fields are not exact")
    if (
        value["accounts"] != 2
        or value["environment"] != ENVIRONMENT
        or value["public_release"] is not False
        or value["repository"] != REPOSITORY
        or value["workflow_path"] != WORKFLOW_PATH
        or value["head_sha"] != head_sha
        or value["workflow_run_id"] != run_id
        or value["workflow_run_attempt"] != run_attempt
        or not SHA1.fullmatch(value["desktop_sha"])
    ):
        raise AttestationError("evidence manifest source binding is invalid")
    artifacts = value["artifacts"]
    if not isinstance(artifacts, list) or {item.get("role") for item in artifacts if isinstance(item, dict)} != MANIFEST_ROLES:
        raise AttestationError("evidence manifest artifact set is incomplete")
    for item in artifacts:
        if not isinstance(item, dict) or set(item) != {"byte_count", "name", "role", "sha256"}:
            raise AttestationError("evidence manifest artifact descriptor is malformed")
        if not isinstance(item["byte_count"], int) or item["byte_count"] < 0 or not SHA256.fullmatch(item["sha256"]):
            raise AttestationError("evidence manifest artifact digest is invalid")
    return raw


def validate(
    value: dict[str, Any],
    head_sha: str,
    merged_oid: str,
    run_id: int,
    run_attempt: int,
    manifest: Path,
    summary: Path,
    cleanup_receipt: Path,
    secret_scan: Path,
    review_receipt: Path,
) -> None:
    expected = {
        "accounts", "admin_bypass_used", "amendment_sha256", "base_oid", "cleanup",
        "cleanup_receipt_sha256", "combined_plan_hash", "diff_sha256",
        "contract_sha256", "evidence_manifest_sha256", "environment", "event", "event_sha256",
        "head_sha", "independence", "local_test_accounts_accessed",
        "manifest_sha256", "merged_oid", "native_github_approval", "operator_id", "plan_binding_sha256",
        "plan_sha256",
        "pr_number", "previous_event_sha256", "public_release", "repository",
        "review_scope", "reviewed_at_utc", "roles",
        "ruleset_required_review_count", "reviews_count", "schema_version",
        "qa_summary_sha256", "secret_scan_scope", "secret_scan_sha256",
        "review_receipt_sha256", "sequence", "self_review_exception", "subagent_review_digests",
        "two_disposable_accounts_only", "unresolved_blocking_findings",
        "validator_sha256", "owner_review_receipt_sha256", "merge_audit_sha256",
        "subagent_review_receipt_sha256", "workflow_job", "workflow_path",
        "workflow_run_attempt", "workflow_run_id",
    }
    if set(value) != expected:
        raise AttestationError("attestation fields are not exact")
    if (
        value["environment"] != ENVIRONMENT
        or value["event"] != "self-attestation"
        or value["accounts"] != 2
        or value["cleanup"] != {
            "accounts": True,
            "coordination_root": True,
            "local_cache": True,
            "runner_temp": True,
            "simulator_keychain": True,
        }
        or value["workflow_job"] != JOB
        or value["workflow_path"] != WORKFLOW_PATH
        or value["public_release"] is not False
        or value["repository"] != REPOSITORY
        or value["roles"] != ["owner", "operations", "executor", "reviewer"]
        or value["native_github_approval"] is not False
        or value["self_review_exception"] is not True
        or value["independence"] is not False
        or value["ruleset_required_review_count"] != 0
        or value["reviews_count"] != 0
        or value["admin_bypass_used"] is not False
        or value["two_disposable_accounts_only"] is not True
        or value["local_test_accounts_accessed"] is not False
        or value["unresolved_blocking_findings"] != []
        or value["schema_version"] != 2
        or value["sequence"] != 1
        or value["previous_event_sha256"] != "0" * 64
        or not isinstance(value["operator_id"], str)
        or not value["operator_id"]
        or not SHA1.fullmatch(value["base_oid"])
        or not SHA1.fullmatch(value["merged_oid"])
        or not SHA1.fullmatch(merged_oid)
        or value["merged_oid"] != merged_oid
        or not isinstance(value["pr_number"], int)
        or value["pr_number"] <= 0
        or value["review_scope"] != "todo-20-pr-and-production-qa"
        or not isinstance(value["reviewed_at_utc"], str)
        or not value["reviewed_at_utc"].endswith("Z")
        or not isinstance(value["subagent_review_digests"], list)
        or not value["subagent_review_digests"]
        or any(not SHA256.fullmatch(item) for item in value["subagent_review_digests"])
    ):
        raise AttestationError("attestation approval boundary is invalid")
    for field, path in (
        ("evidence_manifest_sha256", manifest),
        ("manifest_sha256", manifest),
        ("qa_summary_sha256", summary),
        ("cleanup_receipt_sha256", cleanup_receipt),
        ("secret_scan_sha256", secret_scan),
        ("review_receipt_sha256", review_receipt),
    ):
        if not SHA256.fullmatch(value[field]) or value[field] != digest(path):
            raise AttestationError(f"attestation {field} is not bound to evidence")
    if not SHA256.fullmatch(value["secret_scan_sha256"]):
        raise AttestationError("attestation secret scan digest is invalid")
    for field in (
        "plan_sha256",
        "amendment_sha256",
        "combined_plan_hash",
        "diff_sha256",
        "validator_sha256",
        "contract_sha256",
        "plan_binding_sha256",
        "owner_review_receipt_sha256",
        "merge_audit_sha256",
        "subagent_review_receipt_sha256",
    ):
        if not SHA256.fullmatch(value[field]):
            raise AttestationError(f"attestation {field} is invalid")
    validator_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if value["validator_sha256"] != validator_sha256:
        raise AttestationError("attestation validator digest is not bound")
    receipt = load_review_receipt(review_receipt)
    receipt_fields = (
        "admin_bypass_used", "amendment_sha256", "base_oid", "combined_plan_hash",
        "contract_sha256", "diff_sha256", "environment", "head_sha", "independence",
        "local_test_accounts_accessed", "merged_oid", "native_github_approval",
        "operator_id", "owner_review_receipt_sha256", "merge_audit_sha256",
        "plan_binding_sha256", "plan_sha256", "pr_number", "public_release",
        "repository", "review_scope", "reviewed_at_utc", "roles",
        "ruleset_required_review_count", "reviews_count", "self_review_exception",
        "subagent_review_digests", "subagent_review_receipt_sha256",
        "two_disposable_accounts_only", "unresolved_blocking_findings",
    )
    if any(receipt.get(field) != value[field] for field in receipt_fields):
        raise AttestationError("attestation metadata is not bound to the review receipt")
    if receipt.get("subagent_review_receipt_sha256") not in receipt.get("subagent_review_digests", []):
        raise AttestationError("subagent review receipt digest is not bound")
    if value["secret_scan_scope"] != "pre-attestation":
        raise AttestationError("attestation secret scan scope is invalid")
    if (
        not SHA1.fullmatch(head_sha)
        or value["head_sha"] != head_sha
        or not SHA256.fullmatch(value["event_sha256"])
        or value["workflow_run_id"] != run_id
        or value["workflow_run_attempt"] != run_attempt
    ):
        raise AttestationError("attestation is not bound to this workflow run")
    unsigned = dict(value)
    unsigned.pop("event_sha256")
    if hashlib.sha256(canonical(unsigned)).hexdigest() != value["event_sha256"]:
        raise AttestationError("attestation event hash is invalid")


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        value, raw = load(args.ledger)
        load_manifest(args.manifest, args.merged_oid, args.run_id, args.run_attempt)
        validate(
            value,
            args.head_sha,
            args.merged_oid,
            args.run_id,
            args.run_attempt,
            args.manifest,
            args.summary,
            args.cleanup_receipt,
            args.secret_scan,
            args.review_receipt,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, AttestationError) as error:
        print(f"self-attestation ledger rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"sha256": hashlib.sha256(raw).hexdigest(), "status": "self-attestation-ledger-valid"}, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
