"""Tests for canonical two-tier catalog signing."""

from __future__ import annotations

import base64
import importlib.util
import json
import sys
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
MODULE_PATH = SCRIPTS_DIRECTORY / "sign_catalog.py"
SPEC = importlib.util.spec_from_file_location("floorp_sign_catalog", MODULE_PATH)
assert SPEC and SPEC.loader
SIGN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SIGN
SPEC.loader.exec_module(SIGN)


def record() -> dict[str, object]:
    digest = "a" * 64
    return {
        "artifactBytes": 123,
        "artifactSHA256": digest,
        "artifactURL": "https://catalog.floorp.example/artifacts/example.fwea1",
        "availability": "available",
        "compatibilityProfiles": ["content-script", "action-storage"],
        "extensionID": "example.useful-extension",
        "generation": "gen1",
        "manifestSHA256": "b" * 64,
        "metadata": {
            "category": "Productivity",
            "description": "A useful compatibility build.",
            "displayName": "Useful Example",
            "hostPermissions": ["https://example.test/*"],
            "license": "MIT",
            "minimumFloorpBuild": "0.2.0",
            "modificationStatus": "compatibility-patched",
            "noticesSHA256": "c" * 64,
            "originalArtifactSHA256": "d" * 64,
            "permissions": ["storage", "scripting"],
            "privateProfileCapability": "opt-in",
            "sourceURL": "https://github.com/example/useful-extension",
            "upstream": "example/useful-extension",
            "upstreamRevision": "v1.0.0",
        },
        "resourceInventorySHA256": "e" * 64,
        "version": "1.0.0",
    }


def decode_base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))


class SignCatalogTests(unittest.TestCase):
    def test_signs_canonical_two_tier_catalog(self) -> None:
        root = Ed25519PrivateKey.generate()
        leaf = Ed25519PrivateKey.generate()
        catalog, root_raw = SIGN.signed_catalog(
            records=[record()],
            root_key=root,
            leaf_key=leaf,
            root_key_id="floorp-beta-root-2026",
            leaf_key_id="floorp-beta-leaf-2026-08",
            catalog_id="floorp-curated-beta",
            app_bundle_id="org.floorp.ios",
            minimum_app_version="0.2.0",
            channel="testflight",
            sequence=1,
            issued_at="2026-08-26T12:00:00Z",
            expires_at="2026-09-01T12:00:00Z",
            leaf_not_before="2026-08-25T12:00:00Z",
            leaf_not_after="2026-10-01T12:00:00Z",
        )
        parsed = json.loads(catalog)
        self.assertEqual(catalog, SIGN.canonical_json(parsed))
        self.assertEqual(parsed["schemaVersion"], 2)
        self.assertEqual(root_raw, root.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))

        signing_key = parsed["signingKey"]
        unsigned_leaf = dict(signing_key)
        signature = decode_base64url(unsigned_leaf.pop("signature"))
        Ed25519PublicKey.from_public_bytes(root_raw).verify(signature, SIGN.canonical_json(unsigned_leaf))

        unsigned_catalog = dict(parsed)
        catalog_signature = decode_base64url(unsigned_catalog.pop("signature"))
        leaf_raw = decode_base64url(signing_key["publicKey"])
        Ed25519PublicKey.from_public_bytes(leaf_raw).verify(catalog_signature, SIGN.canonical_json(unsigned_catalog))

    def test_rejects_missing_rich_metadata_and_bad_validity(self) -> None:
        invalid = record()
        invalid.pop("metadata")
        with self.assertRaisesRegex(SIGN.CatalogSigningError, "unexpected fields"):
            SIGN.validate_record(invalid, schema=2)

        root = Ed25519PrivateKey.generate()
        leaf = Ed25519PrivateKey.generate()
        with self.assertRaisesRegex(SIGN.CatalogSigningError, "within 14 days"):
            SIGN.signed_catalog(
                records=[record()],
                root_key=root,
                leaf_key=leaf,
                root_key_id="root",
                leaf_key_id="leaf",
                catalog_id="catalog",
                app_bundle_id="org.floorp.ios",
                minimum_app_version="0.2.0",
                channel="testflight",
                sequence=1,
                issued_at="2026-08-26T12:00:00Z",
                expires_at="2026-10-01T12:00:00Z",
                leaf_not_before="2026-08-25T12:00:00Z",
                leaf_not_after="2026-10-01T12:00:00Z",
            )

    def test_load_records_bytes_validates_the_supplied_snapshot(self) -> None:
        expected = record()
        records = SIGN.load_records_bytes(json.dumps([expected]).encode("utf-8"), schema=2)
        self.assertEqual(records, [expected])

        with self.assertRaisesRegex(SIGN.CatalogSigningError, "non-empty JSON array"):
            SIGN.load_records_bytes(b"[]", schema=2)


if __name__ == "__main__":
    unittest.main()
