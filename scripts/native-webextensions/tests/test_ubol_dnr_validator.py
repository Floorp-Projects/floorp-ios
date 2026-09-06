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
NODE_TEST = Path(__file__).with_name("ubol_dnr_validator_test.mjs")
NORMALIZER_TEST = Path(__file__).with_name(
    "ubol_safari_regex_normalizer_test.mjs"
)


class UBOLSafariDNRValidatorTests(unittest.TestCase):
    def test_submitted_rule_matrix_matches_safari_contract(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            parser = Path(temporary_directory) / "dnr-parser.mjs"
            with zipfile.ZipFile(ARCHIVE) as archive:
                parser.write_bytes(archive.read("js/dnr-parser.js"))

            completed = subprocess.run(
                [node, str(NODE_TEST), str(parser)],
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
        self.assertIn("uBO Safari DNR validator tests passed", completed.stdout)

    def test_safari_dnr_compatibility_contract(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        members = (
            "js/background.js",
            "js/backup-restore.js",
            "js/dnr-parser.js",
            "js/ext-compat.js",
            "js/floorp-reconcile.js",
            "js/ruleset-manager.js",
            "js/safari-dnr-normalizer.js",
            "js/safari-regex-normalizer.js",
            "rulesets/regex/annoyances-overlays.json",
            "rulesets/regex/chn-0.json",
            "rulesets/regex/pol-0.json",
            "rulesets/regex/ublock-filters.json",
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            with zipfile.ZipFile(ARCHIVE) as archive:
                for member in members:
                    destination = root / member
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(archive.read(member))

            completed = subprocess.run(
                [node, str(NORMALIZER_TEST), str(root)],
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
            "Safari DNR compatibility tests passed",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
