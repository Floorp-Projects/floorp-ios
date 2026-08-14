"""TDD contract for non-executing external G5 driver prerequisites.

This is deliberately a public-policy check in the existing protected,
GitHub-hosted preflight. It must not schedule a self-hosted runner, invoke a
driver, receive credentials, execute the actual XCTest, or publish G5 evidence.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CONTRACT = ROOT / "scripts/ci/floorp-notes-sync-g5-external-driver-admission-contract.json"
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-g5-external-driver-admission-contract.py"
BUILD_CONTRACT = ROOT / "docs/floorp-notes-sync-build-contract.md"
RUBY = "/usr/bin/ruby"

DISPATCH_INPUT = "prepare_floorp_notes_sync_g5_contract"
JOB_ID = "notes-sync-g5-operation-contract-preflight"
ENVIRONMENT = "floorp-notes-sync-production-qa"
RUNNER_LABELS = ["self-hosted", "macOS", "floorp-notes-sync-g5"]
ACTUAL_G5_SELECTOR = (
    "XCUITests/FloorpNotesSyncActualG5TwoClientTests/"
    "testActualG5TwoClientProductionMatrix"
)
ACTUAL_G5_TEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"
CANONICAL_G5_ARTIFACT = "floorp-notes-sync-two-client-xcresult"


class FloorpNotesSyncG5ExternalDriverAdmissionContractTests(unittest.TestCase):
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
        cls.jobs: dict[str, Any] = cls.workflow["jobs"]

    def load_validator(self) -> Any | None:
        self.assertTrue(VALIDATOR.is_file(), "external-driver prerequisites validator is missing")
        if not VALIDATOR.is_file():
            return None
        specification = importlib.util.spec_from_file_location(
            "floorp_notes_sync_g5_external_driver_prerequisites_validator_test",
            VALIDATOR,
        )
        self.assertIsNotNone(specification)
        assert specification is not None
        self.assertIsNotNone(specification.loader)
        assert specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
        return module

    def checked_in_contract(self) -> dict[str, Any] | None:
        self.assertTrue(CONTRACT.is_file(), "external-driver prerequisites contract is missing")
        if not CONTRACT.is_file():
            return None
        return json.loads(CONTRACT.read_text(encoding="utf-8"))

    @staticmethod
    def named_step(job: dict[str, Any], name: str) -> dict[str, Any]:
        for step in job["steps"]:
            if step.get("name") == name:
                return step
        raise AssertionError(f"missing step: {name}")

    def test_checked_in_contract_is_canonical_and_explicitly_nonexecuting(self) -> None:
        validator = self.load_validator()
        if validator is None:
            return
        decision = validator.load_and_validate_contract(CONTRACT)
        self.assertEqual(
            decision,
            {
                "credential_delivery": "protected-environment-only",
                "driver_attestation": "not-assessed",
                "driver_execution": "not-authorized",
                "g5_result": "not-assessed",
                "runner_admission": "not-assessed",
                "status": "external-driver-prerequisites-contract-valid",
            },
        )

    def test_parser_rejects_duplicate_noncanonical_and_noninteger_contract_bytes(self) -> None:
        validator = self.load_validator()
        if validator is None:
            return
        raw = CONTRACT.read_bytes()
        variants = (
            raw.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1', 1),
            raw + b" ",
            raw.replace(b'"schema_version":1', b'"schema_version":1.0', 1),
        )
        for variant in variants:
            with self.subTest(variant=variant[-32:]):
                with self.assertRaises(validator.ExternalDriverPrerequisitesContractError):
                    validator.parse_contract_bytes(variant)

    def test_loader_accepts_only_the_checked_in_regular_contract(self) -> None:
        validator = self.load_validator()
        if validator is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            copied = directory / "contract.json"
            copied.write_bytes(CONTRACT.read_bytes())
            with self.assertRaises(validator.ExternalDriverPrerequisitesContractError):
                validator.load_and_validate_contract(copied)

            linked = directory / "contract-link.json"
            linked.symlink_to(CONTRACT)
            with self.assertRaises(validator.ExternalDriverPrerequisitesContractError):
                validator.load_and_validate_contract(linked)

    def test_contract_binds_future_brokered_driver_and_ephemeral_runner_requirements(self) -> None:
        contract = self.checked_in_contract()
        if contract is None:
            return
        self.assertEqual(
            contract["workflow"],
            {
                "dispatch_input": DISPATCH_INPUT,
                "environment": ENVIRONMENT,
                "event": "workflow_dispatch",
                "head_branch": "main",
                "path": ".github/workflows/ci.yml",
            },
        )
        self.assertEqual(
            contract["driver"],
            {
                "artifact_retrieval": "required-after-run",
                "credential_delivery": "root-owned-broker-required-before-execution",
                "execution": "not-authorized",
                "interface": "metadata-only-g5-receipt-v1",
            },
        )
        self.assertEqual(
            contract["runner"],
            {
                "binary_digest": "required-before-execution",
                "ephemeral_lease": "required-before-execution",
                "kind": "dedicated-self-hosted-required-before-execution",
                "labels": RUNNER_LABELS,
                "secret_delivery": "root-owned-broker-required-before-execution",
                "source_checkout": "anonymous-ephemeral",
            },
        )
        self.assertEqual(
            contract["attestation"],
            {
                "driver_signature": "required-before-execution",
                "expiry": "required-before-execution",
                "revocation_check": "required-before-execution",
                "same_release_binding": "required-before-execution",
            },
        )
        self.assertEqual(
            contract["future_g5_artifact"],
            {
                "artifact_kind": "github-actions-artifact",
                "artifact_name": CANONICAL_G5_ARTIFACT,
                "required_test": ACTUAL_G5_TEST,
                "retrieval": "required-after-run",
            },
        )

    def test_contract_rejects_execution_retention_or_unsealed_runner_mutations(self) -> None:
        validator = self.load_validator()
        contract = self.checked_in_contract()
        if validator is None or contract is None:
            return
        mutations = (
            (("boundary", "execution_authorization"), "authorized"),
            (("boundary", "g5_result"), "passed"),
            (("driver", "execution"), "authorized"),
            (("driver", "credential_delivery"), "workflow-step-env"),
            (("runner", "kind"), "github-hosted"),
            (("runner", "secret_delivery"), "workflow-step-env"),
            (("attestation", "driver_signature"), "not-required"),
            (("isolation_contract", "secrets_retained"), True),
            (("network_contract", "payload_retained"), True),
        )
        for path, value in mutations:
            with self.subTest(path=path):
                altered = copy.deepcopy(contract)
                target = altered
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(validator.ExternalDriverPrerequisitesContractError):
                    validator.validate_contract(altered)

    def test_existing_protected_preflight_validates_prerequisites_without_driver_execution(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["environment"], ENVIRONMENT)
        self.assertEqual(job["permissions"], {})
        validation = self.named_step(job, "Validate external G5 driver prerequisites contract")
        self.assertIn(
            "/usr/bin/python3 -I scripts/ci/validate-floorp-notes-sync-g5-external-driver-admission-contract.py",
            validation["run"],
        )
        self.assertIn(
            "--contract scripts/ci/floorp-notes-sync-g5-external-driver-admission-contract.json",
            validation["run"],
        )
        serialized = json.dumps(validation, sort_keys=True).lower()
        for forbidden in (
            "secrets.",
            "github.token",
            "xcodebuild",
            "test-without-building",
            ACTUAL_G5_SELECTOR.lower(),
            "upload-artifact",
            CANONICAL_G5_ARTIFACT,
            "floorp_notes_sync_g5_run",
            "floorp_notes_sync_production_qa",
        ):
            self.assertNotIn(forbidden, serialized)

    def test_actual_selector_remains_unavailable_until_all_future_prerequisites_are_admitted(self) -> None:
        self.assertNotIn(ACTUAL_G5_SELECTOR, WORKFLOW.read_text(encoding="utf-8"))
        source = BUILD_CONTRACT.read_text(encoding="utf-8")
        for required in (
            "root-owned broker",
            "ephemeral runner",
            "driver admission attestation",
            "does not validate a driver admission attestation",
            "unconditionally skipped",
        ):
            self.assertIn(required, source)


if __name__ == "__main__":
    unittest.main()
