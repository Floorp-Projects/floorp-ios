"""Contract checks for the curated-catalog TestFlight dispatch gate."""

from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CATALOG_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/floorp-curated-catalog-testflight.yml"
GENERIC_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/floorp-xcode-cloud-testflight.yml"
CI_WORKFLOW = REPOSITORY_ROOT / ".github/workflows/ci.yml"


class CuratedCatalogTestFlightWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog_workflow = CATALOG_WORKFLOW.read_text(encoding="utf-8")
        cls.generic_workflow = GENERIC_WORKFLOW.read_text(encoding="utf-8")
        cls.ci_workflow = CI_WORKFLOW.read_text(encoding="utf-8")

    def test_candidate_uses_a_separate_tag_only_dispatch_contract(self) -> None:
        for required in (
            "name: Floorp Curated Catalog TestFlight Candidate",
            "test \"$GITHUB_REF_TYPE\" = \"tag\"",
            "^floorp-catalog-([0-9a-f]{40})$",
            "git cat-file -t \"refs/tags/$GITHUB_REF_NAME\"",
            "test \"$GITHUB_REF_NAME\" = \"floorp-catalog-$candidate_sha\"",
            "main_sha=\"$(git rev-parse \"refs/remotes/origin/main\")\"",
            "test \"$candidate_sha\" = \"$main_sha\"",
            "--source-tag \"$FLOORP_CATALOG_RELEASE_TAG\"",
            "--wait",
        ):
            self.assertIn(required, self.catalog_workflow)
        self.assertNotIn("catalog_release:", self.catalog_workflow)
        self.assertNotIn("wait_for_completion:", self.catalog_workflow)

    def test_candidate_verifies_the_signed_catalog_before_apple_credentials(self) -> None:
        for required in (
            "FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256",
            "python3 -c 'import cryptography'",
            "scripts/webextensions/verify_signed_curated_catalog_release.py",
            "--catalog-root firefox-ios/Floorp/WebExtensions/CuratedCatalog",
            "--release-xcconfig firefox-ios/Client/Configuration/FloorpRelease.xcconfig",
            "--bundle-id app.floorp.Floorp",
            "--channel testflight",
            "--catalog-id floorp-ios-curated-testflight",
            "--expected-package-count 17",
            "--artifact-origin https://catalog.floorp.invalid/fwea1/",
            "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover",
            "scripts.release.tests.test_curated_catalog_xcode_cloud_post_clone",
            "scripts.release.tests.test_trigger_xcode_cloud",
        ):
            self.assertIn(required, self.catalog_workflow)
        self.assertLess(
            self.catalog_workflow.index("- name: Verify signed curated catalog release contract"),
            self.catalog_workflow.index("- name: Prepare App Store Connect API key"),
        )
        self.assertLess(
            self.catalog_workflow.index("- name: Verify protected tag and merged source identity"),
            self.catalog_workflow.index("- name: Verify signed curated catalog release contract"),
        )

    def test_candidate_uses_its_own_protected_environment(self) -> None:
        self.assertIn("environment: floorp-curated-catalog-candidate", self.catalog_workflow)
        self.assertNotIn("environment: floorp-testflight", self.catalog_workflow)

    def test_candidate_never_submits_external_beta_automatically(self) -> None:
        self.assertIn(
            "This workflow does not assign an external TestFlight group or submit Beta App Review.",
            self.catalog_workflow,
        )
        self.assertNotIn("submit-floorp-external-beta.sh", self.catalog_workflow)

    def test_generic_testflight_dispatch_cannot_pose_as_a_catalog_candidate(self) -> None:
        for forbidden in (
            "catalog_release:",
            "FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256",
            "verify_signed_curated_catalog_release.py",
            "floorp-catalog-",
        ):
            self.assertNotIn(forbidden, self.generic_workflow)

    def test_normal_ci_exercises_the_non_secret_catalog_contracts(self) -> None:
        for required in (
            "Install curated catalog signature test dependency",
            "cryptography==50.0.1",
            "Run curated WebExtensions catalog contracts",
            "scripts.webextensions.tests.test_build_curated_catalog",
            "scripts.webextensions.tests.test_curated_catalog_source_provenance",
            "scripts.webextensions.tests.test_floorp_1password_ssh_agent_signer",
            "scripts.webextensions.tests.test_sign_catalog",
            "scripts.webextensions.tests.test_sign_curated_catalog",
            "scripts.webextensions.tests.test_verify_signed_curated_catalog_release",
            "scripts.release.tests.test_curated_catalog_testflight_workflow",
            "scripts.release.tests.test_verify_curated_catalog_release_approval",
            "scripts.release.tests.test_curated_catalog_xcode_cloud_post_clone",
            "scripts.release.tests.test_trigger_xcode_cloud",
            "node scripts/webextensions/tests/curated_catalog_functional.mjs",
        ):
            self.assertIn(required, self.ci_workflow)


if __name__ == "__main__":
    unittest.main()
