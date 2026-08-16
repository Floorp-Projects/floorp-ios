#!/usr/bin/python3 -I
"""Create the immutable metadata-only Todo 20 merge-audit artifact.

The operation input must be the canonical receipt emitted by the guarded
merge executor. The executor, rather than this command, performs the PUT and
records its safe ``merged``/``sha`` projection. This command only binds that
receipt to the exact repository pull-request audit event and fails closed on
bypass evidence.
"""

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
MERGE_AUDIT_SOURCE = "github-org-audit-log"
MERGE_RESPONSE_SOURCE = "github-api-put-merge-executor"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class MergeAuditError(ValueError):
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


def load_json(path: Path) -> tuple[Any, bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeAuditError(f"{path.name} is not valid JSON") from error
    if path.is_symlink() or not path.is_file():
        raise MergeAuditError(f"{path.name} is not a regular file")
    return value, raw


def flatten_events(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list) and all(isinstance(item, dict) for item in value):
        return value
    if isinstance(value, list) and all(isinstance(item, list) for item in value):
        flattened = [event for page in value for event in page if isinstance(event, dict)]
        if sum(len(page) for page in value) != len(flattened):
            raise MergeAuditError("audit response contains malformed events")
        return flattened
    raise MergeAuditError("audit response is not a paginated event list")


def string_values(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [item for child in value.values() for item in string_values(child)]
    if isinstance(value, list):
        return [item for child in value for item in string_values(child)]
    return []


def event_repository(event: dict[str, Any]) -> str | None:
    for key in ("repo", "repository"):
        value = event.get(key)
        if isinstance(value, str):
            return value
    return None


def event_timestamp(event: dict[str, Any]) -> int | float | str:
    for key in ("@timestamp", "created_at"):
        value = event.get(key)
        if isinstance(value, (int, float, str)) and not isinstance(value, bool):
            return value
    raise MergeAuditError("audit merge event has no timestamp")


def event_id(event: dict[str, Any]) -> str:
    candidates = [event.get("_document_id"), event.get("id")]
    data = event.get("data")
    if isinstance(data, dict):
        candidates.append(data.get("request_id"))
    for value in candidates:
        if isinstance(value, (int, str)) and not isinstance(value, bool) and str(value):
            return str(value)
    raise MergeAuditError("audit merge event has no immutable event ID")


def event_merge_oid(event: dict[str, Any]) -> str:
    candidates = [event.get("merge_commit_sha"), event.get("merged_oid"), event.get("sha")]
    data = event.get("data")
    if isinstance(data, dict):
        candidates.extend((data.get("merge_commit_sha"), data.get("merged_oid"), data.get("sha")))
    for value in candidates:
        if isinstance(value, str) and SHA1.fullmatch(value):
            return value
    raise MergeAuditError("audit merge event has no merge OID")


def is_bypass_event(event: dict[str, Any]) -> bool:
    if event_repository(event) != REPOSITORY:
        return False
    action = event.get("action")
    action_text = action.lower() if isinstance(action, str) else ""
    if any(marker in action_text for marker in ("bypass", "policy_override", "override")):
        return True
    serialized = json.dumps(event, ensure_ascii=False, sort_keys=True).lower()
    return "overridden_codes" in serialized or "bypass" in serialized or "policy_override" in serialized


def audit_projection(events: list[dict[str, Any]], pr_number: int) -> tuple[dict[str, Any], int]:
    expected_path = f"/pull/{pr_number}/merge"
    merge_events: list[dict[str, Any]] = []
    for event in events:
        if event.get("action") != "pull_request.merge" or event_repository(event) != REPOSITORY:
            continue
        if not any(expected_path in value for value in string_values(event)):
            continue
        merge_events.append(
            {
                "action": "pull_request.merge",
                "event_id_sha256": sha256(event_id(event).encode("utf-8")),
                "merge_oid": event_merge_oid(event),
                "pull_request_path": expected_path,
                "repository": REPOSITORY,
                "timestamp": event_timestamp(event),
            }
        )
    merge_events.sort(key=lambda value: canonical(value))
    projection = {"merge_events": merge_events}
    return projection, sum(1 for event in events if is_bypass_event(event))


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation-receipt", type=Path, required=True)
    parser.add_argument("--audit-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--waive-audit",
        action="store_true",
        help=(
            "create the schema-v3 owner-waived merge audit when the "
            "organization audit-log endpoint is unavailable (free org plan); "
            "the no-bypass fact is explicitly not claimed"
        ),
    )
    parser.add_argument("--owner-waiver", type=Path, required=False)
    return parser.parse_args(arguments)


def workflow_source() -> tuple[int, str]:
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise MergeAuditError("merge audit workflow repository is invalid")
    try:
        run_id = int(os.environ["GITHUB_RUN_ID"])
    except (KeyError, ValueError) as error:
        raise MergeAuditError("merge audit workflow run ID is unavailable") from error
    source_sha = os.environ.get("GITHUB_SHA")
    if run_id <= 0 or not isinstance(source_sha, str) or not SHA1.fullmatch(source_sha):
        raise MergeAuditError("merge audit workflow source SHA is invalid")
    return run_id, source_sha


WAIVER_FIELDS = {
    "approved_at_utc", "endpoint_unavailable", "operator_id", "plan_hash",
    "schema_version", "statement",
}


def load_canonical(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeAuditError(f"{path.name} is not valid JSON") from error
    if path.is_symlink() or not path.is_file() or not isinstance(value, dict) or raw != canonical(value):
        raise MergeAuditError(f"{path.name} is not canonical JSON")
    return value, raw


def validate_owner_waiver(path: Path) -> dict[str, Any]:
    waiver, _ = load_canonical(path)
    if set(waiver) != WAIVER_FIELDS:
        raise MergeAuditError("owner waiver fields are not exact")
    if (
        waiver["schema_version"] != 1
        or not isinstance(waiver["operator_id"], str)
        or not waiver["operator_id"]
        or waiver["operator_id"] != os.environ.get("GITHUB_ACTOR")
        or not isinstance(waiver["approved_at_utc"], str)
        or not waiver["approved_at_utc"].endswith("Z")
        or not isinstance(waiver["endpoint_unavailable"], str)
        or not waiver["endpoint_unavailable"]
        or not isinstance(waiver["statement"], str)
        or not waiver["statement"]
        or not SHA256.fullmatch(waiver["plan_hash"])
    ):
        raise MergeAuditError("owner waiver is stale or incomplete")
    binding_path = Path("docs/floorp-notes-sync-todo20-plan-binding.json")
    binding, _ = load_canonical(binding_path)
    if binding.get("combined_plan_hash") != waiver["plan_hash"]:
        raise MergeAuditError("owner waiver plan hash does not match the checked-in plan binding")
    return waiver


def waived_artifact(
    operation: dict[str, Any],
    operation_raw: bytes,
    source_run_id: int,
    source_sha: str,
    waiver: dict[str, Any],
) -> bytes:
    merge_projection = operation["merge_response"]
    response_digest = sha256(canonical(merge_projection))
    artifact = {
        "admin_bypass_used": None,
        "audit_bypass_event_count": None,
        "audit_endpoint_unavailable": True,
        "audit_event_count": 0,
        "audit_event_id_sha256": None,
        "audit_event_timestamp": None,
        "audit_projection_sha256": None,
        "audit_source": "github-org-audit-log-unavailable-owner-waived",
        "base_oid": operation["base_oid"],
        "bypass_requested": False,
        "head_sha": operation["head_sha"],
        "merge_endpoint": operation["merge_endpoint"],
        "merge_method": "squash",
        "merge_response": merge_projection,
        "merge_response_sha256": response_digest,
        "merge_response_source": operation["merge_response_source"],
        "merge_admission_receipt_sha256": operation["merge_admission_receipt_sha256"],
        "merged_oid": operation["merged_oid"],
        "oid_guarded": True,
        "operation_receipt_sha256": sha256(operation_raw),
        "pr_number": operation["pr_number"],
        "repository": REPOSITORY,
        "schema_version": 3,
        "server_merge_sha": operation["server_merge_sha"],
        "server_merged": True,
        "server_merged_at": operation["server_merged_at"],
        "source_workflow_run_id": source_run_id,
        "source_workflow_sha": source_sha,
        "source_workflow": "protected-guarded-merge-workflow",
        "waiver_approved_at_utc": waiver["approved_at_utc"],
        "waiver_operator_id": waiver["operator_id"],
        "waiver_plan_hash": waiver["plan_hash"],
    }
    return canonical(artifact)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        source_run_id, source_sha = workflow_source()
        if args.waive_audit:
            if args.owner_waiver is None:
                raise MergeAuditError("owner waiver receipt is required for the waived audit")
            waiver = validate_owner_waiver(args.owner_waiver)
        operation, operation_raw = load_json(args.operation_receipt)
        if not isinstance(operation, dict) or operation_raw != canonical(operation):
            raise MergeAuditError("merge operation receipt is not canonical JSON")
        expected_operation_fields = {
            "base_oid", "head_sha", "merge_endpoint", "merge_method", "merge_response",
            "merge_response_sha256", "merge_response_source", "merge_admission_receipt_sha256", "merged_oid", "oid_guarded",
            "pr_number", "repository", "schema_version", "server_merge_sha", "server_merged",
            "server_merged_at",
        }
        if set(operation) != expected_operation_fields:
            raise MergeAuditError("merge operation receipt fields are not exact")
        for value, label in (
            (operation["base_oid"], "base OID"),
            (operation["head_sha"], "head SHA"),
            (operation["merged_oid"], "merged OID"),
        ):
            if not SHA1.fullmatch(value):
                raise MergeAuditError(f"{label} is invalid")
        if not SHA256.fullmatch(operation["merge_admission_receipt_sha256"]):
            raise MergeAuditError("merge admission receipt digest is invalid")
        if operation["schema_version"] != 1 or operation["repository"] != REPOSITORY or operation["pr_number"] <= 0:
            raise MergeAuditError("merge operation receipt identity is invalid")
        if (
            operation["merge_method"] != "squash"
            or operation["merge_endpoint"] != f"PUT /repos/{REPOSITORY}/pulls/{operation['pr_number']}/merge"
            or operation["merge_response_source"] != MERGE_RESPONSE_SOURCE
            or operation["oid_guarded"] is not True
            or operation["server_merged"] is not True
            or operation["server_merge_sha"] != operation["merged_oid"]
            or not isinstance(operation["server_merged_at"], str)
            or not operation["server_merged_at"]
        ):
            raise MergeAuditError("merge operation receipt is not the guarded executor result")
        merge_projection = operation["merge_response"]
        if merge_projection != {"merged": True, "sha": operation["merged_oid"]}:
            raise MergeAuditError("actual PUT merge response is not the guarded squash result")
        if operation["merge_response_sha256"] != sha256(canonical(merge_projection)):
            raise MergeAuditError("merge operation response digest is invalid")
        audit, audit_raw = load_json(args.audit_json)
        if args.waive_audit:
            raw = waived_artifact(operation, operation_raw, source_run_id, source_sha, waiver)
            args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with args.output.open("xb") as handle:
                handle.write(raw)
                handle.flush()
            print('{"status":"merge-audit-created-waived"}')
            return 0
        if json.loads(audit_raw.decode("utf-8")) != audit:
            raise MergeAuditError("audit JSON bytes do not match the parsed response")
        events = flatten_events(audit)
        projection, bypass_count = audit_projection(events, operation["pr_number"])
        if bypass_count:
            raise MergeAuditError("audit log reports a protected-branch bypass event")
        if len(projection["merge_events"]) != 1:
            raise MergeAuditError("audit log does not contain exactly one exact pull_request.merge event")
        audit_event = projection["merge_events"][0]
        if audit_event["merge_oid"] != operation["merged_oid"]:
            raise MergeAuditError("audit merge event OID does not match the guarded PUT result")
        response_digest = sha256(canonical(merge_projection))
        projection_digest = sha256(canonical(projection))
        artifact = {
            "admin_bypass_used": False,
            "audit_bypass_event_count": bypass_count,
            "audit_event_count": len(projection["merge_events"]),
            "audit_event_id_sha256": audit_event["event_id_sha256"],
            "audit_event_timestamp": audit_event["timestamp"],
            "audit_projection_sha256": projection_digest,
            "audit_source": MERGE_AUDIT_SOURCE,
            "base_oid": operation["base_oid"],
            "bypass_requested": False,
            "head_sha": operation["head_sha"],
            "merge_endpoint": operation["merge_endpoint"],
            "merge_method": "squash",
            "merge_response": merge_projection,
            "merge_response_sha256": response_digest,
            "merge_response_source": MERGE_RESPONSE_SOURCE,
            "merge_admission_receipt_sha256": operation["merge_admission_receipt_sha256"],
            "merged_oid": operation["merged_oid"],
            "oid_guarded": True,
            "operation_receipt_sha256": sha256(operation_raw),
            "pr_number": operation["pr_number"],
            "repository": REPOSITORY,
            "schema_version": 2,
            "server_merge_sha": operation["server_merge_sha"],
            "server_merged": True,
            "server_merged_at": operation["server_merged_at"],
            "source_workflow_run_id": source_run_id,
            "source_workflow_sha": source_sha,
            "source_workflow": "protected-guarded-merge-workflow",
        }
        raw = canonical(artifact)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
    except (OSError, UnicodeError, json.JSONDecodeError, MergeAuditError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=merge_audit_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"merge-audit-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
