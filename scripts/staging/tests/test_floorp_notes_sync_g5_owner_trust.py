"""TDD contract for the root-owned G5 driver-trust boundary.

Every key below is created in a temporary directory for the test.  This suite
does not read test accounts, launch a runner, invoke clients, or authorize G5.
"""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import inspect
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/staging/floorp_notes_sync_g5_owner_trust.py"
SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
TRUSTED_NOW = datetime(2026, 8, 15, 12, 0, 0, tzinfo=timezone.utc)


class FloorpNotesSyncG5OwnerTrustTests(unittest.TestCase):
    def load_module(self) -> Any | None:
        self.assertTrue(MODULE_PATH.is_file(), "owner-pinned trust loader is missing")
        if not MODULE_PATH.is_file():
            return None
        specification = importlib.util.spec_from_file_location(
            "floorp_notes_sync_g5_owner_trust_test", MODULE_PATH
        )
        self.assertIsNotNone(specification)
        assert specification is not None
        self.assertIsNotNone(specification.loader)
        assert specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        return module

    @staticmethod
    def run_command(
        command: list[str], *, input_bytes: bytes | None = None
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(command, input=input_bytes, capture_output=True, check=False)

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
    def canonical_bytes(value: object) -> bytes:
        return json.dumps(
            value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")

    @staticmethod
    def sha256(value: bytes) -> str:
        return hashlib.sha256(value).hexdigest()

    def sign_manifest(self, module: Any, owner_key: Path, manifest: dict[str, object], root: Path) -> bytes:
        target = root / "manifest.json"
        target.write_bytes(module.canonical_bytes(manifest))
        signed = self.run_command(
            [str(SSH_KEYGEN), "-Y", "sign", "-f", str(owner_key), "-n", module.OWNER_NAMESPACE, str(target)]
        )
        self.assertEqual(signed.returncode, 0, signed.stderr.decode("utf-8", "replace"))
        return target.with_suffix(".json.sig").read_bytes()

    def install_valid_bundle(
        self, module: Any, root: Path, high_water_path: Path
    ) -> dict[str, object]:
        if root.exists():
            for child in root.iterdir():
                child.unlink()
        else:
            root.mkdir(mode=0o700)
        owner_key, owner_type, owner_value, owner_fingerprint = self.create_test_signer(root, "owner")
        driver_key, driver_type, driver_value, driver_fingerprint = self.create_test_signer(root, "driver")
        owner_allowed_signers = f"owner-login {owner_type} {owner_value}\n".encode("ascii")
        driver_allowed_signers = f"driver-login {driver_type} {driver_value}\n".encode("ascii")
        driver_registry = self.canonical_bytes(
            {
                "driver_registry": [
                    {
                        "authority": "ephemeral test authority",
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
            "authority_domain": "floorp-notes-sync-g5-driver-trust-v1",
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
                "role": "g5-driver-trust-owner",
            },
            "previous_manifest_sha256": None,
            "schema_version": 1,
            "version": 1,
        }
        signature = self.sign_manifest(module, owner_key, manifest, root)
        (root / "manifest.sig").write_bytes(signature)
        manifest_bytes = (root / "manifest.json").read_bytes()
        high_water_path.parent.mkdir(mode=0o700, exist_ok=True)
        state = {
            "manifest_sha256": self.sha256(manifest_bytes),
            "schema_version": 1,
            "version": 1,
        }
        high_water_path.write_bytes(module.canonical_bytes(state))
        return {
            "driver_fingerprint": driver_fingerprint,
            "manifest": manifest,
            "owner_fingerprint": owner_fingerprint,
            "owner_key": owner_key,
        }

    def load_bundle(
        self, module: Any, root: Path, high_water_path: Path
    ) -> dict[str, object]:
        return module._load_owner_pinned_driver_trust_from_root(
            root,
            high_water_path=high_water_path,
            trusted_now=TRUSTED_NOW,
            ssh_keygen=SSH_KEYGEN,
            required_owner_uid=os.geteuid(),
        )

    def test_accepts_a_root_owned_signed_bundle_without_authorizing_execution(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            installed = self.install_valid_bundle(module, root, high_water_path)
            decision = self.load_bundle(module, root, high_water_path)
        self.assertEqual(decision["status"], "owner-pinned-driver-trust-valid")
        self.assertEqual(decision["execution_authorization"], "not-granted")
        self.assertEqual(decision["g5_result"], "not-assessed")
        self.assertEqual(decision["driver_login"], "driver-login")
        self.assertEqual(decision["driver_key_fingerprint"], installed["driver_fingerprint"])
        self.assertEqual(decision["trust_version"], 1)
        self.assertEqual(set(decision["trust_bundle"]), {"allowed_signers", "driver_registry", "revocations"})

    def test_rejects_tampering_rollback_and_owner_signature_mismatch(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            installed = self.install_valid_bundle(module, root, high_water_path)
            cases: list[tuple[str, object]] = []

            tampered = root / "driver-registry.json"
            original_registry = tampered.read_bytes()
            tampered.write_bytes(original_registry + b"\n")
            cases.append(("trust-file-tamper", None))
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)
            tampered.write_bytes(original_registry)

            state = json.loads(high_water_path.read_text(encoding="utf-8"))
            state["version"] = 0
            high_water_path.write_bytes(module.canonical_bytes(state))
            cases.append(("rollback-state", None))
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)
            state["version"] = 1
            high_water_path.write_bytes(module.canonical_bytes(state))

            manifest = copy.deepcopy(installed["manifest"])
            assert isinstance(manifest, dict)
            owner = manifest["owner"]
            assert isinstance(owner, dict)
            owner["key_fingerprint"] = "SHA256:" + "A" * 43
            (root / "manifest.json").write_bytes(module.canonical_bytes(manifest))
            (root / "manifest.sig").write_bytes(
                self.sign_manifest(module, installed["owner_key"], manifest, root)
            )
            state["manifest_sha256"] = self.sha256((root / "manifest.json").read_bytes())
            high_water_path.write_bytes(module.canonical_bytes(state))
            cases.append(("owner-mismatch", None))
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)
        self.assertEqual([label for label, _ in cases], ["trust-file-tamper", "rollback-state", "owner-mismatch"])

    def test_rejects_expired_unsigned_or_untrusted_root_material(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            installed = self.install_valid_bundle(module, root, high_water_path)
            manifest = copy.deepcopy(installed["manifest"])
            assert isinstance(manifest, dict)
            manifest["expires_at"] = "2026-08-15T12:00:00Z"
            (root / "manifest.json").write_bytes(module.canonical_bytes(manifest))
            (root / "manifest.sig").write_bytes(self.sign_manifest(module, installed["owner_key"], manifest, root))
            state = json.loads(high_water_path.read_text(encoding="utf-8"))
            state["manifest_sha256"] = self.sha256((root / "manifest.json").read_bytes())
            high_water_path.write_bytes(module.canonical_bytes(state))
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)

            self.install_valid_bundle(module, root, high_water_path)
            (root / "manifest.sig").write_bytes(b"not an ssh signature")
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)

            self.install_valid_bundle(module, root, high_water_path)
            (root / "owner-allowed-signers").write_bytes(b"wrong-owner ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE5vdEFSZWFsS2V5\n")
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)

    def test_rejects_noncanonical_files_and_incorrect_owner_uid(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            self.install_valid_bundle(module, root, high_water_path)
            manifest_path = root / "manifest.json"
            manifest_path.write_bytes(manifest_path.read_bytes() + b"\n")
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)

            self.install_valid_bundle(module, root, high_water_path)
            with self.assertRaises(module.OwnerTrustError):
                module._load_owner_pinned_driver_trust_from_root(
                    root,
                    high_water_path=high_water_path,
                    trusted_now=TRUSTED_NOW,
                    ssh_keygen=SSH_KEYGEN,
                    required_owner_uid=os.geteuid() + 1,
                )

    def test_rejects_complete_old_bundle_when_separate_high_water_is_newer(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            self.install_valid_bundle(module, root, high_water_path)
            complete_old_bundle = {
                path.name: path.read_bytes()
                for path in root.iterdir()
                if path.is_file()
            }
            high_water_path.write_bytes(
                module.canonical_bytes(
                    {
                        "manifest_sha256": "f" * 64,
                        "schema_version": 1,
                        "version": 2,
                    }
                )
            )
            for name, contents in complete_old_bundle.items():
                (root / name).write_bytes(contents)
            with self.assertRaises(module.OwnerTrustError):
                self.load_bundle(module, root, high_water_path)

    def test_rejects_platforms_without_no_follow_support(self) -> None:
        module = self.load_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "driver-trust"
            high_water_path = Path(temporary) / "state" / "driver-trust-high-water.json"
            self.install_valid_bundle(module, root, high_water_path)
            with mock.patch.object(module.os, "O_NOFOLLOW", 0):
                with self.assertRaises(module.OwnerTrustError):
                    self.load_bundle(module, root, high_water_path)

    def test_public_entry_has_no_caller_supplied_bundle_or_path(self) -> None:
        module = self.load_module()
        if module is None:
            return
        parameters = set(inspect.signature(module.load_owner_pinned_driver_trust).parameters)
        self.assertNotIn("root", parameters)
        self.assertNotIn("trust_bundle", parameters)
        self.assertNotIn("allowed_signers", parameters)
        self.assertNotIn("ssh_keygen", parameters)
        self.assertEqual(parameters, {"trusted_now"})
        self.assertEqual(module.OWNER_NAMESPACE, "floorp-notes-sync-g5-driver-trust-v1")
        self.assertEqual(
            module.OWNER_HIGH_WATER_PATH,
            Path("/private/var/db/floorp-notes-sync/driver-trust-high-water.json"),
        )
        source = MODULE_PATH.read_text(encoding="utf-8")
        self.assertNotIn("importlib", source)
        self.assertNotIn("exec_module", source)
        self.assertNotIn("floorp_notes_sync_g5_driver_admission", source)


if __name__ == "__main__":
    unittest.main()
