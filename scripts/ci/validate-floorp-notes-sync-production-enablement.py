#!/usr/bin/python3 -I
"""Validate the non-distributed Phase 2 Sync-enablement record.

This command only checks that a reviewed enablement record is bound to a
validated Phase 1 metadata-only QA summary. It does not change build settings,
publish an app, contact FxA/Sync, or perform App Store/TestFlight operations.
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


VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-production-qa.py")
ENABLEMENT_VALIDATOR_SOURCE = Path(__file__)
ENVIRONMENT = "floorp-notes-sync-production-qa"
REPOSITORY = "Floorp-Projects/floorp-ios"
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class EnablementError(ValueError):
    pass


def load_qa_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_production_qa_validator_for_enablement",
        VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise EnablementError("cannot load Phase 1 QA validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


QA = load_qa_validator()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EnablementError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EnablementError("enablement record contains a duplicate JSON member")
        result[key] = value
    return result


def canonical_json(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise EnablementError("enablement input cannot be read") from error
    require(raw.endswith(b"\n"), "enablement record must end with one newline")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EnablementError("enablement record is not valid UTF-8 JSON") from error
    require(isinstance(value, dict), "enablement record must be an object")
    canonical = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    require(raw == canonical, "enablement record is not canonical JSON")
    return value, raw


def validate_enablement(record: Any, phase1: dict[str, Any], phase1_raw: bytes) -> dict[str, Any]:
    require(isinstance(record, dict), "enablement record must be an object")
    expected_keys = {
        "app_store_submission",
        "approved",
        "configuration",
        "enablement_validator_sha256",
        "environment",
        "fxa_configuration",
        "operator_id",
        "phase",
        "phase1_summary_sha256",
        "production_qa_validator_sha256",
        "public_release",
        "repository",
        "secret_scan_receipt_sha256",
        "schema_version",
        "source_head_sha",
        "testflight_distribution",
        "wire_protocol",
        "workflow_event",
        "workflow_job",
        "workflow_path",
        "workflow_run_attempt",
        "workflow_run_id",
    }
    require(set(record) == expected_keys, "enablement record fields are not exact")
    require(record["schema_version"] == 1, "enablement schema is unsupported")
    require(record["phase"] == "production-sync-enablement", "enablement phase is invalid")
    require(record["environment"] == ENVIRONMENT, "enablement Environment is invalid")
    require(record["repository"] == REPOSITORY, "enablement repository is invalid")
    require(record["approved"] is True, "enablement is not approved")
    require(record["configuration"] == "production-sync-enabled-qa", "enablement configuration is distributable")
    require(record["fxa_configuration"] == "FxAConfig.Server.release", "enablement FxA configuration is invalid")
    require(record["wire_protocol"] == "sync15", "enablement protocol is invalid")
    require(record["public_release"] is False, "public release is forbidden")
    require(record["app_store_submission"] is False, "App Store submission is forbidden")
    require(record["testflight_distribution"] is False, "TestFlight distribution is forbidden")
    for field in (
        "enablement_validator_sha256",
        "production_qa_validator_sha256",
        "secret_scan_receipt_sha256",
    ):
        require(
            isinstance(record[field], str) and SHA256.fullmatch(record[field]) is not None,
            f"{field} is not a SHA-256 digest",
        )
    require(record["source_head_sha"] == phase1["source"]["head_sha"], "enablement source does not match Phase 1")
    require(record["operator_id"] == phase1["self_attestation"]["operator_id"], "enablement operator does not match Phase 1")
    require(record["workflow_event"] == "workflow_dispatch", "enablement event is not a manual dispatch")
    require(record["workflow_job"] == "notes-sync-production-enablement", "enablement job is invalid")
    require(record["workflow_path"] == ".github/workflows/ci.yml", "enablement workflow is invalid")
    require(record["workflow_run_id"] == phase1["source"]["workflow_run_id"], "enablement run does not match Phase 1")
    require(
        record["workflow_run_attempt"] == phase1["source"]["workflow_run_attempt"],
        "enablement attempt does not match Phase 1",
    )
    require(
        record["production_qa_validator_sha256"] == hashlib.sha256(VALIDATOR_PATH.read_bytes()).hexdigest(),
        "enablement does not bind the production-QA validator",
    )
    require(
        record["enablement_validator_sha256"] == hashlib.sha256(ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "enablement does not bind the enablement validator",
    )
    require(
        record["phase1_summary_sha256"] == hashlib.sha256(phase1_raw).hexdigest(),
        "enablement is not bound to the exact Phase 1 summary bytes",
    )
    return record


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase1-summary", type=Path, required=True)
    parser.add_argument("--enablement-record", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        phase1_raw = args.phase1_summary.read_bytes()
        phase1 = QA.validate_summary(QA.parse_bytes(phase1_raw))
        record, _ = canonical_json(args.enablement_record)
        validate_enablement(record, phase1, phase1_raw)
    except (OSError, QA.ProductionQAError, EnablementError) as error:
        print(f"production Sync enablement rejected: {error}", file=sys.stderr)
        return 2
    print('{"phase":"production-sync-enablement","status":"enablement-record-valid"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
