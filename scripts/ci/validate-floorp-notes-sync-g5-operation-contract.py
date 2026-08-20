#!/usr/bin/python3 -I
"""Validate the protected, proportional Todo 20 production-QA contract.

This validator is a static policy boundary. It never accepts credentials,
launches a client, contacts FxA/Sync, reads a local account file, or produces
QA evidence. The actual run is a separate, manually dispatched job bound to a
protected GitHub Environment and two disposable test accounts.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import stat
import sys
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RELEASE_VALIDATOR_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "validate-floorp-notes-sync-release.py"
CONTRACT_RELATIVE_PATH = Path("scripts/ci/floorp-notes-sync-g5-operation-contract.json")
MAX_CONTRACT_BYTES = 64 * 1024

ENVIRONMENT = "floorp-notes-sync-production-qa"
DISPATCH_INPUT = "run_floorp_notes_sync_production_qa"
G5_WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
G5_EVENT = "workflow_dispatch"
G5_HEAD_BRANCH = "main"
QA_ARTIFACT_NAME = "floorp-notes-sync-two-client-xcresult"
QA_ARTIFACT_KIND = "github-actions-artifact"
QA_REQUIRED_TEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"
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


class OperationContractError(ValueError):
    """The static operation contract is malformed or unsafe."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise OperationContractError(message)


