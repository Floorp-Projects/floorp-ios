"""Tests for the GitHub Actions validation-clock capture client."""

from __future__ import annotations

import contextlib
import importlib.util
import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier


ROOT = Path(__file__).resolve().parents[3]
CLIENT = ROOT / "scripts/ci/create-floorp-validation-clock.sh"
WORKFLOW = ROOT / ".github/workflows/floorp-notes-sync-validation-clock.yml"
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-release.py"
SCHEMA = ROOT / "docs/floorp-notes-sync-release-evidence.schema.json"
HEAD_SHA = "330870f9d6db91433afe1024ac8200f81d260a42"


def load_embedded_clock_client() -> types.ModuleType:
    source = CLIENT.read_text(encoding="utf-8")
    python_source = source.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    module = types.ModuleType("floorp_validation_clock_client_test")
    module.__file__ = str(CLIENT)
    exec(compile(python_source, str(CLIENT), "exec"), module.__dict__)
    return module


def load_validator() -> types.ModuleType:
    module_name = "floorp_notes_sync_release_validator_for_clock_test"
    spec = importlib.util.spec_from_file_location(module_name, VALIDATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load release validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


CLOCK_CLIENT = load_embedded_clock_client()
VALIDATOR_MODULE = load_validator()


MOCK_GH = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
state = Path(os.environ["MOCK_GH_STATE"])
log = Path(os.environ["MOCK_GH_LOG"])
head = os.environ.get("MOCK_HEAD_SHA", "330870f9d6db91433afe1024ac8200f81d260a42")
job_conclusion = os.environ.get("MOCK_JOB_CONCLUSION", "success")
run_id = 987654321
workflow_id = 123456789
workflow_path = ".github/workflows/floorp-notes-sync-validation-clock.yml"

with log.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args, separators=(",", ":")) + "\n")
if os.environ.get("MOCK_REQUIRE_HOSTNAME") == "1" and args[:3] != ["api", "--hostname", "github.com"]:
    print(f"missing pinned GitHub hostname: {args}", file=sys.stderr)
    raise SystemExit(4)

joined = " ".join(args)
if "dispatches" in joined:
    if os.environ.get("MOCK_FAIL_DISPATCH") == "1":
        raise SystemExit(9)
    nonce_arg = next(item for item in args if item.startswith("inputs[clock_nonce]="))
    state.write_text(nonce_arg.split("=", 1)[1])
    raise SystemExit(0)

if "/runs" in joined and not state.exists():
    print(json.dumps({"workflow_runs": []}))
    raise SystemExit(0)

nonce = state.read_text()
display_title = f"Floorp Notes Sync validation clock {nonce}"
run = {
    "conclusion": "success",
    "created_at": "2026-08-09T23:59:00Z",
    "display_title": display_title,
    "event": "workflow_dispatch",
    "head_sha": head,
    "html_url": f"https://github.com/Floorp-Projects/floorp-ios/actions/runs/{run_id}",
    "id": run_id,
    "path": f"{workflow_path}@{head}",
    "repository": {"full_name": "Floorp-Projects/floorp-ios"},
    "run_attempt": 1,
    "status": "completed",
    "updated_at": "2026-08-10T00:00:00Z",
    "url": f"https://api.github.com/repos/Floorp-Projects/floorp-ios/actions/runs/{run_id}",
    "workflow_id": workflow_id,
}

if "/jobs" in joined:
    print(json.dumps({"total_count": 1, "jobs": [{
        "completed_at": "2026-08-10T00:00:00Z",
        "conclusion": job_conclusion,
        "id": 987654322,
        "name": "validation-clock",
        "run_attempt": 1,
        "run_id": run_id,
        "started_at": "2026-08-09T23:59:00Z",
        "status": "completed",
    }]}))
elif "--include" in args:
    print("HTTP/2.0 200 OK")
    print("Date: Mon, 10 Aug 2026 00:02:00 GMT")
    print("Content-Type: application/json")
    print()
    print(json.dumps(run))
elif "/runs" in joined:
    print(json.dumps({"workflow_runs": [run]}))
else:
    print(f"unexpected mock gh arguments: {args}", file=sys.stderr)
    raise SystemExit(3)
