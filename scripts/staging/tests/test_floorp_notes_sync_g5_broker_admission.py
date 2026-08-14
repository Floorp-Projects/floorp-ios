"""TDD contract for the non-executing owner-pinned G5 broker admission bridge.

All keys and trust files below are generated in private temporary directories.
The suite never accesses accounts or credentials, launches a runner/client, or
authorizes G5.
"""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import inspect
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unittest import mock

from scripts.staging import floorp_notes_sync_g5_driver_admission as driver_admission
from scripts.staging import floorp_notes_sync_g5_owner_trust as owner_trust


ROOT = Path(__file__).resolve().parents[3]
BROKER_MODULE_PATH = ROOT / "scripts/staging/floorp_notes_sync_g5_broker_admission.py"
SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
TRUSTED_NOW = datetime(2026, 8, 15, 12, 0, 0, tzinfo=timezone.utc)
EXPIRY = datetime(2026, 8, 15, 12, 30, 0, tzinfo=timezone.utc)
HEAD_SHA = "a" * 40
G1_G4_DIGEST = "b" * 64
RELEASE_INPUTS_DIGEST = "c" * 64
DRIVER_BINARY_DIGEST = "d" * 64


class FloorpNotesSyncG5BrokerAdmissionTests(unittest.TestCase):
    def load_broker_module(self) -> Any | None:
        self.assertTrue(BROKER_MODULE_PATH.is_file(), "owner-pinned broker admission bridge is missing")
        if not BROKER_MODULE_PATH.is_file():
            return None
        specification = importlib.util.spec_from_file_location(
            "floorp_notes_sync_g5_broker_admission_test", BROKER_MODULE_PATH
        )
        self.assertIsNotNone(specification)
        assert specification is not None
        self.assertIsNotNone(specification.loader)
        assert specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        return module

    @staticmethod
    def run_command(command: list[str]) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(command, capture_output=True, check=False)

    def create_test_signer(self, directory: Path, name: str) -> tuple[Path, str, str, str]:
        self.assertTrue(SSH_KEYGEN.is_file(), "the pinned ssh-keygen executable is unavailable")
        private_key = directory / name
        generated = self.run_command(
            [str(SSH_KEYGEN), "-q", "-t", "ed25519", "-N", "", "-f", str(private_key)]
        )
        self.assertEqual(generated.returncode, 0, generated.stderr.decode("utf-8", "replace"))
        fields = private_key.with_suffix(".pub").read_text(encoding="utf-8").split()
        self.assertGreaterEqual(len(fields), 2)
        fingerprint = self.run_command([str(SSH_KEYGEN), "-lf", str(private_key.with_suffix(".pub"))])
        self.assertEqual(fingerprint.returncode, 0, fingerprint.stderr.decode("utf-8", "replace"))
        parsed = fingerprint.stdout.decode("utf-8", "replace").split()
        self.assertGreaterEqual(len(parsed), 2)
        return private_key, fields[0], fields[1], parsed[1]

    @staticmethod
    def sha256(value: bytes) -> str:
        return hashlib.sha256(value).hexdigest()

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

    def install_owner_bundle(self, root: Path, high_water_path: Path) -> dict[str, object]:
        root.mkdir(mode=0o700)
        owner_key, owner_type, owner_value, owner_fingerprint = self.create_test_signer(root, "owner")
        driver_key, driver_type, driver_value, driver_fingerprint = self.create_test_signer(root, "driver")
        owner_allowed_signers = f"owner-login {owner_type} {owner_value}\n".encode("ascii")
        driver_allowed_signers = f"driver-login {driver_type} {driver_value}\n".encode("ascii")
        driver_registry = owner_trust.canonical_bytes(
            {
                "driver_registry": [
                    {
                        "authority": "ephemeral-test-authority",
                        "key_fingerprint": driver_fingerprint,
                        "login": "driver-login",
                        "role": "driver-admission",
                    }
                ],
                "schema_version": 1,
            }
        )
        revocations = b'{"revocations":[],"schema_version":1}'
        (root / "owner-allowed-signers").write_bytes(owner_allowed_signers)
        (root / "allowed-signers").write_bytes(driver_allowed_signers)
        (root / "driver-registry.json").write_bytes(driver_registry)
        (root / "revocations.json").write_bytes(revocations)
        manifest: dict[str, object] = {
            "authority_domain": owner_trust.AUTHORITY_DOMAIN,
            "driver_signer": {
                "key_fingerprint": driver_fingerprint,
                "login": "driver-login",
            },
            "expires_at": "2026-08-15T12:30:00Z",
            "files": {
                "allowed_signers_sha256": self.sha256(driver_allowed_signers),
                "driver_registry_sha256": self.sha256(driver_registry),
                "revocations_sha256": self.sha256(revocations),
            },
            "issued_at": "2026-08-15T12:00:00Z",
            "owner": {
                "key_fingerprint": owner_fingerprint,
                "login": "owner-login",
                "role": owner_trust.OWNER_ROLE,
            },
            "previous_manifest_sha256": None,
            "schema_version": 1,
            "version": 1,
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_bytes(owner_trust.canonical_bytes(manifest))
        signed = self.run_command(
            [
                str(SSH_KEYGEN),
                "-Y",
                "sign",
                "-f",
                str(owner_key),
                "-n",
                owner_trust.OWNER_NAMESPACE,
                str(manifest_path),
            ]
        )
        self.assertEqual(signed.returncode, 0, signed.stderr.decode("utf-8", "replace"))
        signature_path = manifest_path.with_suffix(".json.sig")
        self.assertTrue(signature_path.is_file(), "owner trust signature was not produced")
        (root / "manifest.sig").write_bytes(signature_path.read_bytes())
        high_water_path.parent.mkdir(mode=0o700)
        high_water_path.write_bytes(
            owner_trust.canonical_bytes(
                {
                    "manifest_sha256": self.sha256(manifest_path.read_bytes()),
                    "schema_version": 1,
                    "version": 1,
                }
            )
        )
        return {
            "driver_fingerprint": driver_fingerprint,
            "driver_key": driver_key,
        }

    def make_signed_admission(self, directory: Path, driver_key: Path, driver_fingerprint: str) -> bytes:
        payload: dict[str, object] = {
            "driver": {
                "binary_sha256": DRIVER_BINARY_DIGEST,
                "interface": driver_admission.EXPECTED_DRIVER_INTERFACE,
            },
            "lease": {
                "ephemeral": True,
                "expires_at": "2026-08-15T12:30:00Z",
                "id": "g5-driver-lease-0123456789abcdef",
                "issued_at": "2026-08-15T12:00:00Z",
                "watchdog_cleanup_required": True,
            },
            "release": self.expected_release_binding(),
            "run_binding": self.expected_run_binding(),
            "schema_version": 1,
            "signer": {
                "github_login": "driver-login",
                "key_fingerprint": driver_fingerprint,
                "role": driver_admission.DRIVER_ROLE,
            },
        }
        payload_path = directory / "driver-admission.json"
        payload_path.write_bytes(driver_admission.canonical_bytes(payload))
        signed = self.run_command(
            [
                str(SSH_KEYGEN),
                "-Y",
                "sign",
                "-f",
                str(driver_key),
                "-n",
                driver_admission.NAMESPACE,
                str(payload_path),
            ]
        )
        self.assertEqual(signed.returncode, 0, signed.stderr.decode("utf-8", "replace"))
        envelope = {
            "payload": payload,
            "signature": payload_path.with_suffix(".json.sig").read_text(encoding="ascii"),
        }
        return driver_admission.canonical_bytes(envelope)

    @staticmethod
    def root_loader(root: Path, high_water_path: Path) -> Any:
        def load(*, trusted_now: datetime) -> dict[str, object]:
            return owner_trust._load_owner_pinned_driver_trust_from_root(
                root,
                high_water_path=high_water_path,
                trusted_now=trusted_now,
                ssh_keygen=SSH_KEYGEN,
                required_owner_uid=os.geteuid(),
            )

        return load

    def test_bridge_reloads_fixed_owner_trust_and_returns_exact_non_grant(self) -> None:
        broker = self.load_broker_module()
        if broker is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root = directory / "driver-trust"
            high_water_path = directory / "state" / "driver-trust-high-water.json"
            installed = self.install_owner_bundle(root, high_water_path)
            raw = self.make_signed_admission(directory, installed["driver_key"], installed["driver_fingerprint"])
            loader = self.root_loader(root, high_water_path)
            with mock.patch.object(broker, "_load_owner_pinned_driver_trust", side_effect=loader) as patched:
                decision = broker.verify_broker_admission(
                    raw,
                    expected_run_binding=self.expected_run_binding(),
                    expected_release_binding=self.expected_release_binding(),
                    trusted_now=TRUSTED_NOW,
                )
        self.assertEqual(
            decision,
            {
                "execution_authorization": "not-granted",
                "g5_result": "not-assessed",
            },
        )
        patched.assert_called_once_with(trusted_now=TRUSTED_NOW)

    def test_bridge_reloads_trust_on_each_call_and_rejects_expiry(self) -> None:
        broker = self.load_broker_module()
        if broker is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root = directory / "driver-trust"
            high_water_path = directory / "state" / "driver-trust-high-water.json"
            installed = self.install_owner_bundle(root, high_water_path)
            raw = self.make_signed_admission(directory, installed["driver_key"], installed["driver_fingerprint"])
            loader = self.root_loader(root, high_water_path)
            with mock.patch.object(broker, "_load_owner_pinned_driver_trust", side_effect=loader) as patched:
                broker.verify_broker_admission(
                    raw,
                    expected_run_binding=self.expected_run_binding(),
                    expected_release_binding=self.expected_release_binding(),
                    trusted_now=TRUSTED_NOW,
                )
                with self.assertRaises(broker.BrokerAdmissionError):
                    broker.verify_broker_admission(
                        raw,
                        expected_run_binding=self.expected_run_binding(),
                        expected_release_binding=self.expected_release_binding(),
                        trusted_now=EXPIRY,
                    )
        self.assertEqual(patched.call_count, 2)
        self.assertEqual(patched.call_args_list[1].kwargs, {"trusted_now": EXPIRY})

    def test_bridge_rejects_wrong_bindings_noncanonical_input_and_invalid_loader_result(self) -> None:
        broker = self.load_broker_module()
        if broker is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root = directory / "driver-trust"
            high_water_path = directory / "state" / "driver-trust-high-water.json"
            installed = self.install_owner_bundle(root, high_water_path)
            raw = self.make_signed_admission(directory, installed["driver_key"], installed["driver_fingerprint"])
            loader = self.root_loader(root, high_water_path)
            bad_run = self.expected_run_binding()
            bad_run["head_sha"] = "e" * 40
            bad_release = self.expected_release_binding()
            bad_release["g1_g4_digest_sha256"] = "f" * 64
            with mock.patch.object(broker, "_load_owner_pinned_driver_trust", side_effect=loader):
                for candidate, run, release in (
                    (raw + b" ", self.expected_run_binding(), self.expected_release_binding()),
                    (raw, bad_run, self.expected_release_binding()),
                    (raw, self.expected_run_binding(), bad_release),
                ):
                    with self.subTest(candidate=candidate[:16]):
                        with self.assertRaises(broker.BrokerAdmissionError):
                            broker.verify_broker_admission(
                                candidate,
                                expected_run_binding=run,
                                expected_release_binding=release,
                                trusted_now=TRUSTED_NOW,
                            )

            def invalid_loader(*, trusted_now: datetime) -> dict[str, object]:
                result = loader(trusted_now=trusted_now)
                invalid = copy.deepcopy(result)
                invalid["execution_authorization"] = "granted"
                return invalid

            with mock.patch.object(broker, "_load_owner_pinned_driver_trust", side_effect=invalid_loader):
                with self.assertRaises(broker.BrokerAdmissionError):
                    broker.verify_broker_admission(
                        raw,
                        expected_run_binding=self.expected_run_binding(),
                        expected_release_binding=self.expected_release_binding(),
                        trusted_now=TRUSTED_NOW,
                    )

    def test_public_api_has_no_caller_supplied_trust_or_execution_capability(self) -> None:
        broker = self.load_broker_module()
        if broker is None:
            return
        parameters = set(inspect.signature(broker.verify_broker_admission).parameters)
        self.assertEqual(
            parameters,
            {"raw_admission", "expected_run_binding", "expected_release_binding", "trusted_now"},
        )
        self.assertFalse(hasattr(broker, "load_owner_pinned_driver_trust"))
        self.assertFalse(hasattr(broker, "validate_driver_admission"))
        source = BROKER_MODULE_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "importlib",
            "subprocess",
            "xcodebuild",
            "simctl",
            "socket",
            "urllib",
            "requests",
            "os.system",
        ):
            self.assertNotIn(forbidden, source)
        self.assertIn("_load_owner_pinned_driver_trust", source)
        self.assertIn("_validate_driver_admission", source)
        self.assertNotIn("def main", source)


if __name__ == "__main__":
    unittest.main()
