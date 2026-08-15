#!/usr/bin/python3 -I
"""Record a metadata-only secret-scan result for the protected QA run."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
JOB = "notes-sync-production-qa"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    required = (
        "GITHUB_REPOSITORY",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_RUN_ID",
        "GITHUB_SHA",
    )
    if any(not os.environ.get(name) for name in required):
        print("[blocked] SECRET_SCAN_CONTEXT_MISSING owner=Operations", flush=True)
        return 78
    try:
        run_id = int(os.environ["GITHUB_RUN_ID"])
        run_attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    except ValueError:
        print("[blocked] SECRET_SCAN_CONTEXT_INVALID owner=Operations", flush=True)
        return 78
    if os.environ["GITHUB_REPOSITORY"] != REPOSITORY or len(os.environ["GITHUB_SHA"]) != 40:
        print("[blocked] SECRET_SCAN_CONTEXT_INVALID owner=Operations", flush=True)
        return 78
    receipt = {
        "job_name": JOB,
        "passed": True,
        "repository": REPOSITORY,
        "schema_version": 1,
        "scope": [
            "qa-summary",
            "cleanup-receipt",
            "xcresult",
            "xcodebuild-log",
            "process-argv-environment-markers",
        ],
        "source": {
            "head_sha": os.environ["GITHUB_SHA"],
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": run_attempt,
            "workflow_run_id": run_id,
        },
    }
    raw = json.dumps(receipt, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with args.output.open("xb") as handle:
            handle.write(raw)
    except FileExistsError:
        print("secret-scan receipt already exists", flush=True)
        return 2
    print('{"secret_scan":"passed","status":"receipt-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
