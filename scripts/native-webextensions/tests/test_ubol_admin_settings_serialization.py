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
    / "uBOLite-floorp-ios-2026.825.1619.zip"
)
NODE_TEST = Path(__file__).with_name("ubol_admin_settings_serialization_test.mjs")


class UBOLAdminSettingsSerializationTests(unittest.TestCase):
    def test_managed_changes_share_transaction_and_retry_boundaries(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            script = Path(temporary_directory) / "admin.js"
            with zipfile.ZipFile(ARCHIVE) as archive:
                script.write_bytes(archive.read("js/admin.js"))

            completed = subprocess.run(
                [node, str(NODE_TEST), str(script)],
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
        self.assertIn(
            "uBO managed settings serialization tests passed",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
