import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[3]


class FloorpCIPythonContractTests(unittest.TestCase):
    @staticmethod
    def _webkit_lifecycle_guard(workflow):
        guard_name = "      - name: Reject unsafe WebKit lifecycle diagnostics\n"
        guard = workflow.split(guard_name, 1)[1].split("\n      - name:", 1)[0]
        return guard_name, guard

    @staticmethod
    def _webkit_lifecycle_guard_script(guard):
        run_marker = "        run: |\n"
        return textwrap.dedent(guard.split(run_marker, 1)[1])

    def test_primary_ci_runs_release_contract_suites(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("name: Run Floorp release contract tests", workflow)
        self.assertIn(
            "python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'",
            workflow,
        )
        self.assertIn(
            "python3 -m unittest discover -s scripts/staging/tests -p 'test_*.py'",
            workflow,
        )

    def test_ubol_production_host_integration_runs_in_an_isolated_process(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        test_identifier = (
            "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
            "testBundledUBOLBlocksProductionHostTabsAndRendersDashboard"
        )
        unit_step = workflow.split("      - name: Run unit tests\n", 1)[1].split(
            "\n      - name:", 1
        )[0]
        isolated_step = workflow.split(
            "      - name: Run uBlock Origin Lite production-host integration\n", 1
        )[1].split("\n      - name:", 1)[0]
        acceptance = workflow.index(
            "      - name: Run uBlock Origin Lite release acceptance\n"
        )
        isolated = workflow.index(
            "      - name: Run uBlock Origin Lite production-host integration\n"
        )

        self.assertIn(f"-skip-testing:{test_identifier}", unit_step)
        self.assertIn(f"-only-testing:{test_identifier}", isolated_step)
        self.assertIn("FloorpUBOLProductionHost.xcresult", isolated_step)
        self.assertIn("timeout-minutes: 15", isolated_step)
        self.assertIn("-default-test-execution-time-allowance 720", isolated_step)
        self.assertIn("-maximum-test-execution-time-allowance 720", isolated_step)
        self.assertIn(
            "testBundledUBOLBlocksProductionHostTabsAndRendersDashboard]' passed",
            isolated_step,
        )
        self.assertLess(isolated, acceptance)

    def test_primary_ci_centrally_rejects_unsafe_webkit_lifecycle_diagnostics(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        guard_name, guard = self._webkit_lifecycle_guard(workflow)
        signatures = (
            "Completion handler for function call is no longer reachable",
            "InvalidTransition",
        )
        logs = (
            '$RUNNER_TEMP/test.log',
            '$RUNNER_TEMP/ubol-production-host.log',
            '$RUNNER_TEMP/ubol-release-acceptance.log',
        )

        self.assertIn("if: always()", guard)
        self.assertNotIn("continue-on-error:", guard)
        for signature in signatures:
            self.assertIn(signature, guard)
            self.assertEqual(workflow.count(signature), 1)
        for log in logs:
            self.assertIn(log, guard)
            self.assertEqual(guard.count(log), 1)
        self.assertIn('[[ -f "$log" ]] || return 0', guard)
        self.assertIn('if [[ "$grep_status" -ne 1 ]]', guard)
        self.assertIn("violations=1", guard)
        self.assertIn('exit "$violations"', guard)
        for producer in (
            "      - name: Run unit tests\n",
            "      - name: Run uBlock Origin Lite production-host integration\n",
            "      - name: Run uBlock Origin Lite release acceptance\n",
        ):
            self.assertLess(workflow.index(producer), workflow.index(guard_name))

    def test_ubol_acceptance_uses_one_owned_page_per_readiness_lifecycle(self):
        source = (
            ROOT
            / "firefox-ios/firefox-ios-tests/Tests/ClientTests/Coordinators/"
            "FloorpUBOLWebKitDiagnosticsTests.swift"
        ).read_text()
        host_source = (
            ROOT
            / "firefox-ios/Floorp/NativeWebExtensions/"
            "FloorpNativeWebExtensionHost.swift"
        ).read_text()
        session = source.split(
            "private final class FloorpUBOLReleaseAcceptanceSession {\n", 1
        )[1].split("\nprivate enum FloorpUBOLDNRDiagnosticError", 1)[0]
        run = session.split(
            "    func run() async throws -> FloorpUBOLReleaseAcceptanceReport {\n", 1
        )[1].split("\n    private func inspectActionPopup", 1)[0]
        initial_readiness = session.split(
            "    private func prepareInitialExtensionPage() async throws {\n", 1
        )[1].split("\n    private func inspectActionPopup", 1)[0].split(
            '        print("FLOORP_UBOL_RELEASE_GATE context-loaded")\n', 1
        )[1]
        warm_readiness = session.split(
            "    private func verifyBackgroundWakePreservesState() async throws\n", 1
        )[1].split("\n    private static func makeContext", 1)[0]
        page_factory = session.split(
            "    private static func makeExtensionPage(\n", 1
        )[1].split("\n    private static func waitUntilBackgroundIsReady", 1)[0]
        navigation_waiter = source.split(
            "private final class FloorpUBOLNavigationWaiter: NSObject, WKNavigationDelegate {\n",
            1,
        )[1].split("\n@MainActor\nprivate final class FloorpUBOLDiagnosticControllerDelegate", 1)[0]

        self.assertNotIn("makeReadyExtensionPage", session)
        self.assertNotIn("extension-page-attempt", session)
        self.assertEqual(page_factory.count("WKWebView(frame:"), 1)
        self.assertNotIn("for attempt in", page_factory)
        self.assertNotIn("floorpTearDownDiagnosticWebViewIfSafe", page_factory)

        lifecycle_tokens = (
            "makeExtensionPage(context: context)",
            "retainedExtensionWebView = readyPage.webView",
            "extensionNavigationWaiter = readyPage.waiter",
            "readyPage.waiter.load(",
            "Self.loadBackgroundContent(",
            "Self.waitUntilBackgroundIsReady(",
        )
        navigation_timeouts = (
            (
                initial_readiness,
                "Self.coldExtensionPageNavigationTimeoutNanoseconds",
            ),
            (
                warm_readiness,
                "Self.warmExtensionPageNavigationTimeoutNanoseconds",
            ),
        )
        for lifecycle, expected_navigation_timeout in navigation_timeouts:
            positions = [lifecycle.index(token) for token in lifecycle_tokens]
            self.assertEqual(positions, sorted(positions))
            self.assertIn("remainingReadinessTimeout(until: readinessDeadline)", lifecycle)
            self.assertEqual(lifecycle.count("makeExtensionPage(context: context)"), 1)
            self.assertEqual(
                lifecycle.count("timeoutPolicy: .preserveWebViewForProcessLifetime"),
                1,
            )

            navigation = lifecycle.split("readyPage.waiter.load(", 1)[1].split(
                "timeoutPolicy: .preserveWebViewForProcessLifetime", 1
            )[0]
            self.assertEqual(navigation.count(expected_navigation_timeout), 1)
            self.assertIn(
                "try Self.remainingReadinessTimeout(until: readinessDeadline)",
                navigation,
            )

        self.assertIn(
            "private static let coldExtensionPageNavigationTimeoutNanoseconds: "
            "UInt64 = 30_000_000_000",
            session,
        )
        self.assertIn(
            "private static let warmExtensionPageNavigationTimeoutNanoseconds: "
            "UInt64 = 5_000_000_000",
            session,
        )
        production_readiness = host_source.split(
            "    private func waitForBundledExtensionInitialization(\n", 1
        )[1].split("\n    private func", 1)[0]
        self.assertIn(
            "let pageNavigationBudget = Self.readinessPageNavigationTimeout(\n"
            "                for: identifier,\n"
            "                mode: mode\n"
            "            )",
            production_readiness,
        )
        self.assertIn(
            "timeoutNanoseconds: min(\n"
            "                        try remainingAttemptTimeout(),\n"
            "                        pageNavigationBudget\n"
            "                    )",
            production_readiness,
        )
        self.assertEqual(
            production_readiness.count(
                "Self.readinessPageNavigationTimeout("
            ),
            1,
        )
        semantic_probe = production_readiness.split(
            "probe.callAsyncJavaScript(", 1
        )[1].split(")\n                }()", 1)[0]
        self.assertNotIn("pageNavigationBudget", semantic_probe)
        production_navigation_timeout = host_source.split(
            "    private static func readinessPageNavigationTimeout(\n"
            "        for identifier: String,\n"
            "        mode: BackgroundReadinessMode\n"
            "    ) -> UInt64 {\n",
            1,
        )[1].split("\n    private func", 1)[0]
        self.assertIn(
            "identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier",
            production_navigation_timeout,
        )
        self.assertIn(
            "identifier == FloorpNativeWebExtensionCatalog.darkReader.identifier",
            production_navigation_timeout,
        )
        self.assertIn("case .coldLifecycle = mode", production_navigation_timeout)
        self.assertEqual(
            production_navigation_timeout.count("return 30_000_000_000"),
            2,
        )
        self.assertIn("return 15_000_000_000", production_navigation_timeout)
        self.assertEqual(host_source.count("mode: .coldLifecycle"), 4)

        preserve_timeout = navigation_waiter.split(
            "case .preserveWebViewForProcessLifetime:\n", 1
        )[1].split("self.complete(.failure", 1)[0]
        self.assertIn(
            "FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.retain(webView)",
            preserve_timeout,
        )
        self.assertNotIn("stopLoading()", preserve_timeout)
        self.assertNotIn("navigationDelegate = nil", preserve_timeout)

        japanese_markers = (
            "japanese-enable-rulesets",
            "japanese-count-rules",
            "japanese-restore-session",
            "japanese-wait-scripts",
            "japanese-inspect-registrations",
            "japanese-load-page",
            "japanese-complete",
        )
        marker_positions = [run.index(marker) for marker in japanese_markers]
        self.assertEqual(marker_positions, sorted(marker_positions))
        for marker in japanese_markers:
            self.assertEqual(run.count(marker), 1)

    def test_ubol_ruleset_acceptance_uses_the_shipping_foreground_transaction(self):
        source = (
            ROOT
            / "firefox-ios/firefox-ios-tests/Tests/ClientTests/Coordinators/"
            "FloorpUBOLWebKitDiagnosticsTests.swift"
        ).read_text()
        apply_rulesets = source.split(
            "    private func applyRulesets(_ identifiers: [String]) async throws -> [String] {\n",
            1,
        )[1].split("\n    private func setDefaultFilteringMode", 1)[0]

        self.assertIn("browser.runtime.getURL('js/floorp-reconcile.js')", apply_rulesets)
        self.assertIn("module.reconcileProtection({", apply_rulesets)
        self.assertIn("response?.ready !== true", apply_rulesets)
        self.assertIn(
            "timeoutNanoseconds: Self.coldBackgroundReadinessTimeoutNanoseconds",
            apply_rulesets,
        )
        self.assertNotIn("rulesets.enableRulesets", apply_rulesets)

    def test_ubol_release_acceptance_exercises_cold_document_start_before_prewake(self):
        source = (
            ROOT
            / "firefox-ios/firefox-ios-tests/Tests/ClientTests/Coordinators/"
            "FloorpUBOLWebKitDiagnosticsTests.swift"
        ).read_text()
        session = source.split(
            "private final class FloorpUBOLReleaseAcceptanceSession {\n", 1
        )[1].split("\nprivate enum FloorpUBOLDNRDiagnosticError", 1)[0]
        run = session.split(
            "    func run() async throws -> FloorpUBOLReleaseAcceptanceReport {\n", 1
        )[1].split("\n    private func prepareInitialExtensionPage", 1)[0]
        cold_document_start = session.split(
            "    private func verifyDocumentStartAfterBackgroundIdleWindow(\n", 1
        )[1].split("\n    private func verifyBackgroundWakePreservesState", 1)[0]
        report = source.split(
            "private struct FloorpUBOLReleaseAcceptanceReport: Codable {\n", 1
        )[1].split("\nprivate struct FloorpUBOLPopupAcceptance", 1)[0]

        run_tokens = (
            "try await removeAcceptanceDNRRules()",
            "verifyDocumentStartAfterBackgroundIdleWindow(",
            "verifyBackgroundWakePreservesState()",
        )
        positions = [run.index(token) for token in run_tokens]
        self.assertEqual(positions, sorted(positions))

        cold_tokens = (
            "retainedExtensionWebView?.floorpTearDownDiagnosticWebViewIfSafe()",
            "try await Task.sleep(nanoseconds: 35_000_000_000)",
            'print("FLOORP_UBOL_RELEASE_GATE background-wake-document-start")',
            "let result = try await loadAndInspect(",
            "customCosmeticSettleTimeoutNanoseconds:\n"
            "                Self.customCosmeticActivationTimeoutNanoseconds",
            "navigationTimeoutPolicy: .preserveWebViewForProcessLifetime",
        )
        positions = [cold_document_start.index(token) for token in cold_tokens]
        self.assertEqual(positions, sorted(positions))
        for forbidden in (
            "makeExtensionPage(",
            "loadBackgroundContent(",
            "waitUntilBackgroundIsReady(",
        ):
            self.assertNotIn(forbidden, cold_document_start)

        load_and_inspect = session.split(
            "    private func loadAndInspect(\n", 1
        )[1].split("\n    private func inspectCrossHostCustomFilterIsolation", 1)[0]
        self.assertIn(
            "customCosmeticSettleTimeoutNanoseconds: UInt64 = 15_000_000_000",
            load_and_inspect,
        )
        self.assertIn(
            "private static let customCosmeticActivationTimeoutNanoseconds: UInt64 "
            "= 15_000_000_000",
            session,
        )
        self.assertIn("let settleDeadline = Self.makeReadinessDeadline(", load_and_inspect)
        self.assertIn("let requiredSamples = 8", load_and_inspect)
        self.assertIn("var observedUnexpectedState = false", load_and_inspect)
        self.assertIn(
            "if !expectedCustomCosmeticFilters {\n"
            "                    break\n"
            "                }",
            load_and_inspect,
        )
        self.assertIn(
            "!observedUnexpectedState && consecutiveExpectedSamples >= requiredSamples",
            load_and_inspect,
        )
        self.assertIn(
            "if expectedCustomCosmeticFilters,\n"
            "                   consecutiveExpectedSamples >= requiredSamples",
            load_and_inspect,
        )
        self.assertIn("guard now < settleDeadline else { break }", load_and_inspect)
        self.assertNotIn("for _ in 0..<20", load_and_inspect)

        self.assertIn("let coldDocumentStart: FloorpUBOLPageAcceptance", report)
        self.assertIn("coldDocumentStart.customCosmeticHidden", report)
        self.assertIn("coldDocumentStart.proceduralCosmeticHidden", report)
        self.assertIn("coldDocumentStart.originFallbackCustomCosmeticHidden", report)
        self.assertIn("coldDocumentStart.originFallbackProceduralCosmeticHidden", report)

    def test_ubol_release_acceptance_exercises_origin_fallback_frames(self):
        source = (
            ROOT
            / "firefox-ios/firefox-ios-tests/Tests/ClientTests/Coordinators/"
            "FloorpUBOLWebKitDiagnosticsTests.swift"
        ).read_text()
        session = source.split(
            "private final class FloorpUBOLReleaseAcceptanceSession {\n", 1
        )[1].split("\nprivate enum FloorpUBOLDNRDiagnosticError", 1)[0]
        report = source.split(
            "private struct FloorpUBOLReleaseAcceptanceReport: Codable {\n", 1
        )[1].split("\nprivate struct FloorpUBOLPopupAcceptance", 1)[0]

        self.assertIn('id="floorp-origin-fallback-frame" srcdoc=', session)
        self.assertIn(
            "originFallbackCustom:\n"
            "                    hidden(originFallbackDocument, 'floorp-custom-cosmetic') &&\n"
            "                    hidden(originFallbackDocument, 'floorp-custom-form-control')",
            session,
        )
        self.assertIn("originFallbackProcedural: hidden(", session)
        self.assertIn('id="floorp-cross-origin-frame"', session)
        self.assertIn("!states.crossOriginCustom", session)
        self.assertIn("document.adoptedStyleSheets = [];", session)
        self.assertIn("name.startsWith('data-floorp-ubol-')", session)
        self.assertIn("originFallbackCustomCosmeticHidden: hidden(", session)
        self.assertIn("originFallbackProceduralCosmeticHidden: hidden(", session)
        for page in ("optimal", "crossHostReturn", "privateBrowsing", "coldDocumentStart"):
            self.assertIn(f"{page}.originFallbackCustomCosmeticHidden", report)
            self.assertIn(f"{page}.originFallbackProceduralCosmeticHidden", report)
        self.assertIn("!crossHost.originFallbackCustomCosmeticHidden", report)
        self.assertIn("!crossHost.originFallbackProceduralCosmeticHidden", report)
        self.assertIn("private static let dynamicRuleID = 7_000_001", session)

    def test_webkit_lifecycle_guard_handles_logs_and_grep_failures(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        _, guard = self._webkit_lifecycle_guard(workflow)
        script = self._webkit_lifecycle_guard_script(guard)
        log_names = (
            "test.log",
            "ubol-production-host.log",
            "ubol-release-acceptance.log",
        )
        signatures = (
            "Completion handler for function call is no longer reachable",
            "InvalidTransition",
        )

        def run_guard(directory, path=None):
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = str(directory)
            if path is not None:
                environment["PATH"] = f"{path}{os.pathsep}{environment['PATH']}"
            return subprocess.run(
                ["bash", "-c", script],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            result = run_guard(Path(temporary_directory))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            (directory / log_names[-1]).write_text(signatures[-1] + "\n")
            result = run_guard(directory)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn(log_names[-1], result.stdout)

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            for log_name in log_names:
                (directory / log_name).write_text("clean test output\n")
            result = run_guard(directory)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        for log_name in log_names:
            for signature in signatures:
                with self.subTest(log=log_name, signature=signature):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        directory = Path(temporary_directory)
                        for candidate in log_names:
                            contents = signature if candidate == log_name else "clean"
                            (directory / candidate).write_text(contents + "\n")
                        result = run_guard(directory)
                        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                        self.assertIn(log_name, result.stdout)

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            for log_name in log_names:
                (directory / log_name).write_text("clean test output\n")
            fake_bin = directory / "fake-bin"
            fake_bin.mkdir()
            fake_grep = fake_bin / "grep"
            fake_grep.write_text("#!/bin/sh\nexit 2\n")
            fake_grep.chmod(0o755)

            result = run_guard(directory, path=fake_bin)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("could not be scanned", result.stdout)


if __name__ == "__main__":
    unittest.main()
