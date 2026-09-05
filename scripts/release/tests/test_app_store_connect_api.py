"""Unit tests for scripts/release/app-store-connect-api.py."""

import importlib.util
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).parent.parent / "app-store-connect-api.py"
    spec = importlib.util.spec_from_file_location("app_store_connect_api", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


asc = load_module()


def ci_build_run_body(workflow_id="wf-1", reference_id="ref-1"):
    return {
        "data": {
            "type": "ciBuildRuns",
            "attributes": {},
            "relationships": {
                "workflow": {
                    "data": {"type": "ciWorkflows", "id": workflow_id},
                },
                "sourceBranchOrTag": {
                    "data": {"type": "scmGitReferences", "id": reference_id},
                },
            },
        }
    }


def localization_create_body(build_id="build-1"):
    return {
        "data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": "Release notes"},
            "relationships": {
                "build": {"data": {"type": "builds", "id": build_id}},
            },
        }
    }


def localization_patch_body(localization_id="localization-1"):
    return {
        "data": {
            "type": "betaBuildLocalizations",
            "id": localization_id,
            "attributes": {"whatsNew": "Release notes"},
        }
    }


def review_patch_body(review_id="review-1"):
    return {
        "data": {
            "type": "betaAppReviewDetails",
            "id": review_id,
            "attributes": {"notes": "Release review notes"},
        }
    }


def review_submission_body(build_id="build-1"):
    return {
        "data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {
                "build": {"data": {"type": "builds", "id": build_id}},
            },
        }
    }


def group_build_body(build_id="build-1"):
    return {"data": [{"type": "builds", "id": build_id}]}


