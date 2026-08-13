"""TDD contract for the non-live Notes Sync G5 operation preflight.

This contract is intentionally a scheduling and compilation boundary only.
It cannot authorize or execute a production Sync matrix.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import re
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

DISPATCH_INPUT = "prepare_floorp_notes_sync_g5_contract"
PROTECTED_PREFLIGHT_INPUT = "run_floorp_notes_sync_protected_preflight"
JOB_ID = "notes-sync-g5-operation-contract-preflight"
ENVIRONMENT = "floorp-notes-sync-production-qa"
G5_SELECTOR = "XCUITests/FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix"
CANONICAL_G5_ARTIFACT = "floorp-notes-sync-two-client-xcresult"
G5_TEST = "FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix()"


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_g5_operation_contract_validator_test",
        VALIDATOR,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the non-live G5 operation-contract validator")
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
        # Ruby YAML 1.1 serializes the unquoted GitHub key `on` as `"true"`.
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

    def test_checked_in_contract_is_canonical_and_explicitly_non_live(self) -> None:
        decision = OPERATION_CONTRACT.load_and_validate_contract(CONTRACT)

        self.assertEqual(
            decision,
            {
                "credential_delivery": "protected-environment-only",
                "execution_authorization": "not-authorized",
                "g5_result": "not-assessed",
                "status": "operation-contract-valid",
            },
        )

    def test_contract_binds_the_canonical_future_g5_protocol(self) -> None:
        contract = self.checked_in_contract()
        self.assertEqual(
            contract["workflow"],
            {
                "dispatch_input": DISPATCH_INPUT,
                "event": "workflow_dispatch",
                "head_branch": "main",
                "path": ".github/workflows/ci.yml",
            },
        )
        self.assertEqual(
            contract["future_g5_artifact"],
            {
                "artifact_kind": "github-actions-artifact",
                "artifact_name": CANONICAL_G5_ARTIFACT,
                "required_test": G5_TEST,
                "retrieval": "required-after-run",
            },
        )

    def test_contract_rejects_credential_authorization_and_g5_claims(self) -> None:
        mutations = (
            (("boundary", "credential_delivery"), "workflow-input", "credential delivery"),
            (("boundary", "execution_authorization"), "authorized", "authorization"),
            (("boundary", "g5_result"), "passed", "G5 result"),
            (("future_g5_artifact", "artifact_name"), "other-xcresult", "artifact"),
        )
        for path, value, label in mutations:
            with self.subTest(label=label):
                contract = self.checked_in_contract()
                target = contract
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
                    OPERATION_CONTRACT.validate_operation_contract(contract)

    def test_contract_rejects_non_metadata_tls_and_missing_cleanup_obligations(self) -> None:
        mutations = (
            (("network_contract", "metadata_only"), False, "metadata-only TLS"),
            (("network_contract", "tls_interception"), True, "TLS interception"),
            (("network_contract", "hosts"), ["accounts.firefox.com"], "missing Sync host"),
            (("isolation_contract", "cleanup_required"), False, "cleanup"),
            (("isolation_contract", "rollback_required"), False, "rollback"),
            (("isolation_contract", "local_only_fallback_required"), False, "fallback"),
        )
        for path, value, label in mutations:
            with self.subTest(label=label):
                contract = self.checked_in_contract()
                target = contract
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
                    OPERATION_CONTRACT.validate_operation_contract(contract)

    def test_contract_rejects_duplicate_or_noncanonical_json(self) -> None:
        raw = CONTRACT.read_bytes()
        duplicate = raw.replace(
            b'"schema_version":1',
            b'"schema_version":1,"schema_version":1',
            1,
        )
        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(duplicate)

        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(raw + b" ")

        with self.assertRaises(OPERATION_CONTRACT.OperationContractError):
            OPERATION_CONTRACT.parse_contract_bytes(
                raw.replace(b'"schema_version":1', b'"schema_version":1.0', 1)
            )

    def test_dispatch_input_is_false_by_default_and_keeps_normal_ci_isolated(self) -> None:
        self.assertEqual(
            set(self.dispatch["inputs"]),
            {PROTECTED_PREFLIGHT_INPUT, DISPATCH_INPUT},
        )
        option = self.dispatch["inputs"][DISPATCH_INPUT]
        self.assertEqual(option["type"], "boolean")
        self.assertIs(option["required"], False)
        self.assertIs(option["default"], False)

        expected_skip = (
            "github.event_name != 'workflow_dispatch' || ("
            f"inputs.{PROTECTED_PREFLIGHT_INPUT} != true && "
            f"inputs.{DISPATCH_INPUT} != true)"
        )
        for job_id in ("workflow-lint", "build-and-test", "release-disabled-wrapper"):
            self.assertEqual(
                " ".join(self.jobs[job_id]["if"].split())
                .replace("( ", "(")
                .replace(" )", ")"),
                expected_skip,
            )

    def test_job_is_manual_main_only_environment_bound_and_tokenless(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["environment"], ENVIRONMENT)
        self.assertEqual(job["permissions"], {})
        self.assertEqual(
            " ".join(job["if"].split()),
            "github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main' && "
            f"inputs.{DISPATCH_INPUT} == true && "
            f"inputs.{PROTECTED_PREFLIGHT_INPUT} != true",
        )
        self.assertEqual(
            job["env"],
            {
                "GITHUB_TOKEN": "",
                "GH_TOKEN": "",
                "NODE_AUTH_TOKEN": "",
                "NPM_TOKEN": "",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_ASKPASS": "/usr/bin/false",
            },
        )

    def test_job_validates_then_compiles_only_the_existing_selector(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(
            [step["name"] for step in job["steps"]],
            [
                "Check out source anonymously",
                "Set up Node.js",
                "Validate non-live G5 operation contract",
                "Select Xcode",
                "Bootstrap generated sources",
                "Resolve Swift packages",
                "Compile non-live G5 XCTest route",
            ],
        )

        validation = self.named_step(job, "Validate non-live G5 operation contract")["run"]
        self.assertIn(
            "/usr/bin/python3 -I scripts/ci/validate-floorp-notes-sync-g5-operation-contract.py",
            validation,
        )
        self.assertIn(
            "--contract scripts/ci/floorp-notes-sync-g5-operation-contract.json",
            validation,
        )

        compile_step = self.named_step(job, "Compile non-live G5 XCTest route")
        run = compile_step["run"]
        for expected in (
            "xcodebuild build-for-testing -quiet",
            '-project "$PROJECT_PATH"',
            "-scheme FloorpNotesSyncG5",
            "-configuration FloorpRelease",
            "-destination 'generic/platform=iOS Simulator'",
            "-testPlan FloorpNotesSyncG5",
            f"-only-testing:{G5_SELECTOR}",
            '-derivedDataPath "$RUNNER_TEMP/OperationContractG5CompileDerivedData"',
            '-clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages"',
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "-skipMacroValidation",
            "-parallel-testing-enabled NO",
            "CODE_SIGN_IDENTITY=",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGNING_ALLOWED=NO",
        ):
            self.assertIn(expected, run)

        serialized = json.dumps(job, sort_keys=True).lower()
        for forbidden in (
            "xcodebuild test",
            "test-without-building",
            "floorp_notes_sync_g5_run",
            "floorp_notes_sync_production_qa",
            "firefox_use_stage_server",
            "custom_fxa",
            "secrets.",
            "github.token",
            "upload-artifact",
            "resultbundlepath",
            CANONICAL_G5_ARTIFACT,
            "simctl",
            "curl ",
            "gh api",
        ):
            self.assertNotIn(forbidden, serialized)
        self.assertIsNone(re.search(r"\bxcodebuild\s+test(?:\s|$)", serialized))


if __name__ == "__main__":
    unittest.main()
