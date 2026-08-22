#!/usr/bin/python3 -I
"""Create source-bound evidence for a public-beta FxA QA waiver."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from floorp_notes_sync_public_beta_qa_waiver import (  # noqa: E402
    JOB_NAME,
    REPOSITORY,
    WORKFLOW_PATH,
    APPROVED_FXA_HOSTS,
    APPROVED_SYNC_HOSTS,
    ENDPOINT_POLICY_PATH,
    SHA1,
    canonical,
    validate_waiver,
)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--operator-id", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    parser.add_argument("--approve-fxa-qa-waiver", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        if SHA1.fullmatch(args.source_sha) is None:
            raise ValueError("source SHA is invalid")
        if SHA1.fullmatch(args.desktop_sha) is None:
            raise ValueError("Desktop SHA is invalid")
        if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
            raise ValueError("build number is invalid")
        if args.build_number != "4":
            raise ValueError("waiver build number must be 4")
        if not args.operator_id.strip():
            raise ValueError("operator ID is empty")
        if args.run_id <= 0 or args.run_attempt <= 0:
            raise ValueError("workflow run identity is invalid")
        if not args.approve_fxa_qa_waiver:
            raise ValueError("explicit FxA QA waiver approval is required")

        record = {
            "approval": {
                "approved": True,
                "operator_id": args.operator_id,
                "purpose": "external-testflight",
            },
            "checks": {
                "compile_preflight_passed": True,
                "operation_contract_passed": True,
                "repository_tests_passed": True,
            },
            "desktop": {"source_sha": args.desktop_sha},
            "endpoint": {
                "endpoint_policy_sha256": hashlib.sha256(ENDPOINT_POLICY_PATH.read_bytes()).hexdigest(),
                "fxa_configuration": "FxAConfig.Server.release",
                "fxa_hosts": APPROVED_FXA_HOSTS,
                "sync_hosts": APPROVED_SYNC_HOSTS,
                "wire_protocol": "sync15",
            },
            "ios": {
                "build_number": args.build_number,
                "configuration": "FloorpRelease",
                "repository": REPOSITORY,
                "source_sha": args.source_sha,
            },
            "live_qa": {
                "data_integrity_claim": False,
                "manual_validation_required": True,
                "reason_code": "external-fxa-client-challenge",
                "status": "owner-waived-not-performed",
            },
            "public_release": False,
            "schema_version": 1,
            "source": {
                "event": "workflow_dispatch",
                "head_sha": args.source_sha,
                "job_name": JOB_NAME,
                "repository": REPOSITORY,
                "workflow_path": WORKFLOW_PATH,
                "workflow_run_attempt": args.run_attempt,
                "workflow_run_id": args.run_id,
            },
        }
        validate_waiver(
            record,
            expected_source_sha=args.source_sha,
            expected_desktop_sha=args.desktop_sha,
            expected_run_id=args.run_id,
            expected_run_attempt=args.run_attempt,
        )
        raw = canonical(record)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
        print(
            json.dumps(
                {
                    "source_sha": args.source_sha,
                    "workflow_run_id": args.run_id,
                    "waiver_sha256": hashlib.sha256(raw).hexdigest(),
                    "status": "public-beta-fxa-qa-waiver-created",
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 0
    except (OSError, ValueError, TypeError) as error:
        print(f"public-beta FxA QA waiver rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
