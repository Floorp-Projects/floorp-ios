"""Contract checks for the curated-catalog external TestFlight workflow."""

from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPOSITORY_ROOT / ".github/workflows/floorp-curated-catalog-external-testflight.yml"


class CuratedCatalogExternalTestFlightWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_is_manual_and_requires_explicit_beta_review_authorization(self) -> None:
        for required in (
            "name: Floorp Curated Catalog External TestFlight",
            "workflow_dispatch:",
            "candidate_tag:",
            "xcode_cloud_run_id:",
            "build_id:",
            "submit_beta_app_review:",
            "default: false",
            "inputs.submit_beta_app_review == true",
            "environment: floorp-curated-catalog-external-release",
        ):
            self.assertIn(required, self.workflow)
        self.assertNotIn("pull_request:", self.workflow)
        self.assertNotIn("push:", self.workflow)

    def test_requires_the_exact_current_main_annotated_tag_before_credentials(self) -> None:
        for required in (
            'candidate_tag="$FLOORP_REQUESTED_CANDIDATE_TAG"',
            "^floorp-catalog-([0-9a-f]{40})$",
            'test "$(git cat-file -t "refs/tags/$candidate_tag")" = "tag"',
            'test "$candidate_tag" = "floorp-catalog-$candidate_sha"',
            'main_sha="$(git rev-parse "refs/remotes/origin/main")"',
            'test "$candidate_sha" = "$main_sha"',
            "FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256",
            "verify_signed_curated_catalog_release.py",
        ):
            self.assertIn(required, self.workflow)
        self.assertLess(
            self.workflow.index("- name: Verify protected tag and merged source identity"),
            self.workflow.index("- name: Verify the signed curated catalog release contract"),
        )
        self.assertLess(
            self.workflow.index("- name: Verify the signed curated catalog release contract"),
            self.workflow.index("- name: Verify P0 approvals before App Store Connect credentials"),
        )
        self.assertLess(
            self.workflow.index("- name: Verify P0 approvals before App Store Connect credentials"),
            self.workflow.index("- name: Prepare App Store Connect API key"),
        )

    def test_requires_a_protected_candidate_bound_p0_approval_before_credentials(self) -> None:
        for required in (
            "FLOORP_CURATED_CATALOG_RELEASE_APPROVAL_SHA256",
            "verify_curated_catalog_release_approval.py",
            "docs/floorp-ios-webextensions-curated-catalog-release-approval.json",
            "--catalog-evidence \"$FLOORP_CURATED_CATALOG_EVIDENCE\"",
            "--expected-package-count 1",
            "floorp-curated-catalog-p0-approval.json",
        ):
            self.assertIn(required, self.workflow)

    def test_binds_the_selected_processed_build_to_the_xcode_cloud_tag_run(self) -> None:
        for required in (
            "verify_curated_catalog_testflight_submission.py",
            "--candidate-tag \"$FLOORP_CATALOG_RELEASE_TAG\"",
            "--candidate-sha \"$FLOORP_CATALOG_CANDIDATE_SHA\"",
            "--xcode-cloud-run-id \"$FLOORP_REQUESTED_XCODE_CLOUD_RUN_ID\"",
            "--build-id \"$FLOORP_REQUESTED_BUILD_ID\"",
            "--catalog-evidence \"$FLOORP_CURATED_CATALOG_EVIDENCE\"",
            "FLOORP_CURATED_CATALOG_SUBMISSION_EVIDENCE",
        ):
            self.assertIn(required, self.workflow)
        self.assertLess(
            self.workflow.index("- name: Bind the processed App Store build to the exact candidate"),
            self.workflow.index("- name: Select an existing external group and build Beta App Review details"),
        )
        self.assertLess(
            self.workflow.index("- name: Bind the processed App Store build to the exact candidate"),
            self.workflow.index("- name: Submit the verified build to Beta App Review"),
        )

    def test_resolves_only_the_sole_build_from_the_candidate_xcode_cloud_run(self) -> None:
        for required in (
            "- name: Resolve the sole processed App Store build from the candidate Xcode Cloud run",
            "/v1/ciBuildRuns/$FLOORP_REQUESTED_XCODE_CLOUD_RUN_ID/relationships/builds",
            '[[ "$FLOORP_REQUESTED_XCODE_CLOUD_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]',
            "Xcode Cloud run must produce exactly one App Store build",
            "FLOORP_RESOLVED_BUILD_ID",
            "requested App Store build does not match the Xcode Cloud run output",
        ):
            self.assertIn(required, self.workflow)
        self.assertLess(
            self.workflow.index("- name: Prepare App Store Connect API key"),
            self.workflow.index("- name: Resolve the sole processed App Store build from the candidate Xcode Cloud run"),
        )
        self.assertLess(
            self.workflow.index("- name: Resolve the sole processed App Store build from the candidate Xcode Cloud run"),
            self.workflow.index("- name: Bind the processed App Store build to the exact candidate"),
        )

    def test_submits_only_to_an_existing_external_group_and_keeps_evidence_non_secret(self) -> None:
        for required in (
            "select exactly one existing external TestFlight group",
            "requested external TestFlight group does not exist or is internal",
            "No demo account is required.",
            "Guideline 3.2.2(i)",
            "submit-floorp-external-beta.sh",
            "--authorize-mutation",
            "floorp-curated-catalog-submission-binding.json",
            "external-beta-submission.json",
        ):
            self.assertIn(required, self.workflow)
        self.assertNotIn("POST /v1/betaGroups", self.workflow)
        self.assertNotIn("review-details-payload.json\n            ${{ runner.temp }}", self.workflow)

    def test_beta_review_notes_cover_only_the_single_dark_reader_package(self) -> None:
        for required in (
            "one fixed, app-bundled WebExtension: Dark Reader",
            "Install and enable Dark Reader",
            "switch between On and Off",
            "Open Settings and See all options",
            "change an appearance value such as brightness",
            "Disable and remove Dark Reader",
        ):
            self.assertIn(required, self.workflow)
        for forbidden in (
            "17 WebExtensions",
            "Floorp Site Appearance",
            "Floorp Tracker Block Lite",
            "Very Good AdBlock",
            "Floorp Session Timer",
            "DNR",
        ):
            self.assertNotIn(forbidden, self.workflow)

    def test_untrusted_dispatch_values_are_passed_through_environment_not_shell_literals(self) -> None:
        for forbidden in (
            "candidate_tag='${{ inputs.candidate_tag }}'",
            "--build-id '${{ inputs.build_id }}'",
            "--xcode-cloud-run-id '${{ inputs.xcode_cloud_run_id }}'",
        ):
            self.assertNotIn(forbidden, self.workflow)
        for required in (
            "FLOORP_REQUESTED_CANDIDATE_TAG: ${{ inputs.candidate_tag }}",
            "FLOORP_REQUESTED_XCODE_CLOUD_RUN_ID: ${{ inputs.xcode_cloud_run_id }}",
            "FLOORP_REQUESTED_BUILD_ID: ${{ inputs.build_id }}",
            "FLOORP_REQUESTED_BUILD_ID: ${{ env.FLOORP_RESOLVED_BUILD_ID }}",
        ):
            self.assertIn(required, self.workflow)


if __name__ == "__main__":
    unittest.main()
