"""TDD contract for the compile-only Floorp Notes Sync G5 test product.

The route proves only that the protected XCTest can be built by normal CI.
It must not execute the selector, access accounts or Sync, accept credentials,
or publish something that could be mistaken for G5 evidence.
"""

from __future__ import annotations

import json
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
BUILD_CONTRACT = ROOT / "docs/floorp-notes-sync-build-contract.md"
PROJECT = ROOT / "firefox-ios/Client.xcodeproj/project.pbxproj"
SCHEME = ROOT / "firefox-ios/Client.xcodeproj/xcshareddata/xcschemes/FloorpNotesSyncG5.xcscheme"
TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpNotesSyncG5.xctestplan"
TEST_SOURCE = (
    ROOT
    / "firefox-ios/firefox-ios-tests/Tests/XCUITests/"
    "FloorpNotesSyncTwoClientMatrixTests.swift"
)
POLICY_SOURCE = (
    ROOT
    / "firefox-ios/firefox-ios-tests/Tests/XCUITests/"
    "FloorpNotesSyncG5LaunchPolicy.swift"
)
POLICY_TEST_SOURCE = (
    ROOT
    / "firefox-ios/firefox-ios-tests/Tests/XCUITests/"
    "FloorpNotesSyncG5LaunchPolicyTests.swift"
)
QA_TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpNotesSyncQA.xctestplan"
TEST_PLAN_DIRECTORY = ROOT / "firefox-ios/firefox-ios-tests/Tests"
RUBY = "/usr/bin/ruby"

XCUITESTS_TARGET_ID = "3BFE4B061D342FB800DDF53F"
G5_TEST = "FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix()"
QA_TEST = "FloorpNotesSyncProductionQAConfigurationTests/testReleaseBuildConfigurationIsExplicit()"
G5_BUILD_FILE_ID = "F20A20122F52000100000001"
G5_FILE_REFERENCE_ID = "F20A20132F52000100000001"
G5_POLICY_BUILD_FILE_ID = "F20A20222F52000100000001"
G5_POLICY_FILE_REFERENCE_ID = "F20A20232F52000100000001"
G5_POLICY_TEST_BUILD_FILE_ID = "F20A20322F52000100000001"
G5_POLICY_TEST_FILE_REFERENCE_ID = "F20A20332F52000100000001"
CANONICAL_G5_ARTIFACT = "floorp-notes-sync-two-client-xcresult"


