"""Fail-closed static admission checks for future G5 evidence collection.

This module does not launch clients, receive credentials, invoke a runner, or
emit G5 evidence. It only validates an explicit non-executing contract.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RELEASE_VALIDATOR_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "validate-floorp-notes-sync-release.py"
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
FORBIDDEN_FIELD_PARTS = frozenset(
    {
        "authorization",
        "cookie",
        "credential",
        "key",
        "password",
        "payload",
        "secret",
        "session",
        "token",
    }
)


def load_release_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_release_validator_for_g5_admission",
        RELEASE_VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the repository release-evidence validator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RELEASE_VALIDATOR = load_release_validator()
IOS_REPOSITORY = RELEASE_VALIDATOR.EXPECTED_REPOSITORY
G5_TEST = RELEASE_VALIDATOR.G5_ACTUAL_TWO_CLIENT_XCRESULT_TEST
CI_WORKFLOW_PATH = RELEASE_VALIDATOR.G5_CI_WORKFLOW_PATH
G5_CI_EVENT = RELEASE_VALIDATOR.G5_CI_EVENT
G5_CI_HEAD_BRANCH = RELEASE_VALIDATOR.G5_CI_HEAD_BRANCH
G5_ARTIFACT_NAME = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_NAME
G5_ARTIFACT_KIND = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_KIND
G5_REQUIRED_SYNC_HOST = RELEASE_VALIDATOR.G5_REQUIRED_SYNC_HOST
FXA_HOSTS = frozenset(RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS)
SYNC_HOSTS = frozenset(RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS)


class AdmissionError(ValueError):
    """The contract is insufficient or unsafe for future G5 collection."""


def reject(message: str) -> None:
    raise AdmissionError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        reject(message)


def normalized_field_parts(name: str) -> tuple[str, ...]:
    expanded = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower().replace("-", "_")
    return tuple(part for part in expanded.split("_") if part)


def reject_sensitive_fields(
    value: Any,
    label: str,
    *,
    allowed_paths: frozenset[tuple[str, ...]],
    path: tuple[str, ...] = (),
) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            require(isinstance(key, str), f"{label} contains a non-string field")
            parts = normalized_field_parts(key)
            child_path = (*path, key)
            require(
                child_path in allowed_paths
                or not any(part in FORBIDDEN_FIELD_PARTS for part in parts),
                f"{label} contains a forbidden secret/content field",
            )
            reject_sensitive_fields(
                child,
                label,
                allowed_paths=allowed_paths,
                path=child_path,
            )
    elif isinstance(value, list):
        for child in value:
            reject_sensitive_fields(
                child,
                label,
                allowed_paths=allowed_paths,
                path=path,
            )


def require_exact_keys(value: Any, keys: frozenset[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(value) == keys, f"{label} fields are not exact")
    return value


def validate_admission_contract(contract: Any) -> dict[str, str]:
    root = require_exact_keys(
        contract,
        frozenset(
            {
                "artifact_contract",
                "boundary",
                "candidate",
                "isolation_contract",
                "network_contract",
                "schema_version",
                "workflow",
            }
        ),
        "G5 admission contract",
    )
    require(root["schema_version"] == 1, "G5 admission contract schema is unsupported")

    candidate = require_exact_keys(
        root["candidate"],
        frozenset({"head_sha", "repository"}),
        "candidate",
    )
    require(candidate["repository"] == IOS_REPOSITORY, "candidate repository is not floorp-ios")
    require(
        isinstance(candidate["head_sha"], str) and re.fullmatch(r"[0-9a-f]{40}", candidate["head_sha"]),
        "candidate head SHA is invalid",
    )

    workflow = require_exact_keys(
        root["workflow"],
        frozenset({"event", "head_branch", "path"}),
        "workflow",
    )
    require(
        workflow
        == {
            "event": G5_CI_EVENT,
            "head_branch": G5_CI_HEAD_BRANCH,
            "path": CI_WORKFLOW_PATH,
        },
        "workflow is not an explicit main dispatch",
    )

    artifact = require_exact_keys(
        root["artifact_contract"],
        frozenset({"artifact_kind", "artifact_name", "required_test", "retrieval"}),
        "artifact contract",
    )
    require(artifact["artifact_kind"] == G5_ARTIFACT_KIND, "artifact kind is not GitHub Actions")
    require(artifact["artifact_name"] == G5_ARTIFACT_NAME, "artifact name is not canonical")
    require(artifact["required_test"] == G5_TEST, "artifact test is not the G5 matrix test")
    require(artifact["retrieval"] == "required-after-run", "artifact retrieval may not be omitted")

    boundary = require_exact_keys(
        root["boundary"],
        frozenset(
            {
                "credential_delivery",
                "execution_authorization",
                "g5_result",
                "runner_receipts_accepted",
            }
        ),
        "boundary",
    )
    require(boundary["credential_delivery"] == "protected-environment-only", "credential boundary is not protected-environment-only")
    require(boundary["execution_authorization"] == "not-authorized", "admission boundary must not authorize execution")
    require(boundary["g5_result"] == "not-assessed", "admission boundary must not claim G5")
    require(boundary["runner_receipts_accepted"] is False, "arbitrary runner receipts are forbidden")

    isolation = require_exact_keys(
        root["isolation_contract"],
        frozenset(
            {
                "accounts",
                "cleanup_required",
                "local_only_fallback_required",
                "payload_retained",
                "rollback_required",
                "secrets_retained",
            }
        ),
        "isolation contract",
    )
    require(
        isolation
        == {
            "accounts": 2,
            "cleanup_required": True,
            "local_only_fallback_required": True,
            "payload_retained": False,
            "rollback_required": True,
            "secrets_retained": False,
        },
        "isolation contract lacks cleanup, rollback, or retention guarantees",
    )

    network = require_exact_keys(
        root["network_contract"],
        frozenset(
            {
                "hosts",
                "metadata_only",
                "payload_retained",
                "port",
                "secrets_retained",
                "tls_interception",
                "tls_verified",
            }
        ),
        "network contract",
    )
    hosts = network["hosts"]
    require(
        isinstance(hosts, list)
        and all(isinstance(host, str) for host in hosts)
        and len(hosts) == len(set(hosts))
        and bool(hosts)
        and set(hosts) <= FXA_HOSTS | SYNC_HOSTS
        and G5_REQUIRED_SYNC_HOST in hosts,
        "network hosts are not an approved policy with Sync proof",
    )
    require(
        network
        == {
            "hosts": hosts,
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        },
        "network contract lacks metadata-only TLS guarantees",
    )
    reject_sensitive_fields(
        root,
        "G5 admission contract",
        allowed_paths=frozenset(
            {
                ("boundary", "credential_delivery"),
                ("boundary", "execution_authorization"),
                ("isolation_contract", "payload_retained"),
                ("isolation_contract", "secrets_retained"),
                ("network_contract", "payload_retained"),
                ("network_contract", "secrets_retained"),
            }
        ),
    )

    return {
        "artifact_retrieval": "required-after-run",
        "cleanup_boundary": "not-established",
        "execution_authorization": "not-authorized",
        "g5_result": "not-assessed",
        "status": "admission-contract-valid",
    }
