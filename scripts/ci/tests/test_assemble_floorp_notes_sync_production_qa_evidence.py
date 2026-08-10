from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from scripts.ci.tests import test_validate_floorp_notes_sync_release as fixtures


ROOT = Path(__file__).resolve().parents[3]
ASSEMBLER_PATH = ROOT / "scripts/ci/assemble-floorp-notes-sync-production-qa-evidence.py"
SCHEMA = ROOT / "docs/floorp-notes-sync-release-evidence.schema.json"
BASE_OID = "330870f9d6db91433afe1024ac8200f81d260a42"
REVIEWED_HEAD_OID = "af21d1a4f95eda87dabfaf3a0dfa0fbb89b7ccfb"
G4_ATTESTATION_PATH = "docs/floorp-notes-sync-g4-attestation.json"
G4_ATTESTATION_TEST = (
    "ClientTests/FloorpNotesSyncEngineSelectionTests/"
    "testG4AttestationBindsTask18Evidence()"
)
G4_ATTESTATION_XCRESULT_MARKER = (
    b"FloorpNotesSyncEngineSelectionTests/"
    b"testG4AttestationBindsTask18Evidence()"
)
G4_SOURCE_ROLES = (
    "task-manifest",
    "desktop-ci-run",
    "runtime-ci-run",
    "g4-attestation-source",
    "g4-attestation-ci-run",
    "g4-attestation-xcresult",
    "xpcshell-run",
    "tps-run",
)


