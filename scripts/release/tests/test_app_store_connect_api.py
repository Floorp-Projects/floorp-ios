"""Unit tests for scripts/release/app-store-connect-api.py."""

import importlib.util
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
            "/v1/ciWorkflows?filter[ciProduct]=abc",
            "/v1/ciBuildRuns",
            "/v1/builds",
            "/v1/betaGroups",
            "/v1/ciRuns/123",
            "/v1/ciRuns/123/artifacts",
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
            ("GET", "/v1/ciWorkflows/123"),
        ]
        for method, path in denied:
            self.assertFalse(asc.route_allowed(method, path), f"{method} {path}")


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


class CryptoTests(unittest.TestCase):
    def test_der_to_raw_signature_padding(self):
        der = bytes.fromhex(
            "3045022100b8e5c5e4c5e7b5d5c5b5a5c5d5e5f505152535455565758595a5b5c5d5e5f"
            "022100b8e5c5e4c5e7b5d5c5b5a5c5d5e5f505152535455565758595a5b5c5d5e5f60"
        )
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)

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


if __name__ == "__main__":
    unittest.main()
