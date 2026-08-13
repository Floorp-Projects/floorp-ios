"""TDD contract for canonical, metadata-only G5 execution receipts.

These tests cover parsing and validation only.  They neither authorize nor run
G5, and intentionally contain no account, credential, or Notes data.
"""

from __future__ import annotations

import copy
import json
import unittest

from scripts.staging.floorp_notes_sync_g5_receipt import (
    EXPECTED_REPOSITORY,
    EXPECTED_WORKFLOW_PATH,
    ReceiptError,
    parse_and_validate_receipt,
    validate_receipt,
)


HEAD_SHA = "a" * 40
FIXTURE_DIGEST = "b" * 64


def expected_run_binding() -> dict[str, object]:
    return {
        "head_sha": HEAD_SHA,
        "repository": EXPECTED_REPOSITORY,
        "run_attempt": 1,
        "run_id": 123456789,
        "workflow_path": EXPECTED_WORKFLOW_PATH,
    }


def valid_receipt() -> dict[str, object]:
    return {
        "matrix": {
            "client_slots": ["client-a", "client-b"],
            "fixture_digest": FIXTURE_DIGEST,
            "status": "passed",
        },
        "network": {
            "metadata_only": True,
            "observations": [
                {
                    "host": "accounts.firefox.com",
                    "outcome": "succeeded",
                    "port": 443,
                    "tls_verified": True,
                },
                {
                    "host": "sync.services.mozilla.com",
                    "outcome": "succeeded",
                    "port": 443,
                    "tls_verified": True,
                },
            ],
            "tls_interception": False,
        },
        "outcomes": {
            "base_advanced": True,
            "desktop_cleanup_verified": True,
            "ios_cleanup_verified": True,
            "local_only_fallback_verified": True,
            "remote_cleanup_verified": True,
            "rollback_verified": True,
        },
        "retention": {
            "payload_retained": False,
            "secrets_retained": False,
        },
        "run_binding": expected_run_binding(),
        "schema_version": 1,
    }


class FloorpNotesSyncG5ReceiptTests(unittest.TestCase):
    def test_accepts_exact_safe_receipt_bound_to_expected_run(self) -> None:
        receipt = valid_receipt()

        decision = validate_receipt(receipt, expected_run_binding=expected_run_binding())

        self.assertEqual(decision["status"], "receipt-valid")
        self.assertEqual(decision["execution_authorization"], "not-granted")
        self.assertEqual(decision["g5_result"], "not-assessed")
        self.assertEqual(decision["run_binding"], expected_run_binding())

    def test_parses_only_json_without_duplicate_fields(self) -> None:
        parsed = parse_and_validate_receipt(
            json.dumps(valid_receipt()),
            expected_run_binding=expected_run_binding(),
        )
        self.assertEqual(parsed["status"], "receipt-valid")

        duplicate_schema = '{"schema_version":1,"schema_version":1}'
        with self.assertRaises(ReceiptError):
            parse_and_validate_receipt(
                duplicate_schema,
                expected_run_binding=expected_run_binding(),
            )

    def test_rejects_unknown_and_credential_or_content_like_fields(self) -> None:
        for path, value in (
            (("runner",), "untrusted"),
            (("network", "authorization_header"), "none"),
            (("matrix", "note_content"), "none"),
            (("retention", "token_retained"), False),
        ):
            with self.subTest(path=path):
                receipt = valid_receipt()
                target: dict[str, object] = receipt
                for key in path[:-1]:
                    target = target[key]  # type: ignore[assignment]
                target[path[-1]] = value
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_rejects_sensitive_or_location_like_values(self) -> None:
        mutations = (
            (("matrix", "status"), "Bearer opaque-value"),
            (("matrix", "status"), "https://example.invalid"),
            (("matrix", "status"), "passed?token=opaque"),
            (("matrix", "status"), "passed#fragment"),
            (("matrix", "status"), "person@example.invalid"),
            (("run_binding", "repository"), "Floorp-Projects/floorp-ios OAuth"),
        )
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                receipt = valid_receipt()
                receipt[path[0]][path[1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_rejects_unbound_run_or_noncanonical_slots_and_outcomes(self) -> None:
        mutations = (
            (("run_binding", "head_sha"), "c" * 40),
            (("run_binding", "run_id"), 0),
            (("matrix", "client_slots"), ["client-a", "client-c"]),
            (("matrix", "client_slots"), ["client-b", "client-a"]),
            (("outcomes", "ios_cleanup_verified"), False),
            (("outcomes", "remote_cleanup_verified"), False),
        )
        for path, value in mutations:
            with self.subTest(path=path):
                receipt = valid_receipt()
                receipt[path[0]][path[1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_rejects_unapproved_or_incomplete_network_observations(self) -> None:
        mutations = (
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 80, "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 443, "tls_verified": False}],),
            ([{"host": "unapproved.invalid", "outcome": "succeeded", "port": 443, "tls_verified": True}],),
            ([{"host": "accounts.firefox.com", "outcome": "succeeded", "port": 443, "tls_verified": True}],),
            ([
                {"host": "accounts.firefox.com", "outcome": "succeeded", "port": 443, "tls_verified": True},
                {"host": "accounts.firefox.com", "outcome": "succeeded", "port": 443, "tls_verified": True},
                {"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 443, "tls_verified": True},
            ],),
        )
        for (observations,) in mutations:
            with self.subTest(observations=observations):
                receipt = valid_receipt()
                receipt["network"]["observations"] = observations  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_accepts_approved_oauth_host_as_metadata(self) -> None:
        receipt = valid_receipt()
        receipt["network"]["observations"][0]["host"] = "oauth.accounts.firefox.com"  # type: ignore[index]

        decision = validate_receipt(receipt, expected_run_binding=expected_run_binding())

        self.assertEqual(decision["status"], "receipt-valid")

    def test_rejects_tls_interception_retention_or_extra_event_fields(self) -> None:
        for path, value in (
            (("network", "tls_interception"), True),
            (("network", "metadata_only"), False),
            (("retention", "payload_retained"), True),
            (("retention", "secrets_retained"), True),
        ):
            with self.subTest(path=path):
                receipt = valid_receipt()
                receipt[path[0]][path[1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

        receipt = copy.deepcopy(valid_receipt())
        receipt["network"]["observations"][0]["url"] = "https://example.invalid"  # type: ignore[index]
        with self.assertRaises(ReceiptError):
            validate_receipt(receipt, expected_run_binding=expected_run_binding())


if __name__ == "__main__":
    unittest.main()