class FloorpNotesSyncG5TestProductContractTests(unittest.TestCase):
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

    def test_scheme_uses_unsigned_floorp_release_and_dedicated_g5_plan(self) -> None:
        self.assertTrue(SCHEME.is_file(), "the G5 route needs a dedicated shared scheme")
        if not SCHEME.is_file():
            return
        tree = ET.parse(SCHEME)
        test_action = tree.getroot().find("TestAction")
        self.assertIsNotNone(test_action)
        assert test_action is not None
        self.assertEqual(test_action.attrib.get("buildConfiguration"), "FloorpRelease")
        self.assertEqual(
            [
                reference.attrib.get("reference")
                for reference in test_action.findall("./TestPlans/TestPlanReference")
            ],
            ["container:firefox-ios-tests/Tests/FloorpNotesSyncG5.xctestplan"],
        )
        self.assertIsNone(test_action.find("EnvironmentVariables"))
        self.assertNotIn("Fennec_Testing", SCHEME.read_text(encoding="utf-8"))

    def test_plan_selects_only_the_protected_g5_preflight(self) -> None:
        self.assertTrue(TEST_PLAN.is_file(), "the G5 route needs an isolated test plan")
        if not TEST_PLAN.is_file():
            return
        plan = json.loads(TEST_PLAN.read_text(encoding="utf-8"))
        self.assertEqual(plan["version"], 1)
        self.assertEqual(len(plan["configurations"]), 1)
        self.assertRegex(plan["configurations"][0]["id"], r"^[0-9A-F-]{36}$")
        self.assertEqual(plan["configurations"][0]["name"], "Floorp Notes Sync G5")
        self.assertEqual(plan["configurations"][0]["options"], {})
        self.assertEqual(plan["defaultOptions"], {"language": "en-US", "region": "US"})
        self.assertEqual(len(plan["testTargets"]), 1)
        target = plan["testTargets"][0]
        self.assertEqual(
            target["target"],
            {
                "containerPath": "container:Client.xcodeproj",
                "identifier": XCUITESTS_TARGET_ID,
                "name": "XCUITests",
            },
        )
        self.assertEqual(target["selectedTests"], [G5_TEST])

    def test_preflight_is_direct_xctest_and_has_no_operational_side_effect(self) -> None:
        self.assertTrue(TEST_SOURCE.is_file(), "the G5 selector must be an actual XCTest source")
        if not TEST_SOURCE.is_file():
            return
        source = TEST_SOURCE.read_text(encoding="utf-8")
        self.assertIn("final class FloorpNotesSyncTwoClientMatrixTests: XCTestCase", source)
        self.assertIn("func testTwoClientProductionMatrix()", source)
        self.assertIn(
            "FloorpNotesSyncG5LaunchPolicy.allows(environment: environment)",
            source,
        )
        self.assertNotIn('environment["FLOORP_NOTES_SYNC_G5_RUN"]', source)
        self.assertNotIn('environment["FLOORP_NOTES_SYNC_PRODUCTION_QA"]', source)
        self.assertNotIn('environment["FIREFOX_USE_STAGE_SERVER"]', source)
        for forbidden in (
            "BaseTestCase",
            "StageServer",
            "XCUIApplication",
            "URLSession",
            "XCTAttachment",
            "screenshot()",
            "debugDescription",
            "Logger",
            "NSLog",
            "print(",
            "PASSWORD",
            "TOKEN",
            "CREDENTIAL",
            "COORDINATOR",
        ):
            self.assertNotIn(forbidden, source)

    def test_non_live_launch_policy_is_pure_and_fail_closed(self) -> None:
        self.assertTrue(POLICY_SOURCE.is_file(), "the G5 selector needs a pure launch policy")
        if not POLICY_SOURCE.is_file():
            return
        source = POLICY_SOURCE.read_text(encoding="utf-8")
        self.assertIn("enum FloorpNotesSyncG5LaunchPolicy", source)
        self.assertIn("static func allows(environment: [String: String]) -> Bool", source)
        for required in (
            '"FLOORP_NOTES_SYNC_G5_RUN"',
            '"FLOORP_NOTES_SYNC_PRODUCTION_QA"',
            '"FIREFOX_USE_STAGE_SERVER"',
            '"CUSTOM_FXA_SERVER"',
            '"CUSTOM_SYNC_TOKEN_SERVER"',
            '"FIREFOX_USE_CHINA_SYNC_SERVICE"',
            '"FIREFOX_USE_CUSTOM_FXA_CONTENT_SERVER"',
            '"FIREFOX_USE_CUSTOM_SYNC_TOKEN_SERVER"',
        ):
            self.assertIn(required, source)
        for forbidden in (
            "ProcessInfo",
            "XCUIApplication",
            "BaseTestCase",
            "URLSession",
            "XCTAttachment",
            "screenshot()",
            "debugDescription",
            "Logger",
            "NSLog",
            "print(",
            "EMAIL",
            "PASSWORD",
            "CREDENTIAL",
            "SECRET",
        ):
            self.assertNotIn(forbidden, source)

    def test_launch_policy_has_direct_xctest_coverage(self) -> None:
        self.assertTrue(POLICY_TEST_SOURCE.is_file(), "the pure launch policy needs XCTest coverage")
        if not POLICY_TEST_SOURCE.is_file():
            return
        source = POLICY_TEST_SOURCE.read_text(encoding="utf-8")
        self.assertIn("final class FloorpNotesSyncG5LaunchPolicyTests: XCTestCase", source)
        self.assertIn("testAllowsExactlyTheTwoExplicitIntentFlags", source)
        self.assertIn("testRejectsEachNonProductionEndpointOverride", source)
        for forbidden in (
            "XCUIApplication",
            "BaseTestCase",
            "XCTAttachment",
            "screenshot()",
            "Logger",
            "NSLog",
            "print(",
            "EMAIL",
            "PASSWORD",
            "CREDENTIAL",
            "SECRET",
        ):
            self.assertNotIn(forbidden, source)

    def test_source_is_wired_into_the_existing_xcui_target(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        for build_file_id, filename in (
            (G5_BUILD_FILE_ID, "FloorpNotesSyncTwoClientMatrixTests.swift"),
            (G5_POLICY_BUILD_FILE_ID, "FloorpNotesSyncG5LaunchPolicy.swift"),
            (G5_POLICY_TEST_BUILD_FILE_ID, "FloorpNotesSyncG5LaunchPolicyTests.swift"),
        ):
            self.assertIn(f"{build_file_id} /* {filename} in Sources */", project)
            self.assertEqual(project.count(build_file_id), 2)
        for file_reference_id, filename in (
            (G5_FILE_REFERENCE_ID, "FloorpNotesSyncTwoClientMatrixTests.swift"),
            (G5_POLICY_FILE_REFERENCE_ID, "FloorpNotesSyncG5LaunchPolicy.swift"),
            (G5_POLICY_TEST_FILE_REFERENCE_ID, "FloorpNotesSyncG5LaunchPolicyTests.swift"),
        ):
            self.assertIn(f"{file_reference_id} /* {filename} */", project)
            self.assertEqual(project.count(file_reference_id), 3)

    def test_ordinary_unbounded_plans_explicitly_skip_the_protected_g5_selector(self) -> None:
        for plan_path in sorted(TEST_PLAN_DIRECTORY.glob("*.xctestplan")):
            if plan_path == TEST_PLAN:
                continue
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            for target in plan["testTargets"]:
                if target["target"].get("name") != "XCUITests":
                    continue
                if "selectedTests" not in target:
                    self.assertIn(
                        G5_TEST,
                        target.get("skippedTests", []),
                        f"{plan_path.name} could execute the protected G5 XCTest",
                    )

    def test_existing_production_qa_plan_remains_configuration_only(self) -> None:
        plan = json.loads(QA_TEST_PLAN.read_text(encoding="utf-8"))
        self.assertEqual(plan["testTargets"][0]["selectedTests"], [QA_TEST])
        self.assertNotIn(G5_TEST, plan["testTargets"][0]["selectedTests"])

    def test_primary_ci_compiles_but_cannot_execute_or_publish_the_route(self) -> None:
        compile_step = self.named_step(
            self.jobs["build-and-test"],
            "Compile release-disabled G5 XCTest route",
        )
        run = compile_step["run"]
        for expected in (
            "xcodebuild build-for-testing -quiet",
            "-project \"$PROJECT_PATH\"",
            "-scheme FloorpNotesSyncG5",
            "-configuration FloorpRelease",
            "-destination \"$DESTINATION\"",
            "-testPlan FloorpNotesSyncG5",
            "-only-testing:XCUITests/FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix",
            "-derivedDataPath \"$RUNNER_TEMP/G5RouteCompileDerivedData\"",
            "-clonedSourcePackagesDirPath \"$RUNNER_TEMP/SourcePackages\"",
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "-skipMacroValidation",
            "-parallel-testing-enabled NO",
            "CODE_SIGN_IDENTITY=",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGNING_ALLOWED=NO",
        ):
            self.assertIn(expected, run)

        serialized = json.dumps(compile_step, sort_keys=True).lower()
        for forbidden in (
            "test-without-building",
            "floorp_notes_sync_g5_run",
            "floorp_notes_sync_production_qa",
            "firefox_use_stage_server",
            "custom_fxa_server",
            "secrets.",
            "environment",
            "uses",
            "resultbundlepath",
            "upload-artifact",
            "curl ",
            "gh api",
        ):
            self.assertNotIn(forbidden, serialized)

    def test_primary_ci_time_budget_covers_compile_only_route_and_unit_tests(self) -> None:
        job = self.jobs["build-and-test"]
        self.assertEqual(job["timeout-minutes"], 120)
        self.assertEqual(
            self.named_step(job, "Run unit tests")["timeout-minutes"],
            30,
        )

    def test_primary_ci_job_cannot_confuse_compile_output_with_g5_evidence(self) -> None:
        serialized = json.dumps(self.jobs["build-and-test"], sort_keys=True).lower()
        self.assertNotIn("floorp-notes-sync-production-qa", serialized)
        self.assertNotIn(CANONICAL_G5_ARTIFACT, serialized)
        self.assertNotIn("run_g5_", serialized)

    def test_build_contract_excludes_compile_only_results_from_g5_evidence(self) -> None:
        source = BUILD_CONTRACT.read_text(encoding="utf-8")
        self.assertIn("Ordinary PR/main CI compiles", source)
        self.assertIn("without executing its protected selector", source)
        self.assertIn("cannot satisfy G5 evidence", source)
        self.assertRegex(source, r"external driver is\s+the coordinator")
        self.assertIn("metadata-only participant", source)
        self.assertIn("must not carry credentials", source)
        self.assertIn("or retain attachments", source)

    def test_all_actions_in_primary_ci_remain_pinned(self) -> None:
        serialized = json.dumps(self.jobs["build-and-test"], sort_keys=True)
        uses = re.findall(r'"uses": "([^"]+)"', serialized)
        self.assertTrue(uses)
        self.assertTrue(all(re.search(r"@[0-9a-f]{40}$", item) for item in uses))


if __name__ == "__main__":
    unittest.main()
