"""Contract tests for the protected Todo 20 production-QA operation."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CONTRACT = ROOT / "scripts/ci/floorp-notes-sync-g5-operation-contract.json"
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-g5-operation-contract.py"
RUBY = "/usr/bin/ruby"

DISPATCH_INPUT = "run_floorp_notes_sync_production_qa"
JOB_ID = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"
CANONICAL_ARTIFACT = "floorp-notes-sync-two-client-xcresult"
EXPECTED_CASES = (
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
        "floorp_notes_sync_t20_operation_contract_validator",
        VALIDATOR,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the operation-contract validator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


OPERATION_CONTRACT = load_validator()


class FloorpNotesSyncG5OperationContractTests(unittest.TestCase):
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
    def named_step(job: dict[str, Any], name: str) -> dict[str, Any]:
        for step in job["steps"]:
            if step.get("name") == name:
                return step
        raise AssertionError(f"missing step: {name}")

    @staticmethod
    def checked_in_contract() -> dict[str, Any]:
        return json.loads(CONTRACT.read_text(encoding="utf-8"))

    def test_checked_in_contract_is_canonical_and_protected(self) -> None:
        decision = OPERATION_CONTRACT.load_and_validate_contract(CONTRACT)
        self.assertEqual(
            decision,
            {
                "credential_delivery": "protected-environment-secrets-only",
                "execution_authorization": "single-operator-protected-qa",
                "phase_1_result": "data-integrity-qa-required",
                "phase_2_enablement": "requires-validator-approve",
                "status": "operation-contract-valid",
            },
        )

    def test_contract_binds_the_complete_matrix_and_cleanup(self) -> None:
        contract = self.checked_in_contract()
        self.assertEqual(contract["schema_version"], 2)
        self.assertEqual(contract["integrity_matrix"]["required_cases"], list(EXPECTED_CASES))
        self.assertEqual(contract["integrity_matrix"]["accounts"], 2)
        self.assertEqual(contract["integrity_matrix"]["clients"], ["desktop", "mobile"])
        self.assertEqual(contract["integrity_matrix"]["result_format"], "metadata-only")
        self.assertTrue(contract["isolation_contract"]["cleanup_required"])
        self.assertTrue(contract["isolation_contract"]["keychain_cleanup_required"])
        self.assertTrue(contract["isolation_contract"]["runner_temp_cleanup_required"])
        self.assertTrue(contract["isolation_contract"]["simulator_cache_cleanup_required"])

    def test_contract_rejects_infrastructure_and_approval_reintroduction(self) -> None:
        contract = self.checked_in_contract()
        mutations = (
            (("execution", "phase_2_enablement_requires_phase_1"), False),
            (("network_contract", "direct_rest_forbidden"), False),
            (("isolation_contract", "cleanup_required"), False),
        )
        for path, value in mutations:
            with self.subTest(path=path):
                mutated = copy.deepcopy(contract)
                target = mutated
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
                    OPERATION_CONTRACT.validate_operation_contract(mutated)

    def test_removed_governance_is_not_an_active_contract_field(self) -> None:
        serialized = json.dumps(self.checked_in_contract(), sort_keys=True).lower()
        for marker in (
            "g6_signatures_required",
            "mozilla_reviewer_required",
            "custom_broker_required",
            "dedicated_runner_group_required",
            "driver_admission_required",
            "driver_trust_chain_required",
            "external_driver_required",
        ):
            self.assertNotIn(marker, serialized)

    def test_duplicate_and_noncanonical_json_remain_rejected(self) -> None:
        raw = CONTRACT.read_bytes()
        duplicate = raw.replace(
            b'"schema_version":2',
            b'"schema_version":2,"schema_version":2',
            1,
        )
        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(duplicate)
        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(raw + b" ")
        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(
                raw.replace(b'"schema_version":2', b'"schema_version":2.0', 1)
            )

    def test_dispatch_input_is_false_by_default(self) -> None:
        option = self.dispatch["inputs"][DISPATCH_INPUT]
        self.assertEqual(option["type"], "boolean")
        self.assertFalse(option["required"])
        self.assertFalse(option["default"])

    def test_qa_job_is_main_only_environment_bound_and_secret_redacted(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["environment"], ENVIRONMENT)
        self.assertEqual(job["permissions"], {})
        self.assertEqual(
            " ".join(job["if"].split()),
            "github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main' && "
            f"inputs.{DISPATCH_INPUT} == true",
        )
        serialized = json.dumps(job, sort_keys=True).lower()
        for secret_name in (
            "floorp_notes_sync_account_a_email",
            "floorp_notes_sync_account_a_password",
            "floorp_notes_sync_account_b_email",
            "floorp_notes_sync_account_b_password",
        ):
            self.assertIn(secret_name, serialized)
        for forbidden in (
            "echo $floorp_notes_sync",
            "printf $floorp_notes_sync",
            "external-driver",
            "root-owned-broker",
            "dedicated-g5-runner",
            "curl ",
            "gh api",
        ):
            self.assertNotIn(forbidden, serialized)

    def test_qa_job_requires_phase_one_before_enablement_and_cleans_up(self) -> None:
        job = self.jobs[JOB_ID]
        names = [step["name"] for step in job["steps"]]
        self.assertIn("Validate Todo 20 operation contract", names)
        self.assertIn("Run protected two-client integrity QA", names)
        self.assertIn("Scan QA material for secrets", names)
        self.assertIn("Clean up test accounts and client state", names)
        self.assertIn("Upload metadata-only QA evidence", names)
        self.assertNotIn(CANONICAL_ARTIFACT, json.dumps(self.jobs["build-and-test"], sort_keys=True))


if __name__ == "__main__":
    unittest.main()
