from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_bundled_extensions.py"
SPEC = importlib.util.spec_from_file_location("verify_bundled_extensions", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class BundledNativeWebExtensionVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        source = REPOSITORY_ROOT / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
        destination = self.root / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
        destination.parent.mkdir(parents=True)
        shutil.copytree(source, destination)
        self.bundle_root = destination
        review_notes_source = REPOSITORY_ROOT / "docs/app-review-notes-native-webextensions.md"
        review_notes_destination = self.root / "docs/app-review-notes-native-webextensions.md"
        review_notes_destination.parent.mkdir(parents=True)
        shutil.copy2(review_notes_source, review_notes_destination)
        self.review_notes = review_notes_destination

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_exact_bundled_release_assets(self) -> None:
        VERIFIER.verify_repository(self.root)

    def test_rejects_archive_digest_drift(self) -> None:
        archive = self.bundle_root / "darkreader-chrome-mv3-4.9.129.zip"
        archive.write_bytes(archive.read_bytes() + b"drift")

        with self.assertRaisesRegex(RuntimeError, "unexpected SHA-256"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_missing_license(self) -> None:
        (self.bundle_root / "uBOLite_2026.825.1619.LICENSE").unlink()

        with self.assertRaisesRegex(RuntimeError, "bundled extension file set changed"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_unreviewed_extra_asset(self) -> None:
        (self.bundle_root / "unreviewed.zip").write_bytes(b"PK\x05\x06")

        with self.assertRaisesRegex(RuntimeError, "bundled extension file set changed"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_legacy_runtime_tree(self) -> None:
        (self.root / "firefox-ios/Floorp/WebExtensions").mkdir(parents=True)

        with self.assertRaisesRegex(RuntimeError, "legacy WebExtension implementation remains"):
            VERIFIER.verify_repository(self.root)

    def test_rejects_review_notes_over_app_store_connect_limit(self) -> None:
        document = self.review_notes.read_text(encoding="utf-8")
        self.review_notes.write_text(
            document.replace("```text\n", "```text\n" + ("x" * 4_001), 1),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RuntimeError, "4,000-byte limit"):
            VERIFIER.verify_repository(self.root)


if __name__ == "__main__":
    unittest.main()
