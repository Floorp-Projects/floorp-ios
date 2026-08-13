#!/usr/bin/python3 -I
"""Validate the checked-in, non-live Notes Sync G5 operation contract.

This utility is deliberately static: it reads one checked-in JSON document and
never accepts credentials, launches a client, contacts a service, or produces
G5 evidence.  A valid result records only that a future operation must still
use the separately protected execution boundary.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import stat
import sys
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RELEASE_VALIDATOR_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "validate-floorp-notes-sync-release.py"
CONTRACT_RELATIVE_PATH = Path("scripts/ci/floorp-notes-sync-g5-operation-contract.json")
MAX_CONTRACT_BYTES = 64 * 1024


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
IOS_REPOSITORY = RELEASE_VALIDATOR.EXPECTED_REPOSITORY
G5_WORKFLOW_PATH = RELEASE_VALIDATOR.G5_CI_WORKFLOW_PATH
G5_EVENT = RELEASE_VALIDATOR.G5_CI_EVENT
G5_HEAD_BRANCH = RELEASE_VALIDATOR.G5_CI_HEAD_BRANCH
G5_ARTIFACT_KIND = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_KIND
G5_ARTIFACT_NAME = RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_NAME
G5_REQUIRED_TEST = RELEASE_VALIDATOR.G5_TWO_CLIENT_XCRESULT_TEST
G5_REQUIRED_SYNC_HOST = RELEASE_VALIDATOR.G5_REQUIRED_SYNC_HOST
APPROVED_HOSTS = frozenset(RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS) | frozenset(
    RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS
)
DISPATCH_INPUT = "prepare_floorp_notes_sync_g5_contract"


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


def validate_operation_contract(contract: Any) -> dict[str, str]:
    root = require_exact_keys(
        contract,
        frozenset(
            {
                "boundary",
                "future_g5_artifact",
                "isolation_contract",
                "network_contract",
                "schema_version",
                "workflow",
            }
        ),
        "operation contract",
    )
    require(root["schema_version"] == 1, "operation contract schema is unsupported")

    workflow = require_exact_keys(
        root["workflow"],
        frozenset({"dispatch_input", "event", "head_branch", "path"}),
        "workflow",
    )
    require(
        workflow
        == {
            "dispatch_input": DISPATCH_INPUT,
            "event": G5_EVENT,
            "head_branch": G5_HEAD_BRANCH,
            "path": G5_WORKFLOW_PATH,
        },
        "operation contract is not bound to the canonical main dispatch",
    )

    artifact = require_exact_keys(
        root["future_g5_artifact"],
        frozenset({"artifact_kind", "artifact_name", "required_test", "retrieval"}),
        "future G5 artifact",
    )
    require(
        artifact
        == {
            "artifact_kind": G5_ARTIFACT_KIND,
            "artifact_name": G5_ARTIFACT_NAME,
            "required_test": G5_REQUIRED_TEST,
            "retrieval": "required-after-run",
        },
        "future G5 artifact is not canonical",
    )

    boundary = require_exact_keys(
        root["boundary"],
        frozenset({"credential_delivery", "execution_authorization", "g5_result"}),
        "boundary",
    )
    require(
        boundary
        == {
            "credential_delivery": "protected-environment-only",
            "execution_authorization": "not-authorized",
            "g5_result": "not-assessed",
        },
        "operation contract must remain non-live and not-authorized",
    )

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
        "isolation contract lacks the required isolation and cleanup obligations",
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
        and bool(hosts)
        and all(isinstance(host, str) for host in hosts)
        and hosts == sorted(set(hosts))
        and set(hosts) <= APPROVED_HOSTS
        and G5_REQUIRED_SYNC_HOST in hosts,
        "network contract is not an approved canonical metadata-only host policy",
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
        "network contract lacks metadata-only TLS and retention guarantees",
    )

    return {
        "credential_delivery": "protected-environment-only",
        "execution_authorization": "not-authorized",
        "g5_result": "not-assessed",
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
        help="the repository's checked-in non-live G5 operation contract",
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
