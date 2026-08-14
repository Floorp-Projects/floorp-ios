#!/usr/bin/python3 -I
"""Validate static prerequisites for a future external Notes Sync G5 driver.

This utility reads exactly one checked-in public JSON contract. It never
receives credentials, schedules a runner, invokes a driver, launches a client,
contacts a service, or produces G5 evidence. It records only requirements that
must be independently admitted before a separate actual-run implementation is
allowed to replace the fail-closed XCTest skip.
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
CONTRACT_RELATIVE_PATH = Path("scripts/ci/floorp-notes-sync-g5-external-driver-admission-contract.json")
MAX_CONTRACT_BYTES = 64 * 1024
DISPATCH_INPUT = "prepare_floorp_notes_sync_g5_contract"
ENVIRONMENT = "floorp-notes-sync-production-qa"
RUNNER_LABELS = ["self-hosted", "macOS", "floorp-notes-sync-g5"]


class ExternalDriverPrerequisitesContractError(ValueError):
    """The static external-driver prerequisites are malformed or unsafe."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ExternalDriverPrerequisitesContractError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ExternalDriverPrerequisitesContractError(
                "external-driver prerequisites contract contains a duplicate JSON member"
            )
        result[key] = value
    return result


def reject_nonfinite_number(_: str) -> Any:
    raise ExternalDriverPrerequisitesContractError(
        "external-driver prerequisites contract contains a non-finite JSON number"
    )


def reject_float(_: str) -> Any:
    raise ExternalDriverPrerequisitesContractError(
        "external-driver prerequisites contract contains a floating-point JSON number"
    )


