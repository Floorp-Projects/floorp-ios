"""Contract tests for the isolated Floorp Notes production-QA XCUITest route.

This route is intentionally separate from the normal Fennec_Testing UI suite.
It prepares a release-configuration test target for a manually authorized
production-QA run; it is not G5 evidence and it must not run on PR/push CI.
"""

from __future__ import annotations

import json
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "firefox-ios/Client.xcodeproj/project.pbxproj"
SCHEME = ROOT / "firefox-ios/Client.xcodeproj/xcshareddata/xcschemes/FloorpNotesSyncQA.xcscheme"
TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpNotesSyncQA.xctestplan"
TEST_SOURCE = (
    ROOT
    / "firefox-ios/firefox-ios-tests/Tests/XCUITests/"
    "FloorpNotesSyncProductionQAConfigurationTests.swift"
)
TEST_PLAN_DIRECTORY = ROOT / "firefox-ios/firefox-ios-tests/Tests"

XCUITESTS_TARGET_ID = "3BFE4B061D342FB800DDF53F"
XCUITESTS_CONFIGURATION_LIST_ID = "3BFE4B201D342FB900DDF53F"
PRODUCTION_QA_TEST = (
    "FloorpNotesSyncProductionQAConfigurationTests/"
    "testReleaseBuildConfigurationIsExplicit()"
)
FLOORP_RELEASE_CONFIGURATION_ID = "F20A20012F52000100000001"
FLOORP_RELEASE_BUILD_FILE_ID = "F20A20022F52000100000001"
FLOORP_RELEASE_FILE_REFERENCE_ID = "F20A20032F52000100000001"


class FloorpNotesSyncProductionQaXCTestContractTests(unittest.TestCase):
    def test_scheme_uses_release_configuration_and_dedicated_plan(self):
        tree = ET.parse(SCHEME)
        root = tree.getroot()
        test_action = root.find("TestAction")
        self.assertIsNotNone(test_action)
        assert test_action is not None
        self.assertEqual(test_action.attrib.get("buildConfiguration"), "FloorpRelease")
        self.assertEqual(
            [reference.attrib.get("reference") for reference in test_action.findall("./TestPlans/TestPlanReference")],
            ["container:firefox-ios-tests/Tests/FloorpNotesSyncQA.xctestplan"],
        )
        self.assertNotIn("Fennec_Testing", SCHEME.read_text())

    def test_plan_selects_only_the_explicit_production_qa_configuration_test(self):
        plan = json.loads(TEST_PLAN.read_text())
        self.assertEqual(plan["version"], 1)
        self.assertEqual(
            plan["configurations"],
            [
                {
                    "id": "6E68F7F9-92AB-48FE-8013-4A33A6B2E023",
                    "name": "Floorp Notes Sync QA",
                    "options": {},
                }
            ],
        )
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
        self.assertEqual(target["selectedTests"], [PRODUCTION_QA_TEST])

    def test_xcui_target_has_an_unsigned_floorp_release_configuration(self):
        project = PROJECT.read_text()
        configuration_list_start = project.index(
            f'{XCUITESTS_CONFIGURATION_LIST_ID} /* Build configuration list for PBXNativeTarget "XCUITests" */ = {{'
        )
        configuration_list_end = project.index("\n\t\t};", configuration_list_start)
        configuration_list = project[configuration_list_start:configuration_list_end]
        self.assertTrue(
            f"{FLOORP_RELEASE_CONFIGURATION_ID} /* FloorpRelease */," in configuration_list,
            "XCUITests must expose FloorpRelease rather than falling back to Fennec_Testing",
        )
        configuration_start = project.index(
            f"{FLOORP_RELEASE_CONFIGURATION_ID} /* FloorpRelease */ = {{"
        )
        configuration_end = project.index("\n\t\t};", configuration_start)
        body = project[configuration_start:configuration_end]
        self.assertIn('CODE_SIGN_ENTITLEMENTS = "";', body)
        self.assertIn('CODE_SIGN_IDENTITY = "";', body)
        self.assertIn("CODE_SIGNING_ALLOWED = NO;", body)
        self.assertIn('INFOPLIST_FILE = "firefox-ios-tests/Tests/XCUITests/Info.plist";', body)
        self.assertIn("TEST_TARGET_NAME = Client;", body)

    def test_configuration_test_is_compiled_by_xcui_target_and_requires_explicit_opt_in(self):
        project = PROJECT.read_text()
        self.assertTrue(
            f"{FLOORP_RELEASE_BUILD_FILE_ID} /* FloorpNotesSyncProductionQAConfigurationTests.swift in Sources */"
            in project,
            "production-QA test source must be in the XCUITests Sources phase",
        )
        self.assertTrue(
            f"{FLOORP_RELEASE_FILE_REFERENCE_ID} /* FloorpNotesSyncProductionQAConfigurationTests.swift */"
            in project,
            "production-QA test source must have a project file reference",
        )
        source = TEST_SOURCE.read_text()
        self.assertIn("final class FloorpNotesSyncProductionQAConfigurationTests", source)
        self.assertIn("func testReleaseBuildConfigurationIsExplicit()", source)
        self.assertIn("FLOORP_NOTES_SYNC_PRODUCTION_QA", source)
        self.assertNotIn("StageServer", source)

    def test_non_dedicated_full_suite_plans_explicitly_skip_production_qa_test(self):
        for plan_path in sorted(TEST_PLAN_DIRECTORY.glob("*.xctestplan")):
            if plan_path == TEST_PLAN:
                continue
            plan = json.loads(plan_path.read_text())
            for target in plan["testTargets"]:
                if target["target"].get("name") != "XCUITests":
                    continue
                # Selected-test plans cannot accidentally discover a newly
                # compiled XCTest. Plans without that allowlist run every
                # XCUITest not explicitly skipped and must reject this route.
                if "selectedTests" not in target:
                    self.assertTrue(
                        PRODUCTION_QA_TEST in target.get("skippedTests", []),
                        f"{plan_path.name} could run the protected production-QA XCTest",
                    )


if __name__ == "__main__":
    unittest.main()
