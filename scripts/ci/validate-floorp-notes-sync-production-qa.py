#!/usr/bin/python3 -I
"""Validate metadata-only evidence from the bounded Todo 20 QA executor.

The input is a local, canonical JSON summary produced by the existing
desktop/mobile client pair. It contains no Notes payload and this validator
never contacts FxA/Sync or reads credentials. A valid summary is necessary but
not sufficient for Phase 2 enablement: the repository execution validator and
append-only ledger must bind the same digest and workflow run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import stat
import sys
from pathlib import Path
from typing import Any


MAX_BYTES = 128 * 1024
ENVIRONMENT = "floorp-notes-sync-production-qa"
REPOSITORY = "Floorp-Projects/floorp-ios"
APPROVED_FXA_HOSTS = (
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
)
APPROVED_SYNC_HOSTS = (
    "event-sync.services.mozilla.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
)
APPROVED_HOSTS = tuple(sorted((*APPROVED_FXA_HOSTS, *APPROVED_SYNC_HOSTS)))
REQUIRED_CASES = (
    "desktop-create-mobile-sync-desktop-recheck",
    "mobile-create-desktop-sync-mobile-recheck",
    "same-record-concurrent-edit",
    "update-delete-conflict",
    "offline-edit-reconnect-retry",
    "upload-save-commit-failure",
    "restart-preserves-unsynced-local-data",
    "old-new-client-mixed",
    "large-empty-multiple-records",
    "account-switch-isolation",
    "retry-idempotence",
    "base-revision-confirmation-gate",
)
REQUIRED_INVARIANTS = (
    "no-data-loss",
    "no-duplicate-records",
    "no-incorrect-delete-or-resurrection",
    "no-account-mixing",
    "no-rollback-on-retry",
    "base-revision-after-confirmation-only",
)
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
REQUIRED_XCTEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix"
MAX_XCRESULT_NODES = 4096
MAX_XCRESULT_DEPTH = 64


class ProductionQAError(ValueError):
    """The metadata-only production QA summary is unsafe or incomplete."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProductionQAError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProductionQAError("QA summary contains a duplicate JSON member")
        result[key] = value
    return result


def reject_float(_: str) -> Any:
    raise ProductionQAError("QA summary contains a floating-point number")


def reject_constant(_: str) -> Any:
    raise ProductionQAError("QA summary contains a non-finite number")


def parse_bytes(raw: bytes) -> dict[str, Any]:
    require(raw.endswith(b"\n"), "QA summary must end with one newline")
    require(len(raw) <= MAX_BYTES, "QA summary exceeds the size limit")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProductionQAError("QA summary is not valid UTF-8 JSON") from error
    require(isinstance(value, dict), "QA summary root must be an object")
    canonical = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    require(raw == canonical, "QA summary is not canonical JSON")
    return value


