"""Contract tests for the protected Todo 20 XCTest product."""

from __future__ import annotations

import json
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/floorp-notes-sync-production-qa.yml"
BUILD_CONTRACT = ROOT / "docs/floorp-notes-sync-build-contract.md"
PROJECT = ROOT / "firefox-ios/Client.xcodeproj/project.pbxproj"
SCHEME = ROOT / "firefox-ios/Client.xcodeproj/xcshareddata/xcschemes/FloorpNotesSyncG5.xcscheme"
TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpNotesSyncG5.xctestplan"
TEST_SOURCE = ROOT / "firefox-ios/firefox-ios-tests/Tests/XCUITests/FloorpNotesSyncTwoClientMatrixTests.swift"
ACTUAL_TEST_SOURCE = ROOT / "firefox-ios/firefox-ios-tests/Tests/XCUITests/FloorpNotesSyncActualG5TwoClientTests.swift"
POLICY_SOURCE = ROOT / "firefox-ios/firefox-ios-tests/Tests/XCUITests/FloorpNotesSyncG5LaunchPolicy.swift"
POLICY_TEST_SOURCE = ROOT / "firefox-ios/firefox-ios-tests/Tests/XCUITests/FloorpNotesSyncG5LaunchPolicyTests.swift"
QA_TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpNotesSyncQA.xctestplan"
TEST_PLAN_DIRECTORY = ROOT / "firefox-ios/firefox-ios-tests/Tests"
RUBY = "/usr/bin/ruby"

