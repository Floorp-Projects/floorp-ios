"""TDD contract for the proportional Todo 20 production-QA rescope."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / "scripts/ci/floorp-notes-sync-g5-operation-contract.json"
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-g5-operation-contract.py"
WORKFLOW = ROOT / ".github/workflows/ci.yml"
RUBY = "/usr/bin/ruby"

DISPATCH_INPUT = "run_floorp_notes_sync_production_qa"
JOB_ID = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"
FORBIDDEN_OPERATION_REQUIREMENTS = (
    "external-driver",
    "root-owned-broker",
    "dedicated-g5-runner",
    "driver-trust-chain",
    "g6-signature",
    "mozilla-reviewer",
)
REQUIRED_CASES = (
    "desktop-create-mobile-sync-desktop-recheck",
    "mobile-create-desktop-sync-mobile-recheck",
    "same-record-concurrent-edit",
    "update-delete-conflict",
    "offline-edit-reconnect-retry",
    "upload-save-commit-failure",
    "restart-preserves-unsynced-local-data",
    "old-new-client-mixed",
    "large-empty-multiple-records",
    "account-switch-isolation",
    "retry-idempotence",
    "base-revision-confirmation-gate",
)


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_t20_rescope_contract_validator",
        VALIDATOR,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the Todo 20 operation-contract validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


VALIDATOR_MODULE = load_validator()


class FloorpNotesSyncT20RescopeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        result = subprocess.run(
            [
                RUBY,
                "-rjson",
                "-ryaml",
                "-e",
                "print JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true))",
                str(WORKFLOW),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(f"failed to parse ci.yml: {result.stderr}")
        cls.workflow: dict[str, Any] = json.loads(result.stdout)
        cls.dispatch: dict[str, Any] = cls.workflow["true"]["workflow_dispatch"]
        cls.jobs: dict[str, Any] = cls.workflow["jobs"]

    @staticmethod
    def checked_in_contract() -> dict[str, Any]:
        return json.loads(CONTRACT.read_text(encoding="utf-8"))

    def test_contract_is_protected_two_phase_qa_not_g5_infrastructure_admission(self) -> None:
        contract = self.checked_in_contract()
        decision = VALIDATOR_MODULE.load_and_validate_contract(CONTRACT)
        self.assertEqual(decision["status"], "operation-contract-valid")
        self.assertEqual(contract["schema_version"], 2)
        self.assertEqual(contract["boundary"]["execution_authorization"], "single-operator-protected-qa")
        self.assertEqual(contract["boundary"]["phase_1_result"], "data-integrity-qa-required")
        self.assertEqual(contract["boundary"]["public_release"], "forbidden")
        self.assertTrue(contract["execution"]["phase_2_enablement_requires_phase_1"])
        self.assertEqual(
            contract["workflow"]["enablement_dispatch_input"],
            "run_floorp_notes_sync_production_enablement",
        )
        self.assertEqual(contract["workflow"]["enablement_job"], "notes-sync-production-enablement")
        self.assertEqual(
            contract["approval_model"]["self_attestation"],
            "owner-operations-executor-reviewer",
        )
        self.assertTrue(contract["approval_model"]["self_review_exception"])
        self.assertFalse(contract["approval_model"]["independence"])
        self.assertFalse(contract["approval_model"]["native_github_approval"])
        self.assertEqual(contract["approval_model"]["required_approving_review_count"], 0)
        self.assertEqual(contract["approval_model"]["reviews_count"], 0)

    def test_contract_contains_the_complete_data_integrity_matrix(self) -> None:
        contract = self.checked_in_contract()
        matrix = contract["integrity_matrix"]
        self.assertEqual(matrix["clients"], ["desktop", "mobile"])
        self.assertEqual(matrix["accounts"], 2)
        self.assertEqual(tuple(matrix["required_cases"]), REQUIRED_CASES)
        self.assertEqual(matrix["result_format"], "metadata-only")
        self.assertEqual(matrix["payload_observation"], "forbidden")
        self.assertIn("no-data-loss", matrix["required_invariants"])
        self.assertIn("no-account-mixing", matrix["required_invariants"])
        self.assertIn("base-revision-after-confirmation-only", matrix["required_invariants"])

    def test_contract_has_no_removed_infrastructure_requirement(self) -> None:
        serialized = json.dumps(self.checked_in_contract(), sort_keys=True).lower()
        for forbidden in FORBIDDEN_OPERATION_REQUIREMENTS:
            self.assertNotIn(forbidden, serialized)

    def test_workflow_exposes_protected_manual_production_qa_job(self) -> None:
        self.assertIn(DISPATCH_INPUT, self.dispatch["inputs"])
        option = self.dispatch["inputs"][DISPATCH_INPUT]
        self.assertEqual(option["type"], "boolean")
        self.assertFalse(option["required"])
        self.assertFalse(option["default"])

        enablement_option = self.dispatch["inputs"]["run_floorp_notes_sync_production_enablement"]
        self.assertEqual(enablement_option["type"], "boolean")
        self.assertFalse(enablement_option["required"])
        self.assertFalse(enablement_option["default"])

        job = self.jobs[JOB_ID]
        self.assertEqual(job["environment"], ENVIRONMENT)
        self.assertEqual(job["runs-on"], "macos-26")
        serialized = json.dumps(job, sort_keys=True).lower()
        self.assertIn("floorp_notes_sync_account_a_email", serialized)
        self.assertIn("floorp_notes_sync_account_a_password", serialized)
        self.assertIn("floorp_notes_sync_account_b_email", serialized)
        self.assertIn("floorp_notes_sync_account_b_password", serialized)
        self.assertNotIn("validate external g5 driver prerequisites contract", serialized)
        self.assertNotIn("dedicated-g5-runner", serialized)
        self.assertIn("validate live production-qa summary and cleanup receipt", serialized)
        self.assertIn("record-floorp-notes-sync-secret-scan.py", serialized)
        self.assertIn("record-floorp-notes-sync-self-attestation.py", serialized)
        self.assertIn("validate-floorp-notes-sync-self-attestation.py", json.dumps(self.workflow, sort_keys=True).lower())

        enablement = self.jobs["notes-sync-production-enablement"]
        self.assertEqual(enablement["needs"], "notes-sync-production-qa")
        enablement_text = json.dumps(enablement, sort_keys=True).lower()
        self.assertIn("create-floorp-notes-sync-production-enablement.py", enablement_text)
        self.assertIn("validate non-distributed enablement record", enablement_text)
        self.assertNotIn("app store", enablement_text)
        self.assertNotIn("testflight", enablement_text)
        self.assertNotIn("root-owned-broker", serialized)

    def test_source_bound_receipts_authenticate_protected_ruleset_reads(self) -> None:
        for job_id, step_name in (
            (
                "notes-sync-production-enablement-waived",
                "Capture source-bound review evidence and create waived enablement record",
            ),
            ("notes-sync-production-qa", "Capture source-bound Todo 20 review receipt"),
        ):
            job = self.jobs[job_id]
            step = next(item for item in job["steps"] if item.get("name") == step_name)
            run = step["run"]
            self.assertIn(
                '-H "Authorization: Bearer $FLOORP_TODO20_GH_AUDIT_TOKEN"',
                run,
                f"{job_id} must authenticate its protected ruleset read",
            )

    def test_waived_enablement_uses_explicit_owner_review_gate_waiver(self) -> None:
        job = self.jobs["notes-sync-production-enablement-waived"]
        serialized = json.dumps(job, sort_keys=True)
        self.assertIn("FLOORP_TODO20_OWNER_REVIEW_WAIVER_JSON", serialized)
        self.assertNotIn("FLOORP_TODO20_OWNER_REVIEW_JSON", serialized)
        self.assertIn("owner-review-waiver", serialized)
        self.assertIn("owner_review_gate_waiver_missing", serialized)

    def test_workflow_keeps_normal_ci_and_public_release_disabled(self) -> None:
        serialized = json.dumps(self.workflow, sort_keys=True).lower()
        self.assertNotIn("app store", serialized)
        self.assertNotIn("testflight", serialized)
        self.assertNotIn("floorp_notes_sync_g5_run", serialized)


if __name__ == "__main__":
    unittest.main()
