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


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


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
    parser.add_argument("--phase1-summary", type=Path, required=False)
    parser.add_argument("--cleanup-receipt", type=Path, required=False)
    parser.add_argument("--secret-scan-receipt", type=Path, required=False)
    parser.add_argument("--secret-scan-target", type=Path, action="append", required=False)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--waived-qa",
        action="store_true",
        help=(
            "create the owner-waived enablement record bound to the "
            "guarded-merge evidence and the live-QA owner waiver instead of "
            "a Phase 1 matrix summary"
        ),
    )
    parser.add_argument("--review-receipt", type=Path, required=False)
    parser.add_argument("--merge-audit", type=Path, required=False)
    parser.add_argument("--live-qa-waiver", type=Path, required=False)
    parser.add_argument("--plan-binding", type=Path, required=False)
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
    if os.environ.get("ENABLEMENT_WAIVED_QA") == "1":
        require(
            os.environ["GITHUB_JOB"] == "notes-sync-production-enablement-waived",
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_job_mismatch",
        )
    else:
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
        if args.waived_qa:
            if (
                args.review_receipt is None
                or args.merge_audit is None
                or args.live_qa_waiver is None
                or args.plan_binding is None
            ):
                raise EnablementPreparationError(
                    "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_inputs_missing"
                )
            review_receipt_raw = args.review_receipt.read_bytes()
            merge_audit_raw = args.merge_audit.read_bytes()
            live_qa_waiver_raw = args.live_qa_waiver.read_bytes()
            binding_raw = args.plan_binding.read_bytes()
            review_receipt = json.loads(review_receipt_raw.decode("utf-8"))
            merge_audit = json.loads(merge_audit_raw.decode("utf-8"))
            live_qa_waiver = json.loads(live_qa_waiver_raw.decode("utf-8"))
            binding = json.loads(binding_raw.decode("utf-8"))
            require(
                isinstance(review_receipt, dict)
                and isinstance(merge_audit, dict)
                and isinstance(live_qa_waiver, dict)
                and isinstance(binding, dict),
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_inputs_invalid",
            )
            require(
                live_qa_waiver["operator_id"] == context["actor"],
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_operator_mismatch",
            )
            require(
                live_qa_waiver["plan_hash"] == binding["combined_plan_hash"],
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_plan_mismatch",
            )
            require(
                merge_audit["schema_version"] == 3
                and merge_audit["audit_source"] == "github-org-audit-log-unavailable-owner-waived"
                and merge_audit["audit_endpoint_unavailable"] is True
                and merge_audit["admin_bypass_used"] is None,
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_audit_invalid",
            )
            require(
                review_receipt["merge_audit_sha256"] == sha256(merge_audit_raw),
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_receipt_mismatch",
            )
            require(
                review_receipt["source_workflow_run_id"]
                == int(os.environ["FLOORP_TODO20_GUARDED_MERGE_RUN_ID"]),
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=waived_enablement_run_mismatch",
            )
            require(
                review_receipt.get("owner_review_status") == "waived-not-performed",
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=owner_review_gate_waiver_missing",
            )
            require(
                isinstance(review_receipt.get("owner_review_waiver_sha256"), str)
                and len(review_receipt["owner_review_waiver_sha256"]) == 64,
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=owner_review_gate_waiver_invalid",
            )
            record = {
                "app_store_submission": False,
                "approved": True,
                "audit_endpoint_unavailable": True,
                "audit_source": "github-org-audit-log-unavailable-owner-waived",
                "configuration": "production-sync-enabled-qa",
                "enablement_validator_sha256": sha256(ENABLEMENT_VALIDATOR_PATH.read_bytes()),
                "environment": ENABLEMENT.ENVIRONMENT,
                "fxa_configuration": "FxAConfig.Server.release",
                "guarded_merge_run_id": review_receipt["source_workflow_run_id"],
                "live_qa": "owner-waived-not-performed",
                "live_qa_waiver_approved_at_utc": live_qa_waiver["approved_at_utc"],
                "live_qa_waiver_operator_id": live_qa_waiver["operator_id"],
                "live_qa_waiver_plan_hash": live_qa_waiver["plan_hash"],
                "merge_audit_sha256": sha256(merge_audit_raw),
                "no_data_loss_claim": False,
                "operator_id": context["actor"],
                "owner_review_status": review_receipt["owner_review_status"],
                "owner_review_waiver_sha256": review_receipt["owner_review_waiver_sha256"],
                "phase": "production-sync-enablement",
                "phase1_summary_sha256": None,
                "public_release": False,
                "repository": REPOSITORY,
                "review_receipt_sha256": sha256(review_receipt_raw),
                "schema_version": 2,
                "source_head_sha": context["head_sha"],
                "testflight_distribution": False,
                "wire_protocol": "sync15",
                "workflow_event": "workflow_dispatch",
                "workflow_job": "notes-sync-production-enablement-waived",
                "workflow_path": WORKFLOW_PATH,
                "workflow_run_attempt": context["run_attempt"],
                "workflow_run_id": context["run_id"],
            }
            ENABLEMENT.validate_waived_enablement(
                record,
                review_receipt_raw,
                merge_audit_raw,
                live_qa_waiver_raw,
                binding_raw,
            )
            write_exclusive(args.output, canonical_bytes(record))
            print('{"phase":"production-sync-enablement","status":"enablement-record-created-waived"}')
            return 0
        if (
            args.phase1_summary is None
            or args.cleanup_receipt is None
            or args.secret_scan_receipt is None
            or not args.secret_scan_target
        ):
            raise EnablementPreparationError(
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=enablement_phase1_inputs_missing"
            )
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
            args.secret_scan_target,
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
            args.secret_scan_target,
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
