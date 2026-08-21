"""Contract tests for the protected Todo 20 live executor."""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/ci/floorp_notes_sync_live_executor.py"
RUNNER_PATH = ROOT / "scripts/ci/run-floorp-notes-sync-production-qa.py"


def load_module():
    sys.path.insert(0, str(MODULE_PATH.parent))
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_live_executor_test", MODULE_PATH
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load live executor")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def load_runner():
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_live_runner_test", RUNNER_PATH
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load live runner")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


EXECUTOR = load_module()
RUNNER = load_runner()


class FakeBrowser:
    def __init__(self, href: str):
        self.href = href

    def execute(self, _script: str, _args=None):
        return self.href


class LiveExecutorContractTests(unittest.TestCase):
    def test_private_environment_removes_all_protected_secret_names(self) -> None:
        environment = {
            name: f"sentinel-{index}"
            for index, name in enumerate(EXECUTOR.SECRET_ENV_NAMES)
        }
        environment["SAFE_MARKER"] = "retained"
        with patch.dict(os.environ, environment, clear=True):
            private = EXECUTOR.private_environment()
        self.assertEqual(private["SAFE_MARKER"], "retained")
        self.assertTrue(all(name not in private for name in EXECUTOR.SECRET_ENV_NAMES))

    @patch.object(EXECUTOR.subprocess, "run")
    def test_simulator_coordination_uses_absolute_tool_paths(self, run) -> None:
        run.return_value = SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        coordination = EXECUTOR.SimulatorCoordination(
            "simulator-udid", "/tmp/floorp-notes-sync-test"
        )

        coordination.prepare()
        coordination.write(
            actor="desktop",
            case_name=EXECUTOR.CASE_NAMES[0],
            phase="request",
            outcome="ready",
            sequence=1,
        )

        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn("/bin/mkdir", commands[0][-1])
        self.assertIn("/bin/chmod", commands[0][-1])
        self.assertIn("/bin/chmod", commands[1][-1])

    @patch.object(EXECUTOR.time, "sleep")
    @patch.object(EXECUTOR.subprocess, "run")
    def test_simulator_coordination_retries_transient_spawn_abort(self, run, sleep) -> None:
        run.side_effect = [
            SimpleNamespace(returncode=134, stdout=b"", stderr=b""),
            SimpleNamespace(returncode=0, stdout=b"", stderr=b""),
        ]
        coordination = EXECUTOR.SimulatorCoordination(
            "simulator-udid", "/tmp/floorp-notes-sync-test"
        )

        coordination.prepare()

        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(EXECUTOR.SIMULATOR_SPAWN_RETRY_DELAY_SECONDS)
        self.assertEqual(
            run.call_args_list[0].args[0][:5],
            ["xcrun", "simctl", "spawn", EXECUTOR.SIMULATOR_SPAWN_MODE, "simulator-udid"],
        )

    def test_source_binding_requires_manual_main_workflow(self) -> None:
        context = {
            "GITHUB_ACTOR": "operator",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_JOB": "notes-sync-production-qa",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": EXECUTOR.REPOSITORY,
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "123",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": f"{EXECUTOR.REPOSITORY}/{EXECUTOR.WORKFLOW_PATH}@{'a' * 40}",
        }
        with patch.dict(os.environ, context, clear=True):
            source = EXECUTOR.source_from_environment()
        self.assertEqual(source["workflow_run_id"], 123)
        context["GITHUB_REF"] = "refs/heads/feature"
        with patch.dict(os.environ, context, clear=True):
            with self.assertRaises(EXECUTOR.LiveExecutorError):
                EXECUTOR.source_from_environment()

    def test_source_binding_accepts_the_separate_public_beta_workflow(self) -> None:
        context = {
            "GITHUB_ACTOR": "operator",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_JOB": EXECUTOR.PUBLIC_BETA_JOB_NAME,
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": EXECUTOR.REPOSITORY,
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "123",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": f"{EXECUTOR.REPOSITORY}/{EXECUTOR.PUBLIC_BETA_WORKFLOW_PATH}@{'a' * 40}",
        }
        with patch.dict(os.environ, context, clear=True):
            source = EXECUTOR.source_from_environment()
        self.assertEqual(source["job_name"], EXECUTOR.PUBLIC_BETA_JOB_NAME)
        self.assertEqual(source["workflow_path"], EXECUTOR.PUBLIC_BETA_WORKFLOW_PATH)

    def test_xcodebuild_command_contains_no_account_values(self) -> None:
        args = Namespace(
            ios_project=Path("/tmp/project.xcodeproj"),
            scheme="FloorpNotesSyncG5",
            configuration="FloorpRelease",
            destination="platform=iOS Simulator,id=sim",
            test_plan="FloorpNotesSyncG5",
            result_bundle=Path("/tmp/result.xcresult"),
            derived_data=Path("/tmp/derived"),
            source_packages=Path("/tmp/packages"),
            xcconfig=Path("/tmp/qa.xcconfig"),
        )
        command = RUNNER.build_xcodebuild_command(args)
        self.assertNotIn("FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD", command)
        self.assertNotIn("sentinel-password", command)
        self.assertIn("-only-testing:XCUITests/FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix", command)

    def test_desktop_page_scope_rejects_unapproved_https_host(self) -> None:
        client = EXECUTOR.DesktopNotesClient(FakeBrowser("https://evil.example/"), set())
        with self.assertRaises(EXECUTOR.LiveExecutorError):
            client._assert_page_scope()

    def test_desktop_page_scope_records_approved_https_host(self) -> None:
        observed = set()
        client = EXECUTOR.DesktopNotesClient(
            FakeBrowser("https://accounts.firefox.com/settings"), observed
        )
        client._assert_page_scope()
        self.assertEqual(observed, {"accounts.firefox.com"})

    def test_unobserved_matrix_boundaries_fail_closed(self) -> None:
        self.assertIn("legacy_client_artifact_and_driver_missing", EXECUTOR.CASE_BLOCKERS[EXECUTOR.CASE_NAMES[7]])
        self.assertIn("upload_save_commit_failure_observation_missing", EXECUTOR.CASE_BLOCKERS[EXECUTOR.CASE_NAMES[5]])
        self.assertIn("base_revision_observation_missing", EXECUTOR.CASE_BLOCKERS[EXECUTOR.CASE_NAMES[11]])

    def test_mobile_upload_cases_pull_before_desktop_mutation(self) -> None:
        class FakeDesktop:
            def __init__(self):
                self.calls = []

            def sync_now(self):
                self.calls.append("sync")

            def edit(self, title, suffix):
                self.calls.append(("edit", title, suffix))

            def delete(self, title):
                self.calls.append(("delete", title))

            def row_count(self, title):
                self.calls.append(("row_count", title))
                return 1

        class FakeCoordination:
            def __init__(self):
                self.events = []

            def write(self, **event):
                self.events.append(event)

        executor = EXECUTOR.LiveExecutor.__new__(EXECUTOR.LiveExecutor)
        executor.desktop = FakeDesktop()
        executor.coordination = FakeCoordination()
        executor.observed_cases = []

        for index in (2, 3, 4):
            spec = SimpleNamespace(
                name=EXECUTOR.CASE_NAMES[index],
                seed=f"T20-{index + 1:02d}",
                final_sequence=(index * 4) + 4,
            )
            executor._finish_case(spec)

        calls = executor.desktop.calls
        edit_index = calls.index(("edit", "T20-03", "desktop-edit-T20-03"))
        self.assertEqual(calls[edit_index - 1], "sync")
        delete_index = calls.index(("delete", "T20-04"))
        self.assertEqual(calls[delete_index - 1], "sync")
        offline_row = calls.index(("row_count", "T20-05"))
        self.assertEqual(calls[offline_row - 1], "sync")


if __name__ == "__main__":
    unittest.main()
