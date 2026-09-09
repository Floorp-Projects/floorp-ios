from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"
CI_DOCUMENTATION_PATH = ROOT / "docs/ci-cd.md"


class FloorpWebExtensionOSMatrixContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW_PATH.read_text()
        cls.documentation = CI_DOCUMENTATION_PATH.read_text()
        job_marker = "\n  webextension-os-matrix:\n"
        cls.job = cls.workflow.split(job_marker, 1)[1]

    @classmethod
    def _step(cls, name):
        marker = f"      - name: {name}\n"
        return cls.job.split(marker, 1)[1].split("\n      - name:", 1)[0]

    def test_job_pins_macos_xcode_and_runtime_versions(self):
        self.assertEqual((ROOT / ".xcode-version").read_text().strip(), "26.3")
        for declaration in (
            'WEBEXTENSION_XCODE_VERSION: "26.3"',
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

        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        self.assertIn("set -euo pipefail", minimum_runtime)
        self.assertEqual(self.job.count("xcodebuild -downloadPlatform iOS"), 2)
        self.assertEqual(
            minimum_runtime.count("xcodebuild -downloadPlatform iOS"), 1
        )
        self.assertEqual(acceptance.count("xcodebuild -downloadPlatform iOS"), 1)
        self.assertIn('-buildVersion "$WEBEXTENSION_MINIMUM_OS"', minimum_runtime)
        self.assertNotIn(
            '-buildVersion "$WEBEXTENSION_MODERN_OS"', minimum_runtime
        )
        self.assertIn('-buildVersion "$WEBEXTENSION_MODERN_OS"', acceptance)
        self.assertNotIn('-buildVersion "$WEBEXTENSION_MINIMUM_OS"', acceptance)
        for architecture_branch in (
            "x86_64|arm64)",
            'runtime_architecture_variant="universal"',
            "Unsupported macos-15 runner architecture",
        ):
            self.assertIn(architecture_branch, minimum_runtime)
        self.assertIn(
            '-architectureVariant "$runtime_architecture_variant"',
            minimum_runtime,
        )
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
        self.assertIn(
            'minimum_runtime="com.apple.CoreSimulator.SimRuntime.iOS-'
            '${WEBEXTENSION_MINIMUM_OS//./-}"',
            minimum_runtime,
        )
        for storage_cleanup_contract in (
            "xcrun simctl runtime list -j",
            '(.value.deletable | type == "boolean")',
            "select(.value.deletable == true)",
            "select(.value.runtimeIdentifier != $minimum_runtime)",
            "{uuid: .key, runtimeIdentifier: .value.runtimeIdentifier}",
            '[[ "$runtime_identifier" == "$minimum_runtime"',
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
            '-buildVersion "$WEBEXTENSION_MINIMUM_OS"'
        )
        self.assertLess(initial_runtime_delete, initial_absence_gate)
        self.assertLess(initial_absence_gate, minimum_download)
        for existing_minimum_contract in (
            'minimum_runtime_count="$(jq -er',
            'case "$minimum_runtime_count" in',
            "Runtime %s is already available; download skipped.",
            "Minimum-OS runtime inventory is ambiguous",
        ):
            self.assertIn(existing_minimum_contract, minimum_runtime)
        for fail_closed_check in (
            ".identifier == $identifier",
            ".isAvailable == true",
            ".supportedArchitectures | index($architecture) != null",
            ".supportedDeviceTypes | any(.identifier == $device_type)",
            '[[ "$minimum_runtime_count" != "1" ]]',
            "Expected one compatible minimum-OS runtime",
        ):
            self.assertIn(fail_closed_check, minimum_runtime)
        self.assertNotIn("|| true", minimum_runtime)

        verification = minimum_runtime.index(
            '[[ "$minimum_runtime_count" != "1" ]]'
        )
        creation = minimum_runtime.index(
            'minimum_simulator_id="$(xcrun simctl create'
        )
        self.assertLess(verification, creation)

    def test_job_creates_exact_simulators_and_builds_once_for_minimum_os(self):
        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        self.assertEqual(self.job.count("xcrun simctl create"), 2)
        self.assertEqual(minimum_runtime.count("xcrun simctl create"), 1)
        self.assertEqual(acceptance.count("xcrun simctl create"), 1)
        self.assertIn("FLOORP_WEBEXT_IOS184_DESTINATION", minimum_runtime)
        self.assertNotIn("FLOORP_WEBEXT_IOS260_DESTINATION", minimum_runtime)
        self.assertIn("FLOORP_WEBEXT_IOS260_DESTINATION", acceptance)
        self.assertIn('modern_destination="platform=iOS Simulator', acceptance)

        build = self._step("Build minimum-OS test products once")
        self.assertEqual(self.job.count("xcodebuild build-for-testing"), 1)
        self.assertIn("set -euo pipefail", build)
        self.assertIn('-destination "$FLOORP_WEBEXT_IOS184_DESTINATION"', build)
        self.assertIn(
            'IPHONEOS_DEPLOYMENT_TARGET="$WEBEXTENSION_MINIMUM_OS"', build
        )
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/WebExtensionDerivedData"', build)
        self.assertIn("-testPlan FloorpCI", build)

        self.assertEqual(acceptance.count("xcodebuild test-without-building"), 1)
        self.assertNotIn("xcodebuild test ", acceptance)
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/WebExtensionDerivedData"', acceptance)
        self.assertIn(
            'IPHONEOS_DEPLOYMENT_TARGET="$WEBEXTENSION_MINIMUM_OS"',
            acceptance,
        )

    def test_runtime_use_is_sequential_and_minimum_runtime_reclaim_is_exact(self):
        minimum_runtime = self._step("Prepare iOS 18.4 simulator runtime")
        acceptance = self._step("Run focused WebExtension OS acceptance")
        minimum_boot = acceptance.index(
            'xcrun simctl bootstatus "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID" -b'
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
            '-buildVersion "$WEBEXTENSION_MODERN_OS"'
        )
        modern_create = acceptance.index(
            'modern_simulator_id="$(xcrun simctl create'
        )
        modern_boot = acceptance.index(
            'xcrun simctl bootstatus "$modern_simulator_id" -b'
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
                    modern_boot,
                    modern_test,
                ]
            ),
        )

        for exact_reclaim_contract in (
            'select(.value.runtimeIdentifier == $runtime_identifier)',
            "length == 1",
            ".[0].deletable == true",
            'reclaim_runtime_identifier" != "$minimum_runtime"',
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
        self.assertIn('[[ "$modern_runtime_count" != "1" ]]', acceptance)
        self.assertIn("Expected one compatible iOS 26.0 runtime", acceptance)

    def test_focused_acceptance_selects_the_supported_tests_on_each_os(self):
        acceptance = self._step("Run focused WebExtension OS acceptance")
        minimum = acceptance.split(
            'xcrun simctl bootstatus "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID" -b', 1
        )[1].split(
            'xcrun simctl shutdown "$FLOORP_WEBEXT_IOS184_SIMULATOR_ID"', 1
        )[0]
        modern = acceptance.split(
            'xcrun simctl bootstatus "$modern_simulator_id" -b', 1
        )[1].split('exit "$overall_status"', 1)[0]

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
        for documented_contract in (
            "Native WebExtensions iOS 18.4 and 26.0 acceptance",
            "`macos-15` with Xcode 26.3 selected from `.xcode-version`",
            "either required simulator runtime is installed",
            "obtains exact iOS 18.4 and iOS 26.0 runtimes on demand",
            "requests the Xcode 26.3 universal archive for both releases",
            "iOS 18.4 catalog entry does not publish an arm64-only archive",
            "preserves any existing iOS 18.4",
            "deletes only other runtime images that CoreSimulator",
            "Unknown inventory data or a failed deletion stops the job",
            "successful `simctl runtime delete` can precede secure-storage",
            "waits within a fixed bound until every explicitly deleted",
            "runtime UUID is absent from repeatedly validated",
            "refuses to start the iOS 18.4 phase",
            "if an iOS 26.0 runtime image",
            "remains in CoreSimulator storage",
            "post-cleanup free-space report",
            "requires exactly one compatible runtime",
            "Main Menu-to-Dark Reader direct popup path",
            "uBlock Origin Lite is",
            "below its iOS 26.0 minimum",
            "uniquely re-resolves the",
            "deletable iOS 18.4 runtime UUID",
            "waits for that exact UUID",
            "to disappear from validated inventory",
            "records the reclaimed space before",
            "obtaining iOS 26.0 with the same download mechanism",
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
            self.assertIn(documented_contract, self.documentation)
        self.assertNotIn("image-provided iOS 26.0", self.documentation)
        self.assertIn(
            '"required_status_checks": ["Validate workflows", '
            '"Build and unit test"]',
            self.documentation,
        )


if __name__ == "__main__":
    unittest.main()