def exact_keys(value: Any, expected: frozenset[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(value) == expected, f"{label} fields are not exact")
    return value


def safe_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be a non-empty string")
    if pattern is not None:
        require(pattern.fullmatch(value) is not None, f"{label} has an invalid format")
    return value


def reject_sensitive_fields(value: Any, label: str, path: tuple[str, ...] = ()) -> None:
    sensitive = {
        "access_token",
        "authorization",
        "authorization_header",
        "cookie",
        "credential",
        "credentials",
        "email",
        "key",
        "note_content",
        "note_title",
        "notes_content",
        "notes_payload",
        "notes_title",
        "oauth_token",
        "password",
        "payload",
        "raw_sync_key",
        "refresh_token",
        "request_body",
        "response_body",
        "secret",
        "session",
        "sync_key",
        "token",
    }
    if isinstance(value, dict):
        for key, child in value.items():
            require(isinstance(key, str), f"{label} has a non-string field")
            normalized = re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower()
            require(normalized not in sensitive, f"{label} contains forbidden field {'.'.join((*path, key))}")
            reject_sensitive_fields(child, label, (*path, key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_sensitive_fields(child, label, (*path, str(index)))
    elif isinstance(value, str):
        lowered = value.lower()
        for marker in ("authorization: bearer", "bearer ", "begin private key", "oauth_token"):
            require(marker not in lowered, f"{label} contains a forbidden secret marker")


def validate_summary(summary: Any) -> dict[str, Any]:
    root = exact_keys(
        summary,
        frozenset(
            {
                "accounts",
                "cases",
                "cleanup",
                "cleanup_receipt_sha256",
                "clients",
                "environment",
                "invariants",
                "network",
                "phase",
                "phase_2_enablement_ready",
                "public_release",
                "schema_version",
                "self_attestation",
                "source",
            }
        ),
        "QA summary",
    )
    require(root["schema_version"] == 1, "QA summary schema is unsupported")
    require(root["phase"] == "production-qa", "QA summary phase is not production-qa")
    require(root["environment"] == ENVIRONMENT, "QA summary Environment is not protected")
    require(root["accounts"] == 2, "QA summary must use exactly two accounts")
    require(root["clients"] == ["desktop", "mobile"], "QA summary clients are not desktop/mobile")
    require(root["public_release"] is False, "QA summary must not authorize public release")
    require(root["phase_2_enablement_ready"] is True, "QA summary is not ready for Phase 2")
    safe_string(root["cleanup_receipt_sha256"], "cleanup receipt SHA-256", SHA256)

    source = exact_keys(
        root["source"],
        frozenset(
            {
                "event",
                "head_sha",
                "job_name",
                "repository",
                "workflow_path",
                "workflow_run_attempt",
                "workflow_run_id",
            }
        ),
        "QA source",
    )
    require(source["repository"] == REPOSITORY, "QA source repository is not canonical")
    require(source["event"] == "workflow_dispatch", "QA source is not a manual dispatch")
    require(source["job_name"] == "notes-sync-production-qa", "QA source job is not canonical")
    require(source["workflow_path"] == ".github/workflows/ci.yml", "QA source workflow is not canonical")
    safe_string(source["head_sha"], "QA source head SHA", SHA1)
    require(isinstance(source["workflow_run_id"], int) and source["workflow_run_id"] > 0, "QA run ID is invalid")
    require(
        isinstance(source["workflow_run_attempt"], int) and source["workflow_run_attempt"] > 0,
        "QA run attempt is invalid",
    )

    cases = root["cases"]
    require(isinstance(cases, list) and len(cases) == len(REQUIRED_CASES), "QA case list is incomplete")
    case_names: list[str] = []
    for index, case in enumerate(cases):
        item = exact_keys(case, frozenset({"name", "passed"}), f"QA case {index}")
        name = safe_string(item["name"], f"QA case {index} name")
        require(name not in case_names, "QA case list contains a duplicate")
        case_names.append(name)
        require(item["passed"] is True, f"QA case {name} did not pass")
    require(case_names == list(REQUIRED_CASES), "QA case order/set is not canonical")

    invariants = exact_keys(
        root["invariants"],
        frozenset(REQUIRED_INVARIANTS),
        "QA invariants",
    )
    require(all(value is True for value in invariants.values()), "a data-integrity invariant failed")

    network = exact_keys(
        root["network"],
        frozenset({"direct_rest_used", "hosts", "metadata_only", "tls_verified", "wire_protocol"}),
        "QA network",
    )
    require(network["hosts"] == list(APPROVED_HOSTS), "QA network contains an unapproved host")
    require(network["metadata_only"] is True, "QA network is not metadata-only")
    require(network["direct_rest_used"] is False, "QA used a direct REST/token path")
    require(network["tls_verified"] is True, "QA TLS was not verified")
    require(network["wire_protocol"] == "sync15", "QA wire protocol is not sync15")

    cleanup = exact_keys(
        root["cleanup"],
        frozenset({"accounts", "local_cache", "runner_temp", "simulator_keychain"}),
        "QA cleanup",
    )
    require(all(value is True for value in cleanup.values()), "QA cleanup is incomplete")

    attestation = exact_keys(
        root["self_attestation"],
        frozenset({"approved", "environment", "operator_id", "roles"}),
        "QA self-attestation",
    )
    require(attestation["approved"] is True, "QA self-attestation is not approved")
    require(attestation["environment"] == ENVIRONMENT, "self-attestation Environment mismatch")
    safe_string(attestation["operator_id"], "self-attestation operator")
    require(attestation["roles"] == ["owner", "operations", "executor"], "self-attestation roles are not exact")

    reject_sensitive_fields(root, "QA summary")
    return root


def load_and_validate(path: Path) -> dict[str, Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProductionQAError("QA summary is unavailable") from error
    require(stat.S_ISREG(metadata.st_mode) and not path.is_symlink(), "QA summary must be a regular file")
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise ProductionQAError("QA summary cannot be read") from error
    return validate_summary(parse_bytes(raw))


def validate_xcresult(path: Path) -> dict[str, Any]:
    """Require the selected production matrix XCTest to have Passed nodes."""
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProductionQAError("xcresult bundle is unavailable") from error
    require(stat.S_ISDIR(metadata.st_mode) and not path.is_symlink(), "xcresult bundle must be a regular directory")
    environment = {
        name: os.environ[name]
        for name in ("HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR")
        if os.environ.get(name)
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        completed = subprocess.run(
            [
                "/usr/bin/xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                str(path),
                "--format",
                "json",
            ],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=120,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ProductionQAError("xcresulttool execution failed") from error
    require(completed.returncode == 0, "xcresulttool rejected the xcresult bundle")
    try:
        payload = json.loads(completed.stdout, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, ProductionQAError) as error:
        raise ProductionQAError("xcresulttool returned malformed JSON") from error
    require(isinstance(payload, dict), "xcresulttool result root is malformed")
    roots = payload.get("testNodes")
    require(isinstance(roots, list), "xcresulttool testNodes are missing")
    matching_results: list[str] = []
    pending = [(node, 1) for node in roots]
    visited = 0
    while pending:
        node, depth = pending.pop()
        visited += 1
        require(visited <= MAX_XCRESULT_NODES, "xcresult test-node count exceeds the limit")
        require(depth <= MAX_XCRESULT_DEPTH, "xcresult test-node depth exceeds the limit")
        require(isinstance(node, dict), "xcresult test node is malformed")
        children = node.get("children", [])
        require(isinstance(children, list), "xcresult test-node children are malformed")
        pending.extend((child, depth + 1) for child in children)
        if node.get("nodeType") != "Test Case":
            continue
        identifier = node.get("nodeIdentifier")
        result = node.get("result")
        require(isinstance(identifier, str) and identifier, "xcresult test identifier is malformed")
        require(isinstance(result, str) and result, "xcresult test result is malformed")
        if identifier.endswith(REQUIRED_XCTEST) or identifier.endswith(REQUIRED_XCTEST.replace("/", ".")):
            matching_results.append(result)
    require(matching_results and all(result == "Passed" for result in matching_results), "required XCTest did not have Passed result nodes")
    return {"passed_nodes": len(matching_results), "required_test": REQUIRED_XCTEST}


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--xcresult", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        summary = load_and_validate(args.summary)
        xcresult = validate_xcresult(args.xcresult)
    except ProductionQAError as error:
        print(f"production QA summary rejected: {error}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "cases": len(summary["cases"]),
                "cleanup": "verified",
                "phase": summary["phase"],
                "xcresult": xcresult,
                "status": "production-qa-summary-valid",
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
