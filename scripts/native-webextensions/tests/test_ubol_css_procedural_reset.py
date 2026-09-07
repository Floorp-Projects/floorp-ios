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
NODE_TEST = Path(__file__).with_name("ubol_css_procedural_reset_test.mjs")


class UBOLCSSProceduralResetTests(unittest.TestCase):
    def test_reset_without_css_removal_covers_both_runtime_css_inventories(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            script = Path(temporary_directory) / "css-procedural-api.js"
            with zipfile.ZipFile(ARCHIVE) as archive:
                script.write_bytes(archive.read("js/scripting/css-procedural-api.js"))

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
        self.assertIn("uBO procedural reset tests passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