XCUITESTS_TARGET_ID = "3BFE4B061D342FB800DDF53F"
STATIC_G5_TEST = "FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix()"
STATIC_G5_SELECTOR = "XCUITests/FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix"
ACTUAL_G5_TEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"
ACTUAL_G5_SELECTOR = "XCUITests/FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix"
QA_TEST = "FloorpNotesSyncProductionQAConfigurationTests/testReleaseBuildConfigurationIsExplicit()"
G5_BUILD_FILE_ID = "F20A20122F52000100000001"
G5_FILE_REFERENCE_ID = "F20A20132F52000100000001"
G5_POLICY_BUILD_FILE_ID = "F20A20222F52000100000001"
G5_POLICY_FILE_REFERENCE_ID = "F20A20232F52000100000001"
G5_POLICY_TEST_BUILD_FILE_ID = "F20A20322F52000100000001"
G5_POLICY_TEST_FILE_REFERENCE_ID = "F20A20332F52000100000001"
ACTUAL_G5_BUILD_FILE_ID = "F20A20422F52000100000001"
ACTUAL_G5_FILE_REFERENCE_ID = "F20A20432F52000100000001"


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

    def test_scheme_uses_unsigned_floorp_release_and_qa_plan(self) -> None:
        tree = ET.parse(SCHEME)
        test_action = tree.getroot().find("TestAction")
        self.assertIsNotNone(test_action)
        assert test_action is not None
        self.assertEqual(test_action.attrib.get("buildConfiguration"), "FloorpRelease")
        self.assertEqual(
            [reference.attrib.get("reference") for reference in test_action.findall("./TestPlans/TestPlanReference")],
            ["container:firefox-ios-tests/Tests/FloorpNotesSyncG5.xctestplan"],
        )
        self.assertNotIn("Fennec_Testing", SCHEME.read_text(encoding="utf-8"))

    def test_production_qa_plan_selects_actual_matrix(self) -> None:
        plan = json.loads(TEST_PLAN.read_text(encoding="utf-8"))
        target = plan["testTargets"][0]
        self.assertEqual(target["target"]["identifier"], XCUITESTS_TARGET_ID)
        self.assertEqual(target["selectedTests"], [ACTUAL_G5_TEST])
        self.assertNotIn(STATIC_G5_TEST, target["selectedTests"])

    def test_actual_selector_drives_metadata_only_coordination_and_never_attachments(self) -> None:
        source = ACTUAL_TEST_SOURCE.read_text(encoding="utf-8")
        self.assertIn("ProcessInfo.processInfo.environment", source)
        self.assertIn("FLOORP_NOTES_SYNC_COORDINATION_ROOT", source)
        self.assertIn("MetadataCoordination", source)
        self.assertIn("FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL", source)
        for forbidden in (
            "URLSession",
            "XCTAttachment",
            "screenshot()",
            "Logger",
            "NSLog",
            "print(",
        ):
            self.assertNotIn(forbidden, source)

    def test_static_preflight_remains_non_live_and_separate(self) -> None:
        source = TEST_SOURCE.read_text(encoding="utf-8")
        self.assertIn("FloorpNotesSyncG5LaunchPolicy.allows(environment: environment)", source)
        self.assertNotIn(ACTUAL_G5_TEST, source)
        for forbidden in (
            "XCUIApplication",
            "URLSession",
            "XCTAttachment",
            "PASSWORD",
            "TOKEN",
            "CREDENTIAL",
        ):
            self.assertNotIn(forbidden, source)

    def test_launch_policy_rejects_non_production_endpoint_overrides(self) -> None:
        source = POLICY_SOURCE.read_text(encoding="utf-8")
        for required in (
            '"FIREFOX_USE_STAGE_SERVER"',
            '"CUSTOM_FXA_SERVER"',
            '"CUSTOM_SYNC_TOKEN_SERVER"',
            '"FIREFOX_USE_CHINA_SYNC_SERVICE"',
            '"FIREFOX_USE_CUSTOM_FXA_CONTENT_SERVER"',
        ):
            self.assertIn(required, source)
        self.assertNotIn("URLSession", source)
        self.assertNotIn("PASSWORD", source)

    def test_source_is_wired_into_the_existing_xcui_target(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        for build_file_id, filename in (
            (G5_BUILD_FILE_ID, "FloorpNotesSyncTwoClientMatrixTests.swift"),
            (G5_POLICY_BUILD_FILE_ID, "FloorpNotesSyncG5LaunchPolicy.swift"),
            (G5_POLICY_TEST_BUILD_FILE_ID, "FloorpNotesSyncG5LaunchPolicyTests.swift"),
            (ACTUAL_G5_BUILD_FILE_ID, "FloorpNotesSyncActualG5TwoClientTests.swift"),
        ):
            self.assertIn(f"{build_file_id} /* {filename} in Sources */", project)
            self.assertEqual(project.count(build_file_id), 2)
        for file_reference_id, filename in (
            (G5_FILE_REFERENCE_ID, "FloorpNotesSyncTwoClientMatrixTests.swift"),
            (G5_POLICY_FILE_REFERENCE_ID, "FloorpNotesSyncG5LaunchPolicy.swift"),
            (G5_POLICY_TEST_FILE_REFERENCE_ID, "FloorpNotesSyncG5LaunchPolicyTests.swift"),
            (ACTUAL_G5_FILE_REFERENCE_ID, "FloorpNotesSyncActualG5TwoClientTests.swift"),
        ):
            self.assertIn(f"{file_reference_id} /* {filename} */", project)
            self.assertEqual(project.count(file_reference_id), 3)

    def test_ordinary_unbounded_plans_cannot_execute_actual_matrix(self) -> None:
        for plan_path in sorted(TEST_PLAN_DIRECTORY.glob("*.xctestplan")):
            if plan_path == TEST_PLAN:
                continue
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            for target in plan["testTargets"]:
                if target["target"].get("name") != "XCUITests":
                    continue
                self.assertNotIn(ACTUAL_G5_TEST, target.get("selectedTests", []))
                if "selectedTests" not in target:
                    self.assertIn(ACTUAL_G5_TEST, target.get("skippedTests", []))

    def test_existing_configuration_qa_plan_remains_separate(self) -> None:
        plan = json.loads(QA_TEST_PLAN.read_text(encoding="utf-8"))
        self.assertEqual(plan["testTargets"][0]["selectedTests"], [QA_TEST])
        self.assertNotIn(ACTUAL_G5_TEST, plan["testTargets"][0]["selectedTests"])

    def test_production_qa_job_runs_only_after_protected_manual_dispatch(self) -> None:
        job = self.jobs["notes-sync-production-qa"]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["environment"], "floorp-notes-sync-production-qa")
        self.assertEqual(
            " ".join(job["if"].split()),
            "github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main' && "
            "inputs.run_floorp_notes_sync_production_qa == true && "
            "inputs.run_floorp_notes_sync_production_enablement_waived != true",
        )
        serialized = json.dumps(job, sort_keys=True).lower()
        self.assertNotIn("external-driver", serialized)
        self.assertNotIn("root-owned-broker", serialized)
        self.assertNotIn("dedicated-g5-runner", serialized)
        self.assertNotIn("app store", serialized)
        self.assertNotIn("testflight", serialized)

    def test_build_contract_records_proportional_todo20_boundary(self) -> None:
        source = BUILD_CONTRACT.read_text(encoding="utf-8")
        self.assertIn("single-operator-protected-qa", source)
        self.assertIn("metadata-only", source)
        self.assertIn("no direct REST", source)
        self.assertIn("App Store", source)
        self.assertIn("G6 and broker requirements are not Todo 20 gates", source)


if __name__ == "__main__":
    unittest.main()