'''


class ValidationClockClientTests(unittest.TestCase):
    @staticmethod
    def client_arguments(output: Path) -> list[str]:
        return [
            "--repository",
            "Floorp-Projects/floorp-ios",
            "--workflow",
            "floorp-notes-sync-validation-clock.yml",
            "--expected-head",
            HEAD_SHA,
            "--max-age-seconds",
            "300",
            "--output",
            str(output),
            "--poll-interval-seconds",
            "0",
            "--timeout-seconds",
            "5",
        ]

    def run_client(
        self,
        *,
        preseed_run: bool = False,
        **environment_overrides: str,
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path, dict[str, str]]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        mock_gh = directory / "gh"
        mock_gh.write_text(MOCK_GH, encoding="utf-8")
        mock_gh.chmod(mock_gh.stat().st_mode | stat.S_IXUSR)
        output = directory / "clock.json"
        environment = os.environ.copy()
        for name in CLOCK_CLIENT.UNSAFE_GITHUB_ENVIRONMENT:
            environment.pop(name, None)
        state = directory / "state"
        environment["MOCK_GH_STATE"] = str(state)
        environment["MOCK_GH_LOG"] = str(directory / "gh.log")
        environment["MOCK_REQUIRE_HOSTNAME"] = "1"
        environment.update(environment_overrides)
        if preseed_run:
            nonce_input = "\n".join(
                (
                    "Floorp-Projects/floorp-ios",
                    "floorp-notes-sync-validation-clock.yml",
                    HEAD_SHA,
                    str(output.resolve()),
                )
            ).encode("utf-8")
            state.write_text(hashlib.sha256(nonce_input).hexdigest()[:32], encoding="utf-8")
            environment["MOCK_FAIL_DISPATCH"] = "1"
        arguments = self.client_arguments(output)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            returncode = CLOCK_CLIENT.main(
                arguments,
                test_gh_bin=mock_gh,
                test_environment=environment,
            )
        result = subprocess.CompletedProcess(arguments, returncode, stdout.getvalue(), stderr.getvalue())
        return result, output, mock_gh, environment

    def test_workflow_is_minimal_read_only_and_has_no_checkout(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", source)
        self.assertIn("contents: read", source)
        self.assertIn("clock_nonce:", source)
        self.assertNotIn("actions/checkout", source)
        self.assertNotIn("pull_request:", source)
        self.assertNotIn("push:", source)
        self.assertNotIn("schedule:", source)

    def test_happy_path_writes_canonical_terminal_manifest(self):
        result, output, mock_gh, environment = self.run_client()
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = output.read_bytes()
        manifest = json.loads(raw)
        self.assertEqual(raw, json.dumps(manifest, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode())
        self.assertEqual(manifest["run"]["head_sha"], HEAD_SHA)
        self.assertEqual(manifest["run"]["attempt"], 1)
        self.assertEqual(manifest["github_http_date"], "Mon, 10 Aug 2026 00:02:00 GMT")
        self.assertEqual(manifest["jobs"][0]["conclusion"], "success")
        gh_calls = [
            json.loads(line)
            for line in Path(environment["MOCK_GH_LOG"]).read_text(encoding="utf-8").splitlines()
        ]
        self.assertGreaterEqual(len(gh_calls), 4)
        self.assertTrue(all(call[:3] == ["api", "--hostname", "github.com"] for call in gh_calls))

        validator_environment = dict(environment)
        validator_environment["MOCK_REQUIRE_HOSTNAME"] = "0"
        schema = VALIDATOR_MODULE.load_pinned_schema(ROOT, SCHEMA)
        trusted_gh = VALIDATOR_MODULE.select_gh_executable(mock_gh)
        trusted_environment = VALIDATOR_MODULE.trusted_gh_environment(
            validator_environment
        )
        trusted_now = VALIDATOR_MODULE.validate_clock(
            manifest,
            schema,
            HEAD_SHA,
            None,
            trusted_gh,
            trusted_environment,
        )
        self.assertEqual(trusted_now.isoformat(), "2026-08-10T00:02:00+00:00")

    def test_wrong_head_fails_without_manifest(self):
        result, output, _, _ = self.run_client(MOCK_HEAD_SHA="8" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_retry_resumes_existing_nonce_without_duplicate_dispatch(self):
        result, output, _, _ = self.run_client(preseed_run=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())

    def test_failed_job_fails_without_manifest(self):
        result, output, _, _ = self.run_client(MOCK_JOB_CONCLUSION="failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_public_cli_rejects_all_github_tool_overrides(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for option in ("--gh-bin", "--test-gh-bin"):
                with self.subTest(option=option):
                    output = directory / f"{option[2:]}.json"
                    result = subprocess.run(
                        [str(CLIENT), *self.client_arguments(output), option, "/tmp/fake-gh"],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("unrecognized arguments", result.stderr)
                    self.assertFalse(output.exists())

    def test_public_entrypoint_ignores_path_toolchain_replacements(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marker = directory / "fake-toolchain-ran"
            replacement = f"#!/bin/sh\ntouch '{marker}'\nexit 99\n"
            for executable_name in ("bash", "python3"):
                executable = directory / executable_name
                executable.write_text(replacement, encoding="utf-8")
                executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
            environment = os.environ.copy()
            environment["PATH"] = f"{directory}:{environment.get('PATH', '')}"

            result = subprocess.run(
                [str(CLIENT), "--help"],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("trusted Floorp Notes Sync validation clock", result.stdout)
            self.assertFalse(marker.exists())

    def test_network_redirection_environment_is_rejected_before_github_access(self):
        unsafe_values = {
            "GH_HOST": "attacker.invalid",
            "GH_HTTP_UNIX_SOCKET": "/tmp/attacker.sock",
            "GITHUB_API_URL": "https://attacker.invalid/api",
            "HTTPS_PROXY": "https://attacker.invalid:8443",
            "NODE_EXTRA_CA_CERTS": "/tmp/attacker-node-ca.pem",
            "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
        }
        for name, value in unsafe_values.items():
            with self.subTest(name=name):
                result, output, _, environment = self.run_client(**{name: value})
                self.assertEqual(result.returncode, 1)
                self.assertIn(name, result.stderr)
                self.assertFalse(output.exists())
                log = Path(environment["MOCK_GH_LOG"])
                self.assertFalse(log.exists(), "unsafe environment reached the GitHub executable")

    def test_github_environment_is_allowlisted(self):
        source = {
            "HOME": "/Users/release",
            "GH_TOKEN": "test-token",
            "PATH": "/tmp/attacker-bin",
            "GH_PAGER": "/tmp/attacker-pager",
            "PYTHONPATH": "/tmp/attacker-python",
            "MOCK_GH_STATE": "/tmp/mock-state",
        }

        production = CLOCK_CLIENT.hardened_gh_environment(source)
        test_environment = CLOCK_CLIENT.hardened_gh_environment(
            source,
            include_test_controls=True,
        )

        self.assertEqual(
            production,
            {
                "GH_PROMPT_DISABLED": "1",
                "GH_TOKEN": "test-token",
                "HOME": "/Users/release",
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            },
        )
        self.assertEqual(test_environment["MOCK_GH_STATE"], "/tmp/mock-state")
        self.assertNotIn("GH_PAGER", test_environment)
        self.assertNotIn("PYTHONPATH", test_environment)

    def test_existing_manifest_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "clock.json"
            marker = b'{"existing":true}'
            output.write_bytes(marker)
            with self.assertRaises(CLOCK_CLIENT.ClockError):
                CLOCK_CLIENT.write_atomic(output, {"replacement": True})
            self.assertEqual(output.read_bytes(), marker)

    def test_dangling_symlink_manifest_is_never_replaced_or_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            missing_target = directory / "missing-target.json"
            output = directory / "clock.json"
            output.symlink_to(missing_target)
            self.assertFalse(output.exists())

            with self.assertRaises(CLOCK_CLIENT.ClockError):
                CLOCK_CLIENT.write_atomic(output, {"replacement": True})

            self.assertTrue(output.is_symlink())
            self.assertEqual(output.readlink(), missing_target)
            self.assertFalse(missing_target.exists())

    def test_concurrent_atomic_publication_has_exactly_one_winner(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "clock.json"
            barrier = Barrier(2)
            candidates = ({"writer": "first"}, {"writer": "second"})

            def publish(value: dict[str, str]) -> str:
                barrier.wait()
                try:
                    CLOCK_CLIENT.write_atomic(output, value)
                    return "published"
                except CLOCK_CLIENT.ClockError:
                    return "rejected"

            with ThreadPoolExecutor(max_workers=2) as executor:
                outcomes = list(executor.map(publish, candidates))

            self.assertEqual(sorted(outcomes), ["published", "rejected"])
            self.assertIn(json.loads(output.read_bytes()), candidates)
            self.assertEqual(list(directory.glob(".clock.json.*")), [])


if __name__ == "__main__":
    unittest.main()
