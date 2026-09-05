from __future__ import annotations

import hashlib
import json
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
PROVENANCE = ARCHIVE.with_suffix(".provenance.json")
NODE_TEST = Path(__file__).with_name("darkreader_floorp_compat_test.mjs")


class DarkReaderFloorpCompatTests(unittest.TestCase):
    def test_archive_contains_durable_floorp_compatibility_layer(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the compatibility harness")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            with zipfile.ZipFile(ARCHIVE) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                compat = archive.read("background/floorp-compat.js")
                background = archive.read("background/index.js").decode("utf-8")
                surfaces = {
                    path: archive.read(path).decode("utf-8")
                    for path in (
                        "ui/devtools/index.js",
                        "ui/options/index.js",
                        "ui/popup/index.js",
                        "ui/stylesheet-editor/index.js",
                    )
                }
                readiness = archive.read("floorp-readiness.html")
            compat_path = root / "floorp-compat.js"
            compat_path.write_bytes(compat)

            self.assertEqual(
                manifest["background"],
                {
                    "scripts": [
                        "background/floorp-compat.js",
                        "background/index.js",
                    ],
                    "persistent": False,
                },
            )
            self.assertIn(b"Dark Reader readiness", readiness)
            self.assertIn("message?.what === \"floorpReadiness\"", background)
            self.assertIn("sender?.id !== chrome.runtime.id", background)
            self.assertIn("await Messenger.mutationQueue.flush()", background)
            self.assertIn("await UserStorage.saveSettingsIntoStorage.flush()", background)
            self.assertIn("settings readback did not match memory", background)
            self.assertNotIn("chrome.storage.local.get", background)
            self.assertNotIn("chrome.storage.local.set", background)
            for path, surface in surfaces.items():
                with self.subTest(surface=path):
                    self.assertIn("sendMutation(type, data)", surface)
                    self.assertIn("globalThis.floorpPrepareToClose", surface)
                    self.assertNotIn("chrome.storage.local.get", surface)

            completed = subprocess.run(
                [node, str(NODE_TEST), str(compat_path)],
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
                "Dark Reader Floorp compatibility tests passed",
                completed.stdout,
            )

    def test_provenance_digest_matches_archive(self) -> None:
        provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
        digest = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
        self.assertEqual(provenance["sha256"], digest)


if __name__ == "__main__":
    unittest.main()
