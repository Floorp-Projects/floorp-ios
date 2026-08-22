"""TDD contract for the manual, compile-only Notes Sync preflight.

The job is an Environment-bound scheduling preflight only.  It must never
execute the protected selector, handle credentials, or produce G5 evidence.
"""

from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/floorp-notes-sync-production-qa.yml"
NORMAL_WORKFLOW = ROOT / ".github/workflows/ci.yml"
UPSTREAM_SYNC_WORKFLOW = ROOT / ".github/workflows/upstream-sync.yml"
BUILD_CONTRACT = ROOT / "docs/floorp-notes-sync-build-contract.md"
RELEASE_CONFIG = ROOT / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
RUBY = "/usr/bin/ruby"

DISPATCH_INPUT = "run_floorp_notes_sync_protected_preflight"
OPERATION_CONTRACT_INPUT = "prepare_floorp_notes_sync_g5_contract"
PRODUCTION_QA_INPUT = "run_floorp_notes_sync_production_qa"
ENABLEMENT_INPUT = "run_floorp_notes_sync_production_enablement"
GUARDED_MERGE_INPUT = "run_floorp_notes_sync_guarded_merge"
RECOVERY_INPUT = "run_floorp_notes_sync_merge_audit_recovery"
WAIVED_ENABLEMENT_INPUT = "run_floorp_notes_sync_production_enablement_waived"
JOB_ID = "notes-sync-protected-preflight"
ENVIRONMENT = "floorp-notes-sync-production-qa"
STATIC_G5_SELECTOR = "XCUITests/FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix"
ACTUAL_G5_SELECTOR = (
    "XCUITests/FloorpNotesSyncActualG5TwoClientTests/"
    "testActualG5TwoClientProductionMatrix"
)


