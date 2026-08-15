#!/usr/bin/python3 -I
"""Create the immutable metadata-only Todo 20 merge-audit artifact.

The merge response input must be the exact JSON returned by the guarded
``PUT /pulls/{number}/merge`` operation. Only its safe ``merged``/``sha``
projection is retained. The audit input is read only to project the exact
repository pull-request merge event and to fail closed on bypass evidence.
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
MERGE_AUDIT_SOURCE = "github-org-audit-log"
MERGE_RESPONSE_SOURCE = "github-api-put-merge"
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
    parser.add_argument("--merge-response", type=Path, required=True)
    parser.add_argument("--audit-json", type=Path, required=True)
    parser.add_argument("--base-oid", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--merged-oid", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        for value, label in (
            (args.base_oid, "base OID"),
            (args.head_sha, "head SHA"),
            (args.merged_oid, "merged OID"),
        ):
            if not SHA1.fullmatch(value):
                raise MergeAuditError(f"{label} is invalid")
        if args.pr_number <= 0:
            raise MergeAuditError("PR number is invalid")
        merge_response, _ = load_json(args.merge_response)
        if not isinstance(merge_response, dict):
            raise MergeAuditError("merge response is not an object")
        merge_projection = {
            "merged": merge_response.get("merged"),
            "sha": merge_response.get("sha"),
        }
        if merge_projection != {"merged": True, "sha": args.merged_oid}:
            raise MergeAuditError("actual PUT merge response is not the guarded squash result")
        audit, audit_raw = load_json(args.audit_json)
        if json.loads(audit_raw.decode("utf-8")) != audit:
            raise MergeAuditError("audit JSON bytes do not match the parsed response")
        events = flatten_events(audit)
        projection, bypass_count = audit_projection(events, args.pr_number)
        if bypass_count:
            raise MergeAuditError("audit log reports a protected-branch bypass event")
        if not projection["merge_events"]:
            raise MergeAuditError("audit log has no exact pull_request.merge event")
        response_digest = sha256(canonical(merge_projection))
        projection_digest = sha256(canonical(projection))
        artifact = {
            "admin_bypass_used": False,
            "audit_bypass_event_count": bypass_count,
            "audit_event_count": len(projection["merge_events"]),
            "audit_projection_sha256": projection_digest,
            "audit_source": MERGE_AUDIT_SOURCE,
            "base_oid": args.base_oid,
            "bypass_requested": False,
            "head_sha": args.head_sha,
            "merge_endpoint": f"PUT /repos/{REPOSITORY}/pulls/{args.pr_number}/merge",
            "merge_method": "squash",
            "merge_response": merge_projection,
            "merge_response_sha256": response_digest,
            "merge_response_source": MERGE_RESPONSE_SOURCE,
            "merged_oid": args.merged_oid,
            "oid_guarded": True,
            "pr_number": args.pr_number,
            "repository": REPOSITORY,
            "schema_version": 2,
            "server_merge_sha": args.merged_oid,
            "server_merged": True,
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
