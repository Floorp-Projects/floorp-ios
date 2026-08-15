#!/usr/bin/python3 -I
"""Fail-closed entry point for the protected Todo 20 QA run.

The existing desktop/mobile clients own the Sync operation and must produce a
metadata-only summary. This entry point only checks that protected secrets are
present in the process environment and validates that summary; it never reads
the local account directory, prints a secret, performs a REST/token request,
or fabricates a passing result.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


REQUIRED_SECRET_ENV = (
    "FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD",
)
VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-production-qa.py")
SHA1 = re.compile(r"[0-9a-f]{40}\Z")


class ProductionQARunError(RuntimeError):
    """The protected execution boundary is unavailable or invalid."""


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_production_qa_validator_for_runner",
        VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise ProductionQARunError("cannot load the metadata-only QA validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


VALIDATOR = load_validator()


def require_protected_secrets() -> None:
    missing = [name for name in REQUIRED_SECRET_ENV if not os.environ.get(name)]
    if missing:
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations "
            "resume=populate all four protected Environment secrets without using the local account directory"
        )


def require_runtime_binding(summary: dict[str, Any]) -> None:
    required_environment = (
        "GITHUB_ACTOR",
        "GITHUB_EVENT_NAME",
        "GITHUB_JOB",
        "GITHUB_REPOSITORY",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_RUN_ID",
        "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    missing = [name for name in required_environment if not os.environ.get(name)]
    if missing:
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=execution_context_missing "
            "resume=run only inside the protected GitHub workflow with its immutable source context"
        )

    source = summary["source"]
    repository = os.environ["GITHUB_REPOSITORY"]
    workflow_ref = os.environ["GITHUB_WORKFLOW_REF"]
    workflow_prefix = f"{repository}/.github/workflows/ci.yml@"
    try:
        run_id = int(os.environ["GITHUB_RUN_ID"])
        run_attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    except ValueError as error:
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=execution_context_invalid "
            "resume=provide numeric GitHub run metadata"
        ) from error
    expected = {
        "event": os.environ["GITHUB_EVENT_NAME"],
        "head_sha": os.environ["GITHUB_SHA"],
        "job_name": os.environ["GITHUB_JOB"],
        "repository": repository,
        "workflow_path": ".github/workflows/ci.yml",
        "workflow_run_attempt": run_attempt,
        "workflow_run_id": run_id,
    }
    if not SHA1.fullmatch(expected["head_sha"]) or not workflow_ref.startswith(workflow_prefix):
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=execution_context_invalid "
            "resume=bind the summary to the exact checked-in workflow and commit"
        )
    if any(source[key] != value for key, value in expected.items()):
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=execution_context_mismatch "
            "resume=regenerate the client-pair summary for this exact workflow run"
        )
    if summary["self_attestation"]["operator_id"] != os.environ["GITHUB_ACTOR"]:
        raise ProductionQARunError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=self_attestation_mismatch "
            "resume=bind the owner/Operations/executor attestation to the dispatch actor"
        )


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        require_protected_secrets()
        if not args.summary.is_file() or args.summary.is_symlink():
            raise ProductionQARunError(
                "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=client_pair_summary "
                "resume=run the existing desktop/mobile clients and emit the required metadata-only summary"
            )
        summary = VALIDATOR.load_and_validate(args.summary)
        require_runtime_binding(summary)
        summary_sha256 = hashlib.sha256(args.summary.read_bytes()).hexdigest()
    except ProductionQARunError as error:
        print(str(error), file=sys.stderr)
        return 78
    print(
        json.dumps(
            {
                "cases": len(summary["cases"]),
                "cleanup": "verified",
                "phase": "production-qa",
                "summary_sha256": summary_sha256,
                "status": "client-pair-summary-accepted",
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
