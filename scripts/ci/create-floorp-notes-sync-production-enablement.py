#!/usr/bin/python3 -I
"""Create the non-distributed Phase 2 enablement record after Phase 1.

This command is intentionally a gate, not a release switch. It consumes the
metadata-only Phase 1 summary from the same protected workflow run and writes
an immutable record that the existing production Sync configuration may be
enabled in a later reviewed build. It never changes checked-in configuration,
contacts FxA/Sync, or performs distribution.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


QA_VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-production-qa.py")
ENABLEMENT_VALIDATOR_PATH = Path(__file__).with_name(
    "validate-floorp-notes-sync-production-enablement.py"
)
SECRET_SCAN_VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-secret-scan.py")
CLEANUP_VALIDATOR_PATH = Path(__file__).with_name(
    "validate-floorp-notes-sync-production-qa-cleanup.py"
)
REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
PHASE1_JOB = "notes-sync-production-qa"


class EnablementPreparationError(RuntimeError):
    pass


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise EnablementPreparationError(f"cannot load validator: {path.name}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


QA = load_module(QA_VALIDATOR_PATH, "floorp_notes_sync_qa_validator_for_enablement_prepare")
ENABLEMENT = load_module(
    ENABLEMENT_VALIDATOR_PATH,
    "floorp_notes_sync_enablement_validator_for_enablement_prepare",
)
SECRET_SCAN = load_module(
    SECRET_SCAN_VALIDATOR_PATH,
    "floorp_notes_sync_secret_scan_validator_for_enablement_prepare",
)
CLEANUP = load_module(
    CLEANUP_VALIDATOR_PATH,
    "floorp_notes_sync_cleanup_validator_for_enablement_prepare",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EnablementPreparationError(message)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase1-summary", type=Path, required=True)
    parser.add_argument("--cleanup-receipt", type=Path, required=True)
    parser.add_argument("--secret-scan-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def runtime_context() -> dict[str, Any]:
    required = (
        "GITHUB_ACTOR",
        "GITHUB_EVENT_NAME",
        "GITHUB_JOB",
        "GITHUB_REPOSITORY",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_RUN_ID",
        "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    require(
        all(os.environ.get(name) for name in required),
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_context_missing",
    )
    require(
        os.environ.get("FLOORP_NOTES_SYNC_ENABLEMENT_APPROVED") == "1",
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_approval_missing resume=obtain protected Environment approval",
    )
    require(
        os.environ["GITHUB_REPOSITORY"] == REPOSITORY,
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_repository_mismatch",
    )
    require(
        os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch",
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_event_mismatch",
    )
    require(
        os.environ["GITHUB_JOB"] == "notes-sync-production-enablement",
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_job_mismatch",
    )
    require(
        os.environ["GITHUB_WORKFLOW_REF"].startswith(
            f"{REPOSITORY}/{WORKFLOW_PATH}@"
        ),
        "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_workflow_mismatch",
    )
    try:
        run_id = int(os.environ["GITHUB_RUN_ID"])
        run_attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    except ValueError as error:
        raise EnablementPreparationError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_context_invalid"
        ) from error
    return {
        "actor": os.environ["GITHUB_ACTOR"],
        "head_sha": os.environ["GITHUB_SHA"],
        "run_id": run_id,
        "run_attempt": run_attempt,
    }


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8") + b"\n"


def write_exclusive(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("xb") as handle:
            handle.write(raw)
    except FileExistsError as error:
        raise EnablementPreparationError("enablement output already exists") from error


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        context = runtime_context()
        phase1_raw = args.phase1_summary.read_bytes()
        phase1 = QA.validate_summary(QA.parse_bytes(phase1_raw))
        source = phase1["source"]
        require(
            source["repository"] == REPOSITORY,
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_phase1_repository_mismatch",
        )
        require(
            source["head_sha"] == context["head_sha"],
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_phase1_head_mismatch",
        )
        require(
            source["workflow_run_id"] == context["run_id"],
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_phase1_run_mismatch",
        )
        require(
            source["workflow_run_attempt"] == context["run_attempt"],
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_phase1_attempt_mismatch",
        )
        require(
            phase1["self_attestation"]["operator_id"] == context["actor"],
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_operator_mismatch",
        )
        cleanup_receipt, cleanup_receipt_raw = CLEANUP.parse_canonical(args.cleanup_receipt)
        CLEANUP.validate_receipt(cleanup_receipt, phase1, cleanup_receipt_raw)
        secret_scan, secret_scan_raw = SECRET_SCAN.load(args.secret_scan_receipt)
        SECRET_SCAN.validate(
            secret_scan,
            context["head_sha"],
            context["run_id"],
            context["run_attempt"],
        )
        record = {
            "app_store_submission": False,
            "approved": True,
            "configuration": "production-sync-enabled-qa",
            "cleanup_receipt_sha256": hashlib.sha256(cleanup_receipt_raw).hexdigest(),
            "cleanup_validator_sha256": hashlib.sha256(
                CLEANUP_VALIDATOR_PATH.read_bytes()
            ).hexdigest(),
            "enablement_validator_sha256": hashlib.sha256(
                ENABLEMENT_VALIDATOR_PATH.read_bytes()
            ).hexdigest(),
            "environment": ENABLEMENT.ENVIRONMENT,
            "fxa_configuration": "FxAConfig.Server.release",
            "operator_id": context["actor"],
            "phase": "production-sync-enablement",
            "phase1_summary_sha256": hashlib.sha256(phase1_raw).hexdigest(),
            "production_qa_validator_sha256": hashlib.sha256(
                QA_VALIDATOR_PATH.read_bytes()
            ).hexdigest(),
            "public_release": False,
            "repository": REPOSITORY,
            "schema_version": 1,
            "secret_scan_validator_sha256": hashlib.sha256(
                SECRET_SCAN_VALIDATOR_PATH.read_bytes()
            ).hexdigest(),
            "source_head_sha": context["head_sha"],
            "testflight_distribution": False,
            "wire_protocol": "sync15",
            "secret_scan_receipt_sha256": hashlib.sha256(secret_scan_raw).hexdigest(),
            "workflow_event": "workflow_dispatch",
            "workflow_job": "notes-sync-production-enablement",
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": context["run_attempt"],
            "workflow_run_id": context["run_id"],
        }
        ENABLEMENT.validate_enablement(
            record,
            phase1,
            phase1_raw,
            cleanup_receipt_raw,
            secret_scan_raw,
        )
        write_exclusive(args.output, canonical_bytes(record))
    except (
        OSError,
        QA.ProductionQAError,
        ENABLEMENT.EnablementError,
        CLEANUP.CleanupReceiptError,
        SECRET_SCAN.SecretScanError,
        EnablementPreparationError,
    ) as error:
        print(str(error), file=sys.stderr)
        return 78
    print('{"phase":"production-sync-enablement","status":"record-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
