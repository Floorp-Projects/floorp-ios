"""Tests for the release-only signed curated catalog verifier."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS_DIRECTORY / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


INGEST = load_module("floorp_release_ingest", "ingest_extension.py")
SIGN = load_module("floorp_release_sign", "sign_catalog.py")
VERIFY = load_module("floorp_release_verify", "verify_signed_curated_catalog_release.py")


NOW = datetime(2026, 8, 27, 12, 0, tzinfo=timezone.utc)


class VerifySignedCuratedCatalogReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.catalog_root = self.root / "CuratedCatalog"
        self.artifacts = self.catalog_root / "Artifacts"
        self.signed = self.artifacts / "Signed"
        self.signed.mkdir(parents=True)
        resources = {
            "manifest.json": json.dumps({
                "manifest_version": 3,
                "name": "Example",
                "version": "1.0.0",
                "permissions": ["storage"],
                "host_permissions": ["https://example.test/*"],
            }, separators=(",", ":"), sort_keys=True).encode("utf-8"),
            "content.js": b"document.documentElement.dataset.example = '1';\n",
        }
        artifact, inventory = INGEST.encode_fwea1(
            [INGEST.ArchiveEntry(path=path, data=data) for path, data in resources.items()]
        )
        self.artifact_path = self.artifacts / "example.fwea1"
        self.artifact_path.write_bytes(artifact)
        self.record = {
            "artifactBytes": len(artifact),
            "artifactSHA256": INGEST.sha256(artifact),
            "artifactURL": "https://catalog.floorp.invalid/fwea1/example.fwea1",
            "availability": "available",
            "compatibilityProfiles": ["content-script", "action-storage"],
            "extensionID": "example.useful-extension",
            "generation": "g1",
            "manifestSHA256": INGEST.sha256(resources["manifest.json"]),
            "metadata": {
                "category": "productivity",
                "description": "A reviewed local extension.",
                "displayName": "Example",
                "hostPermissions": ["https://example.test/*"],
                "license": "MIT",
                "minimumFloorpBuild": "0.3.0",
                "modificationStatus": "compatibility-patched",
                "noticesSHA256": "b" * 64,
                "originalArtifactSHA256": "c" * 64,
                "permissions": ["storage"],
                "privateProfileCapability": "opt-in",
                "sourceURL": "https://github.com/example/extension",
                "upstream": "example/extension",
                "upstreamRevision": "0123456789abcdef0123456789abcdef01234567",
                "disclosure": {
                    "attribution": "Original project: example/extension.",
                    "privacySummary": "Review requested sites and permissions before installation.",
                    "publisherDisplayName": "Floorp iOS",
                    "reportRoute": "floorp-github-bug-report",
                    "retentionPolicy": "Settings remain in the selected profile until removal.",
                    "reviewEvidenceSHA256": "d" * 64,
                    "reviewedAt": "2026-08-27T00:00:00Z",
                    "sourceReviewSHA256": "e" * 64,
                    "supportRoute": "floorp-github-issues",
                },
            },
            "resourceInventorySHA256": INGEST.sha256(INGEST.canonical_json({"files": list(inventory)})),
            "version": "1.0.0",
        }
        (self.catalog_root / "catalog-input.json").write_bytes(INGEST.canonical_json([self.record]))
        self.xcconfig = self.root / "FloorpRelease.xcconfig"
        self.xcconfig.write_text("FLOORP_MARKETING_VERSION = 0.3.0\n", encoding="utf-8")
        self.root_key = Ed25519PrivateKey.generate()
        self.leaf_key = Ed25519PrivateKey.generate()
        self._sign()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _sign(self, *, expires_at: str = "2026-08-28T00:00:00Z") -> None:
        catalog, root_raw = SIGN.signed_catalog(
            records=[self.record],
            root_key=self.root_key,
            leaf_key=self.leaf_key,
            root_key_id="catalog-root",
            leaf_key_id="catalog-leaf",
            catalog_id="floorp-ios-curated-testflight",
            app_bundle_id="app.floorp.Floorp",
            minimum_app_version="0.3.0",
            channel="testflight",
            sequence=1,
            issued_at="2026-08-27T00:00:00Z",
            expires_at=expires_at,
            leaf_not_before="2026-08-26T00:00:00Z",
            leaf_not_after="2026-09-01T00:00:00Z",
        )
        (self.signed / "catalog.json").write_bytes(catalog)
        (self.signed / "root-public-key.txt").write_text(SIGN.base64url(root_raw) + "\n", encoding="ascii")
        self.root_digest = INGEST.sha256(root_raw)

    def verify(self, **overrides):
        arguments = {
            "catalog_root": self.catalog_root,
            "release_xcconfig": self.xcconfig,
            "expected_root_public_key_sha256": self.root_digest,
            "bundle_id": "app.floorp.Floorp",
            "channel": "testflight",
            "catalog_id": "floorp-ios-curated-testflight",
            "expected_package_count": 1,
            "artifact_origin": "https://catalog.floorp.invalid/fwea1/",
            "now": NOW,
        }
        arguments.update(overrides)
        return VERIFY.verify_release(**arguments)

    def test_accepts_a_current_signed_catalog_bound_to_every_artifact(self) -> None:
        proof = self.verify()
        self.assertEqual(proof["status"], "verified")
        self.assertEqual(proof["packageCount"], 1)
        self.assertEqual(proof["marketingVersion"], "0.3.0")

    def test_rejects_catalog_tampering_after_signature(self) -> None:
        catalog_path = self.signed / "catalog.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog["sequence"] = 2
        catalog_path.write_bytes(INGEST.canonical_json(catalog))
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "catalog signature is invalid"):
            self.verify()

    def test_rejects_a_root_not_bound_to_the_protected_release_anchor(self) -> None:
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "protected release trust anchor"):
            self.verify(expected_root_public_key_sha256="0" * 64)

    def test_rejects_an_artifact_digest_mismatch(self) -> None:
        self.artifact_path.write_bytes(self.artifact_path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "artifact byte count"):
            self.verify()

    def test_rejects_a_catalog_that_does_not_match_the_release_version(self) -> None:
        self.xcconfig.write_text("FLOORP_MARKETING_VERSION = 0.2.0\n", encoding="utf-8")
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "minimum app version"):
            self.verify()

    def test_rejects_an_expired_catalog(self) -> None:
        self._sign(expires_at="2026-08-27T11:59:59Z")
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "not currently valid"):
            self.verify()

    def test_rejects_a_future_dated_revocation_even_when_the_catalog_is_resigned(self) -> None:
        catalog_path = self.signed / "catalog.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        catalog["revocations"] = [{
            "kind": "generation",
            "extensionID": "example.useful-extension",
            "generation": "g0",
            "effectiveAt": "2026-08-27T12:00:01Z",
        }]
        unsigned = dict(catalog)
        unsigned.pop("signature")
        catalog["signature"] = SIGN.base64url(self.leaf_key.sign(INGEST.canonical_json(unsigned)))
        catalog_path.write_bytes(INGEST.canonical_json(catalog))
        with self.assertRaisesRegex(VERIFY.SignedCatalogReleaseError, "future-dated revocation"):
            self.verify()

    def test_cli_refuses_to_replace_existing_evidence(self) -> None:
        output = self.root / "proof.json"
        arguments = [
            "--catalog-root", str(self.catalog_root),
            "--release-xcconfig", str(self.xcconfig),
            "--expected-root-public-key-sha256", self.root_digest,
            "--expected-package-count", "1",
            "--now", "2026-08-27T12:00:00Z",
            "--output", str(output),
        ]
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(VERIFY.main(arguments), 0)
            self.assertEqual(VERIFY.main(arguments), 2)


if __name__ == "__main__":
    unittest.main()
