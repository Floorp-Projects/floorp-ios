"""Runs every curated WebExtension package through its local functional harness."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
HARNESS = Path(__file__).with_name("curated_catalog_functional.mjs")
PACKAGES = (
    REPOSITORY_ROOT
    / "firefox-ios/Floorp/WebExtensions/CuratedCatalog/Packages"
)


class CuratedCatalogFunctionalTests(unittest.TestCase):
    def test_every_adopted_package_has_a_local_functional_smoke_test(self) -> None:
        completed = subprocess.run(
            ["node", str(HARNESS), str(PACKAGES)],
            check=True,
            capture_output=True,
            text=True,
            cwd=REPOSITORY_ROOT,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result, {"status": "ok", "adoptedPackages": 16})


if __name__ == "__main__":
    unittest.main()
