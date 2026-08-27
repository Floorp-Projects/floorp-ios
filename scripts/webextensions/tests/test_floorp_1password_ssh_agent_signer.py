"""Integration tests for the fixed-purpose 1Password SSH-agent adapter."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey


SCRIPTS_DIRECTORY = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
RENDER_PATH = SCRIPTS_DIRECTORY / "render_floorp_1password_managed_signer.py"
SIGN_PATH = SCRIPTS_DIRECTORY / "sign_catalog.py"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


RENDER = load_module(RENDER_PATH, "floorp_render_1password_signer")
SIGN = load_module(SIGN_PATH, "floorp_sign_catalog_for_1password_test")

ROOT_ID = "floorp-ios-curated-root-2026-08"
LEAF_ID = "floorp-ios-curated-leaf-2026-08"


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def raw_public(key: Ed25519PrivateKey) -> bytes:
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def read_exact(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        part = connection.recv(length - len(result))
        if not part:
            raise RuntimeError("incomplete fake-agent request")
        result.extend(part)
    return bytes(result)


def ssh_string(value: bytes) -> bytes:
    return struct.pack(">I", len(value)) + value


def read_ssh_string(value: bytes, offset: int) -> tuple[bytes, int]:
    length = struct.unpack(">I", value[offset:offset + 4])[0]
    start = offset + 4
    return value[start:start + length], start + length


class FakeSSHAgent:
    """A tiny SSH-agent test double; it never handles production key material."""

    def __init__(self, socket_path: Path, keys: dict[bytes, Ed25519PrivateKey], *, malformed: bool = False) -> None:
        self.socket_path = socket_path
        self.keys = keys
        self.malformed = malformed
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(str(socket_path))
        os.chmod(socket_path, 0o700)
        self._server.listen(4)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._stop = threading.Event()
        self.requests = 0

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        try:
            self._server.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self._server.close()
        self._thread.join(timeout=5)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._server.accept()
            except OSError:
                return
            with connection:
                try:
                    length = struct.unpack(">I", read_exact(connection, 4))[0]
                    request = read_exact(connection, length)
                    if not request or request[0] != 13:
                        raise RuntimeError("unexpected fake-agent operation")
                    key_blob, offset = read_ssh_string(request, 1)
                    payload, offset = read_ssh_string(request, offset)
                    flags = struct.unpack(">I", request[offset:offset + 4])[0]
                    if flags != 0 or offset + 4 != len(request):
                        raise RuntimeError("unexpected fake-agent request shape")
                    algorithm, key_offset = read_ssh_string(key_blob, 0)
                    public_key, key_offset = read_ssh_string(key_blob, key_offset)
                    if algorithm != b"ssh-ed25519" or key_offset != len(key_blob):
                        raise RuntimeError("unexpected fake-agent key")
                    self.requests += 1
                    if self.malformed:
                        signature_blob = ssh_string(b"rsa-sha2-512") + ssh_string(b"x" * 64)
                    else:
                        signature_blob = ssh_string(b"ssh-ed25519") + ssh_string(self.keys[public_key].sign(payload))
                    response = bytes([14]) + ssh_string(signature_blob)
                except (KeyError, OSError, RuntimeError, struct.error):
                    response = bytes([5])
                connection.sendall(struct.pack(">I", len(response)) + response)


class OnePasswordSSHAgentSignerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Ed25519PrivateKey.generate()
        self.leaf = Ed25519PrivateKey.generate()
        self.root_raw = raw_public(self.root)
        self.leaf_raw = raw_public(self.leaf)
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temporary_root = Path(self.temporary_directory.name)
        self.adapter = self.temporary_root / "floorp-managed-signer"
        report = RENDER.render(
            output=self.adapter,
            root_key_id=ROOT_ID,
            root_public_key=base64url(self.root_raw),
            leaf_key_id=LEAF_ID,
            leaf_public_key=base64url(self.leaf_raw),
            expected_root_public_key_sha256=hashlib.sha256(self.root_raw).hexdigest(),
        )
        self.adapter_sha256 = report["adapterSHA256"]

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _adapter(self, request: dict[str, object], *, socket_path: Path | None = None) -> subprocess.CompletedProcess[bytes]:
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        if socket_path is not None:
            environment["SSH_AUTH_SOCK"] = str(socket_path)
        return subprocess.run(
            [str(self.adapter)],
            input=canonical_json(request),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )

    def test_rendered_adapter_binds_each_key_to_one_purpose_and_uses_ssh_agent(self) -> None:
        socket_path = self.temporary_root / "agent.sock"
        agent = FakeSSHAgent(socket_path, {self.root_raw: self.root, self.leaf_raw: self.leaf})
        agent.start()
        try:
            with mock.patch.dict(os.environ, {"SSH_AUTH_SOCK": str(socket_path)}, clear=False):
                root_signer = SIGN.ManagedEd25519Signer(
                    command=self.adapter,
                    command_sha256=self.adapter_sha256,
                    key_id=ROOT_ID,
                    environment_names=["SSH_AUTH_SOCK"],
                    timeout_seconds=30,
                )
                leaf_signer = SIGN.ManagedEd25519Signer(
                    command=self.adapter,
                    command_sha256=self.adapter_sha256,
                    key_id=LEAF_ID,
                    environment_names=["SSH_AUTH_SOCK"],
                    timeout_seconds=30,
                )
                self.assertEqual(root_signer.public_key_bytes(), self.root_raw)
                self.assertEqual(leaf_signer.public_key_bytes(), self.leaf_raw)
                root_signature = root_signer.sign(
                    b"leaf-certificate",
                    purpose=SIGN.ROOT_CERTIFICATE_PURPOSE,
                )
                leaf_signature = leaf_signer.sign(
                    b"catalog",
                    purpose=SIGN.CATALOG_SIGNATURE_PURPOSE,
                )
            Ed25519PublicKey.from_public_bytes(self.root_raw).verify(root_signature, b"leaf-certificate")
            Ed25519PublicKey.from_public_bytes(self.leaf_raw).verify(leaf_signature, b"catalog")
            self.assertEqual(agent.requests, 2)
        finally:
            agent.close()

    def test_adapter_rejects_unknown_key_wrong_purpose_and_malformed_agent_signature(self) -> None:
        unknown = self._adapter({"keyID": "unapproved", "operation": "public-key", "schemaVersion": 1})
        self.assertNotEqual(unknown.returncode, 0)
        wrong_purpose = self._adapter({
            "keyID": ROOT_ID,
            "operation": "sign",
            "payload": base64url(b"payload"),
            "purpose": SIGN.CATALOG_SIGNATURE_PURPOSE,
            "schemaVersion": 1,
        })
        self.assertNotEqual(wrong_purpose.returncode, 0)

        socket_path = self.temporary_root / "malformed-agent.sock"
        agent = FakeSSHAgent(socket_path, {self.root_raw: self.root}, malformed=True)
        agent.start()
        try:
            malformed = self._adapter({
                "keyID": ROOT_ID,
                "operation": "sign",
                "payload": base64url(b"payload"),
                "purpose": SIGN.ROOT_CERTIFICATE_PURPOSE,
                "schemaVersion": 1,
            }, socket_path=socket_path)
            self.assertNotEqual(malformed.returncode, 0)
        finally:
            agent.close()

    def test_unrendered_template_and_noncanonical_requests_fail_closed(self) -> None:
        template = SCRIPTS_DIRECTORY / "floorp_1password_ssh_agent_signer.py"
        unrendered = subprocess.run(
            ["/usr/bin/python3", str(template)],
            input=canonical_json({"keyID": ROOT_ID, "operation": "public-key", "schemaVersion": 1}),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            check=False,
        )
        self.assertNotEqual(unrendered.returncode, 0)
        noncanonical = subprocess.run(
            [str(self.adapter)],
            input=b'{"operation":"public-key","keyID":"' + ROOT_ID.encode("ascii") + b'","schemaVersion":1}',
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            check=False,
        )
        self.assertNotEqual(noncanonical.returncode, 0)

    def test_renderer_fails_closed_for_wrong_root_digest_checkout_output_and_overwrite(self) -> None:
        with self.assertRaisesRegex(RENDER.RenderError, "trust-anchor digest"):
            RENDER.build_configuration(
                root_key_id=ROOT_ID,
                root_public_key=base64url(self.root_raw),
                leaf_key_id=LEAF_ID,
                leaf_public_key=base64url(self.leaf_raw),
                expected_root_public_key_sha256="0" * 64,
            )
        with self.assertRaisesRegex(RENDER.RenderError, "outside the source checkout"):
            RENDER.render(
                output=RENDER.REPOSITORY_ROOT / "floorp-managed-signer",
                root_key_id=ROOT_ID,
                root_public_key=base64url(self.root_raw),
                leaf_key_id=LEAF_ID,
                leaf_public_key=base64url(self.leaf_raw),
                expected_root_public_key_sha256=hashlib.sha256(self.root_raw).hexdigest(),
            )
        with self.assertRaisesRegex(RENDER.RenderError, "refuses to overwrite"):
            RENDER.render(
                output=self.adapter,
                root_key_id=ROOT_ID,
                root_public_key=base64url(self.root_raw),
                leaf_key_id=LEAF_ID,
                leaf_public_key=base64url(self.leaf_raw),
                expected_root_public_key_sha256=hashlib.sha256(self.root_raw).hexdigest(),
            )

    def test_renderer_rejects_an_output_below_a_writable_parent(self) -> None:
        unsafe_parent = self.temporary_root / "unsafe-render-parent"
        unsafe_parent.mkdir()
        os.chmod(unsafe_parent, 0o777)
        try:
            with self.assertRaisesRegex(RENDER.RenderError, "owner-controlled"):
                RENDER.render(
                    output=unsafe_parent / "floorp-managed-signer",
                    root_key_id=ROOT_ID,
                    root_public_key=base64url(self.root_raw),
                    leaf_key_id=LEAF_ID,
                    leaf_public_key=base64url(self.leaf_raw),
                    expected_root_public_key_sha256=hashlib.sha256(self.root_raw).hexdigest(),
                )
        finally:
            os.chmod(unsafe_parent, 0o700)

    def test_managed_signer_rejects_an_executable_below_a_writable_parent(self) -> None:
        unsafe_parent = self.temporary_root / "unsafe-command-parent"
        unsafe_parent.mkdir()
        unsafe_adapter = unsafe_parent / "floorp-managed-signer"
        unsafe_adapter.write_bytes(self.adapter.read_bytes())
        os.chmod(unsafe_adapter, 0o700)
        os.chmod(unsafe_parent, 0o777)
        try:
            with self.assertRaisesRegex(SIGN.CatalogSigningError, "owner-controlled"):
                SIGN.ManagedEd25519Signer(
                    command=unsafe_adapter,
                    command_sha256=hashlib.sha256(unsafe_adapter.read_bytes()).hexdigest(),
                    key_id=ROOT_ID,
                    environment_names=[],
                    timeout_seconds=30,
                )
        finally:
            os.chmod(unsafe_parent, 0o700)

    def test_adapter_source_never_invokes_identity_enumeration_or_private_key_tools(self) -> None:
        source = (SCRIPTS_DIRECTORY / "floorp_1password_ssh_agent_signer.py").read_text(encoding="utf-8")
        self.assertNotIn("ssh-add", source)
        self.assertNotIn("ssh-keygen", source)
        self.assertNotIn("subprocess", source)


if __name__ == "__main__":
    unittest.main()
