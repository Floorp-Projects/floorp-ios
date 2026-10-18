import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[3]
GATE = "Repeat WebKit observer regression without retries"
UPLOAD = "Upload WebKit observer stability result"
IDENTIFIER = "WebEngineTests/WKEngineWebViewTests/testLoad_callsObservers"


def passed_results():
    return {"testNodes": [{
        "nodeType": "Test Plan", "name": "Floorp CI", "result": "Passed", "children": [{
            "nodeType": "Unit test bundle", "name": "WebEngineTests", "result": "Passed", "children": [{
                "nodeType": "Test Suite", "name": "WKEngineWebViewTests", "result": "Passed", "children": [{
                    "nodeType": "Test Case", "nodeIdentifier": "WKEngineWebViewTests/testLoad_callsObservers()",
                    "result": "Passed", "children": [
                        {"nodeType": "Repetition", "nodeIdentifier": str(number), "result": "Passed"}
                        for number in range(1, 11)
                    ],
                }],
            }],
        }],
    }]}


class WebViewObserverStabilityWorkflowTests(unittest.TestCase):
    @staticmethod
    def workflow():
        return (ROOT / ".github/workflows/ci.yml").read_text()

    def step(self, name):
        marker = f"      - name: {name}\n"
        workflow = self.workflow()
        self.assertEqual(workflow.count(marker), 1)
        return workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]

    def script(self):
        return textwrap.dedent(self.step(GATE).split("        run: |\n", 1)[1])

    def test_exact_native_test_runs_ten_fresh_launches_before_full_suite(self):
        workflow, step = self.workflow(), self.step(GATE)
        self.assertLess(workflow.index(GATE), workflow.index("      - name: Run unit tests\n"))
        self.assertIn("timeout-minutes: 15", step)
        self.assertIn("set -euo pipefail", step)
        self.assertIn(f"-only-testing:{IDENTIFIER} ", step)
        self.assertEqual(step.count("-only-testing:"), 1)
        for flag in ("-parallel-testing-enabled NO", "-test-iterations 10",
                     "-test-repetition-relaunch-enabled YES", "-test-timeouts-enabled YES"):
            self.assertIn(flag, step)
        for weakened in ("-retry-tests-on-failure", "-run-tests-until-failure", "continue-on-error:", "|| true"):
            self.assertNotIn(weakened, step)
        self.assertNotIn("if:", step.split("        run:", 1)[0])
        self.assertIn("xcrun xcresulttool get test-results tests", step)
        self.assertIn("python3 scripts/ci/check-repeated-xctest-results.py", step)
        self.assertIn(f"--test '{IDENTIFIER}()'", step)
        self.assertIn("--repetitions 10", step)

    def test_result_artifact_is_published_immediately_even_after_failure(self):
        workflow, upload = self.workflow(), self.step(UPLOAD)
        gate_end = workflow.index(f"      - name: {GATE}\n") + len(f"      - name: {GATE}\n")
        self.assertEqual(workflow[gate_end:].split("\n      - name:", 2)[1].splitlines()[0], f" {UPLOAD}")
        self.assertIn("if: always()", upload)
        self.assertIn("name: floorp-webview-observer-stability-${{ github.run_id }}", upload)
        for evidence in ("FloorpWebViewObserverStability.xcresult", "webview-observer-stability.log",
                         "webview-observer-stability-tests.json"):
            self.assertIn(f"${{{{ runner.temp }}}}/{evidence}", upload)
        self.assertIn("if-no-files-found: warn", upload)

    def run_gate(self, data=None, native_status=0, export_status=0, output="clean native output"):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary = directory / "bin"
            binary.mkdir()
            native = binary / "xcodebuild"
            native.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" > "$RUNNER_TEMP/native-arguments.txt"\n'
                'printf "%s\\n" "$FLOORP_TEST_OUTPUT"\nexit "$FLOORP_TEST_NATIVE_STATUS"\n'
            )
            export = binary / "xcrun"
            export.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" > "$RUNNER_TEMP/export-arguments.txt"\n'
                'if [ "$FLOORP_TEST_EXPORT_STATUS" -ne 0 ]; then exit "$FLOORP_TEST_EXPORT_STATUS"; fi\n'
                'cat "$FLOORP_TEST_RESULTS"\n'
            )
            native.chmod(0o755)
            export.chmod(0o755)
            fixture = directory / "fixture.json"
            fixture.write_text(json.dumps(passed_results() if data is None else data))
            environment = dict(os.environ, RUNNER_TEMP=str(directory), PROJECT_PATH="project", SCHEME="Fennec",
                               CONFIGURATION="Fennec_Testing", DESTINATION="simulator",
                               FLOORP_TEST_OUTPUT=output, FLOORP_TEST_NATIVE_STATUS=str(native_status),
                               FLOORP_TEST_EXPORT_STATUS=str(export_status), FLOORP_TEST_RESULTS=str(fixture))
            environment["PATH"] = f"{binary}{os.pathsep}{environment['PATH']}"
            process = subprocess.run(["bash", "-c", self.script()], cwd=ROOT, env=environment,
                                     capture_output=True, text=True, check=False)
            arguments = {}
            for name in ("native", "export"):
                path = directory / f"{name}-arguments.txt"
                arguments[name] = path.read_text().splitlines() if path.exists() else None
            return process, arguments

    def test_real_shell_wiring_accepts_exact_results_and_exports_the_native_bundle(self):
        syntax = subprocess.run(["bash", "-n", "-c", self.script()], capture_output=True, text=True, check=False)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        process, arguments = self.run_gate()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn("Passed: 1 tests, 10 repetitions each", process.stdout)
        self.assertIn(f"-only-testing:{IDENTIFIER}", arguments["native"])
        self.assertEqual(arguments["export"][:4], ["xcresulttool", "get", "test-results", "tests"])
        self.assertTrue(arguments["export"][5].endswith("/FloorpWebViewObserverStability.xcresult"))

    def test_native_or_export_failure_cannot_be_masked_by_the_log_pipeline(self):
        process, arguments = self.run_gate(native_status=17)
        self.assertEqual(process.returncode, 17, process.stdout + process.stderr)
        self.assertIsNone(arguments["export"])
        process, _ = self.run_gate(export_status=19)
        self.assertEqual(process.returncode, 19, process.stdout + process.stderr)

    def test_dependency_teardown_crash_fails_before_export(self):
        process, arguments = self.run_gate(output="Fatal error: No definition registered for type: Service")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Repeated test host resolved", process.stdout)
        self.assertIsNone(arguments["export"])

    def test_real_checker_rejects_wrong_case_skips_failures_missing_runs_and_hidden_retries(self):
        for mutation in ("wrong-bundle", "skipped", "failed", "missing", "hidden-retry"):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(passed_results())
                bundle = data["testNodes"][0]["children"][0]
                case = bundle["children"][0]["children"][0]
                if mutation == "wrong-bundle":
                    bundle["name"] = "WrongTests"
                elif mutation in ("skipped", "failed"):
                    case["children"][0]["result"] = mutation.capitalize()
                elif mutation == "missing":
                    case["children"].pop()
                else:
                    case["children"][0]["children"] = [{"nodeType": "Attempt", "result": "Passed"}]
                process, _ = self.run_gate(data=data)
                self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
                self.assertIn("Invalid repeated XCTest results:", process.stderr)


if __name__ == "__main__":
    unittest.main()