def parse_contract_bytes(raw: bytes) -> dict[str, Any]:
    require(bool(raw), "external-driver prerequisites contract is empty")
    require(
        len(raw) <= MAX_CONTRACT_BYTES,
        "external-driver prerequisites contract exceeds the size limit",
    )
    try:
        parsed = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite_number,
            parse_float=reject_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ExternalDriverPrerequisitesContractError(
            "external-driver prerequisites contract is not valid UTF-8 JSON"
        ) from error
    require(type(parsed) is dict, "external-driver prerequisites contract root must be an object")
    canonical = json.dumps(
        parsed,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    require(raw == canonical, "external-driver prerequisites contract is not canonical JSON")
    return parsed


def require_exact_literal(value: Any, expected: Any, label: str) -> None:
    if type(expected) is dict:
        require(type(value) is dict, f"{label} must be an object")
        require(set(value) == set(expected), f"{label} fields are not exact")
        for key, expected_child in expected.items():
            require_exact_literal(value[key], expected_child, f"{label}.{key}")
        return
    if type(expected) is list:
        require(type(value) is list, f"{label} must be an array")
        require(len(value) == len(expected), f"{label} length is not exact")
        for index, expected_child in enumerate(expected):
            require_exact_literal(value[index], expected_child, f"{label}[{index}]")
        return
    require(type(value) is type(expected) and value == expected, f"{label} is not exact")


def load_release_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_release_validator_for_external_driver_prerequisites",
        RELEASE_VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise ExternalDriverPrerequisitesContractError(
            "cannot load the repository release-evidence validator"
        )
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


RELEASE_VALIDATOR = load_release_validator()
G5_WORKFLOW_PATH = RELEASE_VALIDATOR.G5_CI_WORKFLOW_PATH
G5_EVENT = RELEASE_VALIDATOR.G5_CI_EVENT
G5_HEAD_BRANCH = RELEASE_VALIDATOR.G5_CI_HEAD_BRANCH
G5_ARTIFACT_KIND = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_KIND
G5_ARTIFACT_NAME = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_NAME
G5_REQUIRED_TEST = RELEASE_VALIDATOR.G5_ACTUAL_TWO_CLIENT_XCRESULT_TEST
G5_REQUIRED_SYNC_HOST = RELEASE_VALIDATOR.G5_REQUIRED_SYNC_HOST
APPROVED_HOSTS = sorted(
    frozenset(RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS)
    | frozenset(RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS)
)


def validate_contract(contract: Any) -> dict[str, str]:
    expected = {
        "attestation": {
            "driver_signature": "required-before-execution",
            "expiry": "required-before-execution",
            "revocation_check": "required-before-execution",
            "same_release_binding": "required-before-execution",
        },
        "boundary": {
            "credential_delivery": "protected-environment-only",
            "execution_authorization": "not-authorized",
            "g5_result": "not-assessed",
            "runner_admission": "not-assessed",
        },
        "driver": {
            "artifact_retrieval": "required-after-run",
            "credential_delivery": "root-owned-broker-required-before-execution",
            "execution": "not-authorized",
            "interface": "metadata-only-g5-receipt-v1",
        },
        "future_g5_artifact": {
            "artifact_kind": G5_ARTIFACT_KIND,
            "artifact_name": G5_ARTIFACT_NAME,
            "required_test": G5_REQUIRED_TEST,
            "retrieval": "required-after-run",
        },
        "isolation_contract": {
            "accounts": 2,
            "cleanup_required": True,
            "local_only_fallback_required": True,
            "payload_retained": False,
            "rollback_required": True,
            "secrets_retained": False,
        },
        "network_contract": {
            "hosts": APPROVED_HOSTS,
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        },
        "participant_contract": {
            "coordinator": "external-driver-only",
            "credential_handling": "external-driver-only",
            "ios_participant": "metadata-only-observer",
            "network_capture": "external-driver-only",
            "payload_observation": "forbidden",
            "test_attachments": "forbidden",
        },
        "runner": {
            "binary_digest": "required-before-execution",
            "ephemeral_lease": "required-before-execution",
            "kind": "dedicated-self-hosted-required-before-execution",
            "labels": RUNNER_LABELS,
            "secret_delivery": "root-owned-broker-required-before-execution",
            "source_checkout": "anonymous-ephemeral",
        },
        "schema_version": 1,
        "workflow": {
            "dispatch_input": DISPATCH_INPUT,
            "environment": ENVIRONMENT,
            "event": G5_EVENT,
            "head_branch": G5_HEAD_BRANCH,
            "path": G5_WORKFLOW_PATH,
        },
    }
    require_exact_literal(contract, expected, "external-driver prerequisites contract")
    require(
        G5_REQUIRED_SYNC_HOST in contract["network_contract"]["hosts"],
        "external-driver prerequisites contract lacks the required Sync host",
    )
    return {
        "credential_delivery": "protected-environment-only",
        "driver_attestation": "not-assessed",
        "driver_execution": "not-authorized",
        "g5_result": "not-assessed",
        "runner_admission": "not-assessed",
        "status": "external-driver-prerequisites-contract-valid",
    }


def checked_in_contract_path(path: Path) -> Path:
    try:
        candidate = path.resolve(strict=True)
    except OSError as error:
        raise ExternalDriverPrerequisitesContractError(
            "external-driver prerequisites contract path is unavailable"
        ) from error
    expected = (REPOSITORY_ROOT / CONTRACT_RELATIVE_PATH).resolve(strict=True)
    require(candidate == expected, "only the checked-in external-driver prerequisites contract may be validated")
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise ExternalDriverPrerequisitesContractError(
            "external-driver prerequisites contract cannot be inspected"
        ) from error
    require(
        stat.S_ISREG(mode) and not path.is_symlink(),
        "external-driver prerequisites contract must be a regular file",
    )
    return candidate


def load_and_validate_contract(path: Path) -> dict[str, str]:
    contract_path = checked_in_contract_path(path)
    try:
        raw = contract_path.read_bytes()
    except OSError as error:
        raise ExternalDriverPrerequisitesContractError(
            "external-driver prerequisites contract cannot be read"
        ) from error
    return validate_contract(parse_contract_bytes(raw))


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--contract",
        type=Path,
        required=True,
        help="the repository's checked-in non-executing external-driver prerequisites contract",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        decision = load_and_validate_contract(args.contract)
    except ExternalDriverPrerequisitesContractError as error:
        print(f"external-driver prerequisites contract rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps(decision, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
