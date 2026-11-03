from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "network_snapshot", ROOT / "scripts/native-webextensions/update_ubol_network_snapshot.py"
)
SNAPSHOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SNAPSHOT)


class UBOLNetworkSnapshotTests(unittest.TestCase):
    def make_fixture(self, directory, missing_redirect=False):
        staging = directory / "staging"
        (staging / "rulesets/main").mkdir(parents=True)
        details = []
        archive_path = directory / "snapshot.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for ruleset_id in SNAPSHOT.RULESET_IDS:
                path = f"rulesets/main/{ruleset_id}.json"
                (staging / path).write_text("[]\n")
                action = {"type": "block"}
                if missing_redirect and ruleset_id == "jpn-1":
                    action = {"type": "redirect", "redirect": {"extensionPath": "/missing.js"}}
                archive.writestr(path, json.dumps([
                    {"id": 1, "action": action, "condition": {"urlFilter": "||tracker.example/"}}
                ]))
                details.append({"id": ruleset_id, "rules": {"plain": 0, "regex": 7, "total": 7},
                                "filters": {"total": 123}, "css": {"generic": 45}})
            archive.writestr("js/background.js", "must not replace runtime")
        (staging / "rulesets/ruleset-details.json").write_text(json.dumps(details))
        (staging / "runtime-sentinel.js").write_text("original runtime")
        return staging, archive_path

    def test_updates_only_network_data_and_preserves_other_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            staging, archive = self.make_fixture(Path(temporary))
            with patch.object(SNAPSHOT, "SNAPSHOT_SHA256", hashlib.sha256(archive.read_bytes()).hexdigest()):
                SNAPSHOT.update_snapshot(staging, archive)
            details = json.loads((staging / "rulesets/ruleset-details.json").read_text())
            with zipfile.ZipFile(archive) as source:
                for ruleset_id in SNAPSHOT.RULESET_IDS:
                    path = f"rulesets/main/{ruleset_id}.json"
                    self.assertEqual((staging / path).read_bytes(), source.read(path))
            for entry in details:
                self.assertEqual(entry["rules"], {"plain": 1, "regex": 7, "total": 8})
                self.assertEqual(entry["filters"], {"total": 123})
                self.assertEqual(entry["css"], {"generic": 45})
            self.assertEqual((staging / "runtime-sentinel.js").read_text(), "original runtime")
            self.assertFalse((staging / "js/background.js").exists())

    def test_rejects_wrong_source_digest_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            staging, archive = self.make_fixture(Path(temporary))
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                SNAPSHOT.update_snapshot(staging, archive)
            self.assertEqual((staging / "rulesets/main/easylist.json").read_text(), "[]\n")

    def test_preflights_redirect_dependencies_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            staging, archive = self.make_fixture(Path(temporary), missing_redirect=True)
            with patch.object(SNAPSHOT, "SNAPSHOT_SHA256", hashlib.sha256(archive.read_bytes()).hexdigest()):
                with self.assertRaisesRegex(ValueError, "missing redirect resource"):
                    SNAPSHOT.update_snapshot(staging, archive)
            self.assertEqual((staging / "rulesets/main/easylist.json").read_text(), "[]\n")

    def test_packaged_network_rules_match_reviewed_official_snapshot(self):
        archive = ROOT / "firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.zip"
        expected = {'rulesets/main/ublock-filters.json': 'c6b36174a79cdfb9ed49365ea25fa1c77de4c9642caa5737567395af2485c946',
         'rulesets/main/easylist.json': '350f18522e783bc42f0e5d320334706a0b94ba594ad48573b850f973ad4fb42a',
         'rulesets/main/easyprivacy.json': '7147ac7fb18607b22feff14c17612609c5c8bcfb2fd996a24ef5ae0354cbdd26',
         'rulesets/main/adguard-mobile.json': '475743af95fb15896e7e611d4d8d52c1b7884c472b52a1dc599b8ba810a29719',
         'rulesets/main/jpn-1.json': 'b696bf60cc81027a78ac2ecd3fa0e1842cdc168b2e549ef0ffbd8333719e53f3'}
        with zipfile.ZipFile(archive) as packaged:
            details = {item["id"]: item for item in json.loads(packaged.read("rulesets/ruleset-details.json"))}
            for path, digest in expected.items():
                with self.subTest(path=path):
                    data = packaged.read(path)
                    self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                    ruleset_id = Path(path).stem
                    counts = details[ruleset_id]["rules"]
                    self.assertEqual(counts["plain"], len(json.loads(data)))
                    self.assertEqual(counts["total"], counts["plain"] + counts["regex"])
