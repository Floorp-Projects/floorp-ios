"""TDD contract for canonical, metadata-only G5 execution receipts.

These tests cover parsing and validation only.  They neither authorize nor run
G5, and intentionally contain no account, credential, or Notes data.
"""

from __future__ import annotations

import copy
import json
import unittest
from unittest.mock import patch

from scripts.staging.floorp_notes_sync_g5_receipt import (
    EXPECTED_REPOSITORY,
    EXPECTED_WORKFLOW_PATH,
    ReceiptError,
    parse_and_validate_receipt,
    validate_receipt,
)


HEAD_SHA = "a" * 40
FIXTURE_DIGEST = "b" * 64


class AlwaysEqual:
    def __eq__(self, _: object) -> bool:
        return True


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


def canonical_payload(receipt: dict[str, object] | None = None) -> str:
    value = valid_receipt() if receipt is None else receipt

    def encode(item: object) -> str:
        if isinstance(item, dict):
            keys = sorted(item, key=lambda key: key.encode("utf-16-be"))
            return "{" + ",".join(f"{encode(key)}:{encode(item[key])}" for key in keys) + "}"
        if isinstance(item, list):
            return "[" + ",".join(encode(child) for child in item) + "]"
        return json.dumps(item, ensure_ascii=False, separators=(",", ":"), allow_nan=False)

    return encode(value)


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
            canonical_payload(),
            expected_run_binding=expected_run_binding(),
        )
        self.assertEqual(parsed["status"], "receipt-valid")

        duplicate_schema = '{"schema_version":1,"schema_version":1}'
        with self.assertRaises(ReceiptError):
            parse_and_validate_receipt(
                duplicate_schema,
                expected_run_binding=expected_run_binding(),
            )

    def test_rejects_empty_non_json_and_non_object_payloads(self) -> None:
        for payload in ("", "not-json", "null", "[]", "1", "true"):
            with self.subTest(payload=payload):
                with self.assertRaises(ReceiptError):
                    parse_and_validate_receipt(
                        payload,
                        expected_run_binding=expected_run_binding(),
                    )

    def test_rejects_direct_python_payload_with_unpaired_surrogate(self) -> None:
        payload = '{"invalid":"' + chr(0xD800) + '"}'

        with self.assertRaises(ReceiptError):
            parse_and_validate_receipt(
                payload,
                expected_run_binding=expected_run_binding(),
            )

    def test_rejects_nested_duplicate_json_fields(self) -> None:
        payload = canonical_payload()
        payload = payload.replace(
            '"run_id":123456789,',
            '"run_id":123456789,"run_id":123456789,',
        )

        with self.assertRaises(ReceiptError):
            parse_and_validate_receipt(
                payload,
                expected_run_binding=expected_run_binding(),
            )

    def test_rejects_noncanonical_whitespace_and_key_order_bytes(self) -> None:
        canonical = canonical_payload()
        original = valid_receipt()
        reordered_receipt = {"schema_version": original["schema_version"]}
        reordered_receipt.update(
            {key: value for key, value in original.items() if key != "schema_version"}
        )
        variants = (
            canonical + "\n",
            canonical.replace(":", ": ", 1),
            json.dumps(reordered_receipt, ensure_ascii=False, separators=(",", ":")),
        )
        for payload in variants:
            with self.subTest(payload=payload[:48]):
                with self.assertRaises(ReceiptError):
                    parse_and_validate_receipt(
                        payload,
                        expected_run_binding=expected_run_binding(),
                    )

    def test_rejects_floats_constants_over_safe_integers_and_unpaired_surrogates(self) -> None:
        canonical = canonical_payload()
        payloads = (
            canonical.replace('"run_id":123456789', '"run_id":123456789.0'),
            canonical.replace('"run_id":123456789', '"run_id":NaN'),
            canonical.replace('"run_id":123456789', '"run_id":Infinity'),
            canonical.replace('"run_id":123456789', '"run_id":-Infinity'),
            canonical.replace('"run_id":123456789', '"run_id":9007199254740992'),
            canonical.replace('"status":"passed"', '"status":"\\ud800"'),
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(ReceiptError):
                    parse_and_validate_receipt(
                        payload,
                        expected_run_binding=expected_run_binding(),
                    )

    def test_rejects_numeric_and_boolean_type_aliases_direct_and_parsed(self) -> None:
        direct_mutations = (
            (("schema_version",), True),
            (("schema_version",), 1.0),
            (("network", "observations", 0, "port"), 443.0),
            (("retention", "payload_retained"), 0),
            (("retention", "payload_retained"), 0.0),
            (("retention", "secrets_retained"), 0),
            (("retention", "secrets_retained"), 0.0),
            (("run_binding", "run_id"), 9_007_199_254_740_992),
        )
        for path, value in direct_mutations:
            with self.subTest(path=path, value=value):
                receipt = valid_receipt()
                target: object = receipt
                for key in path[:-1]:
                    target = target[key]  # type: ignore[index]
                target[path[-1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

        canonical = canonical_payload()
        parsed_mutations = (
            canonical.replace('"schema_version":1', '"schema_version":true'),
            canonical.replace('"schema_version":1', '"schema_version":1.0'),
            canonical.replace('"port":443', '"port":443.0', 1),
            canonical.replace('"payload_retained":false', '"payload_retained":0'),
            canonical.replace('"secrets_retained":false', '"secrets_retained":0.0'),
            canonical.replace('"run_id":123456789', '"run_id":9007199254740992'),
        )
        for payload in parsed_mutations:
            with self.subTest(payload=payload):
                with self.assertRaises(ReceiptError):
                    parse_and_validate_receipt(
                        payload,
                        expected_run_binding=expected_run_binding(),
                    )

    def test_uses_utf16be_key_order_for_canonical_receipt_bytes(self) -> None:
        receipt = valid_receipt()
        receipt["matrix"] = {
            "\ue000": receipt["matrix"],
            "😀": receipt["matrix"],
            "client_slots": ["client-a", "client-b"],
            "fixture_digest": FIXTURE_DIGEST,
            "status": "passed",
        }
        # The added keys intentionally make this semantically invalid; canonical
        # bytes must be checked before schema validation for this ordering proof.
        utf16_payload = canonical_payload(receipt)
        code_point_payload = json.dumps(
            receipt,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        self.assertNotEqual(utf16_payload, code_point_payload)

        with self.assertRaises(ReceiptError) as rejected:
            parse_and_validate_receipt(
                code_point_payload,
                expected_run_binding=expected_run_binding(),
            )
        self.assertEqual(str(rejected.exception), "receipt JSON bytes are not canonical")

        with patch(
            "scripts.staging.floorp_notes_sync_g5_receipt.validate_receipt",
            return_value={"status": "receipt-valid"},
        ) as validate:
            parsed = parse_and_validate_receipt(
                utf16_payload,
                expected_run_binding=expected_run_binding(),
            )
        self.assertEqual(parsed, {"status": "receipt-valid"})
        validate.assert_called_once()

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

    def test_rejects_malformed_uppercase_and_wrong_sha_values(self) -> None:
        mutations = (
            (("run_binding", "head_sha"), "A" * 40),
            (("run_binding", "head_sha"), "a" * 39),
            (("run_binding", "head_sha"), "g" * 40),
            (("matrix", "fixture_digest"), "B" * 64),
            (("matrix", "fixture_digest"), "b" * 63),
            (("matrix", "fixture_digest"), "z" * 64),
        )
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                receipt = valid_receipt()
                receipt[path[0]][path[1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_rejects_boolean_run_binding_numbers_and_key_variations(self) -> None:
        for path, value in (
            (("run_binding", "run_id"), True),
            (("run_binding", "run_attempt"), False),
        ):
            with self.subTest(path=path):
                receipt = valid_receipt()
                receipt[path[0]][path[1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

        for key, value in (("unexpected", "value"), ("workflow_path", None)):
            with self.subTest(key=key):
                receipt = valid_receipt()
                if key == "workflow_path":
                    del receipt["run_binding"][key]  # type: ignore[index]
                else:
                    receipt["run_binding"][key] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())

    def test_rejects_invalid_or_noncanonical_expected_run_binding(self) -> None:
        invalid_bindings = (
            {},
            {"head_sha": HEAD_SHA},
            {**expected_run_binding(), "unexpected": "value"},
            {**expected_run_binding(), "head_sha": "A" * 40},
            {**expected_run_binding(), "run_id": True},
            {**expected_run_binding(), "run_attempt": False},
        )
        for binding in invalid_bindings:
            with self.subTest(binding=binding):
                with self.assertRaises(ReceiptError):
                    validate_receipt(valid_receipt(), expected_run_binding=binding)

        for binding in (None, [], 1, True):
            with self.subTest(binding=binding):
                with self.assertRaises(ReceiptError):
                    validate_receipt(valid_receipt(), expected_run_binding=binding)  # type: ignore[arg-type]

    def test_rejects_always_equal_repository_and_workflow_binding_values(self) -> None:
        for key in ("repository", "workflow_path"):
            with self.subTest(key=key):
                binding = expected_run_binding()
                binding[key] = AlwaysEqual()
                with self.assertRaises(ReceiptError):
                    validate_receipt(valid_receipt(), expected_run_binding=binding)

    def test_rejects_unapproved_or_incomplete_network_observations(self) -> None:
        mutations = (
            ([],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 80, "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 443, "tls_verified": False}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "failed", "port": 443, "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "pending", "port": 443, "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": True, "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": "443", "tls_verified": True}],),
            ([{"host": "sync.services.mozilla.com", "outcome": "succeeded", "port": 443, "tls_verified": 1}],),
            ([{"host": 1, "outcome": "succeeded", "port": 443, "tls_verified": True}],),
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

    def test_rejects_extra_fields_in_each_nested_exact_object(self) -> None:
        mutations = (
            (("matrix", "extra"), "value"),
            (("network", "extra"), "value"),
            (("outcomes", "extra"), True),
            (("retention", "extra"), False),
            (("network", "observations", 0, "extra"), "value"),
        )
        for path, value in mutations:
            with self.subTest(path=path):
                receipt = valid_receipt()
                target: object = receipt
                for key in path[:-1]:
                    target = target[key]  # type: ignore[index]
                target[path[-1]] = value  # type: ignore[index]
                with self.assertRaises(ReceiptError):
                    validate_receipt(receipt, expected_run_binding=expected_run_binding())


if __name__ == "__main__":
    unittest.main()
