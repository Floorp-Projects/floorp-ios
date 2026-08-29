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


class AllowlistTests(unittest.TestCase):
    def test_read_allowlist_accepts_required_gets(self):
        for path in [
            "/v1/ciProducts",
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
            "/v1/builds/build-1/preReleaseVersion",
            "/v1/betaGroups",
            "/v1/betaAppReviewDetails",
            "/v1/betaAppReviewSubmissions",
            "/v1/betaBuildLocalizations",
            "/v1/apps/abc/builds",
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
            body.write_text(json.dumps({"data": {"id": "wf-1"}}))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
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
            body.write_text(json.dumps({"data": {"id": "other"}}))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
                    "--authorize-mutation",
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
            body.write_text(json.dumps({"data": {"relationships": {"workflow": {"data": {"id": "wf-1"}}}}}))
            code = self.invoke(
                [
                    "post", "/v1/ciBuildRuns",
                    "--body", str(body),
                    "--intended-id", "wf-1",
                    "--prior-state-sha256", "0" * 64,
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
        def client(method, path, dry_run=False):
            return {
                "data": {
                    "id": "run-1",
                    "attributes": {
                        "executionProgress": "COMPLETE",
                        "completionStatus": "FAILED",
                        "sourceCommit": {"commitSha": "a" * 40},
                    },
                }
            }

        with self.assertRaises(asc.AllowlistError):
            asc.wait_ci_run(client, "run-1", "a" * 40, Path("/tmp/x.json"), dry_run=False)

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
