#!/usr/bin/python3 -I
"""Create the protected, non-distributed Todo 20 QA capability record."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_production_qa_capability import (  # noqa: E402
    APPROVED_FXA_HOSTS,
    APPROVED_SYNC_HOSTS,
    CASE_NAMES,
    CAPABILITY_VERSION,
    ENVIRONMENT,
    INVARIANT_NAMES,
    JOB_NAME,
    PUBLIC_BETA_JOB_NAME,
    PUBLIC_BETA_WORKFLOW_PATH,
    REPOSITORY,
    WORKFLOW_PATH,
    canonical_bytes,
    sha256_bytes,
    sha256_file,
    validate_capability,
)


SHA1 = re.compile(r"[0-9a-f]{40}\Z")


class CapabilityCreationError(RuntimeError):
    pass


def required_environment() -> dict[str, str]:
    names = (
        "GITHUB_ACTOR", "GITHUB_EVENT_NAME", "GITHUB_JOB", "GITHUB_REF",
        "GITHUB_REPOSITORY", "GITHUB_RUN_ATTEMPT", "GITHUB_RUN_ID", "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    values = {name: os.environ.get(name, "") for name in names}
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise CapabilityCreationError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=execution_context_missing resume=run in the protected workflow")
    if values["GITHUB_EVENT_NAME"] != "workflow_dispatch" or values["GITHUB_REF"] != "refs/heads/main":
        raise CapabilityCreationError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=workflow_binding_invalid resume=dispatch the protected job from main")
    expected_workflow_path = {
        JOB_NAME: WORKFLOW_PATH,
        PUBLIC_BETA_JOB_NAME: PUBLIC_BETA_WORKFLOW_PATH,
    }.get(values["GITHUB_JOB"])
    if (
        values["GITHUB_REPOSITORY"] != REPOSITORY
        or expected_workflow_path is None
        or not values["GITHUB_WORKFLOW_REF"].startswith(f"{REPOSITORY}/{expected_workflow_path}@")
    ):
        raise CapabilityCreationError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=workflow_binding_invalid resume=bind the record to the canonical ci workflow")
    if SHA1.fullmatch(values["GITHUB_SHA"]) is None:
        raise CapabilityCreationError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=head_sha_invalid resume=use the immutable workflow head")
    return values


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--endpoint-policy", type=Path, required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--ios-build-number", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        environment = required_environment()
        if SHA1.fullmatch(args.desktop_sha) is None:
            raise CapabilityCreationError("[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=desktop_source_invalid resume=bind the reviewed Desktop SHA")
        contract = json.loads(args.contract.read_text())
        endpoint_policy = json.loads(args.endpoint_policy.read_text())
        endpoints = {row.get("host"): row for row in endpoint_policy.get("endpoints", []) if isinstance(row, dict)}
        expected = {
            **{host: "fxa" for host in APPROVED_FXA_HOSTS},
            **{host: "sync" for host in APPROVED_SYNC_HOSTS},
        }
        for host, service in expected.items():
            row = endpoints.get(host)
            if not isinstance(row, dict) or row.get("status") != "enabled" or row.get("service") != service:
                raise CapabilityCreationError("[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=endpoint_policy_invalid resume=use the approved Mozilla production endpoint matrix")
        contract_digest = sha256_file(args.contract)
        matrix_payload = {
            "cases": CASE_NAMES,
            "invariants": INVARIANT_NAMES,
        }
        matrix_digest = sha256_bytes(canonical_bytes(matrix_payload))
        record = {
            "accounts": 2,
            "build_contract_mode": "production-qa",
            "clients": ["desktop", "mobile"],
            "contract_sha256": contract_digest,
            "desktop": {
                "repository": "Floorp-Projects/Floorp",
                "source_sha": args.desktop_sha,
            },
            "endpoint": {
                "endpoint_policy_sha256": sha256_file(args.endpoint_policy),
                "fxa_configuration": "FxAConfig.Server.release",
                "fxa_hosts": APPROVED_FXA_HOSTS,
                "sync_hosts": APPROVED_SYNC_HOSTS,
                "wire_protocol": "sync15",
            },
            "integrity_matrix_sha256": matrix_digest,
            "ios_build_number": args.ios_build_number,
            "public_release": False,
            "schema_version": 1,
            "self_attestation": {
                "approved": True,
                "environment": ENVIRONMENT,
                "operator_id": environment["GITHUB_ACTOR"],
                "roles": ["owner", "operations", "executor"],
            },
            "source": {
                "event": environment["GITHUB_EVENT_NAME"],
                "head_sha": environment["GITHUB_SHA"],
                "job_name": environment["GITHUB_JOB"] or JOB_NAME,
                "repository": environment["GITHUB_REPOSITORY"],
                "workflow_path": {
                    JOB_NAME: WORKFLOW_PATH,
                    PUBLIC_BETA_JOB_NAME: PUBLIC_BETA_WORKFLOW_PATH,
                }[environment["GITHUB_JOB"]],
                "workflow_run_attempt": int(environment["GITHUB_RUN_ATTEMPT"]),
                "workflow_run_id": int(environment["GITHUB_RUN_ID"]),
            },
            "todo20_contract_version": CAPABILITY_VERSION,
        }
        validate_capability(
            record,
            expected_source_sha=environment["GITHUB_SHA"],
            expected_desktop_sha=args.desktop_sha,
            expected_contract_sha=contract_digest,
            expected_endpoint_policy_sha=sha256_file(args.endpoint_policy),
        )
        destination = args.output.resolve(strict=False)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with destination.open("xb") as handle:
            handle.write(canonical_bytes(record))
            handle.flush()
            os.fsync(handle.fileno())
    except (OSError, ValueError, json.JSONDecodeError, CapabilityCreationError) as error:
        print(str(error), file=sys.stderr)
        return 78 if isinstance(error, CapabilityCreationError) and str(error).startswith("[blocked]") else 2
    print('{"status":"production-qa-capability-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
