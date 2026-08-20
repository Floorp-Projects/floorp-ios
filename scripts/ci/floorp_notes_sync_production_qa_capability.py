#!/usr/bin/python3 -I
"""Canonical capability record for the non-distributed Todo 20 QA build."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
CAPABILITY_VERSION = "todo20-production-sync-integrity-v1"
REPOSITORY = "Floorp-Projects/floorp-ios"
ENVIRONMENT = "floorp-notes-sync-production-qa"
WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
JOB_NAME = "notes-sync-production-qa"
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
CASE_NAMES = [
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
]
INVARIANT_NAMES = [
    "no-data-loss",
    "no-duplicate-records",
    "no-incorrect-delete-or-resurrection",
    "no-account-mixing",
    "no-rollback-on-retry",
    "base-revision-after-confirmation-only",
]
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class CapabilityError(ValueError):
    pass


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True)
        .encode("utf-8")
        + b"\n"
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise CapabilityError(f"{label} fields are not exact")
    return value


def _sha(value: Any, label: str, pattern: re.Pattern[str] = SHA256) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise CapabilityError(f"{label} is not a lowercase digest")
    return value


def _reject_sensitive(value: Any) -> None:
    sensitive = {
        "access_token", "authorization", "cookie", "credential", "email", "key",
        "note_content", "note_title", "password", "payload", "refresh_token",
        "request_body", "response_body", "secret", "session", "sync_key", "token",
    }
    if isinstance(value, dict):
        for key, child in value.items():
            if key in sensitive:
                raise CapabilityError(f"sensitive capability field: {key}")
            _reject_sensitive(child)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive(child)
    elif isinstance(value, str):
        lowered = value.lower()
        if any(marker in lowered for marker in ("bearer ", "begin private key", "oauth_token")):
            raise CapabilityError("capability contains a secret marker")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CapabilityError("capability contains a duplicate JSON member")
        result[key] = value
    return result


def validate_capability(
    value: Any,
    *,
    expected_source_sha: str | None = None,
    expected_desktop_sha: str | None = None,
    expected_contract_sha: str | None = None,
    expected_endpoint_policy_sha: str | None = None,
) -> dict[str, Any]:
    root = _exact(
        value,
        {
            "accounts", "build_contract_mode", "clients", "contract_sha256",
            "desktop", "endpoint", "integrity_matrix_sha256", "public_release",
            "ios_build_number", "schema_version", "self_attestation", "source",
            "todo20_contract_version",
        },
        "capability",
    )
    if root["schema_version"] != SCHEMA_VERSION or root["build_contract_mode"] != "production-qa":
        raise CapabilityError("capability mode or schema is invalid")
    if root["todo20_contract_version"] != CAPABILITY_VERSION:
        raise CapabilityError("capability version is unsupported")
    if root["accounts"] != 2 or root["clients"] != ["desktop", "mobile"]:
        raise CapabilityError("capability must bind exactly two accounts and two clients")
    if not isinstance(root["ios_build_number"], str) or not root["ios_build_number"]:
        raise CapabilityError("capability iOS build number is invalid")
    if root["public_release"] is not False:
        raise CapabilityError("capability cannot authorize a public release")
    contract_sha = _sha(root["contract_sha256"], "contract digest")
    if expected_contract_sha is not None and contract_sha != expected_contract_sha:
        raise CapabilityError("capability contract digest is not bound to the checked-out contract")
    matrix_sha = _sha(root["integrity_matrix_sha256"], "integrity matrix digest")
    expected_matrix_sha = sha256_bytes(
        canonical_bytes({"cases": CASE_NAMES, "invariants": INVARIANT_NAMES})
    )
    if matrix_sha != expected_matrix_sha:
        raise CapabilityError("capability integrity matrix digest is not canonical")

    source = _exact(
        root["source"],
        {"event", "head_sha", "job_name", "repository", "workflow_path", "workflow_run_attempt", "workflow_run_id"},
        "capability source",
    )
    if (
        source["event"] != "workflow_dispatch"
        or source["job_name"] != JOB_NAME
        or source["repository"] != REPOSITORY
        or source["workflow_path"] != WORKFLOW_PATH
    ):
        raise CapabilityError("capability source is not the protected workflow")
    source_sha = _sha(source["head_sha"], "source head", SHA1)
    if expected_source_sha is not None and source_sha != expected_source_sha:
        raise CapabilityError("capability source head is not bound")
    if not isinstance(source["workflow_run_id"], int) or source["workflow_run_id"] <= 0:
        raise CapabilityError("capability workflow run ID is invalid")
    if not isinstance(source["workflow_run_attempt"], int) or source["workflow_run_attempt"] <= 0:
        raise CapabilityError("capability workflow attempt is invalid")

    desktop = _exact(
        root["desktop"],
        {"repository", "source_sha"}, "capability desktop")
    if desktop["repository"] != "Floorp-Projects/Floorp":
        raise CapabilityError("capability desktop repository is invalid")
    desktop_sha = _sha(desktop["source_sha"], "desktop source", SHA1)
    if expected_desktop_sha is not None and desktop_sha != expected_desktop_sha:
        raise CapabilityError("capability desktop source is not bound")

    endpoint = _exact(
        root["endpoint"],
        {"fxa_configuration", "fxa_hosts", "sync_hosts", "wire_protocol", "endpoint_policy_sha256"},
        "capability endpoint",
    )
    if (
        endpoint["fxa_configuration"] != "FxAConfig.Server.release"
        or endpoint["fxa_hosts"] != APPROVED_FXA_HOSTS
        or endpoint["sync_hosts"] != APPROVED_SYNC_HOSTS
        or endpoint["wire_protocol"] != "sync15"
    ):
        raise CapabilityError("capability endpoint is not the approved production sync15 path")
    endpoint_policy_sha = _sha(endpoint["endpoint_policy_sha256"], "endpoint policy digest")
    if expected_endpoint_policy_sha is not None and endpoint_policy_sha != expected_endpoint_policy_sha:
        raise CapabilityError("capability endpoint digest is not bound to the checked-out policy")

    attestation = _exact(
        root["self_attestation"],
        {"approved", "environment", "operator_id", "roles"},
        "capability self-attestation",
    )
    if (
        attestation["approved"] is not True
        or attestation["environment"] != ENVIRONMENT
        or not isinstance(attestation["operator_id"], str)
        or not attestation["operator_id"]
        or attestation["roles"] != ["owner", "operations", "executor"]
    ):
        raise CapabilityError("capability self-attestation is invalid")
    _reject_sensitive(root)
    return root


def load_capability(
    path: Path,
    *,
    expected_source_sha: str | None = None,
    expected_desktop_sha: str | None = None,
    expected_contract_sha: str | None = None,
    expected_endpoint_policy_sha: str | None = None,
) -> dict[str, Any]:
    raw = path.read_bytes()
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    if not raw.endswith(b"\n") or raw != canonical_bytes(value):
        raise CapabilityError("capability is not canonical JSON")
    return validate_capability(
        value,
        expected_source_sha=expected_source_sha,
        expected_desktop_sha=expected_desktop_sha,
        expected_contract_sha=expected_contract_sha,
        expected_endpoint_policy_sha=expected_endpoint_policy_sha,
    )


__all__ = [
    "APPROVED_FXA_HOSTS",
    "APPROVED_SYNC_HOSTS",
    "CASE_NAMES",
    "CAPABILITY_VERSION",
    "CapabilityError",
    "ENVIRONMENT",
    "INVARIANT_NAMES",
    "JOB_NAME",
    "REPOSITORY",
    "WORKFLOW_PATH",
    "canonical_bytes",
    "load_capability",
    "sha256_bytes",
    "sha256_file",
    "validate_capability",
]
