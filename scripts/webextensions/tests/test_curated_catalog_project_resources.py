"""Keep review inputs out of the shipping iOS resource phase."""

from __future__ import annotations

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PROJECT = REPOSITORY_ROOT / "firefox-ios/Client.xcodeproj/project.pbxproj"


class CuratedCatalogProjectResourceTests(unittest.TestCase):
    def test_only_normalized_artifact_folder_is_an_iOS_catalog_resource(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn("path = CuratedCatalog/Artifacts;", project)
        self.assertIn("Curated FWEA1 Artifacts in Resources", project)
        signed_directory = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog/Artifacts/Signed"
        self.assertTrue(signed_directory.is_dir())
        self.assertIn(
            'subdirectory: "Artifacts/Signed"',
            (REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/FloorpWebExtensionCatalog.swift").read_text(
                encoding="utf-8"
            ),
        )
        for review_only_path in (
            "CuratedCatalog/Packages",
            "CuratedCatalog/Review",
            "CuratedCatalog/SourceProvenance",
            "CuratedCatalog/catalog-sources.json",
            "CuratedCatalog/catalog-disclosures.json",
            "CuratedCatalog/catalog-input.json",
            "CuratedCatalog/review-index.json",
        ):
            self.assertNotIn(review_only_path, project)
        for test_fixture in (
            "demanding-mv3 in Resources",
            "content-messaging-mv3 in Resources",
            "event-runtime-mv3 in Resources",
        ):
            self.assertNotIn(test_fixture, project)


if __name__ == "__main__":
    unittest.main()
