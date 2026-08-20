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
import os
import re
import sys
from pathlib import Path
from typing import Any


VALIDATOR_PATH = Path(__file__).with_name("validate-floorp-notes-sync-production-qa.py")
ENABLEMENT_VALIDATOR_SOURCE = Path(__file__)
CLEANUP_VALIDATOR_SOURCE = Path(__file__).with_name(
    "validate-floorp-notes-sync-production-qa-cleanup.py"
)
SECRET_SCAN_VALIDATOR_SOURCE = Path(__file__).with_name(
    "validate-floorp-notes-sync-secret-scan.py"
)
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


def load_validator(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise EnablementError(f"cannot load validator: {path.name}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


CLEANUP = load_validator(CLEANUP_VALIDATOR_SOURCE, "floorp_notes_sync_cleanup_validator_for_enablement")
SECRET_SCAN = load_validator(SECRET_SCAN_VALIDATOR_SOURCE, "floorp_notes_sync_secret_scan_validator_for_enablement")


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


def validate_enablement(
    record: Any,
    phase1: dict[str, Any],
    phase1_raw: bytes,
    cleanup_receipt_raw: bytes,
    secret_scan_receipt_raw: bytes,
    secret_scan_targets: list[Path],
) -> dict[str, Any]:
    require(isinstance(record, dict), "enablement record must be an object")
    expected_keys = {
        "app_store_submission",
        "approved",
        "configuration",
        "cleanup_receipt_sha256",
        "cleanup_validator_sha256",
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
        "secret_scan_validator_sha256",
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
        "cleanup_receipt_sha256",
        "cleanup_validator_sha256",
        "enablement_validator_sha256",
        "production_qa_validator_sha256",
        "secret_scan_receipt_sha256",
        "secret_scan_validator_sha256",
    ):
        require(
            isinstance(record[field], str) and SHA256.fullmatch(record[field]) is not None,
            f"{field} is not a SHA-256 digest",
        )
    require(record["source_head_sha"] == phase1["source"]["head_sha"], "enablement source does not match Phase 1")
    require(record["operator_id"] == phase1["self_attestation"]["operator_id"], "enablement operator does not match Phase 1")
    require(record["workflow_event"] == "workflow_dispatch", "enablement event is not a manual dispatch")
    require(record["workflow_job"] == "notes-sync-production-enablement", "enablement job is invalid")
    require(record["workflow_path"] == ".github/workflows/floorp-notes-sync-production-qa.yml", "enablement workflow is invalid")
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
        record["cleanup_validator_sha256"] == hashlib.sha256(CLEANUP_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "enablement does not bind the cleanup validator",
    )
    require(
        record["secret_scan_validator_sha256"] == hashlib.sha256(SECRET_SCAN_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "enablement does not bind the secret-scan validator",
    )
    require(
        record["phase1_summary_sha256"] == hashlib.sha256(phase1_raw).hexdigest(),
        "enablement is not bound to the exact Phase 1 summary bytes",
    )
    cleanup_receipt = QA.parse_bytes(cleanup_receipt_raw)
    CLEANUP.validate_receipt(cleanup_receipt, phase1, cleanup_receipt_raw)
    secret_scan_receipt = QA.parse_bytes(secret_scan_receipt_raw)
    SECRET_SCAN.validate(
        secret_scan_receipt,
        phase1["source"]["head_sha"],
        phase1["source"]["workflow_run_id"],
        phase1["source"]["workflow_run_attempt"],
        secret_scan_targets,
    )
    require(
        record["cleanup_receipt_sha256"] == hashlib.sha256(cleanup_receipt_raw).hexdigest(),
        "enablement is not bound to the exact cleanup receipt bytes",
    )
    require(
        record["secret_scan_receipt_sha256"] == hashlib.sha256(secret_scan_receipt_raw).hexdigest(),
        "enablement is not bound to the exact secret-scan receipt bytes",
    )
    return record


WAIVED_ENABLEMENT_FIELDS = {
    "app_store_submission",
    "approved",
    "audit_endpoint_unavailable",
    "audit_source",
    "configuration",
    "enablement_validator_sha256",
    "environment",
    "fxa_configuration",
    "guarded_merge_run_id",
    "live_qa",
    "live_qa_waiver_approved_at_utc",
    "live_qa_waiver_operator_id",
    "live_qa_waiver_plan_hash",
    "merge_audit_sha256",
    "no_data_loss_claim",
    "operator_id",
    "owner_review_status",
    "owner_review_waiver_sha256",
    "phase",
    "phase1_summary_sha256",
    "public_release",
    "repository",
    "review_receipt_sha256",
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


def validate_waived_enablement(
    record: Any,
    review_receipt_raw: bytes,
    merge_audit_raw: bytes,
    live_qa_waiver_raw: bytes,
    binding_raw: bytes,
) -> dict[str, Any]:
    require(isinstance(record, dict), "enablement record must be an object")
    require(
        set(record) == WAIVED_ENABLEMENT_FIELDS,
        "enablement record fields are not exact",
    )
    require(record["schema_version"] == 2, "enablement schema is unsupported")
    require(record["phase"] == "production-sync-enablement", "enablement phase is invalid")
    require(record["environment"] == ENVIRONMENT, "enablement Environment is invalid")
    require(record["repository"] == REPOSITORY, "enablement repository is invalid")
    require(record["approved"] is True, "enablement is not approved")
    require(
        record["configuration"] == "production-sync-enabled-qa",
        "enablement configuration is distributable",
    )
    require(
        record["fxa_configuration"] == "FxAConfig.Server.release",
        "enablement FxA configuration is invalid",
    )
    require(record["wire_protocol"] == "sync15", "enablement protocol is invalid")
    require(record["public_release"] is False, "public release is forbidden")
    require(record["app_store_submission"] is False, "App Store submission is forbidden")
    require(record["testflight_distribution"] is False, "TestFlight distribution is forbidden")
    require(record["live_qa"] == "owner-waived-not-performed", "live QA is not recorded as waived")
    require(record["no_data_loss_claim"] is False, "no-data-loss must not be claimed")
    require(
        record["owner_review_status"] == "waived-not-performed",
        "owner review gate is not recorded as waived",
    )
    require(
        isinstance(record["owner_review_waiver_sha256"], str)
        and SHA256.fullmatch(record["owner_review_waiver_sha256"]) is not None,
        "owner review waiver digest is invalid",
    )
    require(record["phase1_summary_sha256"] is None, "waived enablement must not bind a Phase 1 summary")
    require(
        record["audit_source"] == "github-org-audit-log-unavailable-owner-waived",
        "audit source is not the owner-waived unavailability record",
    )
    require(record["audit_endpoint_unavailable"] is True, "audit endpoint unavailability is not recorded")
    for field in ("enablement_validator_sha256", "merge_audit_sha256", "review_receipt_sha256"):
        require(
            isinstance(record[field], str) and SHA256.fullmatch(record[field]) is not None,
            f"{field} is not a SHA-256 digest",
        )
    require(
        str(record["guarded_merge_run_id"])
        == os.environ.get("FLOORP_TODO20_GUARDED_MERGE_RUN_ID"),
        "enablement guarded-merge run does not match the protected selector",
    )
    require(
        record["source_head_sha"] == os.environ.get("GITHUB_SHA"),
        "enablement source head does not match the workflow source",
    )
    require(
        record["operator_id"] == os.environ.get("GITHUB_ACTOR"),
        "enablement operator does not match the dispatch actor",
    )
    require(
        record["live_qa_waiver_operator_id"] == record["operator_id"],
        "live-QA waiver operator does not match the enablement operator",
    )
    require(
        record["workflow_event"] == "workflow_dispatch",
        "enablement event is not a manual dispatch",
    )
    require(
        record["workflow_job"] == "notes-sync-production-enablement-waived",
        "enablement job is invalid",
    )
    require(record["workflow_path"] == ".github/workflows/floorp-notes-sync-production-qa.yml", "enablement workflow is invalid")
    require(
        record["enablement_validator_sha256"]
        == hashlib.sha256(ENABLEMENT_VALIDATOR_SOURCE.read_bytes()).hexdigest(),
        "enablement does not bind the enablement validator",
    )
    require(
        record["merge_audit_sha256"] == hashlib.sha256(merge_audit_raw).hexdigest(),
        "enablement is not bound to the exact merge-audit bytes",
    )
    require(
        record["review_receipt_sha256"] == hashlib.sha256(review_receipt_raw).hexdigest(),
        "enablement is not bound to the exact review-receipt bytes",
    )
    binding = json.loads(binding_raw.decode("utf-8"))
    require(
        isinstance(binding, dict)
        and record["live_qa_waiver_plan_hash"] == binding.get("combined_plan_hash"),
        "enablement live-QA waiver plan hash does not match the checked-in plan binding",
    )
    review_receipt = json.loads(review_receipt_raw.decode("utf-8"))
    require(
        isinstance(review_receipt, dict)
        and review_receipt.get("merge_audit_sha256") == record["merge_audit_sha256"],
        "review receipt is not bound to the enablement merge audit",
    )
    require(
        review_receipt.get("owner_review_status") == record["owner_review_status"]
        and review_receipt.get("owner_review_waiver_sha256") == record["owner_review_waiver_sha256"],
        "review receipt is not bound to the owner-review gate waiver",
    )
    require(
        review_receipt.get("source_workflow_run_id") == record["guarded_merge_run_id"],
        "review receipt guarded-merge run does not match the enablement record",
    )
    require(
        review_receipt.get("audit_source") == "github-org-audit-log-unavailable-owner-waived",
        "review receipt is not the owner-waived audit record",
    )
    merge_audit = json.loads(merge_audit_raw.decode("utf-8"))
    require(
        isinstance(merge_audit, dict)
        and merge_audit.get("schema_version") == 3
        and merge_audit.get("audit_source") == "github-org-audit-log-unavailable-owner-waived"
        and merge_audit.get("audit_endpoint_unavailable") is True
        and merge_audit.get("admin_bypass_used") is None,
        "merge audit is not the owner-waived schema-v3 record",
    )
    live_qa_waiver = json.loads(live_qa_waiver_raw.decode("utf-8"))
    require(
        isinstance(live_qa_waiver, dict)
        and live_qa_waiver.get("operator_id") == record["operator_id"]
        and isinstance(live_qa_waiver.get("approved_at_utc"), str)
        and live_qa_waiver["approved_at_utc"].endswith("Z")
        and live_qa_waiver.get("plan_hash") == record["live_qa_waiver_plan_hash"],
        "live-QA waiver receipt is not bound to the enablement record",
    )
    return record


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase1-summary", type=Path, required=False)
    parser.add_argument("--cleanup-receipt", type=Path, required=False)
    parser.add_argument("--secret-scan-receipt", type=Path, required=False)
    parser.add_argument("--secret-scan-target", type=Path, action="append", required=False)
    parser.add_argument("--enablement-record", type=Path, required=True)
    parser.add_argument(
        "--waived-qa",
        action="store_true",
        help="validate the owner-waived enablement record (no live Phase 1 matrix)",
    )
    parser.add_argument("--review-receipt", type=Path, required=False)
    parser.add_argument("--merge-audit", type=Path, required=False)
    parser.add_argument("--live-qa-waiver", type=Path, required=False)
    parser.add_argument("--plan-binding", type=Path, required=False)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        record, _ = canonical_json(args.enablement_record)
        if args.waived_qa:
            if (
                args.review_receipt is None
                or args.merge_audit is None
                or args.live_qa_waiver is None
                or args.plan_binding is None
            ):
                raise EnablementError("waived-qa mode requires review receipt, merge audit, waiver, and binding")
            validate_waived_enablement(
                record,
                args.review_receipt.read_bytes(),
                args.merge_audit.read_bytes(),
                args.live_qa_waiver.read_bytes(),
                args.plan_binding.read_bytes(),
            )
            print('{"phase":"production-sync-enablement","status":"enablement-record-valid-waived"}')
            return 0
        if (
            args.phase1_summary is None
            or args.cleanup_receipt is None
            or args.secret_scan_receipt is None
            or not args.secret_scan_target
        ):
            raise EnablementError("live enablement inputs are missing")
        phase1_raw = args.phase1_summary.read_bytes()
        cleanup_receipt_raw = args.cleanup_receipt.read_bytes()
        secret_scan_receipt_raw = args.secret_scan_receipt.read_bytes()
        phase1 = QA.validate_summary(QA.parse_bytes(phase1_raw))
        record, _ = canonical_json(args.enablement_record)
        validate_enablement(
            record,
            phase1,
            phase1_raw,
            cleanup_receipt_raw,
            secret_scan_receipt_raw,
            args.secret_scan_target,
        )
    except (OSError, QA.ProductionQAError, EnablementError) as error:
        print(f"production Sync enablement rejected: {error}", file=sys.stderr)
        return 2
    print('{"phase":"production-sync-enablement","status":"enablement-record-valid"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
