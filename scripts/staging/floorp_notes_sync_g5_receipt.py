"""Fail-closed parser for canonical, metadata-only G5 execution receipts.

This module only validates a receipt supplied by a separately trusted artifact
retrieval path.  It does not authorize a run, launch clients, read credentials,
or communicate with FxA or Sync.
"""

from __future__ import annotations

import json
import re
from typing import Any, Mapping


EXPECTED_REPOSITORY = "Floorp-Projects/floorp-ios"
EXPECTED_WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-g5.yml"
APPROVED_HOSTS = frozenset(
    {
        "accounts.firefox.com",
        "api.accounts.firefox.com",
        "oauth.accounts.firefox.com",
        "profile.accounts.firefox.com",
        "static.accounts.firefox.com",
        "event-sync.services.mozilla.com",
        "sync.services.mozilla.com",
        "token.services.mozilla.com",
    }
)
REQUIRED_SYNC_HOST = "sync.services.mozilla.com"
_FORBIDDEN_FIELD_PARTS = frozenset(
    {
        "account",
        "authorization",
        "content",
        "cookie",
        "credential",
        "email",
        "header",
        "key",
        "note",
        "password",
        "payload",
        "query",
        "secret",
        "session",
        "token",
        "url",
    }
)
_DANGEROUS_VALUE = re.compile(
    r"(?:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|://|[?#]|\b(?:authorization|bearer|oauth|token|cookie|password|credential|secret)\b)",
    re.IGNORECASE,
)
_SHA40 = re.compile(r"[0-9a-f]{40}\Z")
_SHA64 = re.compile(r"[0-9a-f]{64}\Z")
_SAFE_POLICY_FIELD_PATHS = frozenset(
    {
        ("retention", "payload_retained"),
        ("retention", "secrets_retained"),
    }
)


class ReceiptError(ValueError):
    """The receipt is not canonical, metadata-only, or bound to its run."""


def _reject(message: str) -> None:
    raise ReceiptError(message)


def _require(condition: bool, message: str) -> None:
    if not condition:
        _reject(message)


def _field_parts(name: str) -> tuple[str, ...]:
    expanded = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower().replace("-", "_")
    return tuple(part for part in expanded.split("_") if part)


def _reject_sensitive_values(value: Any, label: str = "receipt", path: tuple[str, ...] = ()) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            _require(isinstance(key, str), f"{label} has a non-string field name")
            child_path = (*path, key)
            _require(
                child_path in _SAFE_POLICY_FIELD_PATHS
                or not any(part in _FORBIDDEN_FIELD_PARTS for part in _field_parts(key)),
                f"{label} contains a credential or content-like field",
            )
            _reject_sensitive_values(child, label, child_path)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive_values(child, label, path)
    elif isinstance(value, str):
        _require(
            path == ("network", "observations", "host") and value in APPROVED_HOSTS
            or not _DANGEROUS_VALUE.search(value),
            f"{label} contains a dangerous value",
        )


def _exact_object(value: Any, expected: frozenset[str], label: str) -> Mapping[str, Any]:
    _require(isinstance(value, Mapping), f"{label} must be an object")
    _require(set(value) == expected, f"{label} fields are not exact")
    return value


def _positive_int(value: Any, label: str) -> int:
    _require(isinstance(value, int) and not isinstance(value, bool) and value > 0, f"{label} must be positive")
    return value


def _validate_run_binding(value: Any, expected: Mapping[str, Any]) -> dict[str, object]:
    binding = _exact_object(
        value,
        frozenset({"head_sha", "repository", "run_attempt", "run_id", "workflow_path"}),
        "run binding",
    )
    _require(binding["repository"] == EXPECTED_REPOSITORY, "receipt repository is not floorp-ios")
    _require(binding["workflow_path"] == EXPECTED_WORKFLOW_PATH, "receipt workflow is not canonical")
    _require(isinstance(binding["head_sha"], str) and _SHA40.fullmatch(binding["head_sha"]) is not None, "receipt head SHA is invalid")
    _positive_int(binding["run_id"], "receipt run ID")
    _positive_int(binding["run_attempt"], "receipt run attempt")
    _require(dict(binding) == dict(expected), "receipt is not bound to the expected workflow run")
    return dict(binding)


