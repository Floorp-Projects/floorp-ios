#!/usr/bin/python3 -I
"""Record the single-operator Todo 20 approval in an append-only JSONL file."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
JOB = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--cleanup-receipt", type=Path, required=True)
    parser.add_argument("--secret-scan", type=Path, required=True)
    return parser.parse_args(arguments)


def read_evidence(path: Path) -> bytes:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=evidence_unavailable_{path.name}") from error
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations reason=evidence_not_regular_{path.name}")
    return raw


def digest(path: Path) -> str:
    return hashlib.sha256(read_evidence(path)).hexdigest()


def context() -> dict[str, Any]:
    required = (
        "GITHUB_ACTOR", "GITHUB_EVENT_NAME", "GITHUB_JOB", "GITHUB_REF",
        "GITHUB_REPOSITORY", "GITHUB_RUN_ATTEMPT", "GITHUB_RUN_ID", "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    if any(not os.environ.get(name) for name in required):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=self_attestation_context_missing")
    if (
        os.environ["GITHUB_EVENT_NAME"] != "workflow_dispatch"
        or os.environ["GITHUB_JOB"] != JOB
        or os.environ["GITHUB_REF"] != "refs/heads/main"
        or os.environ["GITHUB_REPOSITORY"] != REPOSITORY
        or not os.environ["GITHUB_WORKFLOW_REF"].startswith(f"{REPOSITORY}/{WORKFLOW_PATH}@")
    ):
        raise RuntimeError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=self_attestation_workflow_invalid")
    return {
        "actor": os.environ["GITHUB_ACTOR"],
        "head_sha": os.environ["GITHUB_SHA"],
        "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
    }


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        source = context()
        manifest_sha256 = digest(args.manifest)
        summary_sha256 = digest(args.summary)
        cleanup_sha256 = digest(args.cleanup_receipt)
        secret_scan_sha256 = digest(args.secret_scan)
        event = {
            "accounts": 2,
            "cleanup": {
                "accounts": True,
                "coordination_root": True,
                "local_cache": True,
                "runner_temp": True,
                "simulator_keychain": True,
            },
            "environment": ENVIRONMENT,
            "event": "self-attestation",
            "evidence_manifest_sha256": manifest_sha256,
            "head_sha": source["head_sha"],
            "operator_id": source["actor"],
            "previous_event_sha256": "0" * 64,
            "public_release": False,
            "cleanup_receipt_sha256": cleanup_sha256,
            "qa_summary_sha256": summary_sha256,
            "roles": ["owner", "operations", "executor"],
            "schema_version": 1,
            "secret_scan_sha256": secret_scan_sha256,
            "secret_scan_scope": "pre-attestation",
            "sequence": 1,
            "workflow_job": JOB,
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": source["run_attempt"],
            "workflow_run_id": source["run_id"],
        }
        record = {**event, "event_sha256": hashlib.sha256(canonical(event)).hexdigest()}
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(canonical(record))
            handle.flush()
            os.fsync(handle.fileno())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 78 if str(error).startswith("[blocked]") else 2
    print('{"status":"self-attestation-ledger-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