class AllowlistTests(unittest.TestCase):
    def test_read_allowlist_accepts_required_gets(self):
        for path in [
            "/v1/ciProducts",
            "/v1/ciProducts/product-1?include=app",
            "/v1/ciProducts/37C53C81-4C23-4E04-ADBB-1F238907A310/workflows",
            "/v1/ciProducts/37C53C81-4C23-4E04-ADBB-1F238907A310/buildRuns",
            "/v1/ciWorkflows/D00DF3AC-15CD-430A-9FCB-39F876242926",
            "/v1/ciBuildRuns/bfd267d8-696a-4394-94db-570f0aa9b376",
            "/v1/ciBuildRuns/bfd267d8-696a-4394-94db-570f0aa9b376?include=workflow,sourceBranchOrTag",
            "/v1/ciBuildRuns/bfd267d8-696a-4394-94db-570f0aa9b376/relationships/builds",
            "/v1/ciBuildRuns/bfd267d8-696a-4394-94db-570f0aa9b376/actions",
            "/v1/ciBuildActions/4294e7e3-8adf-47fe-8f7c-02456baba2bb",
            "/v1/ciBuildActions/4294e7e3-8adf-47fe-8f7c-02456baba2bb/artifacts",
            "/v1/scmRepositories/repo-1",
            "/v1/scmRepositories/repo-1/gitReferences",
            "/v1/builds",
            "/v1/builds/build-1?include=preReleaseVersion",
            "/v1/preReleaseVersions/pre-1?include=app",
            "/v1/betaGroups",
            "/v1/betaGroups/group-1?include=app",
            "/v1/betaAppReviewDetails",
            "/v1/betaAppReviewSubmissions",
            "/v1/betaBuildLocalizations",
            "/v1/apps/abc/builds",
            "/v1/apps/abc",
        ]:
            self.assertTrue(asc.route_allowed("GET", path), path)

    def test_write_allowlist_is_exact(self):
        allowed = [
            ("POST", "/v1/ciBuildRuns"),
            ("POST", "/v1/betaBuildLocalizations"),
            ("PATCH", "/v1/betaBuildLocalizations/123"),
            ("PATCH", "/v1/betaAppReviewDetails/123"),
            ("POST", "/v1/betaAppReviewSubmissions"),
            ("POST", "/v1/betaGroups/123/relationships/builds"),
        ]
        for method, path in allowed:
            self.assertTrue(asc.route_allowed(method, path), f"{method} {path}")

    def test_every_other_write_route_is_denied(self):
        denied = [
            ("POST", "/v1/betaGroups"),
            ("POST", "/v1/betaGroups/123"),
            ("DELETE", "/v1/ciBuildRuns/123"),
            ("POST", "/v1/apps"),
            ("PATCH", "/v1/builds/123"),
            ("POST", "/v1/betaAppReviewDetails"),
            ("GET", "/v1/secrets"),
            ("GET", "/v1/ciWorkflows"),
            ("GET", "/v1/ciRuns/123"),
            ("GET", "/v1/ciRuns/123/artifacts"),
            ("GET", "/v1/ciBuildRuns"),
        ]
        for method, path in denied:
            self.assertFalse(asc.route_allowed(method, path), f"{method} {path}")

    def test_ci_workflows_collection_is_not_a_listing_route(self):
        # App Store Connect does not implement GET /v1/ciWorkflows as a
        # collection listing (it returns 403); workflows are listed through
        # GET /v1/ciProducts/{id}/workflows instead. The client must not
        # advertise the bare collection as an allowed read.
        self.assertFalse(asc.route_allowed("GET", "/v1/ciWorkflows"))
        self.assertFalse(asc.route_allowed("GET", "/v1/ciWorkflows?filter[ciProduct]=abc"))

    def test_ci_build_run_write_guard_covers_product_and_repository(self):
        self.assertTrue(asc.guard_route_allowed(
            "POST",
            "/v1/ciBuildRuns",
            "/v1/ciWorkflows/wf-1?include=product,repository",
            "wf-1",
        ))
        self.assertFalse(asc.guard_route_allowed(
            "POST", "/v1/ciBuildRuns", "/v1/ciWorkflows/wf-1", "wf-1"
        ))

    def test_every_allowlisted_write_body_binds_exactly_its_intended_resource(self):
        cases = (
            ("POST", "/v1/ciBuildRuns", ci_build_run_body(), "wf-1"),
            (
                "POST",
                "/v1/betaBuildLocalizations",
                localization_create_body(),
                "build-1",
            ),
            (
                "PATCH",
                "/v1/betaBuildLocalizations/localization-1",
                localization_patch_body(),
                "localization-1",
            ),
            (
                "PATCH",
                "/v1/betaAppReviewDetails/review-1",
                review_patch_body(),
                "review-1",
            ),
            (
                "POST",
                "/v1/betaAppReviewSubmissions",
                review_submission_body(),
                "build-1",
            ),
            (
                "POST",
                "/v1/betaGroups/group-1/relationships/builds",
                group_build_body(),
                "build-1",
            ),
        )
        for method, path, body, intended_id in cases:
            with self.subTest(method=method, path=path):
                asc.validate_write_body(method, path, body, intended_id)

    def test_write_body_rejects_cross_resource_relationships_and_extra_targets(self):
        # Put the intended workflow ID in the source relationship so this body
        # would have passed the old recursive "ID appears somewhere" check.
        mismatched_ci = ci_build_run_body(
            workflow_id="wf-other", reference_id="wf-1"
        )
        mismatched_localization = localization_create_body(build_id="build-other")
        mismatched_localization["data"]["attributes"]["whatsNew"] = "build-1"
        mismatched_submission = review_submission_body(build_id="build-other")
        two_group_builds = group_build_body()
        two_group_builds["data"].append({"type": "builds", "id": "build-other"})
        cases = (
            ("POST", "/v1/ciBuildRuns", mismatched_ci, "wf-1"),
            (
                "POST",
                "/v1/betaBuildLocalizations",
                mismatched_localization,
                "build-1",
            ),
            (
                "POST",
                "/v1/betaAppReviewSubmissions",
                mismatched_submission,
                "build-1",
            ),
            (
                "POST",
                "/v1/betaGroups/group-1/relationships/builds",
                two_group_builds,
                "build-1",
            ),
        )
        for method, path, body, intended_id in cases:
            with self.subTest(method=method, path=path):
                with self.assertRaises(asc.AllowlistError):
                    asc.validate_write_body(method, path, body, intended_id)

    def test_patch_path_body_and_intended_ids_must_all_match(self):
        for path, body_id, intended_id in (
            ("/v1/betaBuildLocalizations/path-id", "body-id", "path-id"),
            ("/v1/betaBuildLocalizations/path-id", "path-id", "intended-id"),
            ("/v1/betaAppReviewDetails/path-id", "body-id", "path-id"),
            ("/v1/betaAppReviewDetails/path-id", "path-id", "intended-id"),
        ):
            body = (
                localization_patch_body(body_id)
                if "betaBuildLocalizations" in path
                else review_patch_body(body_id)
            )
            with self.subTest(path=path, body_id=body_id, intended_id=intended_id):
                with self.assertRaises(asc.AllowlistError):
                    asc.validate_write_body("PATCH", path, body, intended_id)

    def test_review_patch_cannot_edit_reviewer_contact_or_demo_credentials(self):
        for forbidden in (
            "contactEmail",
            "contactFirstName",
            "contactLastName",
            "contactPhone",
            "demoAccountName",
            "demoAccountPassword",
        ):
            body = review_patch_body()
            body["data"]["attributes"][forbidden] = "forbidden"
            with self.subTest(forbidden=forbidden):
                with self.assertRaises(asc.AllowlistError):
                    asc.validate_write_body(
                        "PATCH", "/v1/betaAppReviewDetails/review-1", body, "review-1"
                    )


