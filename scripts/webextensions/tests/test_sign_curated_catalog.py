"""Tests for the no-bypass curated catalog signing handoff."""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
MODULE_PATH = SCRIPTS_DIRECTORY / "sign_curated_catalog.py"
SPEC = importlib.util.spec_from_file_location("floorp_sign_curated_catalog", MODULE_PATH)
assert SPEC and SPEC.loader
SIGN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SIGN
SPEC.loader.exec_module(SIGN)


class SignCuratedCatalogTests(unittest.TestCase):
    def test_source_archives_require_unique_source_id_and_absolute_existing_path(self) -> None:
        with self.assertRaises(SIGN.CuratedCatalogSigningError):
            SIGN._parse_source_archives(["thirdparty-darkreader=relative.tar.gz"])
        with self.assertRaises(SIGN.CuratedCatalogSigningError):
            SIGN._parse_source_archives(["not valid=/tmp/archive.tar.gz"])

    def test_catalog_root_must_belong_to_the_signing_checkout(self) -> None:
        catalog_root = Path(__file__).parents[3] / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
        repository_root = catalog_root.parents[3]
        SIGN._require_catalog_checkout(repository_root, catalog_root)

        with self.assertRaises(SIGN.CuratedCatalogSigningError):
            SIGN._require_catalog_checkout(repository_root, repository_root / "unrelated-catalog")

    def test_signer_requires_one_quarantined_archive_for_each_compatibility_source(self) -> None:
        catalog_root = Path(__file__).parents[3] / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
        sources = SIGN._load_sources(catalog_root)
        expected = {
            source["id"] for source in sources
            if source["modificationStatus"] == "compatibility-patched"
        }
        self.assertEqual(expected, {"thirdparty-darkreader"})
        with self.assertRaisesRegex(SIGN.CuratedCatalogSigningError, "exactly match"):
            SIGN.verify_release_inputs(
                catalog_root=catalog_root,
                records_path=catalog_root / "catalog-input.json",
                source_archives={},
            )

    def test_output_contract_rejects_shipped_or_overlapping_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            repository_root = temporary_root / "source-checkout"
            catalog_root = repository_root / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
            signed_directory = catalog_root / "Artifacts/Signed"
            signed_directory.mkdir(parents=True)
            catalog_output = signed_directory / "catalog.json"
            root_output = signed_directory / "root-public-key.txt"
            evidence = temporary_root / "provenance-evidence.json"
            SIGN._require_output_contract(
                repository_root=repository_root,
                catalog_root=catalog_root,
                catalog_output=catalog_output,
                root_public_key_output=root_output,
                evidence_path=evidence,
                supersede_signed_catalog=False,
                expected_existing_catalog_sha256=None,
                expected_existing_root_public_key_file_sha256=None,
                sequence=1,
            )

            with self.assertRaises(SIGN.CuratedCatalogSigningError):
                SIGN._require_output_contract(
                    repository_root=repository_root,
                    catalog_root=catalog_root,
                    catalog_output=Path(temporary_directory) / "wrong-catalog.json",
                    root_public_key_output=root_output,
                    evidence_path=evidence,
                    supersede_signed_catalog=False,
                    expected_existing_catalog_sha256=None,
                    expected_existing_root_public_key_file_sha256=None,
                    sequence=1,
                )

            catalog_output.touch()
            with self.assertRaises(SIGN.CuratedCatalogSigningError):
                SIGN._require_output_contract(
                    repository_root=repository_root,
                    catalog_root=catalog_root,
                    catalog_output=catalog_output,
                    root_public_key_output=root_output,
                    evidence_path=evidence,
                    supersede_signed_catalog=False,
                    expected_existing_catalog_sha256=None,
                    expected_existing_root_public_key_file_sha256=None,
                    sequence=1,
                )

            catalog_output.unlink()
            evidence.write_text("existing evidence", encoding="utf-8")
            with self.assertRaises(SIGN.CuratedCatalogSigningError):
                SIGN._require_output_contract(
                    repository_root=repository_root,
                    catalog_root=catalog_root,
                    catalog_output=catalog_output,
                    root_public_key_output=root_output,
                    evidence_path=evidence,
                    supersede_signed_catalog=False,
                    expected_existing_catalog_sha256=None,
                    expected_existing_root_public_key_file_sha256=None,
                    sequence=1,
                )

    def test_catalog_rotation_requires_exact_current_outputs_and_a_higher_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            repository_root = temporary_root / "source-checkout"
            catalog_root = repository_root / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
            signed_directory = catalog_root / "Artifacts/Signed"
            signed_directory.mkdir(parents=True)
            catalog_output = signed_directory / "catalog.json"
            root_output = signed_directory / "root-public-key.txt"
            catalog_output.write_bytes(SIGN.canonical_json({"sequence": 1}))
            root_output.write_bytes(b"pinned-root\n")
            evidence = temporary_root / "provenance-evidence.json"
            expected_catalog = SIGN.sha256(catalog_output.read_bytes())
            expected_root = SIGN.sha256(root_output.read_bytes())

            SIGN._require_output_contract(
                repository_root=repository_root,
                catalog_root=catalog_root,
                catalog_output=catalog_output,
                root_public_key_output=root_output,
                evidence_path=evidence,
                supersede_signed_catalog=True,
                expected_existing_catalog_sha256=expected_catalog,
                expected_existing_root_public_key_file_sha256=expected_root,
                sequence=2,
            )

            with self.assertRaisesRegex(SIGN.CuratedCatalogSigningError, "does not match"):
                SIGN._require_output_contract(
                    repository_root=repository_root,
                    catalog_root=catalog_root,
                    catalog_output=catalog_output,
                    root_public_key_output=root_output,
                    evidence_path=evidence,
                    supersede_signed_catalog=True,
                    expected_existing_catalog_sha256="a" * 64,
                    expected_existing_root_public_key_file_sha256=expected_root,
                    sequence=2,
                )
            with self.assertRaisesRegex(SIGN.CuratedCatalogSigningError, "greater"):
                SIGN._require_output_contract(
                    repository_root=repository_root,
                    catalog_root=catalog_root,
                    catalog_output=catalog_output,
                    root_public_key_output=root_output,
                    evidence_path=evidence,
                    supersede_signed_catalog=True,
                    expected_existing_catalog_sha256=expected_catalog,
                    expected_existing_root_public_key_file_sha256=expected_root,
                    sequence=1,
                )

    def test_atomic_write_never_replaces_an_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "evidence.json"
            SIGN._atomic_write(output, b"first")
            with self.assertRaises(SIGN.CuratedCatalogSigningError):
                SIGN._atomic_write(output, b"second")
            self.assertEqual(output.read_bytes(), b"first")

    def test_atomic_replace_requires_the_explicit_existing_catalog_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "catalog.json"
            output.write_bytes(b"first")
            SIGN._atomic_replace_expected(output, b"second", SIGN.sha256(b"first"))
            self.assertEqual(output.read_bytes(), b"second")
            with self.assertRaisesRegex(SIGN.CuratedCatalogSigningError, "changed"):
                SIGN._atomic_replace_expected(output, b"third", SIGN.sha256(b"first"))

    def test_main_rotation_replaces_only_the_catalog_after_rechecking_the_root(self) -> None:
        catalog_root = Path(__file__).parents[3] / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
        repository_root = catalog_root.parents[3]
        records_path = catalog_root / "catalog-input.json"
        records_bytes = records_path.read_bytes()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            catalog_output = temporary_root / "catalog.json"
            root_output = temporary_root / "root-public-key.txt"
            evidence = temporary_root / "provenance-evidence.json"
            catalog_output.write_bytes(b"old-catalog")
            root_output.write_bytes(b"cm9vdA\n")
            arguments = [
                "--records", str(records_path),
                "--output", str(catalog_output),
                "--root-public-key-output", str(root_output),
                "--root-private-key", str(temporary_root / "root.pem"),
                "--leaf-private-key", str(temporary_root / "leaf.pem"),
                "--root-key-id", "test-root",
                "--leaf-key-id", "test-leaf",
                "--catalog-id", "test-catalog",
                "--app-bundle-id", "org.floorp.ios",
                "--minimum-app-version", "0.3.0",
                "--channel", "testflight",
                "--sequence", "2",
                "--issued-at", "2026-08-27T00:00:00Z",
                "--expires-at", "2026-08-28T00:00:00Z",
                "--leaf-not-before", "2026-08-26T00:00:00Z",
                "--leaf-not-after", "2026-09-01T00:00:00Z",
                "--catalog-root", str(catalog_root),
                "--repository-root", str(repository_root),
                "--source-commit", "a" * 40,
                "--provenance-evidence-output", str(evidence),
                "--supersede-signed-catalog",
                "--expected-existing-catalog-sha256", SIGN.sha256(catalog_output.read_bytes()),
                "--expected-existing-root-public-key-file-sha256", SIGN.sha256(root_output.read_bytes()),
            ]
            with (
                mock.patch.object(SIGN, "_require_catalog_checkout"),
                mock.patch.object(SIGN, "_require_clean_source_commit"),
                mock.patch.object(SIGN, "verify_release_inputs", return_value=(records_bytes, [])),
                mock.patch.object(SIGN, "_require_output_contract"),
                mock.patch.object(SIGN, "load_records_bytes", wraps=SIGN.load_records_bytes),
                mock.patch.object(SIGN, "load_catalog_signer", side_effect=[object(), object()]),
                mock.patch.object(SIGN, "signed_catalog", return_value=(b"new-catalog", b"root")),
                mock.patch.object(SIGN, "_atomic_replace_expected") as replace_catalog,
                mock.patch.object(SIGN, "_atomic_write") as write_new,
            ):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(SIGN.main(arguments), 0)

            replace_catalog.assert_called_once_with(
                catalog_output,
                b"new-catalog",
                SIGN.sha256(b"old-catalog"),
            )
            write_new.assert_called_once()
            self.assertEqual(write_new.call_args.args[0], evidence)

    def test_main_signs_the_verified_snapshot_only_after_a_final_clean_recheck(self) -> None:
        catalog_root = Path(__file__).parents[3] / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
        repository_root = catalog_root.parents[3]
        records_path = catalog_root / "catalog-input.json"
        records_bytes = records_path.read_bytes()
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            archive = temporary_root / "source.tar.gz"
            archive.write_bytes(b"review-quarantined fixture")
            evidence = temporary_root / "provenance-evidence.json"
            arguments = [
                "--records", str(records_path),
                "--output", str(catalog_root / "Artifacts/Signed/catalog.json"),
                "--root-public-key-output", str(catalog_root / "Artifacts/Signed/root-public-key.txt"),
                "--root-private-key", str(temporary_root / "root.pem"),
                "--leaf-private-key", str(temporary_root / "leaf.pem"),
                "--root-key-id", "test-root",
                "--leaf-key-id", "test-leaf",
                "--catalog-id", "test-catalog",
                "--app-bundle-id", "org.floorp.ios",
                "--minimum-app-version", "0.3.0",
                "--channel", "testflight",
                "--sequence", "1",
                "--issued-at", "2026-08-27T00:00:00Z",
                "--expires-at", "2026-08-28T00:00:00Z",
                "--leaf-not-before", "2026-08-26T00:00:00Z",
                "--leaf-not-after", "2026-09-01T00:00:00Z",
                "--catalog-root", str(catalog_root),
                "--repository-root", str(repository_root),
                "--source-commit", "a" * 40,
                "--source-archive", f"thirdparty-darkreader={archive}",
                "--provenance-evidence-output", str(evidence),
            ]
            with (
                mock.patch.object(SIGN, "_require_catalog_checkout") as checkout,
                mock.patch.object(SIGN, "_require_clean_source_commit") as clean,
                mock.patch.object(SIGN, "verify_release_inputs", return_value=(records_bytes, [])),
                mock.patch.object(SIGN, "_require_output_contract") as output_contract,
                mock.patch.object(SIGN, "load_records_bytes", wraps=SIGN.load_records_bytes) as load_snapshot,
                mock.patch.object(SIGN, "load_catalog_signer", side_effect=[object(), object()]),
                mock.patch.object(SIGN, "signed_catalog", return_value=(b"{}", b"root")),
                mock.patch.object(SIGN, "_atomic_write"),
            ):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(SIGN.main(arguments), 0)

            self.assertEqual(checkout.call_count, 3)
            self.assertEqual(clean.call_count, 3)
            self.assertEqual(output_contract.call_count, 2)
            self.assertEqual(load_snapshot.call_args.args[0], records_bytes)


if __name__ == "__main__":
    unittest.main()
