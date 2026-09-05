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
