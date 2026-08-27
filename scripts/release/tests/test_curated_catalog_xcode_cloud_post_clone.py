"""Contract tests for the Xcode Cloud candidate-source pre-archive gate."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
GUARD = REPOSITORY_ROOT / "firefox-ios/ci_scripts/verify_curated_catalog_candidate_source.sh"


def run(command: list[str], *, cwd: Path | None = None) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()


class CuratedCatalogXcodeCloudPostCloneTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.remote = root / "origin.git"
        self.repository = root / "checkout"
        run(["git", "init", "--bare", str(self.remote)])
        run(["git", "init", str(self.repository)])
        run(["git", "config", "user.email", "catalog-test@example.invalid"], cwd=self.repository)
        run(["git", "config", "user.name", "Catalog Test"], cwd=self.repository)
        # Keep this disposable repository independent of a developer's global
        # commit-signing configuration. This does not affect release commits.
        run(["git", "config", "commit.gpgsign", "false"], cwd=self.repository)
        (self.repository / "README").write_text("candidate\n", encoding="utf-8")
        run(["git", "add", "README"], cwd=self.repository)
        run(["git", "commit", "-m", "candidate"], cwd=self.repository)
        run(["git", "branch", "-M", "main"], cwd=self.repository)
        run(["git", "remote", "add", "origin", str(self.remote)], cwd=self.repository)
        run(["git", "push", "-u", "origin", "main"], cwd=self.repository)
        self.commit = run(["git", "rev-parse", "HEAD"], cwd=self.repository)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def guard_environment(self, **overrides: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "CI_GIT_REF": f"refs/tags/floorp-catalog-{self.commit}",
                "CI_TAG": f"floorp-catalog-{self.commit}",
                "CI_COMMIT": self.commit,
                "CI_WORKFLOW": "Floorp TestFlight Manual",
                "CI_START_CONDITION": "manual",
                "CI_BUNDLE_ID": "app.floorp.Floorp",
            }
        )
        environment.update(overrides)
        return environment

    def invoke_guard(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(GUARD), str(self.repository)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.guard_environment(**overrides),
        )

    def test_accepts_the_exact_manual_tag_at_the_current_main_commit(self) -> None:
        result = self.invoke_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_a_tag_that_does_not_name_the_checked_out_commit(self) -> None:
        result = self.invoke_guard(CI_COMMIT="a" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not bind", result.stderr)

    def test_candidate_tag_in_ci_tag_cannot_bypass_a_missing_git_ref(self) -> None:
        result = self.invoke_guard(CI_GIT_REF="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git ref does not match CI_TAG", result.stderr)

    def test_rejects_an_automatic_candidate_start(self) -> None:
        result = self.invoke_guard(CI_START_CONDITION="push")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manual Xcode Cloud tag build", result.stderr)

    def test_rejects_a_tag_when_main_has_advanced(self) -> None:
        (self.repository / "README").write_text("advanced\n", encoding="utf-8")
        run(["git", "add", "README"], cwd=self.repository)
        run(["git", "commit", "-m", "advance main"], cwd=self.repository)
        run(["git", "push", "origin", "main"], cwd=self.repository)
        run(["git", "checkout", "--detach", self.commit], cwd=self.repository)

        result = self.invoke_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the current main commit", result.stderr)

    def test_ordinary_branch_builds_remain_unaffected(self) -> None:
        result = self.invoke_guard(CI_GIT_REF="refs/heads/main", CI_TAG="")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