def _validate_matrix(value: Any) -> None:
    matrix = _exact_object(value, frozenset({"client_slots", "fixture_digest", "status"}), "matrix")
    _require(matrix["client_slots"] == ["client-a", "client-b"], "receipt client slots are not the exact opaque pair")
    _require(isinstance(matrix["fixture_digest"], str) and _SHA64.fullmatch(matrix["fixture_digest"]) is not None, "fixture digest is invalid")
    _require(matrix["status"] == "passed", "matrix did not pass")


def _validate_outcomes(value: Any) -> None:
    outcomes = _exact_object(
        value,
        frozenset(
            {
                "base_advanced",
                "desktop_cleanup_verified",
                "ios_cleanup_verified",
                "local_only_fallback_verified",
                "remote_cleanup_verified",
                "rollback_verified",
            }
        ),
        "outcomes",
    )
    _require(all(item is True for item in outcomes.values()), "receipt lacks a required rollback, fallback, or cleanup outcome")


def _validate_network(value: Any) -> None:
    network = _exact_object(value, frozenset({"metadata_only", "observations", "tls_interception"}), "network")
    _require(network["metadata_only"] is True, "network evidence is not metadata-only")
    _require(network["tls_interception"] is False, "TLS interception is forbidden")
    observations = network["observations"]
    _require(isinstance(observations, list) and observations, "network observations are required")
    seen_hosts: set[str] = set()
    for event in observations:
        event = _exact_object(event, frozenset({"host", "outcome", "port", "tls_verified"}), "network observation")
        host = event["host"]
        _require(isinstance(host, str) and host in APPROVED_HOSTS, "network host is not approved")
        _require(host not in seen_hosts, "network hosts must not be duplicated")
        seen_hosts.add(host)
        _require(event["port"] == 443, "network port must be 443")
        _require(event["tls_verified"] is True, "network TLS must be verified")
        _require(event["outcome"] == "succeeded", "network outcome is not canonical")
    _require(REQUIRED_SYNC_HOST in seen_hosts, "network evidence lacks required Sync host")


def validate_receipt(receipt: Any, *, expected_run_binding: Mapping[str, Any]) -> dict[str, object]:
    """Validate a pre-retrieved canonical receipt without authorizing G5."""

    _reject_sensitive_values(receipt)
    root = _exact_object(
        receipt,
        frozenset({"matrix", "network", "outcomes", "retention", "run_binding", "schema_version"}),
        "G5 receipt",
    )
    _require(root["schema_version"] == 1, "receipt schema is unsupported")
    binding = _validate_run_binding(root["run_binding"], expected_run_binding)
    _validate_matrix(root["matrix"])
    _validate_outcomes(root["outcomes"])
    _validate_network(root["network"])
    retention = _exact_object(root["retention"], frozenset({"payload_retained", "secrets_retained"}), "retention")
    _require(retention == {"payload_retained": False, "secrets_retained": False}, "receipt retains payloads or secrets")
    return {
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
        "run_binding": binding,
        "status": "receipt-valid",
    }


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _reject("receipt contains a duplicate JSON field")
        result[key] = value
    return result


def parse_and_validate_receipt(payload: str, *, expected_run_binding: Mapping[str, Any]) -> dict[str, object]:
    """Parse strict JSON then apply :func:`validate_receipt`."""

    _require(isinstance(payload, str), "receipt payload must be JSON text")
    try:
        receipt = json.loads(payload, object_pairs_hook=_reject_duplicate_keys)
    except (json.JSONDecodeError, TypeError) as error:
        raise ReceiptError("receipt payload is not valid JSON") from error
    return validate_receipt(receipt, expected_run_binding=expected_run_binding)
