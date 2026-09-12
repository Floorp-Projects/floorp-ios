"""Contract tests for the Xcode Cloud deployment trigger."""

import contextlib
import io
import importlib.util
import json
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
PRODUCT_ID = "product-1"
REPOSITORY_ID = "repository-1"
REFERENCE_ID = "reference-main"
BUNDLE_RESOURCE_ID = "bundle-id-1"
DEFAULT_BROWSER_CAPABILITY_ID = "capability-default-browser"
LIVE_CAPABILITIES_WITHOUT_DEFAULT_BROWSER = [
    "IN_APP_PURCHASE",
    "WEB_BROWSER_PUBLIC_KEY_CREDENTIALS_REQUESTS",
    "MULTIPATH",
    "APP_GROUPS",
]
WORKFLOW_NAME = "Floorp TestFlight Manual"
REPOSITORY_URL = "https://github.com/Floorp-Projects/floorp-ios.git"
APP_ID = "6796708699"
BUNDLE_ID = "app.floorp.Floorp"
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
                },
                "product": {
                    "data": {"type": "ciProducts", "id": PRODUCT_ID}
                }
            },
        },
        "included": [
            {
                "type": "scmRepositories",
                "id": REPOSITORY_ID,
                "attributes": {"httpCloneUrl": REPOSITORY_URL},
            },
            {
                "type": "ciProducts",
                "id": PRODUCT_ID,
                "attributes": {"name": "Floorp", "productType": "APP"},
            }
        ],
    }


def product_response(app_id=APP_ID, bundle_id=BUNDLE_ID):
    return {
        "data": {
            "type": "ciProducts",
            "id": PRODUCT_ID,
            "attributes": {"name": "Floorp", "productType": "APP"},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}}
            },
        },
        "included": [
            {
                "type": "apps",
                "id": app_id,
                "attributes": {"bundleId": bundle_id},
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
        ],
        "links": {"next": None},
    }


def bundle_ids_response(rows=None):
    return {
        "data": rows
        if rows is not None
        else [
            {
                "type": "bundleIds",
                "id": BUNDLE_RESOURCE_ID,
                "attributes": {"identifier": BUNDLE_ID, "platform": "UNIVERSAL"},
            }
        ],
        "links": {"next": None},
    }


def capabilities_response(capability_types=None):
    if capability_types is None:
        capability_types = LIVE_CAPABILITIES_WITHOUT_DEFAULT_BROWSER + [
            "DEFAULT_WEB_BROWSER"
        ]
    return {
        "data": [
            {
                "type": "bundleIdCapabilities",
                "id": (
                    DEFAULT_BROWSER_CAPABILITY_ID
                    if capability_type == "DEFAULT_WEB_BROWSER"
                    else f"capability-{index}"
                ),
                "attributes": {"capabilityType": capability_type},
            }
            for index, capability_type in enumerate(capability_types)
        ],
        "links": {"next": None},
    }


