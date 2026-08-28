"""Regression coverage for review-only upstream source provenance checks."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
MODULE_PATH = SCRIPTS_DIRECTORY / "verify_curated_source_provenance.py"
SPEC = importlib.util.spec_from_file_location("floorp_verify_curated_source_provenance", MODULE_PATH)
assert SPEC and SPEC.loader
PROVENANCE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROVENANCE
SPEC.loader.exec_module(PROVENANCE)

CATALOG_ROOT = Path(__file__).parents[3] / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"


class CuratedCatalogSourceProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        sources = json.loads((CATALOG_ROOT / "catalog-sources.json").read_text(encoding="utf-8"))
        cls.sources = sources
        cls.source = next(source for source in sources if source["id"] == "thirdparty-very-good-adblock")
        cls.compatibility_source = next(source for source in sources if source["id"] == "thirdparty-utm-stripper")
        cls.provenance = json.loads(
            (CATALOG_ROOT / cls.source["sourceProvenance"]).read_text(encoding="utf-8")
        )
        cls.compatibility_provenance = json.loads(
            (CATALOG_ROOT / cls.compatibility_source["sourceProvenance"]).read_text(encoding="utf-8")
        )

    @staticmethod
    def _write_archive(archive: Path, root: str, entries: list[tuple[str, bytes]]) -> None:
        with tarfile.open(archive, "w") as value:
            for name, contents in entries:
                info = tarfile.TarInfo(f"{root}/{name}")
                info.size = len(contents)
                value.addfile(info, io.BytesIO(contents))

    def _archive_fixture(self, archive: Path, root: str) -> dict[str, object]:
        fixture = copy.deepcopy(self.provenance)
        fixture["archiveRoot"] = root
        fixture["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        return fixture

    def test_declared_provenance_is_bound_to_the_review_package(self) -> None:
        result = PROVENANCE.validate_declared_provenance(CATALOG_ROOT, self.source)
        self.assertEqual(result["path"], self.source["sourceProvenance"])
        self.assertRegex(result["sha256"], r"^[0-9a-f]{64}$")

    def test_every_compatibility_package_requires_a_review_only_provenance_record(self) -> None:
        compatibility_sources = [
            source for source in self.sources
            if source["modificationStatus"] == "compatibility-patched"
        ]
        self.assertEqual(len(compatibility_sources), 14)
        for source in compatibility_sources:
            self.assertIn("sourceProvenance", source)
            result = PROVENANCE.validate_declared_provenance(CATALOG_ROOT, source)
            self.assertEqual(result["path"], source["sourceProvenance"])

    def test_every_adopted_third_party_package_has_a_pinned_mit_notice_and_provenance_basis(self) -> None:
        compatibility_sources = [
            source for source in self.sources
            if source["modificationStatus"] == "compatibility-patched"
        ]
        self.assertEqual(len(compatibility_sources), 14)
        for source in compatibility_sources:
            self.assertEqual(source["license"], "MIT")
            package = CATALOG_ROOT / source["package"]
            license_text = (package / "LICENSE").read_text(encoding="utf-8")
            notice_text = (package / "NOTICE").read_text(encoding="utf-8")
            self.assertIn("MIT", license_text.upper())
            self.assertIn(source["upstreamRevision"], notice_text)
            self.assertIn(source["originalArtifactSHA256"], notice_text)
            self.assertIsNotNone(PROVENANCE.validate_declared_provenance(CATALOG_ROOT, source))

    def test_compatibility_archive_verifier_binds_reviewed_members_and_local_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar"
            fixture = copy.deepcopy(self.compatibility_provenance)
            root = "fixture-root"
            members = [(fixture["licenseMember"], b"license")]
            for index, member in enumerate(fixture["reviewedSourceMembers"]):
                payload = f"reviewed-member-{index}".encode("ascii")
                members.append((member["path"], payload))
                member["sha256"] = hashlib.sha256(payload).hexdigest()
            self._write_archive(archive, root, members)
            fixture["archiveRoot"] = root
            fixture["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
            fixture["licenseMemberSHA256"] = hashlib.sha256(b"license").hexdigest()
            source = copy.deepcopy(self.compatibility_source)
            source["originalArtifactSHA256"] = fixture["archiveSHA256"]
            original_loader = PROVENANCE._load_provenance
            try:
                PROVENANCE._load_provenance = lambda _root, _source: (
                    fixture,
                    CATALOG_ROOT / self.compatibility_source["sourceProvenance"],
                )
                result = PROVENANCE.verify_archive(CATALOG_ROOT, source, archive)
            finally:
                PROVENANCE._load_provenance = original_loader
        self.assertEqual(result["status"], "accepted")
        self.assertEqual(
            result["reviewedMemberCount"],
            len(self.compatibility_provenance["reviewedSourceMembers"]),
        )

    def test_compatibility_archive_verifier_rejects_member_digest_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar"
            fixture = copy.deepcopy(self.compatibility_provenance)
            root = "fixture-root"
            members = [(fixture["licenseMember"], b"license")]
            for index, member in enumerate(fixture["reviewedSourceMembers"]):
                payload = f"reviewed-member-{index}".encode("ascii")
                members.append((member["path"], payload))
                member["sha256"] = hashlib.sha256(payload).hexdigest()
            fixture["reviewedSourceMembers"][0]["sha256"] = "0" * 64
            self._write_archive(archive, root, members)
            fixture["archiveRoot"] = root
            fixture["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
            fixture["licenseMemberSHA256"] = hashlib.sha256(b"license").hexdigest()
            source = copy.deepcopy(self.compatibility_source)
            source["originalArtifactSHA256"] = fixture["archiveSHA256"]
            original_loader = PROVENANCE._load_provenance
            try:
                PROVENANCE._load_provenance = lambda _root, _source: (
                    fixture,
                    CATALOG_ROOT / self.compatibility_source["sourceProvenance"],
                )
                with self.assertRaisesRegex(PROVENANCE.SourceProvenanceError, "member digest"):
                    PROVENANCE.verify_archive(CATALOG_ROOT, source, archive)
            finally:
                PROVENANCE._load_provenance = original_loader

    def test_archive_verifier_accepts_only_the_mapped_block_rule_subset(self) -> None:
        upstream_source = "\n".join(
            f"{{ id: {mapping['upstreamRuleID']}, name: 'fixture', category: 'script', "
            f"urlFilter: '{json.loads((CATALOG_ROOT / self.provenance['packageRules']).read_text())[mapping['artifactRuleID'] - 1]['condition']['urlFilter']}', "
            "resourceTypes: blockedHostTypes }"
            for mapping in self.provenance["artifactRuleMappings"]
        ).encode("utf-8")
        license_bytes = (CATALOG_ROOT / self.provenance["packageLicense"]).read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar"
            root = "fixture-root"
            self._write_archive(
                archive,
                root,
                [("LICENSE", license_bytes), ("src/rules/static-rules.ts", upstream_source)],
            )
            fixture = self._archive_fixture(archive, root)
            fixture["licenseMemberSHA256"] = hashlib.sha256(license_bytes).hexdigest()
            fixture["sourceMemberSHA256"] = hashlib.sha256(upstream_source).hexdigest()
            source = copy.deepcopy(self.source)
            source["originalArtifactSHA256"] = fixture["archiveSHA256"]
            source["sourceProvenance"] = self.source["sourceProvenance"]
            original_loader = PROVENANCE._load_provenance
            original_patch_check = PROVENANCE._assert_patch_and_license
            try:
                PROVENANCE._load_provenance = lambda _root, _source: (fixture, CATALOG_ROOT / self.source["sourceProvenance"])
                PROVENANCE._assert_patch_and_license = lambda _root, _provenance: None
                result = PROVENANCE.verify_archive(CATALOG_ROOT, source, archive)
            finally:
                PROVENANCE._load_provenance = original_loader
                PROVENANCE._assert_patch_and_license = original_patch_check
        self.assertEqual(result["status"], "accepted")
        self.assertEqual(result["ruleCount"], 16)

    def test_archive_reader_rejects_unbounded_or_ambiguous_member_streams(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            root = "fixture-root"

            member_limited = temporary / "member-limited.tar"
            self._write_archive(
                member_limited,
                root,
                [("one", b"a"), ("two", b"b"), ("LICENSE", b"license")],
            )
            fixture = self._archive_fixture(member_limited, root)
            with mock.patch.object(PROVENANCE, "MAX_ARCHIVE_MEMBERS", 2):
                with self.assertRaisesRegex(PROVENANCE.SourceProvenanceError, "member limit"):
                    PROVENANCE._read_archive_members(member_limited, fixture, ["LICENSE"])

            expanded_limited = temporary / "expanded-limited.tar"
            self._write_archive(expanded_limited, root, [("padding", b"12345"), ("LICENSE", b"license")])
            fixture = self._archive_fixture(expanded_limited, root)
            with mock.patch.object(PROVENANCE, "MAX_ARCHIVE_EXPANDED_BYTES", 4):
                with self.assertRaisesRegex(PROVENANCE.SourceProvenanceError, "expanded size limit"):
                    PROVENANCE._read_archive_members(expanded_limited, fixture, ["LICENSE"])

            duplicate_member = temporary / "duplicate-member.tar"
            self._write_archive(duplicate_member, root, [("LICENSE", b"one"), ("LICENSE", b"two")])
            fixture = self._archive_fixture(duplicate_member, root)
            with self.assertRaisesRegex(PROVENANCE.SourceProvenanceError, "appears more than once"):
                PROVENANCE._read_archive_members(duplicate_member, fixture, ["LICENSE"])


if __name__ == "__main__":
    unittest.main()
