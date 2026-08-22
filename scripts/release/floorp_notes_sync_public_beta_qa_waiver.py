#!/usr/bin/python3
"""Shared validation for the explicit public-beta FxA QA waiver."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-public-beta-qa.yml"
JOB_NAME = "notes-sync-public-beta-qa-waived"
ENDPOINT_POLICY_PATH = Path(__file__).resolve().parents[2] / "docs/floorp-release-endpoints.json"
APPROVED_FXA_HOSTS = [
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
]
APPROVED_SYNC_HOSTS = [
    "event-sync.services.mozilla.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
]
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class PublicBetaWaiverError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PublicBetaWaiverError(message)


def reject_float(_: str) -> Any:
    raise PublicBetaWaiverError("waiver contains a floating-point number")


def reject_constant(_: str) -> Any:
    raise PublicBetaWaiverError("waiver contains a non-finite number")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PublicBetaWaiverError("waiver contains a duplicate JSON member")
        result[key] = value
    return result


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"


def parse_bytes(raw: bytes) -> dict[str, Any]:
    require(raw.endswith(b"\n"), "waiver must end with one newline")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicBetaWaiverError("waiver is not valid UTF-8 JSON") from error
    require(isinstance(value, dict), "waiver root must be an object")
    require(raw == canonical(value), "waiver is not canonical JSON")
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


def validate_waiver(
    waiver: Any,
    *,
    expected_source_sha: str | None = None,
    expected_desktop_sha: str | None = None,
    expected_run_id: int | None = None,
    expected_run_attempt: int | None = None,
) -> dict[str, Any]:
    root = exact_keys(
        waiver,
        frozenset(
            {
                "approval",
                "checks",
                "desktop",
                "endpoint",
                "ios",
                "live_qa",
                "public_release",
                "schema_version",
                "source",
            }
        ),
        "waiver",
    )
    require(root["schema_version"] == 1, "waiver schema is unsupported")
    require(root["public_release"] is False, "waiver must remain non-distributable")

    approval = exact_keys(
        root["approval"],
        frozenset({"approved", "operator_id", "purpose"}),
        "waiver approval",
    )
    require(approval["approved"] is True, "waiver approval is not explicit")
    safe_string(approval["operator_id"], "waiver operator")
    require(approval["purpose"] == "external-testflight", "waiver purpose is invalid")

    checks = exact_keys(
        root["checks"],
        frozenset({"compile_preflight_passed", "operation_contract_passed", "repository_tests_passed"}),
        "waiver checks",
    )
    require(all(value is True for value in checks.values()), "waiver preflight checks are incomplete")

    endpoint = exact_keys(
        root["endpoint"],
        frozenset({"endpoint_policy_sha256", "fxa_configuration", "fxa_hosts", "sync_hosts", "wire_protocol"}),
        "waiver endpoint",
    )
    require(
        endpoint["endpoint_policy_sha256"]
        == hashlib.sha256(ENDPOINT_POLICY_PATH.read_bytes()).hexdigest(),
        "waiver endpoint policy is not bound to the checked-in policy",
    )
    require(endpoint["fxa_configuration"] == "FxAConfig.Server.release", "waiver FxA configuration is invalid")
    require(endpoint["fxa_hosts"] == APPROVED_FXA_HOSTS, "waiver FxA host policy is invalid")
    require(endpoint["sync_hosts"] == APPROVED_SYNC_HOSTS, "waiver Sync host policy is invalid")
    require(endpoint["wire_protocol"] == "sync15", "waiver wire protocol is invalid")

    desktop = exact_keys(root["desktop"], frozenset({"source_sha"}), "waiver Desktop source")
    desktop_sha = safe_string(desktop["source_sha"], "waiver Desktop SHA", SHA1)
    if expected_desktop_sha is not None:
        require(desktop_sha == expected_desktop_sha, "waiver Desktop SHA does not match the expected source")

    ios = exact_keys(
        root["ios"],
        frozenset({"build_number", "configuration", "repository", "source_sha"}),
        "waiver iOS source",
    )
    source_sha = safe_string(ios["source_sha"], "waiver iOS source SHA", SHA1)
    require(ios["repository"] == REPOSITORY, "waiver repository is not canonical")
    require(ios["configuration"] == "FloorpRelease", "waiver configuration is not FloorpRelease")
    require(ios["build_number"] == "4", "waiver build number is not the public-beta build")
    if expected_source_sha is not None:
        require(source_sha == expected_source_sha, "waiver source SHA does not match the candidate")

    live_qa = exact_keys(
        root["live_qa"],
        frozenset({"data_integrity_claim", "manual_validation_required", "reason_code", "status"}),
        "waiver live-QA record",
    )
    require(live_qa["data_integrity_claim"] is False, "waiver must not claim data-integrity validation")
    require(live_qa["manual_validation_required"] is True, "manual beta validation is required")
    require(live_qa["reason_code"] == "external-fxa-client-challenge", "waiver reason is invalid")
    require(live_qa["status"] == "owner-waived-not-performed", "live QA status is not waived")

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
        "waiver source binding",
    )
    require(source["repository"] == REPOSITORY, "waiver source repository is not canonical")
    require(source["event"] == "workflow_dispatch", "waiver source is not a manual dispatch")
    require(source["job_name"] == JOB_NAME, "waiver source job is not canonical")
    require(source["workflow_path"] == WORKFLOW_PATH, "waiver workflow path is not canonical")
    bound_sha = safe_string(source["head_sha"], "waiver source head SHA", SHA1)
    require(bound_sha == source_sha, "waiver source and iOS SHA differ")
    require(isinstance(source["workflow_run_id"], int) and source["workflow_run_id"] > 0, "waiver run ID is invalid")
    require(
        isinstance(source["workflow_run_attempt"], int) and source["workflow_run_attempt"] > 0,
        "waiver run attempt is invalid",
    )
    if expected_run_id is not None:
        require(source["workflow_run_id"] == expected_run_id, "waiver run ID does not match the selected artifact")
    if expected_run_attempt is not None:
        require(
            source["workflow_run_attempt"] == expected_run_attempt,
            "waiver run attempt does not match the selected artifact",
        )
    return root


def read_and_validate(path: Path, **kwargs: Any) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    value = parse_bytes(raw)
    validate_waiver(value, **kwargs)
    return value, raw