class ClientBehaviorTests(unittest.TestCase):
    def invoke(self, arguments, http_requests=None):
        original = asc._http_request
        asc._http_request = http_requests or (lambda *args, **kwargs: {"ok": True})
        try:
            return asc.main(arguments)
        finally:
            asc._http_request = original

    def test_dry_run_issues_zero_requests(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out.json"
            code = self.invoke(
                [
                    "get", "/v1/ciProducts",
                    "--issuer-id", "iss", "--key-id", "kid",
                    "--private-key", "/nonexistent.p8",
                    "--dry-run",
                    "--output", str(output),
                ],
                http_requests=lambda *args, **kwargs: calls.append(args) or {"ok": True},
            )
            self.assertEqual(code, 0)
            self.assertEqual(calls, [], "dry-run must not issue requests")
            self.assertTrue(output.exists())

    def test_imported_read_client_cannot_bypass_guarded_write(self):
        calls = []
        original = asc._http_request
        asc._http_request = lambda *args, **kwargs: calls.append(args) or {}
        try:
            with self.assertRaisesRegex(asc.AllowlistError, "require guarded_write"):
                asc.api_call(
                    "POST",
                    "/v1/ciBuildRuns",
                    "jwt",
                    json.dumps(ci_build_run_body()).encode("utf-8"),
                )
        finally:
            asc._http_request = original
        self.assertEqual(calls, [])

    def test_unallowlisted_route_is_denied_without_credentials(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            code = self.invoke(
                ["get", "/v1/secrets", "--output", str(Path(tmp) / "out.json")],
                http_requests=lambda *args, **kwargs: calls.append(args) or {},
            )
            self.assertEqual(code, 1)
            self.assertEqual(calls, [], "denied routes must not issue requests")

    def test_write_without_authorize_mutation_is_denied(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps(ci_build_run_body()))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
                    "--guard-get", "/v1/ciWorkflows/wf-1?include=product,repository",
                    "--output", str(Path(tmp) / "out.json"),
                ],
                http_requests=lambda *args, **kwargs: calls.append(args) or {},
            )
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])

    def test_write_with_unreferenced_intended_id_is_denied(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps(ci_build_run_body(workflow_id="other")))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
                    "--guard-get", "/v1/ciWorkflows/wf-1?include=product,repository",
                    "--authorize-mutation",
                    "--dry-run",
                    "--output", str(Path(tmp) / "out.json"),
                ],
                http_requests=lambda *args, **kwargs: calls.append(args) or {"ok": True},
            )
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])

    def test_missing_credentials_issue_zero_requests(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            code = self.invoke(
                ["get", "/v1/ciProducts", "--output", str(Path(tmp) / "out.json")],
                http_requests=lambda *args, **kwargs: calls.append(args) or {},
            )
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])

    def test_allowed_write_proceeds_past_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps(ci_build_run_body()))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
                    "--guard-get", "/v1/ciWorkflows/wf-1?include=product,repository",
                    "--authorize-mutation",
                    "--issuer-id", "iss", "--key-id", "kid",
                    "--private-key", "/nonexistent.p8",
                    "--output", str(Path(tmp) / "out.json"),
                ],
                http_requests=lambda *args, **kwargs: {"data": {"id": "run-1"}},
            )
            # Credentials are absent, so the JWT step must fail AFTER the
            # allowlist checks pass (exit 1, no network request).
            self.assertEqual(code, 1)

    def test_canonical_state_ignores_format_metadata_and_collection_order(self):
        first = {
            "data": [
                {"type": "items", "id": "2", "attributes": {"name": "two"}},
                {"type": "items", "id": "1", "attributes": {"name": "one"}},
            ],
            "links": {"self": "https://example.invalid/first", "next": None},
            "meta": {"request": "first"},
        }
        second = {
            "meta": {"request": "second"},
            "links": {"self": "https://example.invalid/second"},
            "data": list(reversed(first["data"])),
        }
        self.assertEqual(
            asc.canonical_state_sha256(first),
            asc.canonical_state_sha256(second),
        )

    def test_canonical_state_detects_changes_and_rejects_pagination(self):
        baseline = {"data": [{"type": "items", "id": "1", "attributes": {"v": 1}}]}
        changed = {"data": [{"type": "items", "id": "1", "attributes": {"v": 2}}]}
        duplicate = {"data": baseline["data"] + baseline["data"]}
        self.assertNotEqual(
            asc.canonical_state_sha256(baseline),
            asc.canonical_state_sha256(changed),
        )
        self.assertNotEqual(
            asc.canonical_state_sha256(baseline),
            asc.canonical_state_sha256(duplicate),
        )
        with self.assertRaises(asc.AllowlistError):
            asc.canonical_state_sha256({
                "data": baseline["data"],
                "links": {"next": "https://api.appstoreconnect.apple.com/next"},
            })
        with self.assertRaises(asc.AllowlistError):
            asc.canonical_state_sha256({
                "data": baseline["data"],
                "links": "malformed",
            })

    def test_canonical_state_includes_expanded_relationship_resources(self):
        baseline = {
            "data": {"type": "ciWorkflows", "id": "wf-1"},
            "included": [
                {"type": "scmRepositories", "id": "repo-1", "attributes": {"httpCloneUrl": "https://example.invalid/one"}},
                {"type": "ciProducts", "id": "product-1", "attributes": {"productType": "APP"}},
            ],
        }
        reordered = {"data": baseline["data"], "included": list(reversed(baseline["included"]))}
        changed = json.loads(json.dumps(baseline))
        changed["included"][0]["attributes"]["httpCloneUrl"] = "https://example.invalid/two"
        self.assertEqual(
            asc.canonical_state_sha256(baseline),
            asc.canonical_state_sha256(reordered),
        )
        self.assertNotEqual(
            asc.canonical_state_sha256(baseline),
            asc.canonical_state_sha256(changed),
        )

    def test_authorized_write_checks_guard_then_mutates(self):
        state = {"data": [{"type": "betaAppReviewDetails", "id": "rev-1"}]}
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_kid.p8"
            key.write_text("test key")
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps({
                "data": {"type": "betaAppReviewDetails", "id": "rev-1",
                         "attributes": {"notes": "release"}},
            }))
            original_make_jwt = asc.make_jwt
            asc.make_jwt = lambda *args: "jwt"
            try:
                code = self.invoke(
                    [
                        "patch", "/v1/betaAppReviewDetails/rev-1",
                        "--body", str(body),
                        "--intended-id", "rev-1",
                        "--prior-state-sha256", asc.canonical_state_sha256(state),
                        "--guard-get", "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200",
                        "--authorize-mutation",
                        "--issuer-id", "iss", "--key-id", "kid",
                        "--private-key", str(key),
                        "--output", str(Path(tmp) / "out.json"),
                    ],
                    http_requests=lambda method, url, headers, payload: (
                        calls.append((method, url))
                        or (state if method == "GET" else {"data": {"id": "rev-1"}})
                    ),
                )
            finally:
                asc.make_jwt = original_make_jwt
        self.assertEqual(code, 0)
        self.assertEqual([method for method, _ in calls], ["GET", "PATCH"])

    def test_stale_guard_blocks_before_mutation(self):
        state = {"data": [{"type": "betaAppReviewDetails", "id": "rev-1"}]}
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_kid.p8"
            key.write_text("test key")
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps(review_patch_body("rev-1")))
            original_make_jwt = asc.make_jwt
            asc.make_jwt = lambda *args: "jwt"
            try:
                code = self.invoke(
                    [
                        "patch", "/v1/betaAppReviewDetails/rev-1",
                        "--body", str(body),
                        "--intended-id", "rev-1",
                        "--prior-state-sha256", "0" * 64,
                        "--guard-get", "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200",
                        "--authorize-mutation",
                        "--issuer-id", "iss", "--key-id", "kid",
                        "--private-key", str(key),
                        "--output", str(Path(tmp) / "out.json"),
                    ],
                    http_requests=lambda method, url, headers, payload: (
                        calls.append((method, url)) or state
                    ),
                )
            finally:
                asc.make_jwt = original_make_jwt
        self.assertEqual(code, 1)
        self.assertEqual([method for method, _ in calls], ["GET"])

    def test_invalid_digest_or_guard_route_issues_zero_requests(self):
        cases = (
            ("INVALID", "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200"),
            ("0" * 64, "/v1/builds?filter[app]=6796708699"),
            (
                "0" * 64,
                "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=1",
            ),
            (
                "0" * 64,
                "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200&fields[betaAppReviewDetails]=notes",
            ),
        )
        for digest, guard in cases:
            with self.subTest(digest=digest, guard=guard), tempfile.TemporaryDirectory() as tmp:
                calls = []
                body = Path(tmp) / "body.json"
                body.write_text(json.dumps(review_patch_body("rev-1")))
                code = self.invoke(
                    [
                        "patch", "/v1/betaAppReviewDetails/rev-1",
                        "--body", str(body),
                        "--intended-id", "rev-1",
                        "--prior-state-sha256", digest,
                        "--guard-get", guard,
                        "--authorize-mutation",
                        "--output", str(Path(tmp) / "out.json"),
                    ],
                    http_requests=lambda *args: calls.append(args) or {},
                )
                self.assertEqual(code, 1)
                self.assertEqual(calls, [])

    def test_write_dry_run_does_not_fetch_guard_or_mutate(self):
        calls = []
        state = {"data": []}
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp) / "body.json"
            output = Path(tmp) / "out.json"
            body.write_text(json.dumps(review_submission_body()))
            code = self.invoke(
                [
                    "post", "/v1/betaAppReviewSubmissions",
                    "--body", str(body),
                    "--intended-id", "build-1",
                    "--prior-state-sha256", asc.canonical_state_sha256(state),
                    "--guard-get", "/v1/betaAppReviewSubmissions?filter[build]=build-1&limit=200",
                    "--authorize-mutation", "--dry-run",
                    "--output", str(output),
                ],
                http_requests=lambda *args: calls.append(args) or {},
            )
            self.assertEqual(code, 0)
            self.assertEqual(calls, [])
            self.assertEqual(
                json.loads(output.read_text())["precondition_status"],
                "not_checked_dry_run",
            )

    def test_patch_guard_must_uniquely_contain_target_resource(self):
        state = {"data": [{"type": "betaAppReviewDetails", "id": "other"}]}
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_kid.p8"
            key.write_text("test key")
            body = Path(tmp) / "body.json"
            body.write_text(json.dumps(review_patch_body("rev-1")))
            original_make_jwt = asc.make_jwt
            asc.make_jwt = lambda *args: "jwt"
            try:
                code = self.invoke(
                    [
                        "patch", "/v1/betaAppReviewDetails/rev-1",
                        "--body", str(body),
                        "--intended-id", "rev-1",
                        "--prior-state-sha256", asc.canonical_state_sha256(state),
                        "--guard-get", "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200",
                        "--authorize-mutation",
                        "--issuer-id", "iss", "--key-id", "kid",
                        "--private-key", str(key),
                        "--output", str(Path(tmp) / "out.json"),
                    ],
                    http_requests=lambda method, url, headers, payload: (
                        calls.append((method, url)) or state
                    ),
                )
            finally:
                asc.make_jwt = original_make_jwt
        self.assertEqual(code, 1)
        self.assertEqual([method for method, _ in calls], ["GET"])

    def test_wait_ci_run_polls_ci_build_run_completion(self):
        # App Store Connect exposes runs as ciBuildRuns: terminal state is
        # executionProgress COMPLETE + completionStatus SUCCESS, and the head
        # lives in sourceCommit.commitSha.
        calls = []

        def client(method, path, dry_run=False):
            calls.append(path)
            return {
                "data": {
                    "id": "run-1",
                    "type": "ciBuildRuns",
                    "attributes": {
                        "executionProgress": "COMPLETE",
                        "completionStatus": "SUCCEEDED",
                        "sourceCommit": {"commitSha": "a" * 40},
                    },
                }
            }

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "run.json"
            asc.wait_ci_run(client, "run-1", "a" * 40, out, dry_run=False)
            self.assertEqual(calls, ["/v1/ciBuildRuns/run-1"])
            self.assertEqual(json.loads(out.read_text())["data"]["id"], "run-1")

    def test_wait_ci_run_accepts_succeeded_completion_status(self):
        # The API reports success as completionStatus "SUCCEEDED" (not
        # "SUCCEEDED"); the waiter must treat it as terminal and successful.
        def client(method, path, dry_run=False):
            return {
                "data": {
                    "id": "run-1",
                    "attributes": {
                        "executionProgress": "COMPLETE",
                        "completionStatus": "SUCCEEDED",
                        "sourceCommit": {"commitSha": "a" * 40},
                    },
                }
            }

        original_sleep = asc.time.sleep
        asc.time.sleep = lambda seconds: (_ for _ in ()).throw(
            AssertionError("waiter polled again: SUCCEEDED was not treated as terminal")
        )
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "run.json"
                asc.wait_ci_run(client, "run-1", "a" * 40, out, dry_run=False)
                self.assertEqual(
                    json.loads(out.read_text())["data"]["attributes"]["completionStatus"],
                    "SUCCEEDED",
                )
        finally:
            asc.time.sleep = original_sleep

    def test_wait_ci_run_rejects_head_mismatch(self):
        def client(method, path, dry_run=False):
            return {
                "data": {
                    "id": "run-1",
                    "attributes": {
                        "executionProgress": "COMPLETE",
                        "completionStatus": "SUCCEEDED",
                        "sourceCommit": {"commitSha": "b" * 40},
                    },
                }
            }

        with self.assertRaises(asc.AllowlistError):
            asc.wait_ci_run(client, "run-1", "a" * 40, Path("/tmp/x.json"), dry_run=False)

    def test_wait_ci_run_raises_on_failed_completion(self):
        for status in ("FAILED", "ERRORED", "CANCELED", "SKIPPED"):
            with self.subTest(status=status):
                def client(method, path, dry_run=False):
                    return {
                        "data": {
                            "id": "run-1",
                            "attributes": {
                                "executionProgress": "COMPLETE",
                                "completionStatus": status,
                                "sourceCommit": {"commitSha": "a" * 40},
                            },
                        }
                    }

                original_sleep = asc.time.sleep
                asc.time.sleep = lambda seconds: (_ for _ in ()).throw(
                    AssertionError(f"waiter polled again after terminal status {status}")
                )
                try:
                    with self.assertRaises(asc.AllowlistError):
                        asc.wait_ci_run(
                            client,
                            "run-1",
                            "a" * 40,
                            Path("/tmp/x.json"),
                            dry_run=False,
                        )
                finally:
                    asc.time.sleep = original_sleep

    def test_download_ci_artifact_resolves_actions_then_artifacts(self):
        # Artifacts hang off ciBuildActions: list actions, then the action's
        # artifacts, and pick the one whose fileType matches the relationship.
        responses = {
            "/v1/ciBuildRuns/run-1/actions": {
                "data": [{"id": "action-1", "type": "ciBuildActions"}]
            },
            "/v1/ciBuildActions/action-1/artifacts": {
                "data": [
                    {"id": "a1", "attributes": {"fileType": "LOG_BUNDLE", "downloadUrl": "https://x/log"}},
                    {"id": "a2", "attributes": {"fileType": "ARCHIVE", "downloadUrl": "https://x/archive"}},
                ]
            },
        }
        calls = []

        def client(method, path, dry_run=False):
            calls.append(path)
            return responses[path]

        original_urlopen = asc.urllib.request.urlopen

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b"archive-bytes"

        asc.urllib.request.urlopen = lambda request, timeout=300: FakeResponse()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "a.zip"
                sha = Path(tmp) / "a.zip.sha256"
                asc.download_ci_artifact(client, "run-1", "archives", out, sha, dry_run=False)
                self.assertEqual(out.read_bytes(), b"archive-bytes")
                self.assertEqual(
                    sha.read_text().strip(),
                    hashlib.sha256(b"archive-bytes").hexdigest(),
                )
                self.assertEqual(calls, [
                    "/v1/ciBuildRuns/run-1/actions",
                    "/v1/ciBuildActions/action-1/artifacts",
                ])
        finally:
            asc.urllib.request.urlopen = original_urlopen


