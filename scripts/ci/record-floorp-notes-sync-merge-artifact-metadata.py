#!/usr/bin/python3 -I
"""Record the protected upload-artifact identity without runner secrets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
HEAD_BRANCH = "agent/floorp-plan-t20-live-executor"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class ArtifactMetadataError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--artifact-id", type=int, required=True)
    parser.add_argument("--artifact-digest", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        if args.run_id <= 0 or args.artifact_id <= 0:
            raise ArtifactMetadataError("artifact or workflow run ID is invalid")
        if not SHA256.fullmatch(args.artifact_digest):
            raise ArtifactMetadataError("artifact digest is invalid")
        if not SHA1.fullmatch(args.head_sha):
            raise ArtifactMetadataError("workflow head SHA is invalid")
        value = {
            "artifact_digest": args.artifact_digest,
            "artifact_id": args.artifact_id,
            "artifact_name": f"floorp-notes-sync-guarded-merge-{args.run_id}",
            "conclusion": "success",
            "event": "workflow_dispatch",
            "head_branch": HEAD_BRANCH,
            "head_sha": args.head_sha,
            "repository": REPOSITORY,
            "run_id": args.run_id,
            "schema_version": 1,
            "status": "completed",
            "workflow_path": WORKFLOW_PATH,
        }
        raw = canonical(value)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
    except (OSError, ArtifactMetadataError) as error:
        print(f"[blocked] AUTHORIZATION_MISSING owner=Operations reason=merge_artifact_metadata_invalid_{error}", file=sys.stderr)
        return 78
    print('{"status":"merge-artifact-metadata-recorded"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
