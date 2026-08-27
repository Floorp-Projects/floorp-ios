"""Keep curated-catalog release documentation bound to the checked-in inputs."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CATALOG_ROOT = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
COMPATIBILITY = REPOSITORY_ROOT / "docs/EXTENSION_COMPATIBILITY.md"
THIRD_PARTY = REPOSITORY_ROOT / "docs/THIRD_PARTY_EXTENSIONS.md"
BETA_REVIEW_DRAFT = (
    REPOSITORY_ROOT
    / "docs/floorp-ios-webextensions-internal-catalog-beta-app-review-draft.md"
)
P0_POLICY_APPROVAL = (
    REPOSITORY_ROOT / "docs/floorp-ios-webextensions-curated-catalog-p0-policy-approval.json"
)
WHAT_TO_TEST_EN = REPOSITORY_ROOT / "firefox-ios/TestFlight/WhatToTest.en-US.txt"
WHAT_TO_TEST_JA = REPOSITORY_ROOT / "firefox-ios/TestFlight/WhatToTest.ja-JP.txt"


class CuratedCatalogDocumentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.records = json.loads((CATALOG_ROOT / "catalog-input.json").read_text())
        cls.sources = json.loads((CATALOG_ROOT / "catalog-sources.json").read_text())
        cls.compatibility = COMPATIBILITY.read_text(encoding="utf-8")
        cls.third_party = THIRD_PARTY.read_text(encoding="utf-8")
        cls.beta_review_draft = BETA_REVIEW_DRAFT.read_text(encoding="utf-8")
        cls.what_to_test_en = WHAT_TO_TEST_EN.read_text(encoding="utf-8")
        cls.what_to_test_ja = WHAT_TO_TEST_JA.read_text(encoding="utf-8")
        cls.p0_policy_approval_data = P0_POLICY_APPROVAL.read_bytes()
        cls.p0_policy_approval = json.loads(cls.p0_policy_approval_data)

    def test_sole_maintainer_p0_policy_record_is_canonical_and_binds_the_fixed_input(self) -> None:
        approval = self.p0_policy_approval
        self.assertEqual(
            approval,
            {
                "approvalDate": "2026-08-28",
                "approvalID": "floorp-ios-maintainer-p0-policy-20260828",
                "catalogInputSHA256": hashlib.sha256(
                    (CATALOG_ROOT / "catalog-input.json").read_bytes()
                ).hexdigest(),
                "keyOperations": "1password-ssh-agent-nonexport",
                "packageCount": 16,
                "privateModeAndDataRetention": "profile-isolated-retain-until-explicit-uninstall",
                "prohibitedCapabilities": [
                    "arbitrary-url-install",
                    "chrome-web-store-install",
                    "crx-zip-shared-sheet-install",
                    "fail-open",
                    "permission-escalation",
                    "remote-dnr-lists",
                    "remote-javascript-wasm",
                    "silent-update",
                ],
                "revocationOperations": "signed-immediate-revocation-immutable-generation",
                "schema": 1,
                "scope": "initial-external-testflight-fixed-bundled-catalog",
                "status": "approved",
                "thirdPartyRedistributionBasis": "verified-mit-license-notice-provenance",
            },
        )
        self.assertEqual(
            self.p0_policy_approval_data,
            json.dumps(approval, separators=(",", ":"), sort_keys=True).encode("utf-8"),
        )

    def test_exactly_the_fixed_sixteen_are_documented(self) -> None:
        self.assertEqual(len(self.records), 16)
        record_ids = {record["extensionID"] for record in self.records}
        source_ids = {source["extensionID"] for source in self.sources}
        self.assertEqual(record_ids, source_ids)
        self.assertEqual(
            sum(identifier.startswith("floorp.thirdparty.") for identifier in record_ids),
            13,
        )
        for record in self.records:
            documented_name = record["metadata"]["displayName"].partition(" — ")[0]
            self.assertIn(documented_name, self.compatibility)
            self.assertIn(record["extensionID"], self.beta_review_draft)

    def test_third_party_provenance_table_matches_immutable_catalog_input(self) -> None:
        for record in self.records:
            if not record["extensionID"].startswith("floorp.thirdparty."):
                continue
            metadata = record["metadata"]
            for value in (
                record["extensionID"],
                record["version"],
                record["generation"],
                record["artifactSHA256"],
                metadata["originalArtifactSHA256"],
            ):
                self.assertIn(value, self.third_party)

    def test_testflight_instructions_describe_the_curated_candidate_not_fixtures(self) -> None:
        for text in (self.what_to_test_en, self.what_to_test_ja):
            self.assertNotIn("Floorp Content Messaging Fixture", text)
            self.assertNotIn("Floorp Event Runtime Fixture", text)
            self.assertNotIn("Floorp MV3 Compatibility Fixture", text)
        self.assertIn("16 fixed packages", self.what_to_test_en)
        self.assertIn("Chrome Web Store", self.what_to_test_en)
        self.assertIn("16本", self.what_to_test_ja)
        self.assertIn("Chrome ウェブストア", self.what_to_test_ja)

    def test_beta_review_draft_cannot_be_mistaken_for_an_approval(self) -> None:
        self.assertIn("draft only", self.beta_review_draft)
        self.assertIn("App Store Connect", self.beta_review_draft)
        self.assertIn("承認を表すものではなく", self.beta_review_draft)
        self.assertIn("not an extension store", self.beta_review_draft)
        self.assertIn("no silent update", self.beta_review_draft)


if __name__ == "__main__":
    unittest.main()
