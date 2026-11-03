from pathlib import Path
import json
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
ARCHIVE = ROOT / "firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.zip"


class UBOLStaticRequestDomainExclusionTests(unittest.TestCase):
    def test_obsolete_global_script_exclusion_is_removed(self):
        with zipfile.ZipFile(ARCHIVE) as archive:
            rules = json.loads(archive.read("rulesets/main/ublock-filters.json"))
            details = json.loads(archive.read("rulesets/ruleset-details.json"))

        by_id = {rule["id"]: rule for rule in rules}
        self.assertNotIn(5135, by_id)
        self.assertIn(5134, by_id)
        self.assertIn(5136, by_id)
        self.assertFalse(any(
            rule["condition"].get("urlFilter") == "/8b3ytkn.js|"
            for rule in rules
        ))
        counts = next(item["rules"] for item in details if item["id"] == "ublock-filters")
        self.assertEqual(counts["plain"], len(rules))
        self.assertEqual(counts["total"], counts["plain"] + counts["regex"])

    def test_tracker_blocks_and_scoped_exceptions_are_preserved(self):
        with zipfile.ZipFile(ARCHIVE) as archive:
            rules = json.loads(archive.read("rulesets/main/easyprivacy.json"))

        blocks = {rule["condition"].get("urlFilter"): rule for rule in rules
                  if rule["action"]["type"] == "block"}
        self.assertIn("||d2wy8f7a9ursnm.cloudfront.net/", blocks)
        self.assertEqual(blocks["||hotjar.com/"]["condition"]["domainType"], "thirdParty")
        self.assertTrue(any(
            rule["action"]["type"] == "allow"
            and rule["condition"].get("urlFilter") == "||static.hotjar.com/c/hotjar-"
            and rule["condition"].get("initiatorDomains") == ["mercadopublico.cl"]
            for rule in rules
        ))
