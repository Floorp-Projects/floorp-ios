"""Tests for the explicit public-beta FxA QA waiver contract."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "floorp_notes_sync_public_beta_qa_waiver.py"
SPEC = importlib.util.spec_from_file_location("public_beta_qa_waiver", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CREATE = load_script("create_public_beta_qa_waiver", ROOT / "create-floorp-notes-sync-public-beta-qa-waiver.py")
EVIDENCE = load_script(
    "create_public_beta_evidence",
    ROOT / "create-floorp-notes-sync-public-beta-evidence.py",
)


SOURCE_SHA = "a" * 40
DESKTOP_SHA = "b" * 40
RUN_ID = 123456


def valid_record() -> dict:
    return {
        "approval": {
            "approved": True,
            "operator_id": "test-operator",
            "purpose": "external-testflight",
        },
        "checks": {
            "compile_preflight_passed": True,
            "operation_contract_passed": True,
            "repository_tests_passed": True,
        },
        "desktop": {"source_sha": DESKTOP_SHA},
        "endpoint": {
            "endpoint_policy_sha256": hashlib.sha256(
                MODULE.ENDPOINT_POLICY_PATH.read_bytes()
            ).hexdigest(),
            "fxa_configuration": "FxAConfig.Server.release",
            "fxa_hosts": MODULE.APPROVED_FXA_HOSTS,
            "sync_hosts": MODULE.APPROVED_SYNC_HOSTS,
            "wire_protocol": "sync15",
        },
        "ios": {
            "build_number": "4",
            "configuration": "FloorpRelease",
            "repository": MODULE.REPOSITORY,
            "source_sha": SOURCE_SHA,
        },
        "live_qa": {
            "data_integrity_claim": False,
            "manual_validation_required": True,
            "reason_code": "external-fxa-client-challenge",
            "status": "owner-waived-not-performed",
        },
        "public_release": False,
        "schema_version": 1,
        "source": {
            "event": "workflow_dispatch",
            "head_sha": SOURCE_SHA,
            "job_name": MODULE.JOB_NAME,
            "repository": MODULE.REPOSITORY,
            "workflow_path": MODULE.WORKFLOW_PATH,
            "workflow_run_attempt": 1,
            "workflow_run_id": RUN_ID,
        },
    }


class PublicBetaQaWaiverTests(unittest.TestCase):
    def test_valid_waiver_is_canonical_and_source_bound(self) -> None:
        record = valid_record()
        raw = MODULE.canonical(record)
        self.assertEqual(MODULE.parse_bytes(raw), record)
        MODULE.validate_waiver(
            record,
            expected_source_sha=SOURCE_SHA,
            expected_desktop_sha=DESKTOP_SHA,
            expected_run_id=RUN_ID,
            expected_run_attempt=1,
        )

    def test_data_integrity_claim_is_rejected(self) -> None:
        record = valid_record()
        record["live_qa"]["data_integrity_claim"] = True
        with self.assertRaises(MODULE.PublicBetaWaiverError):
            MODULE.validate_waiver(record)

    def test_extra_fields_are_rejected(self) -> None:
        record = valid_record()
        record["live_qa"]["unexpected"] = "no"
        with self.assertRaises(MODULE.PublicBetaWaiverError):
            MODULE.validate_waiver(record)

    def test_json_is_canonical(self) -> None:
        record = valid_record()
        raw = json.dumps(record, indent=2).encode("utf-8") + b"\n"
        with self.assertRaises(MODULE.PublicBetaWaiverError):
            MODULE.parse_bytes(raw)

    def test_creator_and_public_beta_evidence_accept_waiver(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input-waiver.json"
            output = root / "created-waiver.json"
            evidence = root / "public-beta-evidence.json"
            source.write_bytes(MODULE.canonical(valid_record()))
            self.assertEqual(
                CREATE.main(
                    [
                        "--source-sha", SOURCE_SHA,
                        "--desktop-sha", DESKTOP_SHA,
                        "--build-number", "4",
                        "--operator-id", "test-operator",
                        "--run-id", str(RUN_ID),
                        "--run-attempt", "1",
                        "--approve-fxa-qa-waiver",
                        "--output", str(output),
                    ]
                ),
                0,
            )
            self.assertEqual(
                EVIDENCE.main(
                    [
                        "--waiver", str(output),
                        "--source-sha", SOURCE_SHA,
                        "--desktop-sha", DESKTOP_SHA,
                        "--build-number", "4",
                        "--operator-id", "test-operator",
                        "--approve-public-beta",
                        "--output", str(evidence),
                    ]
                ),
                0,
            )
            result = json.loads(evidence.read_text(encoding="utf-8"))
            self.assertTrue(result["public_release"])
            self.assertEqual(result["qa"]["mode"], "owner-waived")
            self.assertFalse(result["qa"]["data_integrity_claim"])


if __name__ == "__main__":
    unittest.main()
