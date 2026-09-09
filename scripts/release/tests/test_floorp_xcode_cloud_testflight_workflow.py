"""Contract tests for the immutable Xcode Cloud TestFlight bridge."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github" / "workflows" / "floorp-xcode-cloud-testflight.yml"
OBSOLETE_WORKFLOW = ROOT / ".github" / "workflows" / "floorp-public-beta-release.yml"


class FloorpXcodeCloudTestFlightWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_requires_commit_bound_catalog_tag(self):
        self.assertIn("source_tag:", self.text)
        self.assertIn('test "$FLOORP_SOURCE_TAG" = "floorp-catalog-$GITHUB_SHA"', self.text)
        self.assertIn('test "$remote_tag_sha" = "$GITHUB_SHA"', self.text)

    def test_validates_exact_source_ci_acceptance_before_xcode_cloud(self):
        gate = self.text.index("Verify source-bound CI and uBO acceptance")
        trigger = self.text.index("Start Xcode Cloud and wait for completion")
        self.assertLess(gate, trigger)
        self.assertIn("validate-floorp-ci-release-gate.py", self.text)
        self.assertIn("floorp-ubol-release-acceptance-$run_id", self.text)

    def test_validates_checked_in_privacy_declarations_before_credentials(self):
        source = self.text.index("Verify source identity")
        privacy = self.text.index("Validate checked-in release privacy declarations")
        ci_gate = self.text.index("Verify source-bound CI and uBO acceptance")
        credentials = self.text.index("Prepare App Store Connect API key")
        trigger = self.text.index("Start Xcode Cloud and wait for completion")
        self.assertLess(source, privacy)
        self.assertLess(privacy, ci_gate)
        self.assertLess(privacy, credentials)
        self.assertLess(privacy, trigger)

        block = self.text.split(
            "      - name: Validate checked-in release privacy declarations\n", 1
        )[1].split("\n      - name:", 1)[0]
        self.assertIn("scripts/release/validate-floorp-privacy.py", block)
        self.assertIn("--matrix docs/floorp-release-endpoints.json", block)
        self.assertIn("--metadata docs/app-store-connect-metadata.json", block)
        for unsupported_claim in ("--trace", "--static-endpoints", "--ipa"):
            self.assertNotIn(unsupported_claim, block)

    def test_xcode_cloud_uses_immutable_tag_not_mutable_branch(self):
        self.assertIn('--source-tag "$FLOORP_SOURCE_TAG"', self.text)
        self.assertNotIn('--branch "$FLOORP_XCODE_CLOUD_BRANCH"', self.text)
        self.assertIn('--expected-head "$GITHUB_SHA"', self.text)

    def test_catalog_tag_deployment_cannot_skip_completion_wait(self):
        dispatch_inputs = self.text.split("permissions:", 1)[0]
        trigger = self.text.split(
            "      - name: Start Xcode Cloud and wait for completion\n", 1
        )[1].split("\n      - name:", 1)[0]
        self.assertNotIn("wait_for_completion:", dispatch_inputs)
        self.assertNotIn("inputs.wait_for_completion", trigger)
        self.assertIn("            --wait\n", trigger)

    def test_job_timeout_covers_run_and_build_processing_deadlines(self):
        match = re.search(r"^    timeout-minutes: ([0-9]+)$", self.text, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertGreaterEqual(int(match.group(1)), 250)

    def test_trigger_pins_release_identity_and_exports_exact_build(self):
        for declaration in (
            'FLOORP_APP_ID: "6796708699"',
            'FLOORP_BUNDLE_ID: "app.floorp.Floorp"',
            'FLOORP_MARKETING_VERSION: "0.3.0"',
            'FLOORP_PLATFORM: "IOS"',
            'FLOORP_MIN_OS_VERSION: "18.4"',
            'FLOORP_APP_STORE_CONNECT_TEAM_ID: "74c6a531-19e2-4ed5-a34b-915003cc10f9"',
        ):
            self.assertIn(declaration, self.text)
        trigger = self.text.split(
            "      - name: Start Xcode Cloud and wait for completion\n", 1
        )[1].split("\n      - name:", 1)[0]
        for argument in (
            '--expected-bundle-id "$FLOORP_BUNDLE_ID"',
            '--expected-marketing-version "$FLOORP_MARKETING_VERSION"',
            '--expected-platform "$FLOORP_PLATFORM"',
            '--expected-min-os-version "$FLOORP_MIN_OS_VERSION"',
            '--team-id "$FLOORP_APP_STORE_CONNECT_TEAM_ID"',
            '--receipt-output "$receipt"',
        ):
            self.assertIn(argument, trigger)
        self.assertIn("run_id={run['id']}", trigger)
        self.assertIn("build_id={build['id']}", trigger)
        self.assertIn("build_number={build['number']}", trigger)
        self.assertIn("app_store_connect_build_id:", self.text)
        self.assertIn("app_store_connect_build_number:", self.text)

    def test_source_bound_receipt_and_review_notes_are_retained(self):
        self.assertIn("floorp-xcode-cloud-build-receipt-${{ github.run_id }}", self.text)
        self.assertIn("${{ runner.temp }}/ci-release-gate.json", self.text)
        self.assertIn("floorp-xcode-cloud-build-receipt.json", self.text)
        self.assertIn("render-floorp-app-review-notes.py", self.text)
        self.assertIn("floorp-app-review-notes.json", self.text)

    def test_exact_xcode_cloud_binaries_are_downloaded_verified_and_retained(self):
        trigger = self.text.index("Start Xcode Cloud and wait for completion")
        verify = self.text.index(
            "Download and verify exact Xcode Cloud distribution artifacts"
        )
        retain = self.text.index("Retain exact Xcode Cloud distribution artifacts")
        notes = self.text.index("Materialize source-bound App Review notes")
        self.assertLess(trigger, verify)
        self.assertLess(verify, retain)
        self.assertLess(retain, notes)
        self.assertIn("    runs-on: macos-26", self.text)
        self.assertIn("--relationship ARCHIVE", self.text)
        self.assertIn("--relationship ARCHIVE_EXPORT", self.text)
        self.assertIn("materialize-floorp-xcode-cloud-artifacts.py", self.text)
        self.assertIn("collect-floorp-release-evidence.sh", self.text)
        self.assertIn("--phase publication", self.text)
        self.assertIn("--artifact-kind local-export", self.text)
        self.assertIn("--xcode-cloud-artifact-manifest", self.text)
        self.assertIn("floorp-xcode-cloud-distribution-${{ github.run_id }}", self.text)
        self.assertIn("compression-level: 0", self.text)
        self.assertIn("include-hidden-files: true", self.text)
        self.assertIn("artifact-digest", self.text)

    def test_obsolete_manual_signing_workflow_is_removed(self):
        self.assertFalse(OBSOLETE_WORKFLOW.exists())


if __name__ == "__main__":
    unittest.main()
