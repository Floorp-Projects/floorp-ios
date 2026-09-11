from pathlib import Path
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"
CI_DOCUMENTATION_PATH = ROOT / "docs/ci-cd.md"
APP_COMMON_CONFIG_PATH = ROOT / "firefox-ios/Client/Configuration/Common.xcconfig"
BROWSERKIT_PACKAGE_PATH = ROOT / "BrowserKit/Package.swift"
BROWSERKIT_WEBKIT_EXTENSIONS_PATH = (
    ROOT / "BrowserKit/Sources/Shared/Extensions/WKWebViewExtensions.swift"
)
NATIVE_WEBEXTENSION_TESTS_PATH = (
    ROOT
    / "firefox-ios/firefox-ios-tests/Tests/ClientTests/Coordinators/"
    "FloorpNativeWebExtensionIntegrationTests.swift"
)


class FloorpWebExtensionOSMatrixContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW_PATH.read_text()
        cls.documentation = CI_DOCUMENTATION_PATH.read_text()
        cls.app_common_config = APP_COMMON_CONFIG_PATH.read_text()
        cls.browserkit_package = BROWSERKIT_PACKAGE_PATH.read_text()
        cls.browserkit_webkit_extensions = BROWSERKIT_WEBKIT_EXTENSIONS_PATH.read_text()
        cls.native_webextension_tests = NATIVE_WEBEXTENSION_TESTS_PATH.read_text()
        job_marker = "\n  webextension-os-matrix:\n"
        cls.job = cls.workflow.split(job_marker, 1)[1]

    @classmethod
    def _step(cls, name):
        marker = f"      - name: {name}\n"
        return cls.job.split(marker, 1)[1].split("\n      - name:", 1)[0]

    def test_job_pins_macos_xcode_and_runtime_versions(self):
        self.assertEqual((ROOT / ".xcode-version").read_text().strip(), "26.3")
        deployment_target = re.search(
            r"^IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\S+)\s*$",
            self.app_common_config,
            re.MULTILINE,
        )
        self.assertIsNotNone(deployment_target)
        self.assertEqual(deployment_target.group(1), "18.4")
        self.assertEqual(self.browserkit_package.count(".iOS(.v15)"), 1)
        self.assertEqual(
            self.browserkit_webkit_extensions.count("self.__evaluateJavaScript("),
            3,
        )
        self.assertEqual(
            self.browserkit_webkit_extensions.count("self.__callAsyncJavaScript("),
            1,
        )
        self.assertNotIn(
            "self.evaluateJavaScript(", self.browserkit_webkit_extensions
        )
        self.assertNotIn(
            "self.callAsyncJavaScript(", self.browserkit_webkit_extensions
        )
        for declaration in (
            'WEBEXTENSION_XCODE_VERSION: "26.3"',
            'WEBEXTENSION_XCODE_BUILD: "17C529"',
            'WEBEXTENSION_BUILD_RUNTIME_OS: "26.2"',
            'WEBEXTENSION_BUILD_SDK_BUILD: "23C57"',
            'WEBEXTENSION_BUILD_RUNTIME_BUILD: "23C54"',
            'WEBEXTENSION_MINIMUM_RUNTIME_XCODE_VERSION: "16.3"',
            'WEBEXTENSION_MINIMUM_RUNTIME_XCODE_BUILD: "16E140"',
            'WEBEXTENSION_MINIMUM_RUNTIME_BUILD: "22E238"',
            'WEBEXTENSION_MODERN_RUNTIME_XCODE_VERSION: "26.0.1"',
            'WEBEXTENSION_MODERN_RUNTIME_XCODE_BUILD: "17A400"',
            'WEBEXTENSION_MODERN_RUNTIME_BUILD: "23A343"',
            'WEBEXTENSION_MINIMUM_OS: "18.4"',
            'WEBEXTENSION_MODERN_OS: "26.0"',
            (
                "WEBEXTENSION_SIMULATOR_DEVICE_TYPE: "
                "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
            ),
        ):
            self.assertIn(declaration, self.workflow)
            self.assertEqual(self.workflow.count(declaration), 1)

        self.assertIn("runs-on: macos-15", self.job)
        self.assertIn("timeout-minutes: 180", self.job)
        build_job = self.workflow.split("\n  build-and-test:\n", 1)[1].split(
            "\n  webextension-os-matrix:\n", 1
        )[0]
        self.assertIn("timeout-minutes: 150", build_job)
        self.assertNotIn("timeout-minutes: 180", build_job)
        self.assertNotIn("continue-on-error:", self.job)

        select_xcode = self._step("Select pinned Xcode")
        self.assertIn('xcode_version="$(<.xcode-version)"', select_xcode)
        self.assertIn(
            '[[ "$xcode_version" != "$WEBEXTENSION_XCODE_VERSION" ]]',
            select_xcode,
        )
        self.assertIn(
            '"/Applications/Xcode_${xcode_version}.app/Contents/Developer"',
            select_xcode,
        )
        self.assertIn(
            'grep -Fxq "Xcode $WEBEXTENSION_XCODE_VERSION"', select_xcode
        )
        for provider_contract in (
            '"/Applications/Xcode_${WEBEXTENSION_MINIMUM_RUNTIME_XCODE_VERSION}.app/Contents/Developer"',
            '"/Applications/Xcode_${WEBEXTENSION_MODERN_RUNTIME_XCODE_VERSION}.app/Contents/Developer"',
            'grep -Fxq "Xcode $WEBEXTENSION_MINIMUM_RUNTIME_XCODE_VERSION"',
            'grep -Fxq "Build version $WEBEXTENSION_MINIMUM_RUNTIME_XCODE_BUILD"',
            'grep -Fxq "Xcode $WEBEXTENSION_MODERN_RUNTIME_XCODE_VERSION"',
            'grep -Fxq "Build version $WEBEXTENSION_MODERN_RUNTIME_XCODE_BUILD"',
            'xcrun --sdk iphonesimulator --show-sdk-version',
            'xcrun --sdk iphonesimulator --show-sdk-build-version',
            '[[ "$build_runtime_sdk_version" != "$WEBEXTENSION_BUILD_RUNTIME_OS"',
            '"$build_runtime_sdk_build" != "$WEBEXTENSION_BUILD_SDK_BUILD"',
            '[[ "$minimum_runtime_sdk_version" != "$WEBEXTENSION_MINIMUM_OS" ]]',
            '[[ "$modern_runtime_sdk_version" != "$WEBEXTENSION_MODERN_OS" ]]',
            "FLOORP_WEBEXT_MINIMUM_RUNTIME_DEVELOPER_DIRECTORY",
            "FLOORP_WEBEXT_MODERN_RUNTIME_DEVELOPER_DIRECTORY",
            "FLOORP_WEBEXT_BUILD_RUNTIME_DEVELOPER_DIRECTORY",
        ):
            self.assertIn(provider_contract, select_xcode)

        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        self.assertIn("set -euo pipefail", minimum_runtime)
        self.assertEqual(self.job.count("xcodebuild -downloadPlatform iOS"), 3)
        self.assertEqual(
            minimum_runtime.count("xcodebuild -downloadPlatform iOS"), 2
        )
        self.assertEqual(acceptance.count("xcodebuild -downloadPlatform iOS"), 1)
        self.assertIn(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_BUILD_RUNTIME_DEVELOPER_DIRECTORY"',
            minimum_runtime,
        )
        self.assertIn(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_MINIMUM_RUNTIME_DEVELOPER_DIRECTORY"',
            minimum_runtime,
        )
        self.assertIn(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_MODERN_RUNTIME_DEVELOPER_DIRECTORY"',
            acceptance,
        )
        self.assertIn(
            '-buildVersion "$WEBEXTENSION_BUILD_RUNTIME_BUILD"',
            minimum_runtime,
        )
        self.assertIn(
            '-buildVersion "$WEBEXTENSION_MINIMUM_RUNTIME_BUILD"',
            minimum_runtime,
        )
        self.assertIn(
            '-buildVersion "$WEBEXTENSION_MODERN_RUNTIME_BUILD"', acceptance
        )
        for architecture_branch in (
            "x86_64|arm64)",
            'runtime_architecture_variant="universal"',
            "Unsupported macos-15 runner architecture",
        ):
            self.assertIn(architecture_branch, minimum_runtime)
        build_runtime_download = minimum_runtime.split(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_BUILD_RUNTIME_DEVELOPER_DIRECTORY"',
            1,
        )[1].split(";;", 1)[0]
        minimum_download_command = minimum_runtime.split(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_MINIMUM_RUNTIME_DEVELOPER_DIRECTORY"',
            1,
        )[1].split(";;", 1)[0]
        self.assertIn(
            '-architectureVariant "$runtime_architecture_variant"',
            build_runtime_download,
        )
        self.assertNotIn("-architectureVariant", minimum_download_command)
        self.assertIn(
            '-architectureVariant "$FLOORP_WEBEXT_RUNTIME_ARCHITECTURE_VARIANT"',
            acceptance,
        )
        self.assertIn(
            "$simulator_arch:$FLOORP_WEBEXT_RUNTIME_ARCHITECTURE_VARIANT",
            acceptance,
        )
        self.assertIn("x86_64:universal|arm64:universal", acceptance)
        self.assertNotIn('runtime_architecture_variant="arm64"', minimum_runtime)
        for selected_xcode_contract in (
            'xcode-select --print-path',
            '"/Applications/Xcode_${WEBEXTENSION_XCODE_VERSION}.app/Contents/Developer"',
            'grep -Fxq "Xcode $WEBEXTENSION_XCODE_VERSION"',
            'grep -Fxq "Build version $WEBEXTENSION_XCODE_BUILD"',
        ):
            self.assertIn(selected_xcode_contract, minimum_runtime)
            self.assertIn(selected_xcode_contract, acceptance)
        self.assertIn(
            'minimum_runtime="com.apple.CoreSimulator.SimRuntime.iOS-'
            '${WEBEXTENSION_MINIMUM_OS//./-}"',
            minimum_runtime,
        )
        self.assertIn(
            'build_runtime="com.apple.CoreSimulator.SimRuntime.iOS-'
            '${WEBEXTENSION_BUILD_RUNTIME_OS//./-}"',
            minimum_runtime,
        )
        for storage_cleanup_contract in (
            "xcrun simctl runtime list -j",
            '(.value.version | type == "string")',
            '(.value.build | type == "string")',
            '(.value.deletable | type == "boolean")',
            "select(.value.deletable == true)",
            ".value.version == $minimum_version",
            ".value.build == $minimum_build",
            ".value.runtimeIdentifier == $build_runtime",
            ".value.version == $build_version",
            ".value.build == $build_build",
            "runtimeIdentifier: .value.runtimeIdentifier",
            "version: .value.version",
            "build: .value.build",
            '[[ "$runtime_identifier" == "$minimum_runtime" \\',
            '[[ "$runtime_identifier" == "$build_runtime" \\',
            'xcrun simctl runtime delete "$runtime_uuid"',
            "runtime_cleanup_poll_max_attempts=180",
            "runtime_cleanup_poll_interval_seconds=2",
            "runtime_cleanup_complete=0",
            "--slurpfile candidates \"$runtime_delete_candidates\"",
            "select($candidate_uuids | index($uuid) != null)",
            "Runtime cleanup poll %d/%d",
            'sleep "$runtime_cleanup_poll_interval_seconds"',
            "Timed out waiting for exact simulator runtime candidate UUIDs",
            "floorp-webextension-os-matrix-disk-before-ios-18-4-download.log",
        ):
            self.assertIn(storage_cleanup_contract, minimum_runtime)
        self.assertNotIn(
            "select(.value.runtimeIdentifier != $modern_runtime)", minimum_runtime
        )
        self.assertIn(
            '[[ "$modern_runtime_retained" != "0" ]]', minimum_runtime
        )
        self.assertIn(
            "iOS 26.0 must not remain installed during the iOS 18.4 phase",
            minimum_runtime,
        )
        self.assertEqual(
            minimum_runtime.count("xcrun simctl runtime delete"), 1
        )
        for forbidden_deletion in (
            "simctl runtime delete all",
            "simctl runtime delete --notUsedSinceDays",
            'simctl runtime delete "$minimum_runtime"',
            'simctl runtime delete "$modern_runtime"',
        ):
            self.assertNotIn(forbidden_deletion, minimum_runtime)
        self.assertLess(
            minimum_runtime.index('xcrun simctl runtime delete "$runtime_uuid"'),
            minimum_runtime.index("xcodebuild -downloadPlatform iOS"),
        )
        initial_cleanup_poll = minimum_runtime.split(
            "for (( runtime_cleanup_attempt = 1;", 1
        )[1].split("\n          done", 1)[0]
        for polling_contract in (
            "runtime_cleanup_attempt <= runtime_cleanup_poll_max_attempts",
            'xcrun simctl runtime list -j > "$runtime_storage_after_cleanup"',
            '"$runtime_storage_after_cleanup" >/dev/null',
            'remaining_candidate_uuids="$(jq -cer',
            "select($candidate_uuids | index($uuid) != null)",
            '[[ "$remaining_candidate_count" == "0" ]]',
            'sleep "$runtime_cleanup_poll_interval_seconds"',
        ):
            self.assertIn(polling_contract, initial_cleanup_poll)
        initial_runtime_delete = minimum_runtime.index(
            'xcrun simctl runtime delete "$runtime_uuid"'
        )
        initial_absence_gate = minimum_runtime.index(
            '[[ "$runtime_cleanup_complete" != "1" ]]'
        )
        minimum_download = minimum_runtime.index(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_MINIMUM_RUNTIME_DEVELOPER_DIRECTORY"'
        )
        self.assertLess(initial_runtime_delete, initial_absence_gate)
        self.assertLess(initial_absence_gate, minimum_download)
        for existing_minimum_contract in (
            'minimum_runtime_count="$(jq -er',
            'minimum_runtime_identifier_count="$(jq -er',
            'case "$minimum_runtime_count:$minimum_runtime_identifier_count" in',
            "Runtime %s %s is already available; download skipped.",
            "Minimum-OS runtime inventory is ambiguous",
        ):
            self.assertIn(existing_minimum_contract, minimum_runtime)
        for build_support_contract in (
            'build_runtime_count="$(jq -er',
            'build_runtime_identifier_count="$(jq -er',
            'case "$build_runtime_count:$build_runtime_identifier_count" in',
            "Expected one exact build-support runtime",
        ):
            self.assertIn(build_support_contract, minimum_runtime)
        for fail_closed_check in (
            ".identifier == $identifier",
            ".version == $version",
            ".buildversion == $build",
            ".isAvailable == true",
            ".supportedArchitectures | index($architecture) != null",
            ".supportedDeviceTypes | any(.identifier == $device_type)",
            '[[ "$minimum_runtime_count" != "1" \\',
            '|| "$minimum_runtime_identifier_count" != "1"',
            "Expected one exact minimum-OS runtime",
        ):
            self.assertIn(fail_closed_check, minimum_runtime)
        self.assertEqual(minimum_runtime.count(".version == $version"), 4)
        self.assertEqual(minimum_runtime.count(".buildversion == $build"), 4)
        self.assertNotIn("|| true", minimum_runtime)

        verification = minimum_runtime.index(
            '[[ "$minimum_runtime_count" != "1" \\'
        )
        creation = minimum_runtime.index(
            'minimum_simulator_id="$(xcrun simctl create'
        )
        self.assertLess(verification, creation)

    def test_job_creates_exact_simulators_and_builds_once_for_minimum_os(self):
        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        minimum_destination = self._step("Verify minimum-OS build destination")
        self.assertEqual(self.job.count("xcrun simctl create"), 2)
        self.assertEqual(minimum_runtime.count("xcrun simctl create"), 1)
        self.assertEqual(acceptance.count("xcrun simctl create"), 1)
        self.assertIn("FLOORP_WEBEXT_IOS184_DESTINATION", minimum_runtime)
        self.assertNotIn("FLOORP_WEBEXT_IOS260_DESTINATION", minimum_runtime)
        self.assertIn("FLOORP_WEBEXT_IOS260_DESTINATION", acceptance)
        self.assertIn('modern_destination="platform=iOS Simulator', acceptance)
        self.assertEqual(self.job.count("xcodebuild -showdestinations"), 2)
        self.assertIn("set -euo pipefail", minimum_destination)
        self.assertIn("xcodebuild -showdestinations", minimum_destination)
        self.assertIn(
            'grep -Fq "id:$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"',
            minimum_destination,
        )
        self.assertIn(
            "awk '/Ineligible destinations for/{exit} {print}'",
            minimum_destination,
        )
        self.assertIn(
            "floorp-webextension-os-matrix-eligible-destinations-ios-18-4.log",
            minimum_destination,
        )
        self.assertIn("xcodebuild -showdestinations", acceptance)
        self.assertIn('grep -Fq "id:$modern_simulator_id"', acceptance)
        self.assertIn(
            "awk '/Ineligible destinations for/{exit} {print}'", acceptance
        )
        self.assertIn(
            "floorp-webextension-os-matrix-eligible-destinations-ios-26-0"
            "${artifact_suffix}.log",
            acceptance,
        )

        build = self._step("Build minimum-OS test products once")
        linkage = self._step("Reject unavailable Swift WebKit runtime linkage")
        self.assertEqual(self.job.count("xcodebuild build-for-testing"), 1)
        self.assertIn("set -euo pipefail", build)
        self.assertIn('-destination "$FLOORP_WEBEXT_IOS184_DESTINATION"', build)
        self.assertNotIn("IPHONEOS_DEPLOYMENT_TARGET=", build)
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/WebExtensionDerivedData"', build)
        self.assertIn("-testPlan FloorpCI", build)
        self.assertLess(
            self.job.index("      - name: Verify minimum-OS build destination"),
            self.job.index("      - name: Build minimum-OS test products once"),
        )
        self.assertLess(
            self.job.index("      - name: Build minimum-OS test products once"),
            self.job.index(
                "      - name: Reject unavailable Swift WebKit runtime linkage"
            ),
        )
        self.assertLess(
            self.job.index(
                "      - name: Reject unavailable Swift WebKit runtime linkage"
            ),
            self.job.index("      - name: Run focused WebExtension OS acceptance"),
        )
        for linkage_contract in (
            "set -euo pipefail",
            "shopt -s nullglob",
            "PackageFrameworks/Shared_*_PackageProduct.framework/Shared_*_PackageProduct",
            '[[ "${#shared_products[@]}" -ne 1 ]]',
            'otool -L "${shared_products[0]}"',
            "/usr/lib/swift/libswiftWebKit.dylib",
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "floorp-webextension-os-matrix-shared-linkage.log",
        ):
            self.assertIn(linkage_contract, linkage)
        self.assertNotIn("|| true", linkage)

        self.assertEqual(acceptance.count("xcodebuild test-without-building"), 1)
        self.assertNotIn("xcodebuild test ", acceptance)
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/WebExtensionDerivedData"', acceptance)
        self.assertNotIn("IPHONEOS_DEPLOYMENT_TARGET=", acceptance)
        self.assertIn("-default-test-execution-time-allowance 720", acceptance)
        self.assertIn("-maximum-test-execution-time-allowance 720", acceptance)

    def test_runtime_use_is_sequential_and_minimum_runtime_reclaim_is_exact(self):
        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        minimum_boot = acceptance.index(
            'wait_for_simulator_boot \\\n'
            '            "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"'
        )
        minimum_test = acceptance.index(
            "testOfficialDarkReaderAppliesThemeAndRendersInteractivePopup"
        )
        simulator_shutdown = acceptance.index(
            'xcrun simctl shutdown "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"'
        )
        simulator_delete = acceptance.index(
            'xcrun simctl delete "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"'
        )
        runtime_resolve = acceptance.index(
            'select(.value.runtimeIdentifier == $runtime_identifier)'
        )
        runtime_delete = acceptance.index(
            'xcrun simctl runtime delete "$minimum_runtime_uuid"'
        )
        runtime_absence_gate = acceptance.index(
            '[[ "$minimum_runtime_reclaim_complete" != "1" ]]'
        )
        reclaimed_space = acceptance.index(
            "floorp-webextension-os-matrix-disk-after-ios-18-4-reclaim.log"
        )
        modern_download = acceptance.index(
            'DEVELOPER_DIR="$FLOORP_WEBEXT_MODERN_RUNTIME_DEVELOPER_DIRECTORY"'
        )
        modern_create = acceptance.index(
            "xcrun simctl create \\"
        )
        modern_destination_gate = acceptance.index(
            'grep -Fq "id:$modern_simulator_id"'
        )
        modern_boot = acceptance.index(
            'if ! wait_for_simulator_boot \\\n'
            '              "$modern_simulator_id"'
        )
        modern_test = acceptance.index(
            "testOfficialUBOLReleaseAcceptanceGates"
        )
        self.assertEqual(
            [
                minimum_boot,
                minimum_test,
                simulator_shutdown,
                simulator_delete,
                runtime_resolve,
                runtime_delete,
                runtime_absence_gate,
                reclaimed_space,
                modern_download,
                modern_create,
                modern_destination_gate,
                modern_boot,
                modern_test,
            ],
            sorted(
                [
                    minimum_boot,
                    minimum_test,
                    simulator_shutdown,
                    simulator_delete,
                    runtime_resolve,
                    runtime_delete,
                    runtime_absence_gate,
                    reclaimed_space,
                    modern_download,
                    modern_create,
                    modern_destination_gate,
                    modern_boot,
                    modern_test,
                ]
            ),
        )

        for exact_reclaim_contract in (
            'select(.value.runtimeIdentifier == $runtime_identifier)',
            "version: .value.version",
            "build: .value.build",
            "length == 1",
            ".[0].version == $runtime_version",
            ".[0].build == $runtime_build",
            ".[0].deletable == true",
            'reclaim_runtime_identifier" != "$minimum_runtime"',
            'reclaim_runtime_version" != "$WEBEXTENSION_MINIMUM_OS"',
            'reclaim_runtime_build" != "$WEBEXTENSION_MINIMUM_RUNTIME_BUILD"',
            'reclaim_runtime_identifier" == "$modern_runtime"',
            'xcrun simctl runtime delete "$minimum_runtime_uuid"',
            "minimum_runtime_reclaim_poll_max_attempts=180",
            "minimum_runtime_reclaim_poll_interval_seconds=2",
            "minimum_runtime_reclaim_complete=0",
            "[keys[] | select(. == $runtime_uuid)] | length",
            "Minimum-OS runtime reclaim poll %d/%d",
            'sleep "$minimum_runtime_reclaim_poll_interval_seconds"',
            "Timed out waiting for exact minimum-OS runtime UUID to disappear",
            '[[ "$minimum_runtime_remaining" != "0" ]]',
        ):
            self.assertIn(exact_reclaim_contract, acceptance)
        minimum_reclaim_poll = acceptance.split(
            "for (( minimum_runtime_reclaim_attempt = 1;", 1
        )[1].split("\n          done", 1)[0]
        for polling_contract in (
            "minimum_runtime_reclaim_attempt <= minimum_runtime_reclaim_poll_max_attempts",
            'xcrun simctl runtime list -j > "$runtime_storage_after_reclaim"',
            'validate_runtime_storage_inventory "$runtime_storage_after_reclaim"',
            '--arg runtime_uuid "$minimum_runtime_uuid"',
            "[keys[] | select(. == $runtime_uuid)] | length",
            '[[ "$minimum_runtime_uuid_remaining" == "0" ]]',
            'sleep "$minimum_runtime_reclaim_poll_interval_seconds"',
        ):
            self.assertIn(polling_contract, minimum_reclaim_poll)
        self.assertEqual(
            acceptance.count(
                'xcrun simctl runtime delete "$minimum_runtime_uuid"'
            ),
            1,
        )
        self.assertNotIn("|| true", acceptance)
        self.assertIn(
            'modern_runtime="com.apple.CoreSimulator.SimRuntime.iOS-'
            '${WEBEXTENSION_MODERN_OS//./-}"',
            minimum_runtime,
        )
        self.assertIn(
            "floorp-webextension-os-matrix-disk-after-ios-26-0-download.log",
            acceptance,
        )
        for modern_uniqueness_contract in (
            'modern_runtime_identifier_count="$(jq -er',
            'case "$modern_runtime_count:$modern_runtime_identifier_count" in',
            '[[ "$modern_runtime_count" != "1" \\',
            '|| "$modern_runtime_identifier_count" != "1"',
            "Expected one exact iOS 26.0 runtime",
            "Expected one retained build-support runtime",
        ):
            self.assertIn(modern_uniqueness_contract, acceptance)
        self.assertEqual(acceptance.count(".version == $version"), 3)
        self.assertEqual(acceptance.count(".buildversion == $build"), 3)

    def test_focused_acceptance_selects_the_supported_tests_on_each_os(self):
        acceptance = self._step("Run focused WebExtension OS acceptance")
        minimum_start = acceptance.index(
            '          run_test \\\n'
            '            "$FLOORP_WEBEXT_IOS184_DESTINATION"'
        )
        minimum_end = acceptance.index(
            'xcrun simctl shutdown "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"'
        )
        modern_start = acceptance.index(
            '          run_test \\\n'
            '            "$modern_destination"'
        )
        modern_end = acceptance.index('exit "$overall_status"')
        minimum = acceptance[minimum_start:minimum_end]
        modern = acceptance[modern_start:modern_end]

        minimum_tests = (
            (
                "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
                "testMainMenuOpensOnlyAvailableDarkReaderActionDirectlyOnMinimumOS"
            ),
            (
                "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
                "testBundledUBOLIsUnavailableAndInstallFailsBelowMinimumOS"
            ),
            (
                "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
                "testBundledDarkReaderThemesProductionHostTabsInBothPrivacyRealms"
            ),
            (
                "ClientTests/FloorpDarkReaderWebKitAcceptanceTests/"
                "testOfficialDarkReaderAppliesThemeAndRendersInteractivePopup"
            ),
        )
        modern_tests = (
            (
                "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
                "testMainMenuSelectsDarkReaderFromTwoActionPickerAndPresentsInteractivePopup"
            ),
            (
                "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
                "testBundledUBOLBlocksProductionHostTabsAndRendersDashboard"
            ),
            (
                "ClientTests/FloorpUBOLWebKitDiagnosticsTests/"
                "testOfficialUBOLReleaseAcceptanceGates"
            ),
        )

        self.assertEqual(minimum.count("run_test \\\n"), 4)
        self.assertEqual(modern.count("run_test \\\n"), 3)
        selected_pattern = r'"(ClientTests/[^"\n]+)"'
        self.assertEqual(set(re.findall(selected_pattern, minimum)), set(minimum_tests))
        self.assertEqual(set(re.findall(selected_pattern, modern)), set(modern_tests))
        self.assertEqual(minimum.count("UBOL"), 1)
        self.assertNotIn("FLOORP_UBOL_RELEASE_GATE", minimum)
        self.assertIn(
            "FLOORP_DARKREADER_RELEASE_GATE background-resume-popup", minimum
        )
        self.assertIn("FLOORP_UBOL_RELEASE_GATE report", modern)
        self.assertIn(
            "TEST_RUNNER_FLOORP_RUN_UBOL_DNR_DIAGNOSTICS=1", acceptance
        )
        ubol_acceptance_call = modern.split(
            '"ClientTests/FloorpUBOLWebKitDiagnosticsTests/'
            'testOfficialUBOLReleaseAcceptanceGates"',
            1,
        )[1]
        self.assertIn('\n            "1" \\', ubol_acceptance_call)

    def test_simulator_boot_waits_are_bounded_and_modern_boot_recreates_once(self):
        acceptance = self._step("Run focused WebExtension OS acceptance")
        timeout_helper = acceptance.split(
            "          run_command_with_timeout() {", 1
        )[1].split("\n          }", 1)[0]
        boot_helper = acceptance.split(
            "          wait_for_simulator_boot() {", 1
        )[1].split("\n          }", 1)[0]

        self.assertNotIn("xcrun simctl bootstatus", acceptance)
        self.assertEqual(acceptance.count("bootstatus"), 1)
        for bounded_command_contract in (
            'local timeout_seconds="$2"',
            "shift 2",
            "post_kill_wait_seconds = 10",
            "command = sys.argv[2:]",
            "subprocess.Popen(",
            "start_new_session=True",
            "signal.signal(signal.SIGTERM, handle_parent_termination)",
            "signal.signal(signal.SIGINT, handle_parent_termination)",
            "except ParentTermination as termination:",
            "if process is not None and process.poll() is None:",
            "process.wait(timeout=timeout_seconds)",
            "except subprocess.TimeoutExpired:",
            "os.killpg(process.pid, signal.SIGKILL)",
            "process.wait(timeout=post_kill_wait_seconds)",
            "Command did not exit after SIGKILL within",
            "command_status = 124",
            "command_status = 125",
            'pipeline_status=("${PIPESTATUS[@]}")',
            'command_status="${pipeline_status[0]}"',
            'tee_status="${pipeline_status[1]}"',
            '[[ "$tee_status" -ne 0 ]]',
            "Could not retain bounded command output",
            'return "$tee_status"',
            'return "$command_status"',
        ):
            self.assertIn(bounded_command_contract, timeout_helper)
        for bounded_boot_contract in (
            "run_command_with_timeout",
            "720",
            "xcrun",
            "simctl",
            "bootstatus",
            '"$simulator_id"',
            "-b",
        ):
            self.assertIn(bounded_boot_contract, boot_helper)

        self.assertEqual(acceptance.count("wait_for_simulator_boot \\"), 3)
        self.assertIn(
            '"$FLOORP_WEBEXT_IOS184_SIMULATOR_ID" \\\n'
            '            "floorp-webextension-os-matrix-ios-18-4-boot-attempt-1"',
            acceptance,
        )
        for attempt in (1, 2):
            self.assertIn(
                f"floorp-webextension-os-matrix-ios-26-0-boot-attempt-{attempt}",
                acceptance,
            )
        for exact_recreation_contract in (
            "floorp-webextension-os-matrix-ios-26-0-boot-recovery-shutdown-attempt-1",
            "floorp-webextension-os-matrix-ios-26-0-boot-recovery-delete-attempt-1",
            "120",
            "shutdown \\",
            "delete \\",
            '[[ "$delete_status" -ne 0 ]]',
            'create_and_verify_modern_simulator "-retry-2"',
            "did not boot after two bounded attempts",
        ):
            self.assertIn(exact_recreation_contract, acceptance)
        self.assertNotIn(
            'xcrun simctl shutdown "$modern_simulator_id"', acceptance
        )
        self.assertNotIn(
            'xcrun simctl delete "$modern_simulator_id"', acceptance
        )
        self.assertEqual(
            len(
                re.findall(
                    r'^\s+create_and_verify_modern_simulator "(?:|-retry-2)"$',
                    acceptance,
                    re.MULTILINE,
                )
            ),
            2,
        )

        modern_setup = acceptance.split(
            "          create_and_verify_modern_simulator() {", 1
        )[1].split("\n          }", 1)[0]
        recovery = acceptance.split(
            "          recover_modern_simulator_for_cleanup() {", 1
        )[1].split("\n          }", 1)[0]
        self.assertIn(
            'modern_simulator_name="Floorp WebExtension iOS '
            '$WEBEXTENSION_MODERN_OS run-$GITHUB_RUN_ID-attempt-'
            '$GITHUB_RUN_ATTEMPT"',
            acceptance,
        )
        for recovery_contract in (
            "run_command_with_timeout \\",
            "60 \\\n              xcrun simctl list devices -j",
            '--arg runtime "$modern_runtime"',
            '--arg name "$modern_simulator_name"',
            ".devices[$runtime][]?",
            "if length == 1 then .[0]",
            'FLOORP_WEBEXT_IOS260_SIMULATOR_ID=%s\\n',
            "for the always-run cleanup step",
        ):
            self.assertIn(recovery_contract, recovery)
        for bounded_setup_contract in (
            "run_command_with_timeout \\",
            'create_artifact_stem="floorp-webextension-os-matrix-ios-26-0-'
            'simulator-create${artifact_suffix}"',
            "120 \\\n              xcrun simctl create \\",
            "Could not create the exact iOS 26.0 simulator within the fixed timeout",
            '"floorp-webextension-os-matrix-destinations-ios-26-0'
            '${artifact_suffix}"',
            "300 \\\n              xcodebuild -showdestinations \\",
            "Could not verify the exact iOS 26.0 simulator destination within the fixed timeout",
            'grep -Fq "id:$modern_simulator_id"',
            '"$modern_simulator_name" \\',
        ):
            self.assertIn(bounded_setup_contract, modern_setup)
        self.assertEqual(modern_setup.count("run_command_with_timeout \\"), 2)
        self.assertEqual(
            modern_setup.count(
                'recover_modern_simulator_for_cleanup "$artifact_suffix"'
            ),
            2,
        )

    def test_bounded_command_parent_signal_kills_the_child_process_group(self):
        acceptance = self._step("Run focused WebExtension OS acceptance")
        acceptance_lines = acceptance.splitlines()
        helper_start = next(
            index
            for index, line in enumerate(acceptance_lines)
            if "<<'PY'" in line
        ) + 1
        helper_end = next(
            index
            for index in range(helper_start, len(acceptance_lines))
            if acceptance_lines[index].strip() == "PY"
        )
        helper = "\n".join(acceptance_lines[helper_start:helper_end])
        helper = "\n".join(
            line.removeprefix("          ") for line in helper.splitlines()
        ).lstrip()

        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            helper_path = directory_path / "bounded-command.py"
            child_pid_path = directory_path / "child.pid"
            helper_path.write_text(helper)
            child_code = (
                "from pathlib import Path; import os, time; "
                f"Path({str(child_pid_path)!r}).write_text(str(os.getpid())); "
                "time.sleep(60)"
            )
            parent = subprocess.Popen(
                [
                    sys.executable,
                    str(helper_path),
                    "60",
                    sys.executable,
                    "-c",
                    child_code,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.addCleanup(lambda: parent.poll() is None and parent.kill())
            for _ in range(100):
                if child_pid_path.exists():
                    break
                time.sleep(0.01)
            if not child_pid_path.exists():
                parent.kill()
                output, _ = parent.communicate(timeout=10)
                self.fail(f"bounded child did not start:\n{output}")
            child_pid = int(child_pid_path.read_text())

            parent.send_signal(signal.SIGTERM)
            output, _ = parent.communicate(timeout=10)
            self.assertEqual(parent.returncode, 128 + signal.SIGTERM, output)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_minimum_os_negative_test_bootstraps_dependencies_before_seeding_tab(self):
        marker = (
            "    func testBundledUBOLIsUnavailableAndInstallFailsBelowMinimumOS() "
            "async throws {"
        )
        body = self.native_webextension_tests.split(marker, 1)[1].split(
            "\n    func ", 1
        )[0]

        self.assertIn("let dependencies = DependencyHelperMock()", body)
        bootstrap = "dependencies.bootstrapDependencies("
        seed_tab = "let source = manager.seedTab("
        self.assertIn(bootstrap, body)
        self.assertIn("injectedProfile: profile", body)
        self.assertIn("injectedTabManager: manager", body)
        self.assertIn("defer { dependencies.reset() }", body)
        self.assertLess(body.index(bootstrap), body.index(seed_tab))

    def test_test_and_diagnostic_failures_are_not_masked(self):
        acceptance = self._step("Run focused WebExtension OS acceptance")
        self.assertIn("timeout-minutes: 90", acceptance)
        for fail_closed_token in (
            "set -euo pipefail",
            "command_status=${PIPESTATUS[0]}",
            '[[ "$command_status" -ne 0 ]]',
            'grep -Fq "${test_method}]\' passed" "$log_path"',
            'grep -Fq "$completion_marker" "$log_path"',
            "overall_status=1",
            'exit "$overall_status"',
        ):
            self.assertIn(fail_closed_token, acceptance)
        self.assertIn('-resultBundlePath "$result_path"', acceptance)

        diagnostics = self._step("Reject unsafe WebExtension matrix diagnostics")
        self.assertIn("if: always()", diagnostics)
        self.assertIn("set -euo pipefail", diagnostics)
        self.assertIn(
            'for log in "$RUNNER_TEMP"/floorp-webextension-os-matrix-*.log',
            diagnostics,
        )
        self.assertIn('callback_signature+="able"', diagnostics)
        self.assertIn('transition_signature+="Transition"', diagnostics)
        for signature_fragment in (
            'open_tab_signature="Error for open new "',
            'open_tab_signature+="tab"',
            'current_window_signature="Current window for "',
            'current_window_signature+="page"',
            'tabs_create_signature="Promise rejected: Invalid call to tabs."',
            'tabs_create_signature+="create()"',
        ):
            self.assertIn(signature_fragment, diagnostics)
        for signature_variable in (
            "$callback_signature",
            "$transition_signature",
            "$open_tab_signature",
            "$current_window_signature",
            "$tabs_create_signature",
        ):
            self.assertEqual(
                diagnostics.count(f'check_signature "$log" "{signature_variable}"'),
                1,
            )
        self.assertIn('if [[ "$grep_status" -ne 1 ]]', diagnostics)
        self.assertIn("violations=1", diagnostics)
        self.assertIn('exit "$violations"', diagnostics)

        upload = self._step("Upload WebExtension OS matrix evidence")
        self.assertIn("if: always()", upload)
        self.assertIn(
            "uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f",
            upload,
        )
        for evidence in ("*.log", "*.json", "*.xcresult"):
            self.assertIn(
                f"floorp-webextension-os-matrix-{evidence}", upload
            )

    def test_ci_documentation_records_the_os_gate_without_ruleset_drift(self):
        normalized_documentation = " ".join(self.documentation.split())
        for documented_contract in (
            "Native WebExtensions iOS 18.4 and 26.0 acceptance",
            "`macos-15` with Xcode 26.3 selected from `.xcode-version`",
            "either test simulator runtime is installed",
            "obtains exact iOS 18.4 and iOS 26.0 runtimes on demand",
            "Xcode 16.3 for iOS 18.4 and Xcode 26.0.1 for iOS 26.0",
            "verifies each provider's exact Xcode and Simulator SDK version",
            "iOS 18.4 (22E238)",
            "iOS 26.0 (23A343)",
            "Simulator SDK at version 26.2 (23C57)",
            "iOS 26.2 (23C54)",
            "retains that exact build-support runtime",
            "Simulator SDK must itself",
            "report version 26.2 and build 23C57",
            "Xcode 26.3 remains selected for every build and test",
            "preserves only an existing exact iOS 18.4",
            "different build that shares either protected runtime identifier",
            "deletes only other runtime images that CoreSimulator",
            "Unknown inventory data or a failed deletion stops the job",
            "successful `simctl runtime delete` can precede secure-storage",
            "waits within a fixed bound until every explicitly deleted",
            "runtime UUID is absent from repeatedly validated",
            "refuses to start the iOS 18.4 phase",
            "if an iOS 26.0 runtime image",
            "remains in CoreSimulator storage",
            "post-cleanup free-space report",
            "requires exactly one compatible exact-build entry",
            "exactly one total entry for its runtime",
            "list the exact created simulator UUID",
            "as an eligible destination",
            "builds the test products once for the exact iOS 18.4 simulator",
            "does not override `IPHONEOS_DEPLOYMENT_TARGET` globally",
            "Swift package dependencies retain their own supported floors",
            "Main Menu-to-Dark Reader direct popup path",
            "uBlock Origin Lite is",
            "below its iOS 26.0 minimum",
            "uniquely re-resolves the",
            "deletable iOS 18.4 (22E238) runtime UUID",
            "by identifier, version, and build",
            "waits for that exact UUID",
            "to disappear from validated inventory",
            "records the reclaimed space before",
            "obtaining iOS 26.0 with the same download mechanism",
            "iOS 26.2 build-support runtime remains installed",
            "opt-in official uBlock",
            "Origin Lite acceptance.",
            "use `test-without-building` rather than rebuilding",
            "runtime inventories, and `.xcresult`",
            "unsafe WebKit",
            "host-routing, or `tabs.create` diagnostic",
            "any pull request that changes native",
            "at its exact",
            "reviewed head as an additional manual merge condition",
        ):
            self.assertIn(
                " ".join(documented_contract.split()), normalized_documentation
            )
        self.assertNotIn("image-provided iOS 26.0", self.documentation)
        self.assertIn(
            '"required_status_checks": ["Validate workflows", '
            '"Build and unit test"]',
            self.documentation,
        )


if __name__ == "__main__":
    unittest.main()
