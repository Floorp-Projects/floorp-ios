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
NODE_TEST = Path(__file__).with_name("ubol_custom_filter_injection_test.mjs")
RUNTIME_PATHS = (
    "js/background.js",
    "js/filter-manager.js",
    "js/scripting/css-user.js",
    "js/scripting/css-api.js",
    "js/scripting/css-procedural-api.js",
    "js/scripting/css-user-idle-prelude.js",
    "js/scripting/css-user-idle.js",
)


class UBOLCustomFilterInjectionTests(unittest.TestCase):
    def test_bundled_runtime_has_bounded_document_safe_injection(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            extracted_paths: list[Path] = []
            with zipfile.ZipFile(ARCHIVE) as archive:
                for runtime_path in RUNTIME_PATHS:
                    output = temporary_root / Path(runtime_path).name
                    output.write_bytes(archive.read(runtime_path))
                    extracted_paths.append(output)

            completed = subprocess.run(
                [node, str(NODE_TEST), *(str(path) for path in extracted_paths)],
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
            "uBO custom-filter injection tests passed",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