class CryptoTests(unittest.TestCase):
    def test_der_to_raw_signature_padding(self):
        # Well-formed DER with 33-byte (leading-zero) r and s integers:
        # SEQUENCE len 0x46, INTEGER 0x21 00<r32>, INTEGER 0x21 00<s32>.
        # r32 = 01..20, s32 = 21..40 (hex), each prefixed with 0x00.
        der = bytes.fromhex(
            "3046"
            "0221"
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
            "0221"
            "002122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
        )
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(
            raw[:32].hex(),
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
        )
        self.assertEqual(
            raw[32:].hex(),
            "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
        )

    def test_der_to_raw_signature_standard_double_int(self):
        # Standard OpenSSL pkeyutl -sign output: 0x30 len 0x02 rlen r 0x02 slen s,
        # where s carries a leading zero (33-byte integer). The second integer's
        # tag byte must not be mistaken for its length.
        der = bytes.fromhex(
            "304502205c69b8d57282b6f9993835ea895ff1032f89d5b870ad2cfc64c9c274b378b129"
            "022100f17cdc6470b4a99439c46d8eaa5ab95fef3d83ac69a2f168cb999c6badfc6c43"
        )
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(
            raw[:32].hex(),
            "5c69b8d57282b6f9993835ea895ff1032f89d5b870ad2cfc64c9c274b378b129",
        )
        self.assertEqual(
            raw[32:].hex(),
            "f17cdc6470b4a99439c46d8eaa5ab95fef3d83ac69a2f168cb999c6badfc6c43",
        )

    def test_make_jwt_requires_existing_key(self):
        with self.assertRaises(asc.CredentialError):
            asc.make_jwt("iss", "kid", Path("/nonexistent.p8"), 1_700_000_000)

    def test_make_jwt_signs_with_real_p256_key(self):
        openssl = asc.OPENSSL3
        result = subprocess.run(
            [openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
            capture_output=True,
        )
        if result.returncode != 0:
            self.skipTest("openssl ecparam unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "key.p8"
            key.write_bytes(result.stdout)
            token = asc.make_jwt("issuer-1", "key-1", key, 1_700_000_000)
            self.assertEqual(len(token.split(".")), 3)

    def test_polling_client_mints_fresh_jwt_per_request(self):
        # Regression: a wait-ci-run poll can run up to 180 minutes, far beyond
        # the 20-minute JWT lifetime; every request must carry a freshly
        # minted token instead of one minted before the poll loop.
        minted = []
        recorded = []
        original_make_jwt = asc.make_jwt
        original_api_call = asc.api_call

        def fake_make_jwt(issuer_id, key_id, private_key_path, now):
            minted.append(now)
            return "jwt-%d" % len(minted)

        def fake_api_call(method, path, jwt, body=None, dry_run=False):
            recorded.append((method, path, jwt, dry_run))
            return {"ok": True}

        asc.make_jwt = fake_make_jwt
        asc.api_call = fake_api_call
        try:
            client = asc.build_polling_client(
                "issuer-1", "key-1", Path("/unused.p8"), dry_run=False
            )
            client("GET", "/v1/ciRuns/123", dry_run=False)
            client("GET", "/v1/ciRuns/123", dry_run=False)
            self.assertEqual(len(recorded), 2)
            self.assertEqual([entry[2] for entry in recorded], ["jwt-1", "jwt-2"])
        finally:
            asc.make_jwt = original_make_jwt
            asc.api_call = original_api_call

    def test_polling_client_dry_run_mints_nothing(self):
        minted = []
        recorded = []
        original_make_jwt = asc.make_jwt
        original_api_call = asc.api_call

        def fake_make_jwt(issuer_id, key_id, private_key_path, now):
            minted.append(now)
            return "jwt-%d" % len(minted)

        def fake_api_call(method, path, jwt, body=None, dry_run=False):
            recorded.append((method, path, jwt, dry_run))
            return {"ok": True}

        asc.make_jwt = fake_make_jwt
        asc.api_call = fake_api_call
        try:
            client = asc.build_polling_client("", "", Path("."), dry_run=True)
            client("GET", "/v1/ciRuns/123", dry_run=True)
            self.assertEqual(minted, [])
            self.assertEqual(recorded, [("GET", "/v1/ciRuns/123", "", True)])
        finally:
            asc.make_jwt = original_make_jwt
            asc.api_call = original_api_call


if __name__ == "__main__":
    unittest.main()