def load_release_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_release_validator_for_operation_contract",
        RELEASE_VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise OperationContractError("cannot load the repository release-evidence validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


RELEASE_VALIDATOR = load_release_validator()
APPROVED_HOSTS = frozenset(RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS) | frozenset(
    RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS
)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise OperationContractError("operation contract contains a duplicate JSON member")
        result[key] = value
    return result


def reject_nonfinite_number(_: str) -> Any:
    raise OperationContractError("operation contract contains a non-finite JSON number")


def reject_float(_: str) -> Any:
    raise OperationContractError("operation contract contains a floating-point JSON number")


def parse_contract_bytes(raw: bytes) -> dict[str, Any]:
    require(bool(raw), "operation contract is empty")
    require(len(raw) <= MAX_CONTRACT_BYTES, "operation contract exceeds the size limit")
    try:
        parsed = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite_number,
            parse_float=reject_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OperationContractError("operation contract is not valid UTF-8 JSON") from error
    require(isinstance(parsed, dict), "operation contract root must be an object")
    canonical = json.dumps(
        parsed,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    require(raw == canonical, "operation contract is not canonical JSON")
    return parsed


def require_exact_keys(value: Any, expected: frozenset[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(value) == expected, f"{label} fields are not exact")
    return value


def require_exact_string_list(value: Any, expected: tuple[str, ...], label: str) -> None:
    require(isinstance(value, list), f"{label} must be an array")
    require(value == list(expected), f"{label} is not the canonical ordered list")


def validate_operation_contract(contract: Any) -> dict[str, str]:
    root = require_exact_keys(
        contract,
        frozenset(
            {
                "approval_model",
                "boundary",
                "execution",
                "integrity_matrix",
                "isolation_contract",
                "network_contract",
                "participant_contract",
                "qa_artifact",
                "safety_boundary",
                "schema_version",
                "workflow",
            }
        ),
        "operation contract",
    )
    require(root["schema_version"] == 2, "operation contract schema is unsupported")

    approval = require_exact_keys(
        root["approval_model"],
        frozenset(
            {
                "environment",
                "global_governance_unchanged",
                "independence",
                "native_github_approval",
                "required_approving_review_count",
                "reviews_count",
                "self_attestation",
                "self_review_exception",
            }
        ),
        "approval model",
    )
    require(
        approval
        == {
            "environment": ENVIRONMENT,
            "global_governance_unchanged": True,
            "independence": False,
            "native_github_approval": False,
            "required_approving_review_count": 0,
            "reviews_count": 0,
            "self_attestation": "owner-operations-executor-reviewer",
            "self_review_exception": True,
        },
        "approval model is not the bounded single-operator exception",
    )

    safety = require_exact_keys(
        root["safety_boundary"],
        frozenset(
            {
                "admin_bypass_allowed",
                "local_test_accounts_accessed",
                "native_github_approval",
                "public_release",
                "two_disposable_accounts_only",
            }
        ),
        "safety boundary",
    )
    require(
        safety
        == {
            "admin_bypass_allowed": False,
            "local_test_accounts_accessed": False,
            "native_github_approval": False,
            "public_release": False,
            "two_disposable_accounts_only": True,
        },
        "safety boundary is not fail-closed",
    )

    boundary = require_exact_keys(
        root["boundary"],
        frozenset({"credential_delivery", "execution_authorization", "phase_1_result", "public_release"}),
        "boundary",
    )
    require(
        boundary
        == {
            "credential_delivery": "protected-environment-secrets-only",
            "execution_authorization": "single-operator-protected-qa",
            "phase_1_result": "data-integrity-qa-required",
            "public_release": "forbidden",
        },
        "operation contract does not describe the bounded production QA boundary",
    )

    execution = require_exact_keys(
        root["execution"],
        frozenset({"mode", "phase_2_enablement_requires_phase_1", "runner"}),
        "execution",
    )
    require(
        execution
        == {
            "mode": "production-qa",
            "phase_2_enablement_requires_phase_1": True,
            "runner": "github-hosted-macos",
        },
        "execution contract retains an out-of-scope infrastructure requirement",
    )

    matrix = require_exact_keys(
        root["integrity_matrix"],
        frozenset(
            {
                "accounts",
                "clients",
                "payload_observation",
                "required_cases",
                "required_invariants",
                "result_format",
            }
        ),
        "integrity matrix",
    )
    require(matrix["accounts"] == 2, "integrity matrix must use exactly two test accounts")
    require(matrix["clients"] == ["desktop", "mobile"], "integrity matrix must bind desktop and mobile")
    require_exact_string_list(matrix["required_cases"], REQUIRED_CASES, "integrity matrix cases")
    require_exact_string_list(matrix["required_invariants"], REQUIRED_INVARIANTS, "integrity matrix invariants")
    require(matrix["payload_observation"] == "forbidden", "integrity payload observation must be forbidden")
    require(matrix["result_format"] == "metadata-only", "integrity results must be metadata-only")

    artifact = require_exact_keys(
        root["qa_artifact"],
        frozenset({"artifact_kind", "artifact_name", "required_test", "retrieval"}),
        "QA artifact",
    )
    require(
        artifact
        == {
            "artifact_kind": QA_ARTIFACT_KIND,
            "artifact_name": QA_ARTIFACT_NAME,
            "required_test": QA_REQUIRED_TEST,
            "retrieval": "required-after-run",
        },
        "QA artifact is not canonical",
    )

    isolation = require_exact_keys(
        root["isolation_contract"],
        frozenset(
            {
                "accounts",
                "cleanup_required",
                "keychain_cleanup_required",
                "local_only_fallback_required",
                "payload_retained",
                "rollback_required",
                "runner_temp_cleanup_required",
                "secrets_retained",
                "simulator_cache_cleanup_required",
            }
        ),
        "isolation contract",
    )
    require(
        isolation
        == {
            "accounts": 2,
            "cleanup_required": True,
            "keychain_cleanup_required": True,
            "local_only_fallback_required": True,
            "payload_retained": False,
            "rollback_required": True,
            "runner_temp_cleanup_required": True,
            "secrets_retained": False,
            "simulator_cache_cleanup_required": True,
        },
        "isolation contract lacks cleanup and rollback obligations",
    )

    network = require_exact_keys(
        root["network_contract"],
        frozenset(
            {
                "approved_source",
                "direct_rest_forbidden",
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
        and hosts
        and all(isinstance(host, str) for host in hosts)
        and hosts == sorted(set(hosts))
        and set(hosts) == APPROVED_HOSTS,
        "network contract is not the exact approved production host set",
    )
    require(
        network
        == {
            "approved_source": "docs/floorp-release-endpoints.json",
            "direct_rest_forbidden": True,
            "hosts": hosts,
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        },
        "network contract lacks the approved TLS-only boundary",
    )

    participant = require_exact_keys(
        root["participant_contract"],
        frozenset(
            {
                "coordinator",
                "credential_handling",
                "desktop_mobile_execution",
                "network_capture",
                "payload_observation",
                "test_attachments",
            }
        ),
        "participant contract",
    )
    require(
        participant
        == {
            "coordinator": "single-operator-protected-workflow",
            "credential_handling": "protected-environment-secret-only",
            "desktop_mobile_execution": "existing-client-pair",
            "network_capture": "metadata-only",
            "payload_observation": "forbidden",
            "test_attachments": "forbidden",
        },
        "participant contract permits unsafe credential or payload handling",
    )

    workflow = require_exact_keys(
        root["workflow"],
        frozenset(
            {
                "dispatch_input",
                "enablement_dispatch_input",
                "enablement_job",
                "environment",
                "event",
                "head_branch",
                "path",
            }
        ),
        "workflow",
    )
    require(
        workflow
        == {
            "dispatch_input": DISPATCH_INPUT,
            "enablement_dispatch_input": "run_floorp_notes_sync_production_enablement",
            "enablement_job": "notes-sync-production-enablement",
            "environment": ENVIRONMENT,
            "event": G5_EVENT,
            "head_branch": G5_HEAD_BRANCH,
            "path": G5_WORKFLOW_PATH,
        },
        "operation contract is not bound to the protected main workflow",
    )

    return {
        "credential_delivery": "protected-environment-secrets-only",
        "execution_authorization": "single-operator-protected-qa",
        "phase_1_result": "data-integrity-qa-required",
        "phase_2_enablement": "requires-validator-approve",
        "status": "operation-contract-valid",
    }


def checked_in_contract_path(path: Path) -> Path:
    try:
        candidate = path.resolve(strict=True)
    except OSError as error:
        raise OperationContractError("operation contract path is unavailable") from error
    expected = (REPOSITORY_ROOT / CONTRACT_RELATIVE_PATH).resolve(strict=True)
    require(candidate == expected, "only the checked-in operation contract may be validated")
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise OperationContractError("operation contract cannot be inspected") from error
    require(stat.S_ISREG(mode) and not path.is_symlink(), "operation contract must be a regular file")
    return candidate


def load_and_validate_contract(path: Path) -> dict[str, str]:
    contract_path = checked_in_contract_path(path)
    try:
        raw = contract_path.read_bytes()
    except OSError as error:
        raise OperationContractError("operation contract cannot be read") from error
    return validate_operation_contract(parse_contract_bytes(raw))


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--contract",
        type=Path,
        required=True,
        help="the repository's checked-in protected Todo 20 operation contract",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        decision = load_and_validate_contract(args.contract)
    except OperationContractError as error:
        print(f"operation contract rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps(decision, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
