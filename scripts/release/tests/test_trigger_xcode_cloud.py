"""Contract tests for the Xcode Cloud deployment trigger."""

import importlib.util
import unittest
from pathlib import Path


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
                            "isDeleted": True,
                        },
                    },
                    {
                        "type": "scmGitReferences",
                        "id": "other-main",
                        "attributes": {
                            "name": "main",
                            "canonicalName": "refs/heads/main",
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
        with self.assertRaisesRegex(ValueError, "expected one live Git reference"):
            trigger.resolve_branch(api, REPOSITORY_ID, "main")


if __name__ == "__main__":
    unittest.main()
