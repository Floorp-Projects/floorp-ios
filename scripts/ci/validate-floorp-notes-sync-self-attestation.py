#!/usr/bin/python3 -I
"""Validate the append-only Todo 20 single-operator attestation record."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
JOB = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class AttestationError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AttestationError("attestation contains a duplicate JSON member")
        result[key] = value
    return result


def load(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise AttestationError("attestation ledger must contain one newline-terminated event")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    if not isinstance(value, dict) or raw != canonical(value):
        raise AttestationError("attestation ledger is not canonical JSONL")
    return value, raw


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    return parser.parse_args(arguments)


def validate(value: dict[str, Any], head_sha: str, run_id: int, run_attempt: int) -> None:
    expected = {
        "environment", "event", "event_sha256", "head_sha", "operator_id",
        "previous_event_sha256", "public_release", "roles", "schema_version",
        "sequence", "workflow_job", "workflow_path", "workflow_run_attempt",
        "workflow_run_id",
    }
    if set(value) != expected:
        raise AttestationError("attestation fields are not exact")
    if (
        value["environment"] != ENVIRONMENT
        or value["event"] != "self-attestation"
        or value["workflow_job"] != JOB
        or value["workflow_path"] != WORKFLOW_PATH
        or value["public_release"] is not False
        or value["roles"] != ["owner", "operations", "executor"]
        or value["schema_version"] != 1
        or value["sequence"] != 1
        or value["previous_event_sha256"] != "0" * 64
        or not isinstance(value["operator_id"], str)
        or not value["operator_id"]
    ):
        raise AttestationError("attestation approval boundary is invalid")
    if (
        not SHA1.fullmatch(head_sha)
        or value["head_sha"] != head_sha
        or not SHA256.fullmatch(value["event_sha256"])
        or value["workflow_run_id"] != run_id
        or value["workflow_run_attempt"] != run_attempt
    ):
        raise AttestationError("attestation is not bound to this workflow run")
    unsigned = dict(value)
    unsigned.pop("event_sha256")
    if hashlib.sha256(canonical(unsigned)).hexdigest() != value["event_sha256"]:
        raise AttestationError("attestation event hash is invalid")


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        value, raw = load(args.ledger)
        validate(value, args.head_sha, args.run_id, args.run_attempt)
    except (OSError, UnicodeError, json.JSONDecodeError, AttestationError) as error:
        print(f"self-attestation ledger rejected: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"sha256": hashlib.sha256(raw).hexdigest(), "status": "self-attestation-ledger-valid"}, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