def load_assembler():
    spec = importlib.util.spec_from_file_location("floorp_production_qa_assembler", ASSEMBLER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load production-QA evidence assembler")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ASSEMBLER = load_assembler()


class FloorpNotesSyncProductionQaEvidenceAssemblerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_owner = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_owner.name)
        self.output = self.directory / "g1-g4-production-qa.json"
        self.recipe_path = self.directory / "production-qa-recipe.json"
        self.evidence_fixture = fixtures.make_production_qa_evidence()
        self.evidence_fixture["release_inputs"]["ios"]["build_number"] = "4"
        local_materials, remote_materials = fixtures.test_materials(self.evidence_fixture)
        if tuple(
            source["role"]
            for source in self.evidence_fixture["gates"]["g4"]["artifact"]["sources"]
        ) != G4_SOURCE_ROLES:
            self.add_g4_attestation_sources(remote_materials)
        self.bind_xcresult_to_attestation_test(remote_materials)
        attestation_source = next(
            source
            for source in self.evidence_fixture["gates"]["g4"]["artifact"]["sources"]
            if source["role"] == "g4-attestation-source"
        )
        self.g4_attestation = json.loads(
            remote_materials[fixtures.source_identity_key(attestation_source)]
        )
        self.remote_materials = remote_materials
        self.recipe = {
            "build_contract_mode": "production-qa",
            "g3_integration_commands": [
                {
                    "argv": ["verify", "task-19-integration"],
                    "exit_code": 0,
                    "terminal": True,
                }
            ],
            "gates": {},
            "release_inputs": copy.deepcopy(self.evidence_fixture["release_inputs"]),
            "schema_version": 1,
        }
        for gate_name in fixtures.G1_G4_NAMES:
            fixture_gate = self.evidence_fixture["gates"][gate_name]
            gate_recipe = {
                "issued_at": fixture_gate["issued_at"],
                "sources": [],
            }
            if gate_name != "g1":
                gate_recipe["expires_at"] = fixture_gate["expires_at"]
            for source in fixture_gate["artifact"]["sources"]:
                descriptor = copy.deepcopy(source)
                if source["role"] == "integration-receipt":
                    relative = source["path"]
                elif source["kind"] == "local-file":
                    relative = source["path"]
                    self.write_material(relative, local_materials[relative])
                else:
                    suffix = ".json" if source["content_policy"].endswith("json") else ".bin"
                    relative = f"captures/{gate_name}-{source['role']}{suffix}"
                    raw = remote_materials[fixtures.source_identity_key(source)]
                    self.write_material(relative, raw)
                gate_recipe["sources"].append(
                    {"bytes_path": relative, "descriptor": descriptor}
                )
            self.recipe["gates"][gate_name] = gate_recipe

    def add_g4_attestation_sources(self, remote_materials: dict[str, bytes]) -> None:
        inputs = self.evidence_fixture["release_inputs"]
        g3_sources = self.evidence_fixture["gates"]["g3"]["artifact"]["sources"]
        g4_gate = self.evidence_fixture["gates"]["g4"]
        g4_sources = g4_gate["artifact"]["sources"]
        task_manifest, desktop_run, runtime_run, xpcshell, tps = g4_sources
        attestation = {
            "desktop": {
                "merged_sha": inputs["desktop"]["source_sha"],
                "run_head_sha": desktop_run["head_sha"],
                "run_id": desktop_run["run_id"],
                "workflow_path": desktop_run["workflow_path"],
            },
            "floorpci_test": G4_ATTESTATION_TEST,
            "runtime": {
                "merged_sha": inputs["runtime"]["source_sha"],
                "run_head_sha": runtime_run["head_sha"],
                "run_id": runtime_run["run_id"],
                "tree_sha": inputs["runtime"]["tree_sha"],
                "workflow_path": runtime_run["workflow_path"],
            },
            "schema_version": 1,
            "summaries": {
                "task_manifest_sha256": task_manifest["sha256"],
                "tps_sha256": tps["sha256"],
                "xpcshell_sha256": xpcshell["sha256"],
            },
            "task_id": 18,
        }
        attestation_raw = fixtures.canonical_bytes(attestation)
        attestation_source = fixtures.repository_source(
            "g4-attestation-source",
            inputs["ios"]["repository"],
            inputs["ios"]["source_sha"],
            G4_ATTESTATION_PATH,
            "metadata-json",
            attestation_raw,
        )
        attestation_ci = copy.deepcopy(g3_sources[1])
        attestation_ci["role"] = "g4-attestation-ci-run"
        attestation_xcresult = copy.deepcopy(g3_sources[2])
        attestation_xcresult["role"] = "g4-attestation-xcresult"
        g4_gate["artifact"]["sources"] = [
            task_manifest,
            desktop_run,
            runtime_run,
            attestation_source,
            attestation_ci,
            attestation_xcresult,
            xpcshell,
            tps,
        ]
        g4_gate["issued_at"] = "2026-08-09T23:00:00Z"
        g4_gate["expires_at"] = "2026-08-16T23:31:00Z"
        remote_materials[fixtures.source_identity_key(attestation_source)] = attestation_raw
        remote_materials[fixtures.source_identity_key(attestation_ci)] = remote_materials[
            fixtures.source_identity_key(g3_sources[1])
        ]
        remote_materials[fixtures.source_identity_key(attestation_xcresult)] = remote_materials[
            fixtures.source_identity_key(g3_sources[2])
        ]

    def bind_xcresult_to_attestation_test(self, remote_materials: dict[str, bytes]) -> None:
        marker_archive = fixtures.synthetic_xcresult_zip(G4_ATTESTATION_XCRESULT_MARKER)
        for gate_name, role in (
            ("g3", "xcresult"),
            ("g4", "g4-attestation-xcresult"),
        ):
            source = next(
                item
                for item in self.evidence_fixture["gates"][gate_name]["artifact"]["sources"]
                if item["role"] == role
            )
            source["sha256"] = hashlib.sha256(marker_archive).hexdigest()
            remote_materials[fixtures.source_identity_key(source)] = marker_archive

    def tearDown(self) -> None:
        self.temporary_owner.cleanup()

    def write_material(self, relative: str, raw: bytes) -> Path:
        path = self.directory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def write_recipe(self, recipe: dict[str, object] | None = None, *, canonical: bool = True) -> None:
        selected = self.recipe if recipe is None else recipe
        if canonical:
            self.recipe_path.write_bytes(fixtures.canonical_bytes(selected))
        else:
            self.recipe_path.write_text(json.dumps(selected, indent=2), encoding="utf-8")

    def source_entry(self, recipe: dict[str, object], gate: str, role: str) -> dict[str, object]:
        return next(
            entry
            for entry in recipe["gates"][gate]["sources"]
            if entry["descriptor"]["role"] == role
        )

    def replace_captured_bytes(
        self,
        recipe: dict[str, object],
        gate: str,
        role: str,
        raw: bytes,
        filename: str,
    ) -> dict[str, object]:
        entry = self.source_entry(recipe, gate, role)
        entry["bytes_path"] = f"captures/{filename}"
        descriptor = entry["descriptor"]
        descriptor["sha256"] = hashlib.sha256(raw).hexdigest()
        if descriptor["kind"] == "github-repository-file":
            descriptor["blob_sha"] = fixtures.git_blob_sha(raw)
        self.write_material(entry["bytes_path"], raw)
        return entry

    def run_assembler(
        self,
        *,
        base_oid: str = BASE_OID,
        reviewed_head_oid: str = REVIEWED_HEAD_OID,
        merged_oid: str | None = None,
    ) -> tuple[int, str, str]:
        if merged_oid is None:
            merged_oid = self.recipe["release_inputs"]["ios"]["source_sha"]
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            return_code = ASSEMBLER.main(
                [
                    "--recipe",
                    str(self.recipe_path),
                    "--g3-base-oid",
                    base_oid,
                    "--g3-reviewed-head-oid",
                    reviewed_head_oid,
                    "--g3-merged-oid",
                    merged_oid,
                    "--output",
                    str(self.output),
                ]
            )
        return return_code, stdout.getvalue(), stderr.getvalue()

    def assert_recipe_rejected(
        self,
        recipe: dict[str, object],
        *,
        contains: str,
    ) -> None:
        self.write_recipe(recipe)
        return_code, _, stderr = self.run_assembler()
        self.assertNotEqual(return_code, 0, stderr)
        self.assertIn(contains, stderr)
        self.assertFalse(self.output.exists())

    def validate_with_existing_validator(self, evidence: dict[str, object]) -> None:
        clock_path = self.directory / "validation-clock.json"
        clock_path.write_bytes(fixtures.canonical_bytes(fixtures.make_clock()))
        mock_gh = self.directory / "mock-gh"
        mock_gh.write_text(fixtures.MOCK_GH, encoding="utf-8")
        mock_gh.chmod(mock_gh.stat().st_mode | stat.S_IXUSR)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            return_code = fixtures.VALIDATOR_MODULE.main(
                [
                    "--schema",
                    str(SCHEMA),
                    "--evidence",
                    str(self.output),
                    "--validation-clock-manifest",
                    str(clock_path),
                    "--canonicalization",
                    "rfc8785-jcs",
                ],
                test_gh_bin=mock_gh,
                test_gh_environment={"MOCK_GH_SCENARIO": "success"},
                test_remote_artifacts=self.remote_materials,
            )
        self.assertEqual(return_code, 0, stderr.getvalue())
        self.assertIn("APPROVE", stdout.getvalue())

    def test_assembles_canonical_evidence_and_exact_integration_receipt(self):
        self.write_recipe()

        return_code, stdout, stderr = self.run_assembler()

        self.assertEqual(return_code, 0, stderr)
        self.assertIn("APPROVE", stdout)
        raw = self.output.read_bytes()
        evidence = json.loads(raw)
        self.assertEqual(raw, fixtures.canonical_bytes(evidence))
        self.assertFalse(raw.endswith(b"\n"))
        receipt_path = self.directory / "artifacts/task-19-integration-receipt.json"
        receipt_raw = receipt_path.read_bytes()
        receipt = json.loads(receipt_raw)
        self.assertEqual(receipt_raw, fixtures.canonical_bytes(receipt))
        self.assertEqual(
            receipt,
            {
                "commands": self.recipe["g3_integration_commands"],
                "repositories": [
                    {
                        "base_oid": BASE_OID,
                        "head_oid": REVIEWED_HEAD_OID,
                        "merged_oid": self.recipe["release_inputs"]["ios"]["source_sha"],
                        "name": "floorp-ios",
                    }
                ],
                "schema_version": 1,
                "state": "integration_complete",
                "task_id": 19,
            },
        )
        for gate_name in fixtures.G1_G4_NAMES:
            artifact = evidence["gates"][gate_name]["artifact"]
            self.assertEqual(artifact["sha256"], fixtures.digest({"sources": artifact["sources"]}))
        selected_gates = {name: evidence["gates"][name] for name in fixtures.G1_G4_NAMES}
        self.assertEqual(
            evidence["g1_g4_digest_sha256"],
            fixtures.digest({"gates": selected_gates, "release_inputs": evidence["release_inputs"]}),
        )
        self.assertEqual(
            evidence["same_release_key_sha256"],
            fixtures.digest(
                {
                    "gate_artifact_digests": {
                        name: evidence["gates"][name]["artifact"]["sha256"]
                        for name in fixtures.G1_G4_NAMES
                    },
                    "release_inputs": evidence["release_inputs"],
                }
            ),
        )
        g3_sources = evidence["gates"]["g3"]["artifact"]["sources"]
        g4_sources = evidence["gates"]["g4"]["artifact"]["sources"]
        self.assertEqual(tuple(source["role"] for source in g4_sources), G4_SOURCE_ROLES)
        g3_ci = next(source for source in g3_sources if source["role"] == "ci-run")
        g3_xcresult = next(source for source in g3_sources if source["role"] == "xcresult")
        g4_ci = next(
            source for source in g4_sources if source["role"] == "g4-attestation-ci-run"
        )
        g4_xcresult = next(
            source for source in g4_sources if source["role"] == "g4-attestation-xcresult"
        )
        self.assertEqual(
            {**g4_ci, "role": "ci-run"},
            g3_ci,
        )
        self.assertEqual(
            {**g4_xcresult, "role": "xcresult"},
            g3_xcresult,
        )
        self.validate_with_existing_validator(evidence)

    def test_rejects_malformed_or_unbound_g4_external_attestation(self):
        summary_mismatch = copy.deepcopy(self.recipe)
        payload = copy.deepcopy(self.g4_attestation)
        payload["summaries"]["xpcshell_sha256"] = "0" * 64
        self.replace_captured_bytes(
            summary_mismatch,
            "g4",
            "g4-attestation-source",
            fixtures.canonical_bytes(payload),
            "g4-attestation-summary-mismatch.json",
        )
        self.assert_recipe_rejected(summary_mismatch, contains="attestation")

        noncanonical = copy.deepcopy(self.recipe)
        noncanonical_raw = json.dumps(self.g4_attestation, indent=2).encode("utf-8")
        self.replace_captured_bytes(
            noncanonical,
            "g4",
            "g4-attestation-source",
            noncanonical_raw,
            "g4-attestation-noncanonical.json",
        )
        self.assert_recipe_rejected(noncanonical, contains="canonical")

        wrong_source = copy.deepcopy(self.recipe)
        self.source_entry(wrong_source, "g4", "g4-attestation-source")["descriptor"][
            "path"
        ] = "docs/not-the-g4-attestation.json"
        self.assert_recipe_rejected(wrong_source, contains="attestation source")

    def test_rejects_g4_attestation_descriptors_not_identical_to_g3(self):
        run_mismatch = copy.deepcopy(self.recipe)
        run_entry = self.source_entry(run_mismatch, "g4", "g4-attestation-ci-run")
        run_payload = json.loads((self.directory / run_entry["bytes_path"]).read_bytes())
        run_payload["id"] += 1
        run_entry["descriptor"]["run_id"] += 1
        self.source_entry(run_mismatch, "g4", "g4-attestation-xcresult")["descriptor"][
            "run_id"
        ] += 1
        self.replace_captured_bytes(
            run_mismatch,
            "g4",
            "g4-attestation-ci-run",
            fixtures.canonical_bytes(run_payload),
            "g4-attestation-ci-mismatch.json",
        )
        self.assert_recipe_rejected(run_mismatch, contains="role-only")

        xcresult_mismatch = copy.deepcopy(self.recipe)
        self.source_entry(xcresult_mismatch, "g4", "g4-attestation-xcresult")[
            "descriptor"
        ]["artifact_id"] += 1
        self.assert_recipe_rejected(xcresult_mismatch, contains="role-only")

    def test_rejects_g4_attestation_xcresult_without_selected_floorpci_test(self):
        recipe = copy.deepcopy(self.recipe)
        unbound_archive = fixtures.synthetic_xcresult_zip(b"different selected test")
        shared_path = "captures/g4-attestation-unbound-xcresult.bin"
        for gate_name, role in (
            ("g3", "xcresult"),
            ("g4", "g4-attestation-xcresult"),
        ):
            entry = self.replace_captured_bytes(
                recipe,
                gate_name,
                role,
                unbound_archive,
                "g4-attestation-unbound-xcresult.bin",
            )
            entry["bytes_path"] = shared_path
        self.assert_recipe_rejected(recipe, contains="required test marker")

    def test_rejects_noncanonical_recipe_and_non_production_mode(self):
        self.write_recipe(canonical=False)
        return_code, _, stderr = self.run_assembler()
        self.assertNotEqual(return_code, 0)
        self.assertIn("canonical", stderr)
        self.assertFalse(self.output.exists())

        recipe = copy.deepcopy(self.recipe)
        recipe["build_contract_mode"] = "release-enabled"
        self.assert_recipe_rejected(recipe, contains="production-qa")

    def test_rejects_missing_reordered_and_extra_source_roles(self):
        cases: list[tuple[str, dict[str, object]]] = []
        missing = copy.deepcopy(self.recipe)
        missing["gates"]["g4"]["sources"].pop()
        cases.append(("missing", missing))
        missing_attestation = copy.deepcopy(self.recipe)
        missing_attestation["gates"]["g4"]["sources"] = [
            entry
            for entry in missing_attestation["gates"]["g4"]["sources"]
            if entry["descriptor"]["role"] != "g4-attestation-source"
        ]
        cases.append(("missing-attestation", missing_attestation))
        reordered = copy.deepcopy(self.recipe)
        reordered["gates"]["g2"]["sources"][0:2] = reversed(
            reordered["gates"]["g2"]["sources"][0:2]
        )
        cases.append(("reordered", reordered))
        reordered_attestation = copy.deepcopy(self.recipe)
        reordered_attestation["gates"]["g4"]["sources"][3:5] = reversed(
            reordered_attestation["gates"]["g4"]["sources"][3:5]
        )
        cases.append(("reordered-attestation", reordered_attestation))
        extra = copy.deepcopy(self.recipe)
        extra_entry = copy.deepcopy(extra["gates"]["g1"]["sources"][-1])
        extra_entry["descriptor"]["role"] = "unexpected-source"
        extra["gates"]["g1"]["sources"].append(extra_entry)
        cases.append(("extra", extra))
        for name, recipe in cases:
            with self.subTest(name=name):
                self.assert_recipe_rejected(recipe, contains="roles")

    def test_rejects_hash_mismatch_path_escape_and_symlink(self):
        fake_server = self.source_entry(self.recipe, "g2", "fake-server-run")
        fake_server_path = self.directory / fake_server["bytes_path"]
        fake_server_path.write_bytes(fake_server_path.read_bytes() + b"tampered")
        self.write_recipe()
        return_code, _, stderr = self.run_assembler()
        self.assertNotEqual(return_code, 0)
        self.assertIn("SHA-256", stderr)
        self.assertFalse(self.output.exists())

        fake_server_path.write_bytes(fixtures.TEST_SOURCE_BYTES["fake-server-run"])
        escaped = copy.deepcopy(self.recipe)
        self.source_entry(escaped, "g2", "fake-server-run")["bytes_path"] = "../outside.json"
        self.assert_recipe_rejected(escaped, contains="path")

        outside = self.directory.parent / f"{self.directory.name}-outside.json"
        outside.write_bytes(fixtures.TEST_SOURCE_BYTES["fake-server-run"])
        fake_server_path.unlink()
        fake_server_path.symlink_to(outside)
        try:
            self.write_recipe()
            return_code, _, stderr = self.run_assembler()
            self.assertNotEqual(return_code, 0)
            self.assertIn("symlink", stderr)
            self.assertFalse(self.output.exists())
        finally:
            outside.unlink(missing_ok=True)

    def test_rejects_malformed_or_mixed_g3_identity(self):
        self.write_recipe()
        return_code, _, stderr = self.run_assembler(reviewed_head_oid="A" * 40)
        self.assertNotEqual(return_code, 0)
        self.assertIn("Git SHA", stderr)
        self.assertFalse(self.output.exists())

        return_code, _, stderr = self.run_assembler(merged_oid="f" * 40)
        self.assertNotEqual(return_code, 0)
        self.assertIn("merged", stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_mixed_repository_identity_and_wrong_ios_build_number(self):
        mixed = copy.deepcopy(self.recipe)
        self.source_entry(mixed, "g2", "mozilla-xcframework")["descriptor"][
            "repository"
        ] = "Floorp-Projects/Floorp"
        self.assert_recipe_rejected(mixed, contains="repository")

        wrong_build = copy.deepcopy(self.recipe)
        wrong_build["release_inputs"]["ios"]["build_number"] = "5"
        self.assert_recipe_rejected(wrong_build, contains="FloorpRelease.xcconfig")

    def test_rejects_secret_bearing_local_metadata_even_with_matching_digest(self):
        recipe = copy.deepcopy(self.recipe)
        source = self.source_entry(recipe, "g2", "fake-server-run")
        raw = fixtures.canonical_bytes(
            {
                "access_token": "not-a-real-token-value",
                "failed": 0,
                "passed": 24,
                "secrets_retained": False,
            }
        )
        (self.directory / source["bytes_path"]).write_bytes(raw)
        source["descriptor"]["sha256"] = hashlib.sha256(raw).hexdigest()

        self.assert_recipe_rejected(recipe, contains="forbidden")

        command_secret = copy.deepcopy(self.recipe)
        command_secret["g3_integration_commands"][0]["argv"].append(
            "authorization: bearer not-a-real-token-value"
        )
        self.assert_recipe_rejected(command_secret, contains="bearer")

    def test_rejects_gate_times_not_bound_to_captured_artifacts(self):
        cases: list[tuple[str, dict[str, object], str]] = []
        g2 = copy.deepcopy(self.recipe)
        g2["gates"]["g2"]["issued_at"] = "2026-08-08T05:41:31Z"
        cases.append(("g2-published-at", g2, "artifact time"))
        g2_missing_time = copy.deepcopy(self.recipe)
        del self.source_entry(g2_missing_time, "g2", "focus-xcframework")["descriptor"][
            "release_published_at"
        ]
        cases.append(("g2-missing-published-at", g2_missing_time, "artifact time"))
        g2_mixed_time = copy.deepcopy(self.recipe)
        self.source_entry(g2_mixed_time, "g2", "focus-xcframework")["descriptor"][
            "release_published_at"
        ] = "2026-08-08T05:41:31Z"
        cases.append(("g2-mixed-published-at", g2_mixed_time, "artifact times are mixed"))
        g3 = copy.deepcopy(self.recipe)
        g3["gates"]["g3"]["issued_at"] = "2026-08-09T23:31:01Z"
        cases.append(("g3-xcresult-created-at", g3, "XCResult artifact time"))
        g3_expiry = copy.deepcopy(self.recipe)
        g3_expiry["gates"]["g3"]["expires_at"] = "2026-08-16T23:31:01Z"
        cases.append(("g3-xcresult-expires-at", g3_expiry, "XCResult artifact time"))
        g3_missing_time = copy.deepcopy(self.recipe)
        del self.source_entry(g3_missing_time, "g3", "xcresult")["descriptor"][
            "artifact_created_at"
        ]
        cases.append(("g3-missing-created-at", g3_missing_time, "artifact time"))
        g3_rerun = copy.deepcopy(self.recipe)
        g3_run = self.source_entry(g3_rerun, "g3", "ci-run")
        original_g3_run_path = self.directory / g3_run["bytes_path"]
        g3_run_payload = json.loads(original_g3_run_path.read_bytes())
        g3_run_payload["updated_at"] = "2026-08-10T00:01:00Z"
        g3_run_raw = fixtures.canonical_bytes(g3_run_payload)
        g3_run["bytes_path"] = "captures/g3-ci-run-rerun.json"
        g3_run_path = self.directory / g3_run["bytes_path"]
        g3_run_path.write_bytes(g3_run_raw)
        g3_run["descriptor"]["sha256"] = hashlib.sha256(g3_run_raw).hexdigest()
        g3_rerun["gates"]["g3"]["issued_at"] = "2026-08-10T00:01:00Z"
        g3_rerun["gates"]["g3"]["expires_at"] = "2026-08-17T00:01:00Z"
        cases.append(("g3-rerun-cannot-refresh-xcresult", g3_rerun, "XCResult artifact time"))
        g4 = copy.deepcopy(self.recipe)
        g4["gates"]["g4"]["issued_at"] = "2026-08-09T22:59:59Z"
        cases.append(("g4-max-run-created-at", g4, "artifact time"))
        g4_attestation_ci = copy.deepcopy(self.recipe)
        for gate_name, role in (
            ("g3", "ci-run"),
            ("g4", "g4-attestation-ci-run"),
        ):
            run_entry = self.source_entry(g4_attestation_ci, gate_name, role)
            run_payload = json.loads((self.directory / run_entry["bytes_path"]).read_bytes())
            run_payload["created_at"] = "2026-08-09T23:05:00Z"
            self.replace_captured_bytes(
                g4_attestation_ci,
                gate_name,
                role,
                fixtures.canonical_bytes(run_payload),
                "g4-attestation-created-later.json",
            )
        cases.append(("g4-attestation-ci-created-at", g4_attestation_ci, "artifact time"))
        g4_expiry = copy.deepcopy(self.recipe)
        g4_expiry["gates"]["g4"]["expires_at"] = "2026-08-16T23:31:01Z"
        cases.append(("g4-attestation-artifact-expiry", g4_expiry, "artifact time"))
        g4_anchor_deadline = copy.deepcopy(self.recipe)
        for gate_name, role in (
            ("g3", "xcresult"),
            ("g4", "g4-attestation-xcresult"),
        ):
            descriptor = self.source_entry(g4_anchor_deadline, gate_name, role)["descriptor"]
            descriptor["artifact_expires_at"] = "2026-12-01T00:00:00Z"
        anchor = datetime(2026, 8, 9, 23, 0, tzinfo=timezone.utc)
        g4_anchor_deadline["gates"]["g4"]["expires_at"] = (
            anchor + timedelta(days=30, seconds=1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        cases.append(("g4-min-created-at-deadline", g4_anchor_deadline, "artifact time"))
        for name, recipe, message in cases:
            with self.subTest(name=name):
                self.assert_recipe_rejected(recipe, contains=message)

    def test_rejects_existing_output_or_receipt_without_clobbering(self):
        self.output.write_bytes(b"existing-output")
        self.write_recipe()
        return_code, _, stderr = self.run_assembler()
        self.assertNotEqual(return_code, 0)
        self.assertIn("exists", stderr)
        self.assertEqual(self.output.read_bytes(), b"existing-output")
        receipt_path = self.directory / "artifacts/task-19-integration-receipt.json"
        self.assertFalse(receipt_path.exists())

        self.output.unlink()
        receipt_path.write_bytes(b"existing-receipt")
        return_code, _, stderr = self.run_assembler()
        self.assertNotEqual(return_code, 0)
        self.assertIn("exists", stderr)
        self.assertEqual(receipt_path.read_bytes(), b"existing-receipt")
        self.assertFalse(self.output.exists())

    def test_production_module_has_no_test_fixture_dependency(self):
        source = ASSEMBLER_PATH.read_text(encoding="utf-8")
        self.assertNotIn("scripts.ci.tests", source)
        self.assertNotIn("floorp-notes-sync-g1-g4-production-qa-valid.json", source)
        self.assertNotIn("TEST_SOURCE_BYTES", source)


if __name__ == "__main__":
    unittest.main()
