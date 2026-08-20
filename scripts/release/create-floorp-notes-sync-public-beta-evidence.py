#!/usr/bin/python3 -I
"""Create the explicit, source-bound evidence for a public TestFlight beta.

The protected production-QA capability remains non-distributable. This command
creates a separate public-beta record only after validating that capability and
its metadata-only QA summary against the same source SHA and workflow run.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
QA_VALIDATOR_PATH = ROOT / "scripts/ci/validate-floorp-notes-sync-production-qa.py"
CAPABILITY_MODULE_PATH = ROOT / "scripts/ci/floorp_notes_sync_production_qa_capability.py"
CONTRACT_PATH = ROOT / "scripts/ci/floorp-notes-sync-g5-operation-contract.json"
ENDPOINT_POLICY_PATH = ROOT / "docs/floorp-release-endpoints.json"
REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class PublicBetaEvidenceError(ValueError):
    pass


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise PublicBetaEvidenceError(f"cannot load validator: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


QA = load_module(QA_VALIDATOR_PATH, "floorp_notes_sync_public_beta_qa_validator")
CAPABILITY = load_module(
    CAPABILITY_MODULE_PATH,
    "floorp_notes_sync_public_beta_capability_validator",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PublicBetaEvidenceError(message)


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"


def read_canonical(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise PublicBetaEvidenceError(f"{label} cannot be read") from error
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicBetaEvidenceError(f"{label} is not valid JSON") from error
    require(isinstance(value, dict), f"{label} must be an object")
    require(raw == canonical(value), f"{label} is not canonical JSON")
    return value, raw


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--capability", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--operator-id", required=True)
    parser.add_argument("--approve-public-beta", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        require(SHA1.fullmatch(args.source_sha) is not None, "source SHA is invalid")
        require(SHA1.fullmatch(args.desktop_sha) is not None, "Desktop SHA is invalid")
        require(re.fullmatch(r"[1-9][0-9]*", args.build_number) is not None, "build number is invalid")
        require(bool(args.operator_id.strip()), "operator ID is empty")
        require(args.approve_public_beta, "explicit public-beta approval is required")

        summary_raw = args.summary.read_bytes()
        summary = QA.validate_summary(QA.parse_bytes(summary_raw))
        source = summary["source"]
        require(source["repository"] == REPOSITORY, "QA repository is not canonical")
        require(source["head_sha"] == args.source_sha, "QA source SHA does not match the candidate")
        require(source["workflow_path"] == WORKFLOW_PATH, "QA workflow path is not canonical")
        require(summary["public_release"] is False, "QA summary must remain non-distributable")

        capability = CAPABILITY.load_capability(
            args.capability,
            expected_source_sha=args.source_sha,
            expected_desktop_sha=args.desktop_sha,
            expected_contract_sha=CAPABILITY.sha256_file(CONTRACT_PATH),
            expected_endpoint_policy_sha=CAPABILITY.sha256_file(ENDPOINT_POLICY_PATH),
        )
        capability_source = capability["source"]
        require(capability_source == source, "QA capability and summary are from different runs")
        require(capability["ios_build_number"] == args.build_number, "QA build number does not match the candidate")
        require(capability["public_release"] is False, "QA capability must remain non-distributable")

        endpoint = capability["endpoint"]
        record = {
            "approval": {
                "approved": True,
                "operator_id": args.operator_id,
                "purpose": "external-testflight",
            },
            "build_contract_mode": "public-beta",
            "endpoint": endpoint,
            "ios": {
                "build_number": args.build_number,
                "configuration": "FloorpRelease",
                "repository": REPOSITORY,
                "source_sha": args.source_sha,
            },
            "public_release": True,
            "qa": {
                "capability_sha256": sha256_bytes(args.capability.read_bytes()),
                "summary_sha256": sha256_bytes(summary_raw),
                "workflow_path": WORKFLOW_PATH,
                "workflow_run_attempt": source["workflow_run_attempt"],
                "workflow_run_id": source["workflow_run_id"],
            },
            "schema_version": 1,
            "source": source,
        }
        raw = canonical(record)
        require(SHA256.fullmatch(sha256_bytes(raw)) is not None, "evidence digest could not be computed")
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
        print(
            json.dumps(
                {
                    "build_contract_mode": "public-beta",
                    "source_sha": args.source_sha,
                    "workflow_run_id": source["workflow_run_id"],
                    "status": "public-beta-evidence-created",
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"public-beta evidence rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
