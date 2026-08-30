"""Regression coverage for the checked-in curated catalog review build."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
MODULE_PATH = SCRIPTS_DIRECTORY / "build_curated_catalog.py"
SPEC = importlib.util.spec_from_file_location("floorp_build_curated_catalog", MODULE_PATH)
assert SPEC and SPEC.loader
BUILD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILD
SPEC.loader.exec_module(BUILD)

CATALOG_ROOT = (
    Path(__file__).parents[3]
    / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
)


class CuratedCatalogBuildTests(unittest.TestCase):
    def test_checked_in_sources_build_to_reviewable_immutable_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog-output"
            records = BUILD.build(
                sources_path=CATALOG_ROOT / "catalog-sources.json",
                output_directory=output,
                generation_prefix="test20260826",
            )

            self.assertEqual(len(records), 1)
            self.assertEqual(
                {record["extensionID"] for record in records},
                {
                    "floorp.thirdparty.darkreader",
                },
            )
            for record in records:
                artifact = output / "Artifacts" / f"{record['generation'].split('-', 1)[1]}.fwea1"
                self.assertTrue(artifact.read_bytes().startswith(b"FWEA1\n"))
                metadata = record["metadata"]
                self.assertEqual(metadata["minimumFloorpBuild"], "0.3.0")
                self.assertRegex(metadata["noticesSHA256"], r"^[0-9a-f]{64}$")
                disclosure = metadata["disclosure"]
                self.assertEqual(disclosure["publisherDisplayName"], "Floorp iOS")
                self.assertEqual(disclosure["supportRoute"], "floorp-github-issues")
                self.assertEqual(disclosure["reportRoute"], "floorp-github-bug-report")
                self.assertRegex(disclosure["reviewEvidenceSHA256"], r"^[0-9a-f]{64}$")
                self.assertRegex(disclosure["sourceReviewSHA256"], r"^[0-9a-f]{64}$")

            catalog_input = json.loads((output / "catalog-input.json").read_bytes())
            self.assertEqual(catalog_input, records)
            review_index = json.loads((output / "review-index.json").read_bytes())
            self.assertEqual(len(review_index["packages"]), len(records))

    def test_adopted_source_is_bound_to_an_immutable_revision(self) -> None:
        sources = BUILD.source_entries(CATALOG_ROOT / "catalog-sources.json")
        self.assertEqual(len(sources), 1)
        for source in sources:
            self.assertEqual(source["id"], "thirdparty-darkreader")
            self.assertEqual(source["modificationStatus"], "compatibility-patched")
            self.assertRegex(source["upstreamRevision"], r"^[0-9a-f]{40}$")

    def test_disclosures_must_cover_the_exact_catalog_source_set(self) -> None:
        sources = BUILD.source_entries(CATALOG_ROOT / "catalog-sources.json")
        with tempfile.TemporaryDirectory() as directory:
            disclosure_path = Path(directory) / "catalog-disclosures.json"
            disclosure_path.write_text('{"schema":1,"packages":{}}', encoding="utf-8")
            with self.assertRaisesRegex(BUILD.CuratedCatalogBuildError, "exactly match source IDs"):
                BUILD.disclosure_entries(disclosure_path, sources)


if __name__ == "__main__":
    unittest.main()
