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
    "desktop-log",
    "production-qa-capability",
    "production-qa-xcconfig",
    "self-attestation-ledger",
    "review-receipt",
    "pr-metadata",
    "reviews-metadata",
    "ruleset-metadata",
    "exact-secret-values",
    "process-argv-environment-markers",
]
PRE_SCOPE = [item for item in SCOPE if item != "self-attestation-ledger"]
MARKERS = (
    "password=",
    "password:",
    "access_token=",
    "access_token:",
    "refresh_token=",
    "refresh_token:",
    "sync_key=",
    "sync_key:",
    "authorization: bearer ",
    "authorization=",
    "bearer ",
    "cookie=",
    "cookie:",
    "credential=",
    "credential:",
    "begin private key",
    "oauth_token=",
    "oauth_token:",
    "note(_|s_)(content|title|payload)[=:]",
    "request_body[=:]",
    "response_body[=:]",
)
MARKER_SET_SHA256 = hashlib.sha256("\n".join(MARKERS).encode()).hexdigest()
SCAN_METHOD = "regex-and-exact-secret-values-over-declared-targets-and-owned-process-argv"
MARKER_PATTERN = re.compile("|".join(f"(?:{marker})" for marker in MARKERS), re.IGNORECASE)
REQUIRED_TARGETS = {
    "qa-summary.json",
    "cleanup-receipt.json",
    "floorp-notes-sync-two-client.xcresult",
    "xcodebuild.log",
    "desktop.log",
    "production-qa-capability.json",
    "production-qa.xcconfig",
    "self-attestation.jsonl",
    "review-receipt.json",
    "pr-metadata.json",
    "reviews-metadata.json",
    "ruleset-metadata.json",
}
PRE_REQUIRED_TARGETS = REQUIRED_TARGETS - {"self-attestation.jsonl"}
SECRET_ENV_NAMES = [
    "FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD",
]


class SecretScanError(ValueError):
    pass


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--run-attempt", required=True, type=int)
    parser.add_argument("--target", type=Path, action="append", required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--pre-attestation", action="store_true")
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


def digest_target(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.exists():
        raise SecretScanError(f"secret-scan target is unavailable: {path.name}")
    entries: list[bytes] = []
    byte_count = 0
    if path.is_file():
        files = [(path.name, path)]
    elif path.is_dir():
        files = [
            (child.relative_to(path).as_posix(), child)
            for child in sorted(path.rglob("*"))
            if child.is_file() and not child.is_symlink()
        ]
    else:
        raise SecretScanError(f"secret-scan target is not a regular file or directory: {path.name}")
    for relative, child in files:
        raw = child.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("utf-8", errors="ignore")
        if MARKER_PATTERN.search(text):
            raise SecretScanError(f"secret marker detected in {path.name}/{relative}")
        byte_count += len(raw)
        entries.append(relative.encode() + b"\0" + hashlib.sha256(raw).hexdigest().encode())
    return {
        "artifact_sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else hashlib.sha256(b"\n".join(entries)).hexdigest(),
        "byte_count": byte_count,
        "file_count": len(files),
        "name": path.name,
        "sha256": hashlib.sha256(b"\n".join(entries)).hexdigest(),
    }


def validate(
    value: dict[str, Any],
    head_sha: str,
    run_id: int,
    run_attempt: int,
    target_paths: list[Path],
    manifest: Path | None = None,
    include_self_attestation: bool = True,
) -> None:
    if set(value) != {
        "job_name",
        "marker_set_sha256",
        "passed",
        "repository",
        "scan_method",
        "scan_passed",
        "secret_env_names",
        "schema_version",
        "scope",
        "source",
        "target_digests",
    }:
        raise SecretScanError("secret-scan receipt fields are not exact")
    if value["schema_version"] != 1 or value["passed"] is not True:
        raise SecretScanError("secret-scan receipt is not a passing scan")
    if value["scan_method"] != SCAN_METHOD or value["scan_passed"] is not True:
        raise SecretScanError("secret-scan execution method is not bound")
    if value["secret_env_names"] != SECRET_ENV_NAMES:
        raise SecretScanError("secret-scan secret-value scope is incomplete")
    if value["marker_set_sha256"] != MARKER_SET_SHA256:
        raise SecretScanError("secret-scan marker set is not bound")
    if value["job_name"] != "notes-sync-production-qa" or value["repository"] != REPOSITORY:
        raise SecretScanError("secret-scan receipt job/repository is invalid")
    expected_scope = SCOPE if include_self_attestation else PRE_SCOPE
    if value["scope"] != expected_scope:
        raise SecretScanError("secret-scan scope is incomplete")
    targets = value["target_digests"]
    required_targets = REQUIRED_TARGETS if include_self_attestation else PRE_REQUIRED_TARGETS
    if not isinstance(targets, list) or {target.get("name") for target in targets if isinstance(target, dict)} != required_targets:
        raise SecretScanError("secret-scan target digest set is incomplete")
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"artifact_sha256", "byte_count", "file_count", "name", "sha256"}:
            raise SecretScanError("secret-scan target digest is malformed")
        if not isinstance(target["byte_count"], int) or target["byte_count"] < 0:
            raise SecretScanError("secret-scan target byte count is invalid")
        if not isinstance(target["file_count"], int) or target["file_count"] < 1:
            raise SecretScanError("secret-scan target file count is invalid")
        if not isinstance(target["artifact_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", target["artifact_sha256"]):
            raise SecretScanError("secret-scan artifact digest is invalid")
        if not isinstance(target["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", target["sha256"]):
            raise SecretScanError("secret-scan target digest is invalid")
    actual = [digest_target(path) for path in target_paths]
    expected_by_name = {target["name"]: target for target in targets}
    actual_by_name = {target["name"]: target for target in actual}
    if actual_by_name != expected_by_name:
        raise SecretScanError("secret-scan target digest does not match the artifact bytes")
    if manifest is not None:
        try:
            manifest_raw = manifest.read_bytes()
            manifest_value = json.loads(manifest_raw.decode("utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise SecretScanError("evidence manifest is unavailable or invalid") from error
        canonical_manifest = json.dumps(
            manifest_value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode() + b"\n"
        if manifest.is_symlink() or not manifest.is_file() or manifest_raw != canonical_manifest or not isinstance(manifest_value, dict):
            raise SecretScanError("evidence manifest is not canonical JSON")
        artifacts = manifest_value.get("artifacts")
        if not isinstance(artifacts, list):
            raise SecretScanError("evidence manifest artifacts are unavailable")
        manifest_by_name = {
            item.get("name"): item
            for item in artifacts
            if isinstance(item, dict) and item.get("role") != "secret-scan"
        }
        target_names = set(actual_by_name)
        expected_names = set(manifest_by_name)
        if target_names - expected_names - {"self-attestation.jsonl"} or expected_names - target_names:
            raise SecretScanError("secret-scan target set is not bound to the evidence manifest")
        for name in expected_names:
            descriptor = manifest_by_name[name]
            target = actual_by_name[name]
            if (
                not isinstance(descriptor, dict)
                or descriptor.get("byte_count") != target.get("byte_count")
                or descriptor.get("sha256") != target.get("artifact_sha256")
            ):
                raise SecretScanError(f"secret-scan target {name} is not bound to the manifest")
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
        validate(value, args.head_sha, args.run_id, args.run_attempt, args.target, args.manifest, not args.pre_attestation)
    except (OSError, SecretScanError) as error:
        print(f"secret-scan receipt rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"sha256": hashlib.sha256(raw).hexdigest(), "status": "secret-scan-receipt-valid"}, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
