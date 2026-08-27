"""Contract tests for the Xcode Cloud deployment trigger."""

import contextlib
import io
import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace


def load_module():
    module_path = Path(__file__).parent.parent / "trigger-xcode-cloud.py"
    spec = importlib.util.spec_from_file_location("trigger_xcode_cloud", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


trigger = load_module()


WORKFLOW_ID = "workflow-1"
REPOSITORY_ID = "repository-1"
REFERENCE_ID = "reference-main"
WORKFLOW_NAME = "Floorp TestFlight Manual"
REPOSITORY_URL = "https://github.com/Floorp-Projects/floorp-ios.git"
CATALOG_TAG = "floorp-catalog-" + "a" * 40


def workflow_response():
    return {
        "data": {
            "type": "ciWorkflows",
            "id": WORKFLOW_ID,
            "attributes": {"name": WORKFLOW_NAME, "isEnabled": True},
            "relationships": {
                "repository": {
                    "data": {"type": "scmRepositories", "id": REPOSITORY_ID}
                }
            },
        },
        "included": [
            {
                "type": "scmRepositories",
                "id": REPOSITORY_ID,
                "attributes": {"httpCloneUrl": REPOSITORY_URL},
            }
        ],
    }


def references_response(rows=None):
    return {
        "data": rows
        if rows is not None
        else [
            {
                "type": "scmGitReferences",
                "id": REFERENCE_ID,
                "attributes": {
                    "name": "main",
                    "canonicalName": "refs/heads/main",
                    "kind": "BRANCH",
                    "isDeleted": False,
                },
            }
        ]
    }


class FakeAPI:
    def __init__(self, workflow=None, references=None):
        self.workflow = workflow or workflow_response()
        self.references = references or references_response()
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
            return self.workflow
        if path.startswith(f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"):
            return self.references
        raise AssertionError(f"unexpected API request: {method} {path}")


class TriggerContractTests(unittest.TestCase):
    def test_build_request_binds_workflow_and_main_reference(self):
        self.assertEqual(
            trigger.build_request(WORKFLOW_ID, REFERENCE_ID),
            {
                "data": {
                    "type": "ciBuildRuns",
                    "attributes": {},
                    "relationships": {
                        "workflow": {
                            "data": {"type": "ciWorkflows", "id": WORKFLOW_ID}
                        },
                        "sourceBranchOrTag": {
                            "data": {
                                "type": "scmGitReferences",
                                "id": REFERENCE_ID,
                            }
                        },
                    },
                }
            },
        )

    def test_verify_workflow_accepts_the_pinned_xcode_cloud_repository(self):
        api = FakeAPI()
        workflow, repository_id, repository = trigger.verify_workflow(
            api, WORKFLOW_ID, WORKFLOW_NAME, REPOSITORY_URL
        )
        self.assertEqual(workflow["id"], WORKFLOW_ID)
        self.assertEqual(repository_id, REPOSITORY_ID)
        self.assertEqual(repository["attributes"]["httpCloneUrl"], REPOSITORY_URL)

    def test_verify_workflow_rejects_a_different_repository(self):
        api = FakeAPI()
        with self.assertRaisesRegex(ValueError, "repository mismatch"):
            trigger.verify_workflow(
                api,
                WORKFLOW_ID,
                WORKFLOW_NAME,
                "https://github.com/other/project.git",
            )

    def test_verify_workflow_rejects_a_different_workflow_name(self):
        api = FakeAPI()
        with self.assertRaisesRegex(ValueError, "workflow name mismatch"):
            trigger.verify_workflow(api, WORKFLOW_ID, "Other workflow", REPOSITORY_URL)

    def test_resolve_branch_rejects_deleted_or_duplicate_references(self):
        api = FakeAPI(
            references=references_response(
                [
                    {
                        "type": "scmGitReferences",
                        "id": "deleted-main",
                        "attributes": {
                            "name": "main",
                            "canonicalName": "refs/heads/main",
                            "kind": "BRANCH",
                            "isDeleted": True,
                        },
                    },
                    {
                        "type": "scmGitReferences",
                        "id": "other-main",
                        "attributes": {
                            "name": "main",
                            "canonicalName": "refs/heads/main",
                            "kind": "BRANCH",
                            "isDeleted": False,
                        },
                    },
                ]
            )
        )
        self.assertEqual(
            trigger.resolve_branch(api, REPOSITORY_ID, "main")["id"], "other-main"
        )

    def test_resolve_branch_requires_exactly_one_live_match(self):
        api = FakeAPI(references=references_response([]))
        with self.assertRaisesRegex(ValueError, "expected one live branch reference"):
            trigger.resolve_branch(api, REPOSITORY_ID, "main")

    def test_resolve_tag_requires_a_tag_not_a_same_named_branch(self):
        tag_name = CATALOG_TAG
        api = FakeAPI(
            references=references_response(
                [
                    {
                        "type": "scmGitReferences",
                        "id": "tag-reference",
                        "attributes": {
                            "name": tag_name,
                            "canonicalName": f"refs/tags/{tag_name}",
                            "kind": "TAG",
                            "isDeleted": False,
                        },
                    },
                    {
                        "type": "scmGitReferences",
                        "id": "branch-reference",
                        "attributes": {
                            "name": tag_name,
                            "canonicalName": f"refs/heads/{tag_name}",
                            "kind": "BRANCH",
                            "isDeleted": False,
                        },
                    },
                ]
            )
        )
        self.assertEqual(
            trigger.resolve_tag(api, REPOSITORY_ID, tag_name)["id"], "tag-reference"
        )

    def test_resolve_tag_rejects_a_matching_name_with_the_wrong_canonical_namespace(self):
        api = FakeAPI(
            references=references_response(
                [
                    {
                        "type": "scmGitReferences",
                        "id": "misnamed-reference",
                        "attributes": {
                            "name": CATALOG_TAG,
                            "canonicalName": "refs/tags/not-the-candidate-tag",
                            "kind": "TAG",
                            "isDeleted": False,
                        },
                    }
                ]
            )
        )
        with self.assertRaisesRegex(ValueError, "expected one live tag reference"):
            trigger.resolve_tag(api, REPOSITORY_ID, CATALOG_TAG)

    def test_parse_arguments_requires_one_source_selector(self):
        common = [
            "--workflow-id", WORKFLOW_ID,
            "--expected-workflow-name", WORKFLOW_NAME,
            "--expected-repository", REPOSITORY_URL,
            "--expected-head", "a" * 40,
            "--team-id", "team-1",
            "--app-id", "app-1",
            "--output", "/tmp/result.json",
        ]
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                trigger.parse_arguments(common)
        parsed = trigger.parse_arguments(common + ["--source-tag", CATALOG_TAG])
        self.assertEqual(parsed.source_tag, CATALOG_TAG)
        self.assertIsNone(parsed.branch)

    def test_catalog_tag_build_refuses_async_execution_before_loading_credentials(self):
        arguments = SimpleNamespace(
            authorize_mutation=True,
            expected_head="a" * 40,
            branch=None,
            source_tag=CATALOG_TAG,
            wait=False,
        )
        with self.assertRaisesRegex(ValueError, "must wait for source-commit verification"):
            trigger.run(arguments)

    def test_catalog_tag_requires_a_commit_bound_name_before_loading_credentials(self):
        arguments = SimpleNamespace(
            authorize_mutation=True,
            expected_head="a" * 40,
            branch=None,
            source_tag="floorp-catalog-v0.3.0-b5",
            wait=True,
        )
        with self.assertRaisesRegex(ValueError, "40 lowercase Git SHA"):
            trigger.run(arguments)


if __name__ == "__main__":
    unittest.main()
