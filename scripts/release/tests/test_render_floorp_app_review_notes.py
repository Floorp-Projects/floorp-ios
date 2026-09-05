"""Tests for source-bound App Review notes materialization."""

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/render-floorp-app-review-notes.py"
TEMPLATE = ROOT / "docs/app-review-notes-native-webextensions.md"
SOURCE_SHA = "a" * 40


def load_module():
    spec = importlib.util.spec_from_file_location("render_floorp_review_notes", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


renderer = load_module()


def receipt():
    return {
        "schema_version": 1,
        "source": {
            "kind": "tag",
            "name": f"floorp-catalog-{SOURCE_SHA}",
            "commit_sha": SOURCE_SHA,
        },
        "build": {"marketing_version": "0.3.0", "number": "96"},
    }


class ReviewNotesRendererTests(unittest.TestCase):
    def test_output_contains_only_source_bound_notes(self):
        value = renderer.render(TEMPLATE.read_text(encoding="utf-8"), receipt())
        self.assertEqual(set(value), {"notes"})
        notes = value["notes"]
        self.assertTrue(notes.startswith("Floorp 0.3.0 (96)"))
        self.assertIn(
            f"https://github.com/Floorp-Projects/floorp-ios/tree/floorp-catalog-{SOURCE_SHA}",
            notes,
        )
        self.assertIn("GNU GPL v3.0 or later", notes)
        self.assertNotIn("[VERSION]", notes)
        self.assertNotIn("[BUILD]", notes)
        self.assertNotIn("[RELEASE_TAG_OR_FULL_COMMIT]", notes)
        self.assertLessEqual(len(notes.encode("utf-8")), 4000)

    def test_non_commit_bound_receipt_is_rejected(self):
        value = receipt()
        value["source"]["name"] = "floorp-catalog-other"
        with self.assertRaisesRegex(renderer.RenderError, "not commit-bound"):
            renderer.render(TEMPLATE.read_text(encoding="utf-8"), value)

    def test_only_the_reviewed_section_is_materialized(self):
        decoy = "```text\nnot the reviewed notes\n```\n\n"
        value = renderer.render(
            decoy + TEMPLATE.read_text(encoding="utf-8"), receipt()
        )
        self.assertTrue(value["notes"].startswith("Floorp 0.3.0 (96)"))

    def test_missing_disclosure_or_oversized_notes_are_rejected(self):
        template = (
            renderer.REVIEW_NOTES_HEADING
            + "\n\n```text\nFloorp [VERSION] ([BUILD]) "
            + "https://github.com/Floorp-Projects/floorp-ios/tree/"
            + "[RELEASE_TAG_OR_FULL_COMMIT]\n```"
        )
        with self.assertRaisesRegex(renderer.RenderError, "GPL disclosure"):
            renderer.render(template, receipt())
        oversized = (
            renderer.REVIEW_NOTES_HEADING
            + "\n\n```text\n"
            + "GNU GPL v3.0 or later uBOLite-floorp-ios-2026.825.1619.patch "
            + "scripts/package-ubol-ios.sh "
            + "https://github.com/Floorp-Projects/floorp-ios/tree/[RELEASE_TAG_OR_FULL_COMMIT] "
            + "x" * 4100
            + "\n```"
        )
        with self.assertRaisesRegex(renderer.RenderError, "4,000-byte"):
            renderer.render(oversized, receipt())


if __name__ == "__main__":
    unittest.main()
