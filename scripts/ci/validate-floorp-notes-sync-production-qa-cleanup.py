#!/usr/bin/python3 -I
"""Validate the client-pair cleanup receipt without touching FxA/Sync.

The receipt must be emitted by the existing desktop/mobile client pair. This
command verifies its canonical metadata and digest binding to the Phase 1
summary; it does not delete server data or accept a summary boolean alone.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-production-qa.py")
REPOSITORY = "Floorp-Projects/floorp-ios"
ENVIRONMENT = "floorp-notes-sync-production-qa"


class CleanupReceiptError(ValueError):
    pass


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_qa_validator_for_cleanup_receipt",
        VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise CleanupReceiptError("cannot load QA validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


QA = load_validator()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CleanupReceiptError(message)


def parse_canonical(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise CleanupReceiptError("cleanup receipt is unavailable") from error
    value = QA.parse_bytes(raw)
    require(isinstance(value, dict), "cleanup receipt root must be an object")
    return value, raw


def validate_receipt(receipt: Any, summary: dict[str, Any], raw: bytes) -> None:
    require(
        set(receipt)
        == {
            "accounts",
            "environment",
            "local_cache",
            "phase",
            "runner_temp",
            "schema_version",
            "simulator_keychain",
            "source",
        },
        "cleanup receipt fields are not exact",
    )
    require(receipt["schema_version"] == 1, "cleanup receipt schema is unsupported")
    require(receipt["phase"] == "production-qa", "cleanup receipt phase is invalid")
    require(receipt["environment"] == ENVIRONMENT, "cleanup receipt Environment is invalid")
    require(receipt["accounts"] is True, "server-side disposable-account cleanup is not attested")
    require(receipt["local_cache"] is True, "client local-cache cleanup is not attested")
    require(receipt["runner_temp"] is True, "client-pair runner-temp cleanup is not attested")
    require(receipt["simulator_keychain"] is True, "Simulator Keychain cleanup is not attested")
    source = receipt["source"]
    require(
        isinstance(source, dict)
        and set(source) == {"head_sha", "repository", "workflow_run_attempt", "workflow_run_id"},
        "cleanup receipt source fields are not exact",
    )
    require(source["repository"] == REPOSITORY, "cleanup receipt repository is invalid")
    require(source == {key: summary["source"][key] for key in source}, "cleanup receipt source is not bound to QA")
    require(hashlib.sha256(raw).hexdigest() == summary["cleanup_receipt_sha256"], "cleanup receipt digest mismatch")


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        summary_raw = args.summary.read_bytes()
        summary = QA.validate_summary(QA.parse_bytes(summary_raw))
        receipt, receipt_raw = parse_canonical(args.receipt)
        validate_receipt(receipt, summary, receipt_raw)
    except (OSError, QA.ProductionQAError, CleanupReceiptError) as error:
        print(f"production QA cleanup rejected: {error}", file=sys.stderr)
        return 2
    print('{"cleanup":"client-pair-receipt-valid","status":"verified"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
