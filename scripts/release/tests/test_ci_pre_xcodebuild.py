"""Contract tests for the Xcode Cloud pre-xcodebuild source binding."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "firefox-ios" / "ci_scripts" / "ci_pre_xcodebuild.sh"
CONFIG_RELATIVE = Path("firefox-ios/Client/Configuration/FloorpRelease.xcconfig")
APP_STORE_CONNECT_TEAM_ID = "74c6a531-19e2-4ed5-a34b-915003cc10f9"
SIGNING_TEAM_ID = "DV2U35YBHT"


class FloorpXcodeCloudSourceBindingTests(unittest.TestCase):
    def make_repository(self, root: Path) -> tuple[Path, str]:
        repository = root / "repository"
        configuration = repository / CONFIG_RELATIVE
        configuration.parent.mkdir(parents=True)
        configuration.write_text(
            f"FLOORP_DEVELOPMENT_TEAM = {SIGNING_TEAM_ID}\n"
            "FLOORP_MARKETING_VERSION = 0.3.0\n"
            "FLOORP_SOURCE_SHA =\n",
            encoding="utf-8",
        )
        subprocess.run(["/usr/bin/git", "init", "-q", repository], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", repository, "config", "user.email", "ci@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/git", "-C", repository, "config", "user.name", "CI Test"],
            check=True,
        )
        subprocess.run(["/usr/bin/git", "-C", repository, "add", "."], check=True)
        subprocess.run(
            [
                "/usr/bin/git",
                "-c",
                "commit.gpgsign=false",
                "-C",
                repository,
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )
        commit = subprocess.run(
            ["/usr/bin/git", "-C", repository, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            [
                "/usr/bin/git",
                "-c",
                "tag.gpgsign=false",
                "-C",
                repository,
                "tag",
                f"floorp-catalog-{commit}",
            ],
            check=True,
        )
        return repository, commit

    def environment(self, repository: Path, commit: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "CI_XCODE_CLOUD": "TRUE",
                "CI_XCODE_SCHEME": "Floorp",
                "CI_XCODEBUILD_ACTION": "archive",
                "CI_PRIMARY_REPOSITORY_PATH": str(repository),
                "CI_COMMIT": commit,
                "CI_TAG": f"floorp-catalog-{commit}",
                "CI_GIT_REF": f"refs/tags/floorp-catalog-{commit}",
                "CI_BUNDLE_ID": "app.floorp.Floorp",
                "CI_TEAM_ID": APP_STORE_CONNECT_TEAM_ID,
            }
        )
        return environment

    def run_script(self, environment: dict[str, str]):
        return subprocess.run(
            [str(SCRIPT)],
            env=environment,
            capture_output=True,
            text=True,
        )

    def test_valid_floorp_archive_injects_exact_tagged_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository, commit = self.make_repository(Path(temporary))
            result = self.run_script(self.environment(repository, commit))

            self.assertEqual(result.returncode, 0, result.stderr)
            configuration = (repository / CONFIG_RELATIVE).read_text(encoding="utf-8")
            self.assertEqual(configuration.count("FLOORP_SOURCE_SHA"), 1)
            self.assertIn(f"FLOORP_SOURCE_SHA = {commit}\n", configuration)

    def test_valid_detached_checkout_does_not_require_a_local_tag_ref(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository, commit = self.make_repository(Path(temporary))
            subprocess.run(
                ["/usr/bin/git", "-C", repository, "tag", "-d", f"floorp-catalog-{commit}"],
                check=True,
                capture_output=True,
            )
            result = self.run_script(self.environment(repository, commit))

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_floorp_or_non_archive_actions_skip_without_mutation(self):
        for field, value in (
            ("CI_XCODE_SCHEME", "Fennec"),
            ("CI_XCODEBUILD_ACTION", "test-without-building"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self.make_repository(Path(temporary))
                environment = self.environment(repository, commit)
                environment[field] = value
                result = self.run_script(environment)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    "FLOORP_SOURCE_SHA =\n",
                    (repository / CONFIG_RELATIVE).read_text(encoding="utf-8"),
                )

    def test_commit_tag_and_checkout_must_all_match(self):
        cases = ("malformed-commit", "wrong-tag-name", "wrong-git-ref", "wrong-head")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self.make_repository(Path(temporary))
                environment = self.environment(repository, commit)
                if case == "malformed-commit":
                    environment["CI_COMMIT"] = "not-a-sha"
                    environment["CI_TAG"] = "floorp-catalog-not-a-sha"
                    environment["CI_GIT_REF"] = "refs/tags/floorp-catalog-not-a-sha"
                elif case == "wrong-tag-name":
                    environment["CI_TAG"] = f"release-{commit}"
                elif case == "wrong-git-ref":
                    environment["CI_GIT_REF"] = f"refs/heads/{environment['CI_TAG']}"
                else:
                    environment["CI_COMMIT"] = "b" * 40
                    environment["CI_TAG"] = "floorp-catalog-" + "b" * 40
                    environment["CI_GIT_REF"] = "refs/tags/floorp-catalog-" + "b" * 40

                result = self.run_script(environment)
                self.assertNotEqual(result.returncode, 0)

    def test_ci_team_must_match_the_app_store_connect_team(self):
        for value in ("", SIGNING_TEAM_ID, "00000000-0000-0000-0000-000000000000"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self.make_repository(Path(temporary))
                environment = self.environment(repository, commit)
                environment["CI_TEAM_ID"] = value
                result = self.run_script(environment)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("App Store Connect team", result.stderr)
                self.assertIn(
                    "FLOORP_SOURCE_SHA =\n",
                    (repository / CONFIG_RELATIVE).read_text(encoding="utf-8"),
                )

    def test_signing_team_setting_must_be_unique_and_exact(self):
        replacements = (
            "",
            "FLOORP_DEVELOPMENT_TEAM = BADTEAM123",
            f"FLOORP_DEVELOPMENT_TEAM = {SIGNING_TEAM_ID}\n"
            f"FLOORP_DEVELOPMENT_TEAM = {SIGNING_TEAM_ID}",
        )
        for replacement in replacements:
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self.make_repository(Path(temporary))
                configuration = repository / CONFIG_RELATIVE
                configuration.write_text(
                    configuration.read_text(encoding="utf-8").replace(
                        f"FLOORP_DEVELOPMENT_TEAM = {SIGNING_TEAM_ID}", replacement
                    ),
                    encoding="utf-8",
                )
                result = self.run_script(self.environment(repository, commit))

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FLOORP_DEVELOPMENT_TEAM", result.stderr)
                self.assertIn(
                    "FLOORP_SOURCE_SHA =\n",
                    configuration.read_text(encoding="utf-8"),
                )

    def test_source_setting_must_be_unique_and_empty(self):
        for replacement in (
            "FLOORP_SOURCE_SHA = already-set",
            "FLOORP_SOURCE_SHA =\nFLOORP_SOURCE_SHA =",
        ):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self.make_repository(Path(temporary))
                configuration = repository / CONFIG_RELATIVE
                configuration.write_text(
                    configuration.read_text(encoding="utf-8").replace(
                        "FLOORP_SOURCE_SHA =", replacement
                    ),
                    encoding="utf-8",
                )
                result = self.run_script(self.environment(repository, commit))

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exactly one empty", result.stderr)


if __name__ == "__main__":
    unittest.main()
