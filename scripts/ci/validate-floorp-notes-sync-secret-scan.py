#!/usr/bin/python3 -I
"""Validate the metadata-only secret-scan receipt for Todo 20."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


SHA1 = re.compile(r"[0-9a-f]{40}\Z")
REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
SCOPE = [
    "qa-summary",
    "cleanup-receipt",
    "xcresult",
    "xcodebuild-log",
    "process-argv-environment-markers",
]
MARKERS = (
    "password",
    "access_token",
    "refresh_token",
    "sync_key",
    "authorization",
    "bearer ",
    "cookie",
    "credential",
    "secret",
    "begin private key",
    "oauth_token",
    "note(_|s_)(content|title|payload)",
    "request_body",
    "response_body",
)
MARKER_SET_SHA256 = hashlib.sha256("\n".join(MARKERS).encode()).hexdigest()
REQUIRED_TARGETS = {
    "qa-summary.json",
    "cleanup-receipt.json",
    "floorp-notes-sync-two-client.xcresult",
    "xcodebuild.log",
}


class SecretScanError(ValueError):
    pass


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--run-attempt", required=True, type=int)
    return parser.parse_args(arguments)


def load(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise SecretScanError("secret-scan receipt is unavailable") from error
    if not raw.endswith(b"\n"):
        raise SecretScanError("secret-scan receipt must end with one newline")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SecretScanError("secret-scan receipt is not valid JSON") from error
    if not isinstance(value, dict):
        raise SecretScanError("secret-scan receipt must be an object")
    canonical = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    if raw != canonical:
        raise SecretScanError("secret-scan receipt is not canonical JSON")
    return value, raw


def validate(value: dict[str, Any], head_sha: str, run_id: int, run_attempt: int) -> None:
    if set(value) != {
        "job_name",
        "marker_set_sha256",
        "passed",
        "repository",
        "schema_version",
        "scope",
        "source",
        "target_digests",
    }:
        raise SecretScanError("secret-scan receipt fields are not exact")
    if value["schema_version"] != 1 or value["passed"] is not True:
        raise SecretScanError("secret-scan receipt is not a passing scan")
    if value["marker_set_sha256"] != MARKER_SET_SHA256:
        raise SecretScanError("secret-scan marker set is not bound")
    if value["job_name"] != "notes-sync-production-qa" or value["repository"] != REPOSITORY:
        raise SecretScanError("secret-scan receipt job/repository is invalid")
    if value["scope"] != SCOPE:
        raise SecretScanError("secret-scan scope is incomplete")
    targets = value["target_digests"]
    if not isinstance(targets, list) or {target.get("name") for target in targets if isinstance(target, dict)} != REQUIRED_TARGETS:
        raise SecretScanError("secret-scan target digest set is incomplete")
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"byte_count", "file_count", "name", "sha256"}:
            raise SecretScanError("secret-scan target digest is malformed")
        if not isinstance(target["byte_count"], int) or target["byte_count"] < 0:
            raise SecretScanError("secret-scan target byte count is invalid")
        if not isinstance(target["file_count"], int) or target["file_count"] < 1:
            raise SecretScanError("secret-scan target file count is invalid")
        if not isinstance(target["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", target["sha256"]):
            raise SecretScanError("secret-scan target digest is invalid")
    source = value["source"]
    if not isinstance(source, dict) or set(source) != {
        "head_sha",
        "workflow_path",
        "workflow_run_attempt",
        "workflow_run_id",
    }:
        raise SecretScanError("secret-scan source fields are not exact")
    if (
        not SHA1.fullmatch(head_sha)
        or source["head_sha"] != head_sha
        or source["workflow_path"] != WORKFLOW_PATH
        or source["workflow_run_id"] != run_id
        or source["workflow_run_attempt"] != run_attempt
    ):
        raise SecretScanError("secret-scan receipt is not bound to this workflow run")


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        value, raw = load(args.receipt)
        validate(value, args.head_sha, args.run_id, args.run_attempt)
    except (OSError, SecretScanError) as error:
        print(f"secret-scan receipt rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"sha256": hashlib.sha256(raw).hexdigest(), "status": "secret-scan-receipt-valid"}, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
