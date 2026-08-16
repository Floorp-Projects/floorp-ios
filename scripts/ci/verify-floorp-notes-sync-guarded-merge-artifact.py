#!/usr/bin/python3 -I
"""Verify that QA consumed the protected Todo 20 merge-run artifact.

The guarded merge workflow is the authoritative producer.  This verifier
checks the downloaded artifact's run identity, reviewed head, squash OID, and
executor receipt digest before the legacy immutable-commit parity check is
used by the review-receipt capture step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
MERGE_RESPONSE_SOURCE = "github-api-put-merge-executor"
WORKFLOW_SOURCE = "protected-guarded-merge-workflow"
WORKFLOW_PATH = ".github/workflows/ci.yml"
BASE_BRANCH = "main"
HEAD_BRANCH = "agent/floorp-plan-t20-live-executor"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class GuardedMergeArtifactError(ValueError):
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
        raise GuardedMergeArtifactError(f"{label} is not a regular file")
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GuardedMergeArtifactError(f"{label} is invalid JSON") from error
    if not isinstance(value, dict) or raw != canonical(value):
        raise GuardedMergeArtifactError(f"{label} is not canonical JSON")
    return value, raw


def load_json(path: Path, label: str) -> tuple[Any, bytes]:
    if path.is_symlink() or not path.is_file():
        raise GuardedMergeArtifactError(f"{label} is not a regular file")
    try:
        raw = path.read_bytes()
        return json.loads(raw.decode("utf-8")), raw
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GuardedMergeArtifactError(f"{label} is invalid JSON") from error


def require_sha(value: Any, pattern: re.Pattern[str], label: str) -> None:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise GuardedMergeArtifactError(f"{label} is invalid")


def validate_run_metadata(
    run: Any,
    artifacts: Any,
    metadata: dict[str, Any],
    expected_run_id: int,
    expected_head_sha: str,
) -> None:
    expected_metadata_fields = {
        "artifact_digest", "artifact_id", "artifact_name", "conclusion", "event", "head_branch",
        "head_sha", "repository", "run_id", "schema_version", "status", "workflow_path",
    }
    if set(metadata) != expected_metadata_fields:
        raise GuardedMergeArtifactError("merge artifact metadata fields are not exact")
    require_sha(metadata["artifact_digest"], SHA256, "uploaded artifact digest")
    if (
        metadata["schema_version"] != 1
        or metadata["repository"] != REPOSITORY
        or metadata["run_id"] != expected_run_id
        or metadata["artifact_id"] <= 0
        or metadata["artifact_name"] != f"floorp-notes-sync-guarded-merge-{expected_run_id}"
        or metadata["workflow_path"] != WORKFLOW_PATH
        or metadata["event"] != "workflow_dispatch"
        or metadata["head_branch"] != HEAD_BRANCH
        or metadata["status"] != "completed"
        or metadata["conclusion"] != "success"
    ):
        raise GuardedMergeArtifactError("merge artifact metadata is not bound to the protected run")
    if not isinstance(run, dict) or not isinstance(artifacts, dict):
        raise GuardedMergeArtifactError("GitHub Actions metadata is malformed")
    if (
        run.get("id") != expected_run_id
        or run.get("path") != WORKFLOW_PATH
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != HEAD_BRANCH
        or run.get("head_sha") != metadata["head_sha"]
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise GuardedMergeArtifactError("protected merge workflow run is not a successful exact-head dispatch")
    rows = artifacts.get("artifacts")
    if not isinstance(rows, list):
        raise GuardedMergeArtifactError("GitHub Actions artifact list is unavailable")
    matches = [row for row in rows if isinstance(row, dict) and row.get("name") == metadata["artifact_name"]]
    if len(matches) != 1:
        raise GuardedMergeArtifactError("protected merge artifact is missing or duplicated")
    artifact = matches[0]
    workflow_run = artifact.get("workflow_run")
    api_digest = artifact.get("digest")
    if isinstance(api_digest, str) and api_digest.startswith("sha256:"):
        api_digest = api_digest.removeprefix("sha256:")
    if (
        artifact.get("id") != metadata["artifact_id"]
        or artifact.get("expired") is not False
        or not isinstance(workflow_run, dict)
        or workflow_run.get("id") != expected_run_id
        or api_digest != metadata["artifact_digest"]
    ):
        raise GuardedMergeArtifactError("uploaded artifact metadata does not match the Actions API")


RECOVERY_EVIDENCE_FIELDS = {
    "admission_receipt_sha256", "expected_head_sha", "expected_merged_oid",
    "merged_at_utc", "operation_receipt_sha256", "recovery_head_sha",
    "recovery_run_id", "schema_version", "source_executor_step_success",
    "source_run_id",
}


def validate_recovery_evidence(
    evidence: dict[str, Any],
    run: dict[str, Any],
    metadata: dict[str, Any],
    expected_run_id: int,
    expected_head_sha: str,
    expected_merged_oid: str,
    admission_raw: bytes,
    operation_raw: bytes,
) -> None:
    if set(evidence) != RECOVERY_EVIDENCE_FIELDS:
        raise GuardedMergeArtifactError("merge recovery evidence fields are not exact")
    require_sha(evidence["expected_head_sha"], SHA1, "recovery expected head")
    require_sha(evidence["expected_merged_oid"], SHA1, "recovery expected merged OID")
    require_sha(evidence["recovery_head_sha"], SHA1, "recovery head SHA")
    require_sha(evidence["admission_receipt_sha256"], SHA256, "recovery admission digest")
    require_sha(evidence["operation_receipt_sha256"], SHA256, "recovery operation digest")
    if (
        evidence["schema_version"] != 1
        or evidence["recovery_run_id"] != expected_run_id
        or evidence["recovery_run_id"] != run.get("id")
        or evidence["recovery_head_sha"] != run.get("head_sha")
        or evidence["recovery_head_sha"] != metadata["head_sha"]
        or evidence["expected_head_sha"] != expected_head_sha
        or evidence["expected_merged_oid"] != expected_merged_oid
        or evidence["source_executor_step_success"] is not True
        or not isinstance(evidence["source_run_id"], int)
        or evidence["source_run_id"] <= 0
        or evidence["admission_receipt_sha256"] != sha256(admission_raw)
        or evidence["operation_receipt_sha256"] != sha256(operation_raw)
        or not isinstance(evidence["merged_at_utc"], str)
        or not evidence["merged_at_utc"]
    ):
        raise GuardedMergeArtifactError("merge recovery evidence is not bound to the protected recovery run")


def validate(
    merge: dict[str, Any],
    operation: dict[str, Any],
    operation_raw: bytes,
    admission: dict[str, Any],
    admission_raw: bytes,
    expected_run_id: int,
    expected_pr_number: int,
    expected_head_sha: str,
    expected_merged_oid: str,
    run_head_sha: str,
) -> None:
    if expected_run_id <= 0:
        raise GuardedMergeArtifactError("expected workflow run ID is invalid")
    if expected_pr_number <= 0:
        raise GuardedMergeArtifactError("expected PR number is invalid")
    require_sha(expected_head_sha, SHA1, "expected head SHA")
    require_sha(expected_merged_oid, SHA1, "expected merged OID")
    admission_fields = {
        "admin_bypass_used", "base_oid", "base_ref_name", "checks_count", "checks_sha256", "head_ref_name", "head_sha", "native_github_approval",
        "operator_id", "owner_review_sha256", "plan_binding_sha256", "pr_number", "repository",
        "schema_version", "status", "subagent_review_commit_sha", "subagent_review_sha256", "terminal_ci",
    }
    if set(admission) != admission_fields:
        raise GuardedMergeArtifactError("merge admission receipt fields are not exact")
    require_sha(admission["base_oid"], SHA1, "admission base OID")
    for value, label in (
        (admission["checks_sha256"], "admission checks digest"),
        (admission["owner_review_sha256"], "admission owner digest"),
        (admission["plan_binding_sha256"], "admission plan digest"),
        (admission["subagent_review_sha256"], "admission subagent digest"),
    ):
        require_sha(value, SHA256, label)
    if (
        admission["schema_version"] != 1
        or admission["status"] != "GO"
        or admission["repository"] != REPOSITORY
        or not isinstance(admission["pr_number"], int)
        or admission["pr_number"] <= 0
        or admission["base_ref_name"] != BASE_BRANCH
        or admission["head_ref_name"] != HEAD_BRANCH
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
        raise GuardedMergeArtifactError("merge admission receipt is not an exact-head terminal GO")
    operation_fields = {
        "base_oid", "head_sha", "merge_endpoint", "merge_method", "merge_response",
        "merge_response_sha256", "merge_response_source", "merge_admission_receipt_sha256", "merged_oid", "oid_guarded",
        "pr_number", "repository", "schema_version", "server_merge_sha", "server_merged",
        "server_merged_at",
    }
    if set(operation) != operation_fields:
        raise GuardedMergeArtifactError("executor receipt fields are not exact")
    for value, label in (
        (operation["base_oid"], "executor base OID"),
        (operation["head_sha"], "executor head SHA"),
        (operation["merged_oid"], "executor merged OID"),
    ):
        require_sha(value, SHA1, label)
    if (
        operation["schema_version"] != 1
        or operation["repository"] != REPOSITORY
        or not isinstance(operation["pr_number"], int)
        or operation["pr_number"] != expected_pr_number
        or operation["head_sha"] != expected_head_sha
        or operation["merged_oid"] != expected_merged_oid
        or operation["server_merge_sha"] != expected_merged_oid
        or operation["merge_method"] != "squash"
        or operation["merge_endpoint"] != f"PUT /repos/{REPOSITORY}/pulls/{operation['pr_number']}/merge"
        or operation["merge_response_source"] != MERGE_RESPONSE_SOURCE
        or operation["merge_response"] != {"merged": True, "sha": expected_merged_oid}
        or operation["oid_guarded"] is not True
        or operation["server_merged"] is not True
        or not isinstance(operation["server_merged_at"], str)
        or not operation["server_merged_at"]
    ):
        raise GuardedMergeArtifactError("executor receipt is not the expected guarded squash result")
    if operation["merge_response_sha256"] != sha256(canonical(operation["merge_response"])):
        raise GuardedMergeArtifactError("executor response digest is invalid")

    merge_fields = {
        "admin_bypass_used", "audit_bypass_event_count", "audit_event_count",
        "audit_event_id_sha256", "audit_event_timestamp", "audit_projection_sha256",
        "audit_source", "base_oid", "bypass_requested", "head_sha", "merge_endpoint",
        "merge_method", "merge_response", "merge_response_sha256", "merge_response_source",
        "merge_admission_receipt_sha256", "merged_oid", "oid_guarded", "operation_receipt_sha256", "pr_number", "repository",
        "schema_version", "server_merge_sha", "server_merged", "server_merged_at",
        "source_workflow", "source_workflow_run_id", "source_workflow_sha",
    }
    if set(merge) != merge_fields:
        raise GuardedMergeArtifactError("merge audit fields are not exact")
    for value, label in (
        (merge["base_oid"], "merge audit base OID"),
        (merge["head_sha"], "merge audit head SHA"),
        (merge["merged_oid"], "merge audit merged OID"),
        (merge["source_workflow_sha"], "merge audit source SHA"),
    ):
        require_sha(value, SHA1, label)
    require_sha(merge["operation_receipt_sha256"], SHA256, "operation receipt digest")
    require_sha(merge["merge_admission_receipt_sha256"], SHA256, "merge admission receipt digest")
    require_sha(merge["merge_response_sha256"], SHA256, "merge response digest")
    require_sha(merge["audit_event_id_sha256"], SHA256, "audit event ID digest")
    require_sha(merge["audit_projection_sha256"], SHA256, "audit projection digest")
    if (
        merge["schema_version"] != 2
        or merge["repository"] != REPOSITORY
        or not isinstance(merge["pr_number"], int)
        or merge["pr_number"] != expected_pr_number
        or merge["base_oid"] != operation["base_oid"]
        or merge["head_sha"] != expected_head_sha
        or merge["merged_oid"] != expected_merged_oid
        or merge["server_merge_sha"] != expected_merged_oid
        or merge["merge_endpoint"] != operation["merge_endpoint"]
        or merge["merge_method"] != "squash"
        or merge["merge_response_source"] != MERGE_RESPONSE_SOURCE
        or merge["merge_admission_receipt_sha256"] != operation.get("merge_admission_receipt_sha256")
        or merge["merge_response"] != {"merged": True, "sha": expected_merged_oid}
        or merge["merge_response_sha256"] != operation["merge_response_sha256"]
        or merge["oid_guarded"] is not True
        or merge["admin_bypass_used"] is not False
        or merge["bypass_requested"] is not False
        or merge["audit_source"] != "github-org-audit-log"
        or merge["audit_bypass_event_count"] != 0
        or merge["audit_event_count"] != 1
        or merge["source_workflow"] != WORKFLOW_SOURCE
        or merge["source_workflow_run_id"] != expected_run_id
        or merge["source_workflow_sha"] != run_head_sha
        or merge["server_merged"] is not True
        or merge["server_merged_at"] != operation["server_merged_at"]
    ):
        raise GuardedMergeArtifactError("merge audit is not bound to the protected merge run")
    if merge["operation_receipt_sha256"] != sha256(operation_raw):
        raise GuardedMergeArtifactError("merge audit is not bound to the executor receipt")
    if merge["merge_admission_receipt_sha256"] != sha256(admission_raw):
        raise GuardedMergeArtifactError("merge audit is not bound to the admission receipt")


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--merge-audit", type=Path, required=True)
    parser.add_argument("--operation-receipt", type=Path, required=True)
    parser.add_argument("--admission-receipt", type=Path, required=True)
    parser.add_argument("--run-json", type=Path, required=True)
    parser.add_argument("--artifacts-json", type=Path, required=True)
    parser.add_argument("--artifact-metadata", type=Path, required=True)
    parser.add_argument("--expected-run-id", type=int, required=True)
    parser.add_argument("--expected-pr-number", type=int, required=True)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument("--expected-merged-oid", required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        merge, _ = load_canonical(args.merge_audit, "merge audit")
        operation, operation_raw = load_canonical(args.operation_receipt, "executor receipt")
        admission, admission_raw = load_canonical(args.admission_receipt, "merge admission receipt")
        run, _ = load_json(args.run_json, "workflow run metadata")
        artifacts, _ = load_json(args.artifacts_json, "artifact metadata")
        metadata, _ = load_canonical(args.artifact_metadata, "uploaded artifact identity")
        validate_run_metadata(run, artifacts, metadata, args.expected_run_id, args.expected_head_sha)
        recovery_evidence_path = args.merge_audit.parent / "merge-recovery-evidence.json"
        if run.get("head_sha") == args.expected_head_sha:
            if recovery_evidence_path.exists():
                raise GuardedMergeArtifactError("merge recovery evidence is unexpected for an exact-head dispatch")
        else:
            evidence, _ = load_canonical(recovery_evidence_path, "merge recovery evidence")
            validate_recovery_evidence(
                evidence,
                run,
                metadata,
                args.expected_run_id,
                args.expected_head_sha,
                args.expected_merged_oid,
                admission_raw,
                operation_raw,
            )
        validate(
            merge,
            operation,
            operation_raw,
            admission,
            admission_raw,
            args.expected_run_id,
            args.expected_pr_number,
            args.expected_head_sha,
            args.expected_merged_oid,
            run["head_sha"],
        )
    except (GuardedMergeArtifactError, OSError) as error:
        print(f"[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=guarded_merge_artifact_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"guarded-merge-artifact-verified"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
