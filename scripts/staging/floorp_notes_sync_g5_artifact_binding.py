"""Fail-closed, offline binding of G5 receipt metadata to artifact metadata.

This module intentionally accepts only caller-supplied JSON-domain objects.  It
does not retrieve artifacts, access credentials, authorize G5, or perform any
network, browser, Xcode, FxA, or Sync operation.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

from scripts.staging.floorp_notes_sync_g5_receipt import (
    EXPECTED_REPOSITORY,
    EXPECTED_WORKFLOW_PATH,
)


_SHA40 = re.compile(r"[0-9a-f]{40}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_MAX_SAFE_INTEGER = 9_007_199_254_740_991
_ARTIFACT_NAME = "floorp-notes-sync-two-client-xcresult"
_RUN_BINDING_FIELDS = frozenset(
    {"head_sha", "repository", "run_attempt", "run_id", "workflow_path"}
)
_RECEIPT_METADATA_FIELDS = frozenset(
    {"execution_authorization", "g5_result", "run_binding", "status"}
)
_SNAPSHOT_FIELDS = frozenset(
    {
        "artifact_id",
        "artifact_name",
        "artifact_run_id",
        "artifact_zip_sha256",
        "head_sha",
        "receipt_member_sha256",
        "repository",
        "run_attempt",
        "run_id",
        "workflow_path",
    }
)


class ArtifactBindingError(ValueError):
    """Receipt metadata or artifact snapshot is not exactly bound."""


def _reject(message: str) -> None:
    raise ArtifactBindingError(message)


def _require(condition: bool, message: str) -> None:
    if not condition:
        _reject(message)


def _exact_plain_object(value: Any, fields: frozenset[str], label: str) -> dict[str, Any]:
    _require(type(value) is dict, f"{label} must be a plain JSON object")
    _require(all(type(key) is str for key in value), f"{label} has a non-string field")
    _require(set(value) == fields, f"{label} fields are not exact")
    return value


def _positive_safe_int(value: Any, label: str) -> int:
    _require(
        type(value) is int and 0 < value <= _MAX_SAFE_INTEGER,
        f"{label} must be a positive safe integer",
    )
    return value


def _plain_sha(value: Any, length: int, label: str) -> str:
    pattern = _SHA40 if length == 40 else _SHA256
    _require(type(value) is str and pattern.fullmatch(value) is not None, f"{label} is invalid")
    return value


def _canonical_run_binding(value: Any, label: str) -> dict[str, object]:
    binding = _exact_plain_object(value, _RUN_BINDING_FIELDS, label)
    repository = binding["repository"]
    workflow_path = binding["workflow_path"]
    _require(
        type(repository) is str and repository == EXPECTED_REPOSITORY,
        f"{label} repository is not floorp-ios",
    )
    _require(
        type(workflow_path) is str and workflow_path == EXPECTED_WORKFLOW_PATH,
        f"{label} workflow is not canonical",
    )
    return {
        "head_sha": _plain_sha(binding["head_sha"], 40, f"{label} head SHA"),
        "repository": repository,
        "run_attempt": _positive_safe_int(binding["run_attempt"], f"{label} run attempt"),
        "run_id": _positive_safe_int(binding["run_id"], f"{label} run ID"),
        "workflow_path": workflow_path,
    }


def _run_binding_from_snapshot(snapshot: dict[str, Any]) -> dict[str, object]:
    return _canonical_run_binding(
        {field: snapshot[field] for field in _RUN_BINDING_FIELDS},
        "artifact provenance run binding",
    )


def _require_same_run(left: dict[str, object], right: dict[str, object], label: str) -> None:
    for field in _RUN_BINDING_FIELDS:
        _require(left[field] == right[field], f"{label} {field} does not match")


def _validate_receipt_metadata(value: Any, expected_run_binding: Any) -> dict[str, object]:
    metadata = _exact_plain_object(value, _RECEIPT_METADATA_FIELDS, "receipt metadata")
    _require(
        type(metadata["status"]) is str and metadata["status"] == "receipt-valid",
        "receipt metadata status is not receipt-valid",
    )
    _require(
        type(metadata["execution_authorization"]) is str
        and metadata["execution_authorization"] == "not-granted",
        "receipt metadata authorizes execution",
    )
    _require(
        type(metadata["g5_result"]) is str and metadata["g5_result"] == "not-assessed",
        "receipt metadata claims a G5 result",
    )
    receipt_binding = _canonical_run_binding(metadata["run_binding"], "receipt run binding")
    expected_binding = _canonical_run_binding(expected_run_binding, "expected run binding")
    _require_same_run(receipt_binding, expected_binding, "receipt run binding")
    return receipt_binding


def _validate_snapshot(value: Any, run_binding: dict[str, object]) -> dict[str, object]:
    snapshot = _exact_plain_object(value, _SNAPSHOT_FIELDS, "artifact provenance snapshot")
    _require(
        type(snapshot["artifact_name"]) is str and snapshot["artifact_name"] == _ARTIFACT_NAME,
        "artifact name is not canonical",
    )
    _positive_safe_int(snapshot["artifact_id"], "artifact ID")
    _positive_safe_int(snapshot["artifact_run_id"], "artifact run ID")
    snapshot_binding = _run_binding_from_snapshot(snapshot)
    _require_same_run(snapshot_binding, run_binding, "artifact provenance snapshot")
    _require(
        snapshot["artifact_run_id"] == snapshot_binding["run_id"],
        "artifact run ID does not match its run binding",
    )
    return {
        "artifact_id": _positive_safe_int(snapshot["artifact_id"], "artifact ID"),
        "artifact_name": snapshot["artifact_name"],
        "artifact_run_id": snapshot["artifact_run_id"],
        "artifact_zip_sha256": _plain_sha(
            snapshot["artifact_zip_sha256"], 64, "artifact ZIP SHA-256"
        ),
        "receipt_member_sha256": _plain_sha(
            snapshot["receipt_member_sha256"], 64, "receipt member SHA-256"
        ),
    }


def _require_same_artifact(
    snapshot: dict[str, object], expected_snapshot: dict[str, object]
) -> None:
    for field in snapshot:
        _require(snapshot[field] == expected_snapshot[field], f"artifact provenance {field} does not match")


def validate_artifact_provenance_binding(
    receipt_metadata: Any,
    artifact_provenance_snapshot: Any,
    *,
    expected_artifact_binding: Mapping[str, Any],
) -> dict[str, object]:
    """Validate metadata-only artifact binding without authorizing or running G5."""

    expected_snapshot = _validate_snapshot(
        expected_artifact_binding,
        _run_binding_from_snapshot(
            _exact_plain_object(
                expected_artifact_binding, _SNAPSHOT_FIELDS, "expected artifact binding"
            )
        ),
    )
    expected_binding = _run_binding_from_snapshot(
        _exact_plain_object(expected_artifact_binding, _SNAPSHOT_FIELDS, "expected artifact binding")
    )
    receipt_binding = _validate_receipt_metadata(receipt_metadata, expected_binding)
    artifact = _validate_snapshot(artifact_provenance_snapshot, receipt_binding)
    _require_same_artifact(artifact, expected_snapshot)
    return {
        "artifact_provenance": "binding-valid",
        "artifact": artifact,
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
        "run_binding": receipt_binding,
        "status": "artifact-binding-valid",
    }