class FakeAPI:
    def __init__(
        self,
        workflow=None,
        references=None,
        product=None,
        bundle_ids=None,
        capabilities=None,
    ):
        self.workflow = workflow or workflow_response()
        self.references = references or references_response()
        self.product = product or product_response()
        self.bundle_ids = bundle_ids or bundle_ids_response()
        self.capabilities = capabilities or capabilities_response()
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
            return self.workflow
        if path.startswith(f"/v1/ciProducts/{PRODUCT_ID}"):
            return self.product
        if path.startswith(f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"):
            return self.references
        if path == f"/v1/scmRepositories/{REPOSITORY_ID}":
            return {"data": workflow_response()["included"][0]}
        if path.startswith("/v1/bundleIds?"):
            return self.bundle_ids
        if path.startswith(
            f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities?"
        ):
            return self.capabilities
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
        response, workflow, repository_id, repository, product_id, _product = trigger.verify_workflow(
            api, WORKFLOW_ID, WORKFLOW_NAME, REPOSITORY_URL, APP_ID, BUNDLE_ID
        )
        self.assertEqual(response, workflow_response())
        self.assertEqual(workflow["id"], WORKFLOW_ID)
        self.assertEqual(repository_id, REPOSITORY_ID)
        self.assertEqual(product_id, PRODUCT_ID)
        self.assertEqual(repository["attributes"]["httpCloneUrl"], REPOSITORY_URL)

    def test_verify_workflow_rejects_a_different_repository(self):
        api = FakeAPI()
        with self.assertRaisesRegex(ValueError, "repository mismatch"):
            trigger.verify_workflow(
                api,
                WORKFLOW_ID,
                WORKFLOW_NAME,
                "https://github.com/other/project.git",
                APP_ID,
                BUNDLE_ID,
            )

    def test_verify_workflow_rejects_a_different_workflow_name(self):
        api = FakeAPI()
        with self.assertRaisesRegex(ValueError, "workflow name mismatch"):
            trigger.verify_workflow(
                api, WORKFLOW_ID, "Other workflow", REPOSITORY_URL, APP_ID, BUNDLE_ID
            )

    def test_verify_workflow_rejects_wrong_product_app_or_bundle(self):
        with self.assertRaisesRegex(ValueError, "different app"):
            trigger.verify_workflow(
                FakeAPI(product=product_response(app_id="other-app")),
                WORKFLOW_ID,
                WORKFLOW_NAME,
                REPOSITORY_URL,
                APP_ID,
                BUNDLE_ID,
            )
        with self.assertRaisesRegex(ValueError, "bundle ID"):
            trigger.verify_workflow(
                FakeAPI(product=product_response(bundle_id="other.bundle")),
                WORKFLOW_ID,
                WORKFLOW_NAME,
                REPOSITORY_URL,
                APP_ID,
                BUNDLE_ID,
            )

    def test_signing_preflight_requires_exact_ios_bundle_and_default_browser_capability(self):
        api = FakeAPI()

        result = trigger.verify_distribution_signing_capability(api, BUNDLE_ID)

        self.assertEqual(
            result,
            {
                "bundle_id_resource_id": BUNDLE_RESOURCE_ID,
                "bundle_id_platform": "UNIVERSAL",
                "capability_id": DEFAULT_BROWSER_CAPABILITY_ID,
                "capability_type": "DEFAULT_WEB_BROWSER",
            },
        )
        self.assertEqual(
            [(method, path) for method, path, _ in api.calls],
            [
                (
                    "GET",
                    "/v1/bundleIds"
                    "?filter[identifier]=app.floorp.Floorp"
                    "&filter[platform]=IOS"
                    "&fields[bundleIds]=identifier,platform"
                    "&limit=200",
                ),
                (
                    "GET",
                    f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities"
                    "?fields[bundleIdCapabilities]=capabilityType",
                ),
            ],
        )

    def test_signing_preflight_rejects_missing_or_duplicate_bundle_id(self):
        duplicate = bundle_ids_response()["data"] + [
            {
                "type": "bundleIds",
                "id": "bundle-id-2",
                "attributes": {"identifier": BUNDLE_ID, "platform": "UNIVERSAL"},
            }
        ]
        for response, count in (
            (bundle_ids_response([]), 0),
            (bundle_ids_response(duplicate), 2),
        ):
            with self.subTest(count=count):
                with self.assertRaisesRegex(
                    ValueError, f"exactly one registered iOS bundle ID.*found {count}"
                ):
                    trigger.verify_distribution_signing_capability(
                        FakeAPI(bundle_ids=response), BUNDLE_ID
                    )

    def test_signing_preflight_rejects_wrong_identity_and_platform(self):
        for attributes, message in (
            ({"identifier": "other.bundle", "platform": "UNIVERSAL"}, "identifier"),
            ({"identifier": BUNDLE_ID, "platform": "MAC_OS"}, "iOS-compatible"),
            ({"identifier": BUNDLE_ID, "platform": "UNKNOWN"}, "iOS-compatible"),
        ):
            response = bundle_ids_response()
            response["data"][0]["attributes"] = attributes
            with self.subTest(attributes=attributes):
                with self.assertRaisesRegex(ValueError, message):
                    trigger.verify_distribution_signing_capability(
                        FakeAPI(bundle_ids=response), BUNDLE_ID
                    )

    def test_signing_preflight_rejects_missing_or_duplicate_required_capability(self):
        duplicate = capabilities_response(
            ["DEFAULT_WEB_BROWSER", "DEFAULT_WEB_BROWSER"]
        )
        duplicate["data"][1]["id"] = "capability-default-browser-2"
        for response, count in (
            (capabilities_response(LIVE_CAPABILITIES_WITHOUT_DEFAULT_BROWSER), 0),
            (duplicate, 2),
        ):
            with self.subTest(count=count):
                with self.assertRaisesRegex(
                    ValueError, f"DEFAULT_WEB_BROWSER capability; found {count}"
                ):
                    trigger.verify_distribution_signing_capability(
                        FakeAPI(capabilities=response), BUNDLE_ID
                    )

    def test_signing_preflight_rejects_paginated_state(self):
        bundle_response = bundle_ids_response()
        bundle_response["links"]["next"] = "https://api.appstoreconnect.apple.com/v1/next"
        capability_response = capabilities_response()
        capability_response["links"]["next"] = (
            "https://api.appstoreconnect.apple.com/v1/next"
        )
        for api in (
            FakeAPI(bundle_ids=bundle_response),
            FakeAPI(capabilities=capability_response),
        ):
            with self.subTest(calls=api.calls):
                with self.assertRaisesRegex(ValueError, "paginated"):
                    trigger.verify_distribution_signing_capability(api, BUNDLE_ID)

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

    def test_resolve_branch_rejects_a_paginated_partial_lookup(self):
        response = references_response()
        response["links"]["next"] = "https://api.appstoreconnect.apple.com/v1/next"
        api = FakeAPI(references=response)
        with self.assertRaisesRegex(ValueError, "paginated"):
            trigger.resolve_branch(api, REPOSITORY_ID, "main")

    def test_resolve_branch_rejects_malformed_pagination_metadata(self):
        response = references_response()
        response["links"] = "not-an-object"
        api = FakeAPI(references=response)
        with self.assertRaisesRegex(ValueError, "pagination is malformed"):
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
            "--expected-bundle-id", BUNDLE_ID,
            "--expected-marketing-version", "0.3.0",
            "--expected-platform", "IOS",
            "--expected-min-os-version", "18.4",
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
            app_id=APP_ID,
            expected_bundle_id=BUNDLE_ID,
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
            app_id=APP_ID,
            expected_bundle_id=BUNDLE_ID,
        )
        with self.assertRaisesRegex(ValueError, "40 lowercase Git SHA"):
            trigger.run(arguments)

    def test_run_starts_build_only_through_workflow_bound_guarded_write(self):
        class FakeClient:
            def __init__(self):
                self.reads = []
                self.writes = []

            @staticmethod
            def load_credentials(arguments):
                return "issuer", "key", Path("/unused/AuthKey.p8")

            @staticmethod
            def make_jwt(*arguments):
                return "jwt"

            def api_call(self, method, path, token):
                self.reads.append((method, path, token))
                if method != "GET":
                    raise AssertionError("write bypassed guarded_write")
                if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
                    return workflow_response()
                if path.startswith(f"/v1/ciProducts/{PRODUCT_ID}"):
                    return product_response()
                if path == "/v1/builds?filter[app]=6796708699&sort=-version&limit=200":
                    return {"data": [], "links": {"next": None}}
                if path.startswith("/v1/bundleIds?"):
                    return bundle_ids_response()
                if path.startswith(
                    f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities?"
                ):
                    return capabilities_response()
                if path.startswith(
                    f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"
                ):
                    return references_response()
                if path == f"/v1/scmRepositories/{REPOSITORY_ID}":
                    return {"data": workflow_response()["included"][0]}
                raise AssertionError(f"unexpected read: {method} {path}")

            @staticmethod
            def canonical_state_sha256(value):
                if value != workflow_response():
                    raise AssertionError("guard fingerprint did not cover validated workflow")
                return "f" * 64

            def guarded_write(
                self, method, path, token, body, intended_id, prior_state, guard_get
            ):
                self.writes.append(
                    (method, path, token, body, intended_id, prior_state, guard_get)
                )
                return {
                    "data": {
                        "type": "ciBuildRuns",
                        "id": "run-1",
                        "attributes": {"executionProgress": "PENDING"},
                    }
                }

        fake_client = FakeClient()
        original_load_client = trigger.load_client
        trigger.load_client = lambda: fake_client
        try:
            report = trigger.run(
                SimpleNamespace(
                    authorize_mutation=True,
                    expected_head="a" * 40,
                    branch="main",
                    source_tag=None,
                    wait=False,
                    workflow_id=WORKFLOW_ID,
                    expected_workflow_name=WORKFLOW_NAME,
                    expected_repository=REPOSITORY_URL,
                    team_id="team-1",
                    app_id=APP_ID,
                    expected_bundle_id=BUNDLE_ID,
                    expected_marketing_version="0.3.0",
                    expected_platform="IOS",
                    expected_min_os_version="18.4",
                )
            )
        finally:
            trigger.load_client = original_load_client

        self.assertEqual(report["run"]["id"], "run-1")
        self.assertEqual(
            report["signing_preflight"]["capability_type"],
            "DEFAULT_WEB_BROWSER",
        )
        self.assertTrue(all(method == "GET" for method, _, _ in fake_client.reads))
        self.assertIn(
            f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities",
            fake_client.reads[-1][1],
        )
        self.assertEqual(len(fake_client.writes), 1)
        method, path, token, encoded, intended, prior, guard = fake_client.writes[0]
        self.assertEqual((method, path, token), ("POST", "/v1/ciBuildRuns", "jwt"))
        self.assertEqual((intended, prior, guard), (
            WORKFLOW_ID,
            "f" * 64,
            f"/v1/ciWorkflows/{WORKFLOW_ID}?include=product,repository",
        ))
        self.assertEqual(
            json.loads(encoded), trigger.build_request(WORKFLOW_ID, REFERENCE_ID)
        )

    def test_run_missing_default_browser_capability_never_dispatches(self):
        class FakeClient:
            def __init__(self):
                self.writes = []

            @staticmethod
            def load_credentials(arguments):
                return "issuer", "key", Path("/unused/AuthKey.p8")

            @staticmethod
            def make_jwt(*arguments):
                return "jwt"

            @staticmethod
            def canonical_state_sha256(value):
                return "f" * 64

            @staticmethod
            def api_call(method, path, token):
                if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
                    return workflow_response()
                if path.startswith(f"/v1/ciProducts/{PRODUCT_ID}"):
                    return product_response()
                if path.startswith(
                    f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"
                ):
                    return references_response()
                if path == f"/v1/builds?filter[app]={APP_ID}&sort=-version&limit=200":
                    return {"data": [], "links": {"next": None}}
                if path.startswith("/v1/bundleIds?"):
                    return bundle_ids_response()
                if path.startswith(
                    f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities?"
                ):
                    return capabilities_response(
                        LIVE_CAPABILITIES_WITHOUT_DEFAULT_BROWSER
                    )
                raise AssertionError(f"unexpected read: {method} {path}")

            def guarded_write(self, *arguments):
                self.writes.append(arguments)
                raise AssertionError("Xcode Cloud dispatch must remain unreachable")

        fake_client = FakeClient()
        original_load_client = trigger.load_client
        trigger.load_client = lambda: fake_client
        try:
            with self.assertRaisesRegex(ValueError, "DEFAULT_WEB_BROWSER"):
                trigger.run(
                    SimpleNamespace(
                        authorize_mutation=True,
                        expected_head="a" * 40,
                        branch="main",
                        source_tag=None,
                        wait=False,
                        workflow_id=WORKFLOW_ID,
                        expected_workflow_name=WORKFLOW_NAME,
                        expected_repository=REPOSITORY_URL,
                        team_id="team-1",
                        app_id=APP_ID,
                        expected_bundle_id=BUNDLE_ID,
                        expected_marketing_version="0.3.0",
                        expected_platform="IOS",
                        expected_min_os_version="18.4",
                    )
                )
        finally:
            trigger.load_client = original_load_client

        self.assertEqual(fake_client.writes, [])

    def test_waited_run_returns_exact_source_bound_new_build_receipt(self):
        class FakeClient:
            @staticmethod
            def load_credentials(arguments):
                return "issuer", "key", Path("/unused/AuthKey.p8")

            @staticmethod
            def make_jwt(*arguments):
                return "jwt"

            @staticmethod
            def canonical_state_sha256(value):
                return "f" * 64

            @staticmethod
            def build_polling_client(*arguments, **kwargs):
                return object()

            @staticmethod
            def wait_ci_run(client, run_id, expected_head, output, dry_run):
                output.write_text(json.dumps({
                    "data": {
                        "type": "ciBuildRuns",
                        "id": run_id,
                        "attributes": {
                            "executionProgress": "COMPLETE",
                            "completionStatus": "SUCCEEDED",
                            "sourceCommit": {"commitSha": expected_head},
                        },
                    }
                }))

            @staticmethod
            def guarded_write(*arguments):
                return {
                    "data": {
                        "type": "ciBuildRuns",
                        "id": "run-1",
                        "attributes": {"executionProgress": "PENDING"},
                    }
                }

            @staticmethod
            def api_call(method, path, token):
                if path.startswith(f"/v1/ciWorkflows/{WORKFLOW_ID}"):
                    return workflow_response()
                if path.startswith(f"/v1/ciProducts/{PRODUCT_ID}"):
                    return product_response()
                if path.startswith(f"/v1/scmRepositories/{REPOSITORY_ID}/gitReferences"):
                    return references_response([
                        {
                            "type": "scmGitReferences",
                            "id": REFERENCE_ID,
                            "attributes": {
                                "name": CATALOG_TAG,
                                "canonicalName": f"refs/tags/{CATALOG_TAG}",
                                "kind": "TAG",
                                "isDeleted": False,
                            },
                        }
                    ])
                if path == f"/v1/scmRepositories/{REPOSITORY_ID}":
                    return {"data": workflow_response()["included"][0]}
                if path == f"/v1/builds?filter[app]={APP_ID}&sort=-version&limit=200":
                    return {
                        "data": [{
                            "type": "builds", "id": "build-95",
                            "attributes": {"version": "95"},
                        }],
                        "links": {"next": None},
                    }
                if path.startswith("/v1/bundleIds?"):
                    return bundle_ids_response()
                if path.startswith(
                    f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities?"
                ):
                    return capabilities_response()
                if path == "/v1/ciBuildRuns/run-1?include=workflow":
                    return {
                        "data": {
                            "type": "ciBuildRuns",
                            "id": "run-1",
                            "attributes": {
                                "executionProgress": "COMPLETE",
                                "completionStatus": "SUCCEEDED",
                                "sourceCommit": {"commitSha": "a" * 40},
                            },
                            "relationships": {
                                "workflow": {"data": {"type": "ciWorkflows", "id": WORKFLOW_ID}}
                            },
                        }
                    }
                if path == "/v1/ciBuildRuns/run-1/relationships/builds?limit=200":
                    return {"data": [{"type": "builds", "id": "build-96"}], "links": {"next": None}}
                if path == "/v1/builds/build-96?include=app,preReleaseVersion":
                    return {
                        "data": {
                            "type": "builds",
                            "id": "build-96",
                            "attributes": {
                                "version": "96",
                                "processingState": "VALID",
                                "buildAudienceType": "APP_STORE_ELIGIBLE",
                                "expired": False,
                                "usesNonExemptEncryption": False,
                                "minOsVersion": "18.4",
                            },
                            "relationships": {
                                "app": {"data": {"type": "apps", "id": APP_ID}},
                                "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "train-1"}},
                            },
                        },
                        "included": [
                            {"type": "apps", "id": APP_ID, "attributes": {"bundleId": BUNDLE_ID}},
                            {"type": "preReleaseVersions", "id": "train-1", "attributes": {"version": "0.3.0", "platform": "IOS"}},
                        ],
                    }
                raise AssertionError(f"unexpected read: {method} {path}")

        original_load_client = trigger.load_client
        trigger.load_client = lambda: FakeClient()
        try:
            report = trigger.run(SimpleNamespace(
                authorize_mutation=True,
                expected_head="a" * 40,
                branch=None,
                source_tag=CATALOG_TAG,
                wait=True,
                workflow_id=WORKFLOW_ID,
                expected_workflow_name=WORKFLOW_NAME,
                expected_repository=REPOSITORY_URL,
                team_id="team-1",
                app_id=APP_ID,
                expected_bundle_id=BUNDLE_ID,
                expected_marketing_version="0.3.0",
                expected_platform="IOS",
                expected_min_os_version="18.4",
            ))
        finally:
            trigger.load_client = original_load_client

        self.assertEqual(report["receipt"]["run"]["id"], "run-1")
        self.assertEqual(report["receipt"]["build"]["id"], "build-96")
        self.assertEqual(report["receipt"]["build"]["number"], "96")
        self.assertEqual(report["receipt"]["baseline"]["max_build_number"], "95")


if __name__ == "__main__":
    unittest.main()
