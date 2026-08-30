"""TDD contract for the non-executing Todo 20 two-client preflight."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
STAGING = ROOT / "scripts" / "staging"
TOOL = STAGING / "floorp_notes_sync_two_client.py"
PREFLIGHT = STAGING / "preflight-floorp-notes-sync-two-client.sh"
FIXTURE_SOURCE = ROOT / "sync-fixtures" / "floorp-notes" / "floorp-notes-merge-v1.json"
ENDPOINT_SOURCE = ROOT / "docs" / "floorp-release-endpoints.json"
G1_G4_FIXTURE = ROOT / "scripts" / "ci" / "fixtures" / "floorp-notes-sync-g1-g4-production-qa-valid.json"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def jcs_bytes(value: Any) -> bytes:
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        return str(value).encode("ascii")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if isinstance(value, list):
        return b"[" + b",".join(jcs_bytes(item) for item in value) + b"]"
    if isinstance(value, dict):
        members = (
            jcs_bytes(key) + b":" + jcs_bytes(value[key])
            for key in sorted(value, key=lambda item: item.encode("utf-16-be"))
        )
        return b"{" + b",".join(members) + b"}"
    raise TypeError(f"unsupported test JSON value: {type(value).__name__}")


def jcs_digest(value: Any) -> str:
    return hashlib.sha256(jcs_bytes(value)).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n")


def write_canonical_json(path: Path, value: Any) -> None:
    path.write_bytes(jcs_bytes(value))


def local_source(role: str, digest_character: str) -> dict[str, str]:
    return {
        "content_policy": "metadata-json",
        "kind": "local-file",
        "path": f"artifacts/{role}.json",
        "role": role,
        "sha256": digest_character * 64,
    }


def gate_artifact(roles: tuple[str, ...], digest_character: str) -> dict[str, Any]:
    sources = [local_source(role, digest_character) for role in roles]
    return {"sha256": jcs_digest({"sources": sources}), "sources": sources}


class FloorpNotesSyncTwoClientPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_owner = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_owner.name)
        self.fixture_digest = sha256_file(FIXTURE_SOURCE)
        self.endpoint_digest = sha256_file(ENDPOINT_SOURCE)
        self.fixture = json.loads(FIXTURE_SOURCE.read_text())
        self.case_set_digest = jcs_digest(self.fixture["requiredCaseNames"])
        self.as_input = copy.deepcopy(json.loads(G1_G4_FIXTURE.read_text())["release_inputs"]["application_services"])
        self.release_inputs = copy.deepcopy(json.loads(G1_G4_FIXTURE.read_text())["release_inputs"])
        self.as_handoff_path = self.directory / "task-17-as-handoff.json"
        self.evidence_path = self.directory / "g1-g4-production-qa.json"
        self.desktop_path = self.directory / "desktop-build.json"
        self.qa_path = self.directory / "ios-production-qa-build.json"
        self.disabled_path = self.directory / "ios-release-disabled-build.json"
        self.write_valid_inputs()

    def tearDown(self) -> None:
        self.temporary_owner.cleanup()

    def make_evidence(self) -> dict[str, Any]:
        inputs = copy.deepcopy(self.release_inputs)
        g1_roles = (
            "task-manifest",
            "todo16-contract",
            "ios-contract-source",
            "desktop-contract-source",
            "merge-fixture",
        )
        g2_roles = (
            "task-manifest",
            "fake-server-run",
            "focus-xcframework",
            "mozilla-xcframework",
            "release-manifest",
            "sha256sums",
            "swift-components",
        )
        g3_roles = ("integration-receipt", "ci-run", "xcresult")
        g4_roles = (
            "task-manifest",
            "task18-execution-verdict",
            "desktop-ci-run",
            "runtime-ci-run",
            "g4-attestation-source",
            "g4-attestation-ci-run",
            "g4-attestation-xcresult",
            "xpcshell-run",
            "tps-run",
        )
        gates: dict[str, dict[str, Any]] = {
            "g1": {
                "artifact": gate_artifact(g1_roles, "1"),
                "contract": {
                    "case_set_sha256": inputs["contract"]["case_set_sha256"],
                    "control_pref_name": "services.sync.prefs.sync.floorp.browser.note.memos",
                    "control_pref_value": True,
                    "desktop_contract_sha": inputs["desktop"]["source_sha"],
                    "fixture_sha256": inputs["contract"]["fixture_sha256"],
                    "ios_contract_sha": inputs["ios"]["source_sha"],
                    "notes_pref_name": "floorp.browser.note.memos",
                    "record_id": "e2VjODAzMGY3LWMyMGEtNDY0Zi05YjBlLTEzYTNhOWU5NzM4NH0=",
                },
                "issued_at": "2026-08-12T00:00:00Z",
                "status": "passed",
            },
            "g2": {
                "application_services": copy.deepcopy(inputs["application_services"]),
                "artifact": gate_artifact(g2_roles, "2"),
                "expires_at": "2026-08-30T00:00:00Z",
                "fake_server_run_sha256": "3" * 64,
                "issued_at": "2026-08-12T00:00:00Z",
                "status": "passed",
            },
            "g3": {
                "artifact": gate_artifact(g3_roles, "4"),
                "candidate": copy.deepcopy(inputs["ios"]),
                "expires_at": "2026-08-18T00:00:00Z",
                "issued_at": "2026-08-12T00:00:00Z",
                "status": "passed",
                "xcresult_sha256": "5" * 64,
            },
            "g4": {
                "artifact": gate_artifact(g4_roles, "6"),
                "desktop": copy.deepcopy(inputs["desktop"]),
                "expires_at": "2026-08-30T00:00:00Z",
                "issued_at": "2026-08-12T00:00:00Z",
                "runtime": copy.deepcopy(inputs["runtime"]),
                "status": "passed",
                "tps_run_sha256": "7" * 64,
                "xpcshell_run_sha256": "8" * 64,
            },
        }
        evidence: dict[str, Any] = {
            "build_contract_mode": "production-qa",
            "g1_g4_digest_sha256": "",
            "gates": gates,
            "release_inputs": inputs,
            "same_release_key_sha256": "",
            "schema_version": 1,
        }
        evidence["g1_g4_digest_sha256"] = jcs_digest({"gates": gates, "release_inputs": inputs})
        evidence["same_release_key_sha256"] = jcs_digest(
            {
                "gate_artifact_digests": {
                    name: gate["artifact"]["sha256"] for name, gate in gates.items()
                },
                "release_inputs": inputs,
            }
        )
        return evidence

    def write_handoff(self) -> None:
        assets = self.as_input["artifacts"]
        write_json(
            self.as_handoff_path,
            {
                "assets": {
                    "FocusRustComponents.xcframework.zip": assets["focus_xcframework_sha256"],
                    "MozillaRustComponents.xcframework.zip": assets["mozilla_xcframework_sha256"],
                    "SHA256SUMS": assets["sha256sums_sha256"],
                    "release-manifest.json": assets["release_manifest_sha256"],
                    "swift-components.tar.xz": assets["swift_components_sha256"],
                },
                "branch": "floorp-ios",
                "contract_symbols": ["get_registered_sync_engine"],
                "engine_authority_commit": "d588863894e9b3ce58b05a964a7694ab00e28054",
                "engine_component": "components/floorp-prefs-sync",
                "merged_commit": self.as_input["source_sha"],
                "merged_tree": self.as_input["tree_sha"],
                "publication_status": "published",
                "publication_verification": "test fixture metadata only",
                "release_state": "published_prerelease",
                "release_tag": self.as_input["release_tag"],
                "release_url": "https://github.com/Floorp-Projects/application-services/releases/tag/floorp-ios-155.20260731050244.4",
                "repository": self.as_input["repository"],
                "schema_version": 1,
                "todo": 17,
                "upstream": {
                    "actual_merge_base": "b21da19867ff58b1cfd8c83fceba8dac1f243c44",
                    "artifact_version": "155.0.20260731050244",
                    "commit": "b21da19867ff58b1cfd8c83fceba8dac1f243c44",
                    "repository": "mozilla/application-services",
                    "source_version": "155.0a1",
                },
                "workflow_url": "https://github.com/Floorp-Projects/application-services/actions/runs/1",
            },
        )

    def write_evidence(self, evidence: dict[str, Any] | None = None) -> dict[str, Any]:
        result = self.make_evidence() if evidence is None else evidence
        write_canonical_json(self.evidence_path, result)
        return result

    def write_valid_inputs(self) -> None:
        self.write_handoff()
        evidence = self.write_evidence()
        inputs = evidence["release_inputs"]
        endpoint_authority = {
            "custom_fxa_override": False,
            "custom_token_server_override": False,
            "environment": "production",
            "fxa_server": "FxAConfig.Server.release",
            "hosts": sorted(
                [
                    "accounts.firefox.com",
                    "api.accounts.firefox.com",
                    "event-sync.services.mozilla.com",
                    "oauth.accounts.firefox.com",
                    "profile.accounts.firefox.com",
                    "static.accounts.firefox.com",
                    "sync.services.mozilla.com",
                    "token.services.mozilla.com",
                ]
            ),
            "matrix_path": "/trusted/source/docs/floorp-release-endpoints.json",
            "matrix_sha256": self.endpoint_digest,
            "wire_protocol": "sync15",
        }
        write_json(
            self.qa_path,
            {
                "build": {
                    "action": "build-for-testing",
                    "build_number": inputs["ios"]["build_number"],
                    "configuration": "FloorpRelease",
                    "scheme": "FloorpNotesSyncQA",
                    "signing_allowed": False,
                    "signing_verified": False,
                },
                "endpoint_authority": endpoint_authority,
                "evidence": {"embedded_digest_sha256": evidence["g1_g4_digest_sha256"]},
                "gate": {"effective": True, "requested": True},
                "mode": "production-qa",
                "release_inputs": {
                    "application_services": copy.deepcopy(inputs["application_services"]),
                    "ios": copy.deepcopy(inputs["ios"]),
                },
                "runtime_contract": {
                    "engine_registration_allowed": True,
                    "engine_requests_allowed": True,
                    "ui_exposure_allowed": True,
                },
                "schema_version": 1,
                "source": {
                    "commit": inputs["ios"]["source_sha"],
                    "dirty": False,
                    "tree": "2" * 40,
                },
            },
        )
        write_json(
            self.disabled_path,
            {
                "build": {
                    "action": "build",
                    "build_number": inputs["ios"]["build_number"],
                    "configuration": "FloorpRelease",
                    "scheme": "Floorp",
                    "signing_allowed": False,
                    "signing_verified": False,
                },
                "endpoint_authority": endpoint_authority,
                "evidence": {"embedded_digest_sha256": None},
                "gate": {"effective": False, "requested": False},
                "mode": "release-disabled",
                "release_inputs": {"application_services": None, "ios": None},
                "runtime_contract": {
                    "engine_registration_allowed": False,
                    "engine_requests_allowed": False,
                    "ui_exposure_allowed": False,
                },
                "schema_version": 1,
                "source": {
                    "commit": inputs["ios"]["source_sha"],
                    "dirty": False,
                    "tree": "2" * 40,
                },
            },
        )
        write_json(
            self.desktop_path,
            {
                "build": {"build_number": inputs["desktop"]["build_number"]},
                "notes_sync": {"endpoint_authority": "production", "wire_protocol": "sync15"},
                "runtime": copy.deepcopy(inputs["runtime"]),
                "schema_version": 1,
                "source": {
                    "commit": inputs["desktop"]["source_sha"],
                    "repository": "Floorp-Projects/Floorp",
                },
            },
        )

    def preflight_arguments(self) -> list[str]:
        return [
            "preflight",
            "--ios-production-qa-manifest",
            str(self.qa_path),
            "--ios-release-disabled-manifest",
            str(self.disabled_path),
            "--g1-g4-evidence",
            str(self.evidence_path),
            "--desktop-manifest",
            str(self.desktop_path),
            "--as-handoff",
            str(self.as_handoff_path),
            "--fixture",
            str(FIXTURE_SOURCE),
            "--endpoint-matrix",
            str(ENDPOINT_SOURCE),
        ]

    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(TOOL), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_preflight_accepts_exact_static_inputs_without_authorizing_execution(self) -> None:
        result = self.run_tool(*self.preflight_arguments())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(PREFLIGHT.is_file())
        self.assertTrue(os.access(PREFLIGHT, os.X_OK))
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "preflight-valid")
        self.assertEqual(payload["static_evidence_integrity"], "verified")
        self.assertEqual(payload["artifact_retrievability"], "not-assessed")
        self.assertEqual(payload["evidence_freshness"], "not-assessed")
        self.assertEqual(payload["execution_authorization"], "not-authorized")
        self.assertEqual(payload["g5_result"], "not-assessed")
        self.assertEqual(payload["cleanup_boundary"], "not-established")
        self.assertEqual(payload["ios_source_sha"], self.release_inputs["ios"]["source_sha"])
        self.assertEqual(payload["fixture_sha256"], self.fixture_digest)
        self.assertNotIn("G5 passed", result.stdout)
        self.assertNotIn("eligible", result.stdout)

    def test_preflight_rejects_recomputed_mixed_evidence_and_bad_digests(self) -> None:
        evidence = self.make_evidence()
        evidence["release_inputs"]["contract"]["fixture_sha256"] = "0" * 64
        evidence["g1_g4_digest_sha256"] = jcs_digest(
            {"gates": evidence["gates"], "release_inputs": evidence["release_inputs"]}
        )
        evidence["same_release_key_sha256"] = jcs_digest(
            {
                "gate_artifact_digests": {
                    name: gate["artifact"]["sha256"] for name, gate in evidence["gates"].items()
                },
                "release_inputs": evidence["release_inputs"],
            }
        )
        self.write_evidence(evidence)
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("fixture", result.stderr.lower())

        self.write_valid_inputs()
        evidence = self.make_evidence()
        evidence["same_release_key_sha256"] = "0" * 64
        self.write_evidence(evidence)
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("same-release", result.stderr.lower())

        self.write_valid_inputs()
        evidence = self.make_evidence()
        evidence["g1_g4_digest_sha256"] = "0" * 64
        self.write_evidence(evidence)
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("combined", result.stderr.lower())

    def test_preflight_rejects_bound_manifest_and_handoff_mismatches(self) -> None:
        mutations = (
            (self.disabled_path, ("source", "commit"), "9" * 40, "source"),
            (self.qa_path, ("endpoint_authority", "hosts"), ["example.invalid"], "endpoint"),
            (self.qa_path, ("evidence", "embedded_digest_sha256"), "0" * 64, "embedded"),
            (self.as_handoff_path, ("assets", "SHA256SUMS"), "0" * 64, "application services"),
        )
        for path, chain, value, expected in mutations:
            with self.subTest(expected=expected):
                self.write_valid_inputs()
                payload = json.loads(path.read_text())
                target = payload
                for key in chain[:-1]:
                    target = target[key]
                target[chain[-1]] = value
                write_json(path, payload)
                result = self.run_tool(*self.preflight_arguments())
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr.lower())

    def test_preflight_rejects_unknown_handoff_metadata(self) -> None:
        mutations = (
            (("ordinary_metadata",), "ordinary text"),
            (("assets", "additional-asset.zip"), "0" * 64),
            (("upstream", "ordinary_metadata"), "ordinary text"),
        )
        for chain, value in mutations:
            with self.subTest(chain=chain):
                self.write_valid_inputs()
                handoff = json.loads(self.as_handoff_path.read_text())
                target = handoff
                for key in chain[:-1]:
                    target = target[key]
                target[chain[-1]] = value
                write_json(self.as_handoff_path, handoff)
                result = self.run_tool(*self.preflight_arguments())
                self.assertEqual(result.returncode, 2)
                self.assertIn("as handoff", result.stderr.lower())

    def test_preflight_rejects_sensitive_fields_and_pinned_source_drift(self) -> None:
        qa = json.loads(self.qa_path.read_text())
        qa["access_token"] = "not-a-secret"
        write_json(self.qa_path, qa)
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("sensitive", result.stderr.lower())

        self.write_valid_inputs()
        for field_name in (
            "syncToken",
            "sync_token",
            "sync-token",
            "authorizationHeader",
            "authorization_header",
            "authorization-header",
            "noteContent",
            "note_content",
            "note-content",
            "noteTitle",
            "note_title",
            "note-title",
            "notePayload",
            "note_payload",
            "note-payload",
            "notesContent",
            "notes_content",
            "notes-content",
            "notesTitle",
            "notes_title",
            "notes-title",
            "notesPayload",
            "notes_payload",
            "notes-payload",
            "apiKey",
            "api_key",
            "api-key",
            "token",
            "key",
            "session",
            "tokenId",
            "sessionId",
            "cookieValue",
            "secretValue",
            "credentialId",
            "sameReleaseKeySha256",
            "same_release_key_sha256",
            "same-release-key-sha256",
            "customTokenServerOverride",
            "custom_token_server_override",
            "custom-token-server-override",
        ):
            with self.subTest(field_name=field_name):
                self.write_valid_inputs()
                handoff = json.loads(self.as_handoff_path.read_text())
                handoff[field_name] = "not-a-secret"
                write_json(self.as_handoff_path, handoff)
                result = self.run_tool(*self.preflight_arguments())
                self.assertEqual(result.returncode, 2)
                self.assertIn("sensitive", result.stderr.lower())

        self.write_valid_inputs()
        fixture = json.loads(FIXTURE_SOURCE.read_text())
        fixture["productionDesktopObservation"]["repository"] = "example.invalid"
        altered_fixture = self.directory / "altered-fixture.json"
        write_json(altered_fixture, fixture)
        arguments = self.preflight_arguments()
        arguments[arguments.index("--fixture") + 1] = str(altered_fixture)
        result = self.run_tool(*arguments)
        self.assertEqual(result.returncode, 2)
        self.assertIn("fixture", result.stderr.lower())

    def test_preflight_rejects_noncanonical_evidence_symlinks_and_execution_inputs(self) -> None:
        write_json(self.evidence_path, self.make_evidence())
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("canonical", result.stderr.lower())

        self.write_valid_inputs()
        alternate = self.directory / "task-17-as-handoff-real.json"
        self.as_handoff_path.rename(alternate)
        self.as_handoff_path.symlink_to(alternate)
        result = self.run_tool(*self.preflight_arguments())
        self.assertEqual(result.returncode, 2)
        self.assertIn("regular", result.stderr.lower())

        self.as_handoff_path.unlink()
        alternate.rename(self.as_handoff_path)
        for rejected in ("--execute", "--vm-provider", "--credential", "--trust-anchor"):
            with self.subTest(rejected=rejected):
                result = self.run_tool(*self.preflight_arguments(), rejected, "value")
                self.assertEqual(result.returncode, 2)
                self.assertIn("unrecognized", result.stderr.lower())

    def test_operational_commands_remain_fail_closed_and_source_has_no_launch_path(self) -> None:
        for command in ("desktop-build", "matrix", "collect-approvals"):
            with self.subTest(command=command):
                result = self.run_tool(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn("not yet configured", result.stderr.lower())

        source_text = TOOL.read_text()
        for forbidden in (
            "import subprocess",
            "import socket",
            "import urllib",
            "import requests",
            "Popen(",
            "os.system(",
        ):
            self.assertNotIn(forbidden, source_text)


if __name__ == "__main__":
    unittest.main()