class FloorpNotesSyncProtectedPreflightContractTests(unittest.TestCase):
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
            raise AssertionError(f"failed to parse Notes Sync workflow: {result.stderr}")
        cls.workflow: dict[str, Any] = json.loads(result.stdout)
        # Ruby's YAML loader follows YAML 1.1 and parses the unquoted GitHub
        # key `on` as true. JSON object keys are strings, so it becomes
        # `"true"` in the serialized view used by this contract test.
        cls.dispatch: dict[str, Any] = cls.workflow["true"]["workflow_dispatch"]
        cls.jobs: dict[str, Any] = cls.workflow["jobs"]

    @staticmethod
    def named_step(job: dict[str, Any], name: str) -> dict[str, Any]:
        for step in job["steps"]:
            if step.get("name") == name:
                return step
        raise AssertionError(f"missing step: {name}")

    def test_dispatch_adds_an_optional_false_by_default_boolean_opt_in(self) -> None:
        self.assertEqual(
            set(self.dispatch["inputs"]),
            {
                DISPATCH_INPUT,
                OPERATION_CONTRACT_INPUT,
                PRODUCTION_QA_INPUT,
                ENABLEMENT_INPUT,
                GUARDED_MERGE_INPUT,
                RECOVERY_INPUT,
                WAIVED_ENABLEMENT_INPUT,
            },
        )
        for input_name in (
            DISPATCH_INPUT,
            OPERATION_CONTRACT_INPUT,
            PRODUCTION_QA_INPUT,
            ENABLEMENT_INPUT,
            GUARDED_MERGE_INPUT,
            RECOVERY_INPUT,
            WAIVED_ENABLEMENT_INPUT,
        ):
            option = self.dispatch["inputs"][input_name]
            self.assertEqual(option["type"], "boolean")
            self.assertIs(option["required"], False)
            self.assertIs(option["default"], False)

    def test_inputless_upstream_ci_dispatch_remains_compatible(self) -> None:
        source = UPSTREAM_SYNC_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("actions/workflows/ci.yml/dispatches", source)
        self.assertIn('--data "{\\"ref\\":\\"${SYNC_BRANCH}\\"}"', source)

    def test_job_is_manual_main_only_and_environment_bound(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["timeout-minutes"], 90)
        self.assertEqual(job["environment"], ENVIRONMENT)
        self.assertEqual(
            " ".join(job["if"].split()).replace("( ", "(").replace(" )", ")"),
            "github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main' && "
            f"inputs.{DISPATCH_INPUT} == true && "
            f"inputs.{OPERATION_CONTRACT_INPUT} != true && "
            f"inputs.{PRODUCTION_QA_INPUT} != true && "
            f"inputs.{ENABLEMENT_INPUT} != true && "
            f"inputs.{GUARDED_MERGE_INPUT} != true && "
            f"inputs.{RECOVERY_INPUT} != true && "
            f"inputs.{WAIVED_ENABLEMENT_INPUT} != true",
        )
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})

    def test_manual_preflight_is_separate_from_normal_ci(self) -> None:
        normal_ci = NORMAL_WORKFLOW.read_text(encoding="utf-8")
        for forbidden in (
            "run_floorp_notes_sync_",
            "notes-sync-production-qa:",
            "FloorpNotesSyncG5",
            "release-disabled-wrapper:",
        ):
            self.assertNotIn(forbidden, normal_ci)
    def test_manual_preflight_has_a_unique_non_cancelling_workflow_slot(self) -> None:
        concurrency = self.workflow["concurrency"]
        self.assertIn("github.run_id", concurrency["group"])
        self.assertIn(DISPATCH_INPUT, concurrency["group"])
        self.assertIn(OPERATION_CONTRACT_INPUT, concurrency["group"])
        self.assertIn(RECOVERY_INPUT, concurrency["group"])
        self.assertIn(WAIVED_ENABLEMENT_INPUT, concurrency["group"])
        self.assertEqual(
            " ".join(concurrency["cancel-in-progress"].split())
            .replace("( ", "(")
            .replace(" )", ")"),
            "${{ github.event_name != 'workflow_dispatch' || ("
            f"inputs.{DISPATCH_INPUT} != true && "
            f"inputs.{OPERATION_CONTRACT_INPUT} != true && "
            f"inputs.{PRODUCTION_QA_INPUT} != true && "
            f"inputs.{ENABLEMENT_INPUT} != true && "
            f"inputs.{GUARDED_MERGE_INPUT} != true && "
            f"inputs.{RECOVERY_INPUT} != true && "
            f"inputs.{WAIVED_ENABLEMENT_INPUT} != true)" + " }}",
        )

    def test_waived_enablement_job_condition_is_satisfiable(self) -> None:
        job = self.jobs["notes-sync-production-enablement-waived"]
        condition = " ".join(job["if"].split())
        self.assertIn(f"inputs.{WAIVED_ENABLEMENT_INPUT} == true", condition)
        self.assertNotIn(f"inputs.{WAIVED_ENABLEMENT_INPUT} != true", condition)
        self.assertIn("github.ref == 'refs/heads/main'", condition)

    def test_job_shape_steps_and_xcode_commands_are_allowlisted(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(
            set(job),
            {
                "name",
                "if",
                "environment",
                "permissions",
                "env",
                "runs-on",
                "timeout-minutes",
                "steps",
            },
        )
        self.assertNotIn("needs", job)
        self.assertEqual(
            [step["name"] for step in job["steps"]],
            [
                "Check out source anonymously",
                "Set up Node.js",
                "Select Xcode",
                "Bootstrap generated sources",
                "Resolve Swift packages",
                "Prepare iOS Simulator",
                "Compile protected G5 XCTest route",
            ],
        )

        runs = "\n".join(
            step["run"] for step in job["steps"] if "run" in step
        )
        self.assertEqual(runs.count("xcodebuild"), 3)
        for expected in (
            "xcodebuild -version",
            "xcodebuild -resolvePackageDependencies",
            "xcodebuild build-for-testing -quiet",
        ):
            self.assertIn(expected, runs)
        self.assertNotRegex(runs, r"\bxcodebuild\s+test(?:\s|$)")

    def test_job_uses_no_github_token_or_authenticated_source_checkout(self) -> None:
        job = self.jobs[JOB_ID]
        self.assertEqual(job["permissions"], {})
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

        checkout = self.named_step(job, "Check out source anonymously")
        self.assertNotIn("uses", checkout)
        self.assertIn("https://github.com/${GITHUB_REPOSITORY}.git", checkout["run"])
        for expected in (
            "credential.helper=",
            "http.https://github.com/.extraheader=",
            "GITHUB_SHA",
        ):
            self.assertIn(expected, checkout["run"])

        setup_node = self.named_step(job, "Set up Node.js")
        self.assertRegex(setup_node["uses"], r"@[0-9a-f]{40}$")
        self.assertEqual(
            setup_node["with"],
            {
                "node-version-file": ".nvmrc",
                "token": "",
                "package-manager-cache": False,
            },
        )

    def test_job_builds_only_the_unsigned_guard_selector(self) -> None:
        job = self.jobs[JOB_ID]
        setup_node = self.named_step(job, "Set up Node.js")
        self.assertRegex(setup_node["uses"], r"@[0-9a-f]{40}$")
        self.assertEqual(
            self.named_step(job, "Bootstrap generated sources")["env"], {"CI": "true"}
        )

        compile_step = self.named_step(job, "Compile protected G5 XCTest route")
        run = compile_step["run"]
        for expected in (
            "xcodebuild build-for-testing -quiet",
            '-project "$PROJECT_PATH"',
            "-scheme FloorpNotesSyncG5",
            "-configuration FloorpRelease",
            '-destination "$DESTINATION"',
            "-testPlan FloorpNotesSyncG5",
            f"-only-testing:{STATIC_G5_SELECTOR}",
            '-derivedDataPath "$RUNNER_TEMP/ProtectedG5PreflightDerivedData"',
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
        self.assertNotIn(f"-only-testing:{ACTUAL_G5_SELECTOR}", run)

    def test_job_cannot_execute_or_publish_g5(self) -> None:
        serialized = json.dumps(self.jobs[JOB_ID], sort_keys=True).lower()
        for forbidden in (
            "test-without-building",
            "floorp_notes_sync_g5_run",
            "firefox_use_stage_server",
            "custom_fxa",
            "custom_token",
            "secrets.",
            "github.token",
            "upload-artifact",
            "resultbundlepath",
            "floorp-notes-sync-two-client-xcresult",
            "g5_completed",
            "validation-clock",
            "validate-floorp-notes-sync-release.py",
            "assemble-floorp-notes-sync",
            "build-floorp-notes-sync-ios.sh",
            "run-floorp-notes-sync-matrix.sh",
            "-xcconfig",
            "--allow-signing",
            "allowprovisioningupdates",
            "curl ",
            "gh api",
            "archive",
            "exportarchive",
        ):
            self.assertNotIn(forbidden, serialized)
        self.assertIsNone(re.search(r"\bxcodebuild\s+test(?:\s|$)", serialized))

    def test_docs_and_release_defaults_preserve_the_evidence_boundary(self) -> None:
        contract = BUILD_CONTRACT.read_text(encoding="utf-8")
        for expected in (
            "protected manual preflight",
            "does not execute the selector",
            "does not authorize G5",
            "cannot satisfy G5 evidence",
            "anonymous source checkout",
            "pass a GitHub token to checkout, setup, cache, shell, or tool calls",
            "makes no nonissuance claim",
            "does not reference that context",
        ):
            self.assertIn(expected, contract)

        release = RELEASE_CONFIG.read_text(encoding="utf-8")
        self.assertIn("FLOORP_NOTES_SYNC_BUILD_MODE = release-default", release)
        self.assertIn("FLOORP_NOTES_SYNC_REQUESTED = YES", release)
        self.assertIn("FLOORP_NOTES_SYNC_EFFECTIVE = YES", release)
        self.assertIn("FLOORP_NOTES_SYNC_ENDPOINT_AUTHORITY = production", release)
        self.assertIn("FLOORP_NOTES_SYNC_PROTOCOL = sync15", release)


if __name__ == "__main__":
    unittest.main()
