"""Tests for candidate-bound curated-catalog TestFlight submission checks."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).parent.parent / "verify_curated_catalog_testflight_submission.py"
    spec = importlib.util.spec_from_file_location("verify_curated_catalog_testflight_submission", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


submission = load_module()


APP_ID = "6796708699"
BUILD_ID = "build-1"
HEAD = "a" * 40
RUN_ID = "run-1"
TAG = f"floorp-catalog-{HEAD}"
WORKFLOW_ID = "workflow-1"
WORKFLOW_NAME = "Floorp TestFlight Manual"
REPOSITORY_ID = "repository-1"
REPOSITORY_URL = "https://github.com/Floorp-Projects/floorp-ios.git"
REFERENCE_ID = "tag-reference-1"


def catalog_evidence():
    return {
        "catalogID": "floorp-ios-curated-testflight",
        "catalogInputSHA256": "b" * 64,
        "catalogSHA256": "c" * 64,
        "marketingVersion": "0.3.0",
        "packageCount": 1,
        "rootPublicKeySHA256": "d" * 64,
        "sequence": 1,
        "status": "verified",
    }


class FakeAPI:
    def __init__(self):
        self.calls = []
        self.run_source = HEAD
        self.run_reference = REFERENCE_ID
        self.build_link = BUILD_ID
        self.processing_state = "VALID"
        self.marketing_version = "0.3.0"

    def __call__(self, method, path):
        self.calls.append((method, path))
        if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
            return {
                "data": {
                    "type": "ciWorkflows",
                    "id": WORKFLOW_ID,
                    "attributes": {"name": WORKFLOW_NAME, "isEnabled": True},
                    "relationships": {"repository": {"data": {"type": "scmRepositories", "id": REPOSITORY_ID}}},
                },
                "included": [{
                    "type": "scmRepositories",
                    "id": REPOSITORY_ID,
                    "attributes": {"httpCloneUrl": REPOSITORY_URL},
                }],
            }
        if path.startswith(f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"):
            return {"data": [{
                "type": "scmGitReferences",
                "id": REFERENCE_ID,
                "attributes": {
                    "name": TAG,
                    "canonicalName": f"refs/tags/{TAG}",
                    "kind": "TAG",
                    "isDeleted": False,
                },
            }]}
        if path == f"/v1/ciBuildRuns/{RUN_ID}?include=workflow,sourceBranchOrTag":
            return {"data": {
                "type": "ciBuildRuns",
                "id": RUN_ID,
                "attributes": {
                    "completionStatus": "SUCCEEDED",
                    "executionProgress": "COMPLETE",
                    "sourceCommit": {"commitSha": self.run_source},
                },
                "relationships": {
                    "workflow": {"data": {"type": "ciWorkflows", "id": WORKFLOW_ID}},
                    "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": self.run_reference}},
                },
            }}
        if path == f"/v1/ciBuildRuns/{RUN_ID}/relationships/builds":
            return {"data": [{"type": "builds", "id": self.build_link}]}
        if path == f"/v1/builds/{BUILD_ID}?include=preReleaseVersion":
            return {"data": {
                "type": "builds",
                "id": BUILD_ID,
                "attributes": {"processingState": self.processing_state, "version": "5"},
                "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "pre-1"}}},
            }}
        if path == "/v1/preReleaseVersions/pre-1?include=app":
            return {"data": {
                "type": "preReleaseVersions",
                "id": "pre-1",
                "attributes": {"version": self.marketing_version, "platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
            }}
        raise AssertionError(f"unexpected API request: {method} {path}")


class CuratedCatalogSubmissionTests(unittest.TestCase):
    def verify(self, api: FakeAPI):
        return submission.verify_submission(
            api=api,
            workflow_id=WORKFLOW_ID,
            workflow_name=WORKFLOW_NAME,
            repository_url=REPOSITORY_URL,
            candidate_tag=TAG,
            candidate_sha=HEAD,
            xcode_cloud_run_id=RUN_ID,
            build_id=BUILD_ID,
            app_id=APP_ID,
            marketing_version="0.3.0",
            catalog_evidence=catalog_evidence(),
        )

    def test_accepts_the_single_processed_build_from_the_exact_tag_run(self):
        api = FakeAPI()
        result = self.verify(api)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["candidateTag"], TAG)
        self.assertEqual(result["buildID"], BUILD_ID)
        self.assertEqual(result["buildNumber"], "5")
        self.assertIn(
            (
                "GET",
                f"/v1/ciBuildRuns/{RUN_ID}?include=workflow,sourceBranchOrTag",
            ),
            api.calls,
        )
        self.assertIn(
            ("GET", f"/v1/builds/{BUILD_ID}?include=preReleaseVersion"),
            api.calls,
        )
        self.assertIn(
            ("GET", "/v1/preReleaseVersions/pre-1?include=app"),
            api.calls,
        )

    def test_rejects_a_run_with_a_different_source_commit(self):
        api = FakeAPI()
        api.run_source = "b" * 40
        with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "source commit"):
            self.verify(api)

    def test_rejects_a_run_from_a_different_tag_reference(self):
        api = FakeAPI()
        api.run_reference = "other-tag-reference"
        with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "source tag"):
            self.verify(api)

    def test_rejects_a_build_not_linked_to_the_xcode_cloud_run(self):
        api = FakeAPI()
        api.build_link = "other-build"
        with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "not the Xcode Cloud run output"):
            self.verify(api)

    def test_rejects_a_build_that_is_not_processed(self):
        api = FakeAPI()
        api.processing_state = "PROCESSING"
        with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "has not processed"):
            self.verify(api)

    def test_rejects_a_build_with_a_different_marketing_version(self):
        api = FakeAPI()
        api.marketing_version = "0.2.0"
        with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "marketing version"):
            self.verify(api)

    def test_catalog_evidence_requires_the_current_single_dark_reader_package(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence_path = Path(temporary_directory) / "catalog-evidence.json"
            evidence_path.write_text(json.dumps(catalog_evidence()), encoding="utf-8")
            self.assertEqual(submission._catalog_evidence(evidence_path, "0.3.0")["packageCount"], 1)
            stale = catalog_evidence()
            stale["packageCount"] = 2
            evidence_path.write_text(json.dumps(stale), encoding="utf-8")
            with self.assertRaisesRegex(submission.CuratedCatalogSubmissionError, "single Dark Reader"):
                submission._catalog_evidence(evidence_path, "0.3.0")


if __name__ == "__main__":
    unittest.main()
