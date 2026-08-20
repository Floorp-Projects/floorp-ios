"""Regression tests proving the PR #104 bridge is historical, not a gate."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/floorp-notes-sync-production-qa.yml"
CONTRACT = ROOT / "scripts/ci/floorp-notes-sync-g5-external-driver-admission-contract.json"
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-g5-external-driver-admission-contract.py"
BUILD_CONTRACT = ROOT / "docs/floorp-notes-sync-build-contract.md"
RUBY = "/usr/bin/ruby"
LEGACY_DISPATCH_INPUT = "prepare_floorp_notes_sync_g5_contract"
QA_JOB_ID = "notes-sync-production-qa"
ENVIRONMENT = "floorp-notes-sync-production-qa"
ACTUAL_G5_SELECTOR = "XCUITests/FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix"
ACTUAL_G5_TEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"


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

    @staticmethod
    def named_step(job: dict[str, Any], name: str) -> dict[str, Any]:
        for step in job["steps"]:
            if step.get("name") == name:
                return step
        raise AssertionError(f"missing step: {name}")

    def load_legacy_validator(self) -> Any:
        self.assertTrue(VALIDATOR.is_file())
        specification = importlib.util.spec_from_file_location(
            "floorp_notes_sync_legacy_driver_contract_validator_test",
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

    def test_legacy_contract_remains_parseable_but_is_not_an_active_acceptance_gate(self) -> None:
        validator = self.load_legacy_validator()
        decision = validator.load_and_validate_contract(CONTRACT)
        self.assertEqual(decision["status"], "external-driver-prerequisites-contract-valid")
        serialized_workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("validate-floorp-notes-sync-g5-external-driver-admission-contract.py", serialized_workflow)
        self.assertNotIn("root-owned-broker", serialized_workflow)

    def test_legacy_parser_still_rejects_duplicate_and_noncanonical_bytes(self) -> None:
        validator = self.load_legacy_validator()
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

    def test_legacy_loader_rejects_copies_and_symlinks(self) -> None:
        validator = self.load_legacy_validator()
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

    def test_current_production_qa_job_owns_actual_matrix_without_legacy_driver_step(self) -> None:
        job = self.jobs[QA_JOB_ID]
        self.assertEqual(job["environment"], ENVIRONMENT)
        serialized = json.dumps(job, sort_keys=True).lower()
        self.assertIn("run-floorp-notes-sync-production-qa.py", serialized)
        self.assertIn("floorp_notes_sync_account_a_email", serialized)
        self.assertIn("floorp_notes_sync_account_b_password", serialized)
        self.assertNotIn("external-driver", serialized)
        self.assertNotIn("root-owned-broker", serialized)
        self.assertNotIn("dedicated-g5-runner", serialized)

    def test_build_contract_overlay_redefines_the_old_text(self) -> None:
        source = BUILD_CONTRACT.read_text(encoding="utf-8")
        self.assertIn("Formal Todo 20 rescope boundary", source)
        self.assertIn("G6 and broker requirements are not Todo 20 gates", source)
        self.assertIn("single-operator-protected-qa", source)
        self.assertIn("existing FxA", source)
        self.assertIn(ACTUAL_G5_TEST, source)


if __name__ == "__main__":
    unittest.main()
