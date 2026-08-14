"""TDD contract for a signed, non-executing G5 driver admission record.

The tests use only ephemeral keys in a private temporary directory. They do
not use a production signer, credentials, accounts, browsers, clients, or
network services, and a valid record never authorizes G5 by itself.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/staging/floorp_notes_sync_g5_driver_admission.py"
SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
NAMESPACE = "floorp-notes-sync-g5-driver-admission-v1"
HEAD_SHA = "a" * 40
G1_G4_DIGEST = "b" * 64
RELEASE_INPUTS_DIGEST = "c" * 64
DRIVER_BINARY_DIGEST = "d" * 64
TRUSTED_NOW = datetime(2026, 8, 14, 12, 0, 0, tzinfo=timezone.utc)


class FloorpNotesSyncG5DriverAdmissionTests(unittest.TestCase):
    def load_module(self) -> Any | None:
        self.assertTrue(MODULE_PATH.is_file(), "signed driver-admission verifier is missing")
        if not MODULE_PATH.is_file():
            return None
        specification = importlib.util.spec_from_file_location(
            "floorp_notes_sync_g5_driver_admission_test",
            MODULE_PATH,
        )
        self.assertIsNotNone(specification)
        assert specification is not None
        self.assertIsNotNone(specification.loader)
        assert specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        return module

    @staticmethod
    def run_command(command: list[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(command, input=input_bytes, capture_output=True, check=False)

    def create_test_signer(self, directory: Path) -> tuple[Path, str, str, str]:
        self.assertTrue(SSH_KEYGEN.is_file(), "the pinned ssh-keygen executable is unavailable")
        private_key = directory / "driver-admission-test-key"
        generated = self.run_command(
            [str(SSH_KEYGEN), "-q", "-t", "ed25519", "-N", "", "-f", str(private_key)]
        )
        self.assertEqual(generated.returncode, 0, generated.stderr.decode("utf-8", "replace"))
        fields = private_key.with_suffix(".pub").read_text(encoding="utf-8").split()
        self.assertGreaterEqual(len(fields), 2)
        key_type, key_value = fields[0], fields[1]
        fingerprint = self.run_command([str(SSH_KEYGEN), "-lf", str(private_key.with_suffix(".pub"))])
        self.assertEqual(fingerprint.returncode, 0, fingerprint.stderr.decode("utf-8", "replace"))
        parsed = fingerprint.stdout.decode("utf-8", "replace").split()
        self.assertGreaterEqual(len(parsed), 2)
        return private_key, key_type, key_value, parsed[1]

    @staticmethod
    def expected_run_binding() -> dict[str, object]:
        return {
            "head_sha": HEAD_SHA,
            "repository": "Floorp-Projects/floorp-ios",
            "run_attempt": 1,
            "run_id": 123456789,
            "workflow_path": ".github/workflows/ci.yml",
        }

    @staticmethod
    def expected_release_binding() -> dict[str, object]:
        return {
            "g1_g4_digest_sha256": G1_G4_DIGEST,
            "release_inputs_sha256": RELEASE_INPUTS_DIGEST,
        }

    def payload(self, fingerprint: str) -> dict[str, object]:
        return {
            "driver": {
                "binary_sha256": DRIVER_BINARY_DIGEST,
                "interface": "metadata-only-g5-receipt-v1",
            },
            "lease": {
                "ephemeral": True,
                "expires_at": "2026-08-14T12:30:00Z",
                "id": "g5-driver-lease-0123456789abcdef",
                "issued_at": "2026-08-14T12:00:00Z",
                "watchdog_cleanup_required": True,
            },
            "release": {
                "g1_g4_digest_sha256": G1_G4_DIGEST,
                "release_inputs_sha256": RELEASE_INPUTS_DIGEST,
            },
            "run_binding": self.expected_run_binding(),
            "schema_version": 1,
            "signer": {
                "github_login": "driver-owner",
                "key_fingerprint": fingerprint,
                "role": "driver-admission",
            },
        }

    def trust_bundle(self, key_type: str, key_value: str, fingerprint: str) -> dict[str, bytes]:
        return {
            "allowed_signers": f"driver-owner {key_type} {key_value}\n".encode("ascii"),
            "driver_registry": json.dumps(
                {
                    "driver_registry": [
                        {
                            "authority": "test-only ephemeral signer",
                            "key_fingerprint": fingerprint,
                            "login": "driver-owner",
                            "role": "driver-admission",
                        }
                    ],
                    "schema_version": 1,
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8"),
            "revocations": b'{"revocations":[],"schema_version":1}',
        }

    def sign_document(self, module: Any, private_key: Path, payload: dict[str, object], directory: Path) -> dict[str, object]:
        signed = directory / "driver-admission-payload.json"
        signed.write_bytes(module.canonical_bytes(payload))
        result = self.run_command(
            [str(SSH_KEYGEN), "-Y", "sign", "-f", str(private_key), "-n", NAMESPACE, str(signed)]
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        signature = signed.with_suffix(signed.suffix + ".sig").read_text(encoding="ascii")
        return {"payload": payload, "signature": signature}

    def make_valid_inputs(self, module: Any, directory: Path) -> tuple[dict[str, object], dict[str, bytes]]:
        private_key, key_type, key_value, fingerprint = self.create_test_signer(directory)
        payload = self.payload(fingerprint)
        return self.sign_document(module, private_key, payload, directory), self.trust_bundle(key_type, key_value, fingerprint)

    def validate_raw(
        self,
        module: Any,
        document: dict[str, object],
        trust: dict[str, bytes],
        *,
        trusted_now: datetime = TRUSTED_NOW,
    ) -> dict[str, object]:
        return module.validate_driver_admission(
            module.canonical_bytes(document),
            trust_bundle=trust,
            expected_run_binding=self.expected_run_binding(),
            expected_release_binding=self.expected_release_binding(),
            trusted_now=trusted_now,
            ssh_keygen=SSH_KEYGEN,
        )

    def test_accepts_a_signed_ephemeral_driver_admission_but_does_not_authorize_g5(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, trust = self.make_valid_inputs(module, Path(temporary))
            decision = self.validate_raw(module, document, trust)
        self.assertEqual(decision["status"], "driver-admission-valid")
        self.assertEqual(decision["execution_authorization"], "not-granted")
        self.assertEqual(decision["g5_result"], "not-assessed")
        self.assertEqual(decision["run_binding"], self.expected_run_binding())
        self.assertEqual(decision["release_binding"], self.expected_release_binding())
        self.assertEqual(decision["driver_binary_sha256"], DRIVER_BINARY_DIGEST)

    def test_rejects_tampering_wrong_run_and_non_ephemeral_cleanup_less_records(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, trust = self.make_valid_inputs(module, Path(temporary))
            mutations = (
                ("binary", lambda payload: payload["driver"].__setitem__("binary_sha256", "e" * 64)),
                ("run", lambda payload: payload["run_binding"].__setitem__("head_sha", "f" * 40)),
                ("non-ephemeral", lambda payload: payload["lease"].__setitem__("ephemeral", False)),
                ("no-watchdog", lambda payload: payload["lease"].__setitem__("watchdog_cleanup_required", False)),
            )
            for label, mutate in mutations:
                with self.subTest(label=label):
                    altered = copy.deepcopy(document)
                    mutate(altered["payload"])
                    with self.assertRaises(module.DriverAdmissionError):
                        self.validate_raw(module, altered, trust)

    def test_rejects_a_valid_signature_for_a_different_release_candidate(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            private_key, key_type, key_value, fingerprint = self.create_test_signer(directory)
            for field, value in (
                ("g1_g4_digest_sha256", "e" * 64),
                ("release_inputs_sha256", "f" * 64),
            ):
                with self.subTest(field=field):
                    payload = self.payload(fingerprint)
                    payload["release"][field] = value
                    document = self.sign_document(module, private_key, payload, directory)
                    with self.assertRaises(module.DriverAdmissionError):
                        self.validate_raw(
                            module,
                            document,
                            self.trust_bundle(key_type, key_value, fingerprint),
                        )

    def test_raw_entry_point_requires_one_canonical_signed_document(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, trust = self.make_valid_inputs(module, Path(temporary))
            canonical = module.canonical_bytes(document)
            decision = module.validate_driver_admission(
                canonical,
                trust_bundle=trust,
                expected_run_binding=self.expected_run_binding(),
                expected_release_binding=self.expected_release_binding(),
                trusted_now=TRUSTED_NOW,
                ssh_keygen=SSH_KEYGEN,
            )
            self.assertEqual(decision["status"], "driver-admission-valid")
            with self.assertRaises(module.DriverAdmissionError):
                module.validate_driver_admission(
                    canonical + b" ",
                    trust_bundle=trust,
                    expected_run_binding=self.expected_run_binding(),
                    expected_release_binding=self.expected_release_binding(),
                    trusted_now=TRUSTED_NOW,
                    ssh_keygen=SSH_KEYGEN,
                )
            with self.assertRaises(module.DriverAdmissionError):
                module.validate_driver_admission(
                    document,
                    trust_bundle=trust,
                    expected_run_binding=self.expected_run_binding(),
                    expected_release_binding=self.expected_release_binding(),
                    trusted_now=TRUSTED_NOW,
                    ssh_keygen=SSH_KEYGEN,
                )

    def test_rejects_a_lease_at_its_exact_expiry_boundary(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, trust = self.make_valid_inputs(module, Path(temporary))
            with self.assertRaises(module.DriverAdmissionError):
                self.validate_raw(
                    module,
                    document,
                    trust,
                    trusted_now=datetime(2026, 8, 14, 12, 30, 0, tzinfo=timezone.utc),
                )

    def test_parser_and_trust_loader_bound_depth_signers_and_timeouts(self) -> None:
        module = self.load_module()
        if module is None:
            return
        deeply_nested = (
            b'{"payload":'
            + b"[" * 17
            + b"null"
            + b"]" * 17
            + b',"signature":"not-a-real-signature"}'
        )
        with self.assertRaises(module.DriverAdmissionError):
            module.parse_driver_admission_bytes(deeply_nested)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, key_type, key_value, _ = self.create_test_signer(directory)
            one_signer = f"driver-owner {key_type} {key_value}\n".encode("ascii")
            with self.assertRaises(module.DriverAdmissionError):
                module.load_allowed_signers(one_signer + one_signer, SSH_KEYGEN)
            with mock.patch.object(
                module.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(["ssh-keygen"], 1),
            ):
                with self.assertRaises(module.DriverAdmissionError):
                    module.load_allowed_signers(one_signer, SSH_KEYGEN)

    def test_rejects_expired_revoked_untrusted_and_sensitive_admissions(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, trust = self.make_valid_inputs(module, Path(temporary))
            admission_digest = module.digest(document["payload"])
            variants: list[tuple[str, dict[str, object], dict[str, bytes]]] = []

            expired = copy.deepcopy(document)
            expired["payload"]["lease"]["expires_at"] = "2026-08-14T11:59:59Z"
            variants.append(("expired", expired, trust))

            revoked = copy.deepcopy(trust)
            revoked["revocations"] = json.dumps(
                {
                    "revocations": [
                        {
                            "identifier": admission_digest,
                            "kind": "admission",
                            "reason": "test revocation",
                            "revoked_at": "2026-08-14T11:00:00Z",
                        }
                    ],
                    "schema_version": 1,
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            variants.append(("revoked", document, revoked))

            untrusted = copy.deepcopy(trust)
            untrusted["driver_registry"] = b'{"driver_registry":[],"schema_version":1}'
            variants.append(("untrusted", document, untrusted))

            sensitive = copy.deepcopy(document)
            sensitive["payload"]["driver"]["password"] = "forbidden"
            variants.append(("sensitive", sensitive, trust))

            for label, candidate, candidate_trust in variants:
                with self.subTest(label=label):
                    with self.assertRaises(module.DriverAdmissionError):
                        self.validate_raw(module, candidate, candidate_trust)

    def test_parser_rejects_duplicate_noncanonical_and_floating_json(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            document, _ = self.make_valid_inputs(module, Path(temporary))
        canonical = module.canonical_bytes(document)
        variants = (
            canonical + b" ",
            canonical.replace(b'"payload":', b'"payload":{},"payload":', 1),
            canonical.replace(b'"schema_version":1', b'"schema_version":1.0', 1),
        )
        for raw in variants:
            with self.subTest(raw=raw[:64]):
                with self.assertRaises(module.DriverAdmissionError):
                    module.parse_driver_admission_bytes(raw)


if __name__ == "__main__":
    unittest.main()
