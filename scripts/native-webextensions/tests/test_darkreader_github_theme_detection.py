from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
ARCHIVE = (
    ROOT
    / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
    / "darkreader-floorp-ios-mv3-4.9.129.zip"
)
NODE_TEST = Path(__file__).with_name("darkreader_github_theme_detection_test.mjs")


class DarkReaderGitHubThemeDetectionTests(unittest.TestCase):
    def test_local_and_remote_site_themes_detect_only_dark_github_pages(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the theme detection harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            with zipfile.ZipFile(ARCHIVE) as archive:
                archive.extractall(temporary_directory)
            completed = subprocess.run(
                [node, str(NODE_TEST), temporary_directory],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        self.assertIn("Dark Reader GitHub theme detection tests passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
