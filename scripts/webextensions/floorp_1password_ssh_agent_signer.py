#!/usr/bin/python3
"""Template for the Floorp curated-catalog 1Password SSH-agent signer.

This file is deliberately *not* an executable signing authority as checked
in: its configuration placeholder is rendered into an owner-controlled file
outside the source checkout by ``render_floorp_1password_managed_signer.py``.
The rendered file contains only two public Ed25519 keys, their approved key
IDs, and the two catalog signing purposes.  It never reads, exports, or
serializes a private key.

The adapter speaks the managed-signer protocol on standard input/output and
the SSH-agent protocol only over the explicitly inherited ``SSH_AUTH_SOCK``.
It has no command-line arguments, does not enumerate agent identities, and
will ask the agent to sign only with the configured public key for its one
allowed purpose.
"""

from __future__ import annotations

# The managed-signing CLI runs this adapter with cwd=/ and a minimal
# environment.  Remove the adapter directory before importing anything that
# could otherwise be shadowed by a sibling file.
import sys

if sys.path:
    del sys.path[0]
sys.dont_write_bytecode = True

import base64
import hashlib
import json
import os
import re
import socket
import stat
import struct


SCHEMA_VERSION = 1
ROOT_CERTIFICATE_PURPOSE = "floorp-curated-catalog/root-leaf-certificate/v1"
CATALOG_SIGNATURE_PURPOSE = "floorp-curated-catalog/leaf-catalog/v1"
SSH_AGENTC_SIGN_REQUEST = 13
SSH_AGENT_SIGN_RESPONSE = 14
MAX_REQUEST_BYTES = 6 * 1024 * 1024
MAX_PAYLOAD_BYTES = 4 * 1024 * 1024
MAX_AGENT_RESPONSE_BYTES = 1024 * 1024
SOCKET_TIMEOUT_SECONDS = 25
KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,96}\Z")

# This exact token is replaced exactly once in the rendered adapter.  It is
# intentionally a public, canonical base64url configuration blob, never key
# material.  Do not run this unrendered template as a signing authority.
CONFIGURATION_BASE64 = "__FLOORP_CATALOG_SIGNER_CONFIGURATION_V1__"


class AdapterError(RuntimeError):
    """An untrusted adapter request or SSH-agent response was rejected."""


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _strict_json(data: bytes) -> object:
    def object_pairs_hook(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise AdapterError("duplicate JSON member")
            result[key] = value
        return result

    def reject_constant(_value: str) -> object:
        raise AdapterError("non-finite JSON value")

    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=object_pairs_hook,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, AdapterError) as error:
        raise AdapterError("request is not strict UTF-8 JSON") from error
    if _canonical_json(value) != data:
        raise AdapterError("request is not canonical JSON")
    return value


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _base64url_bytes(value: object, *, length: int | None, label: str) -> bytes:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise AdapterError(f"{label} is not canonical base64url")
    try:
        decoded = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except (ValueError, TypeError) as error:
        raise AdapterError(f"{label} is not canonical base64url") from error
    if (length is not None and len(decoded) != length) or _base64url(decoded) != value:
        raise AdapterError(f"{label} has an invalid length or encoding")
    return decoded


def _load_configuration() -> dict[str, dict[str, object]]:
    try:
        encoded = _base64url_bytes(CONFIGURATION_BASE64, length=None, label="embedded signer configuration")
    except AdapterError as error:
        raise AdapterError("adapter is not a rendered signer") from error
    if len(encoded) == 0 or len(encoded) > 16 * 1024:
        raise AdapterError("embedded signer configuration length is invalid")
    configuration = _strict_json(encoded)
    if not isinstance(configuration, dict) or set(configuration) != {"keys", "schemaVersion"}:
        raise AdapterError("embedded signer configuration shape is invalid")
    if configuration.get("schemaVersion") != SCHEMA_VERSION:
        raise AdapterError("embedded signer configuration schema is invalid")
    keys = configuration.get("keys")
    if not isinstance(keys, list) or len(keys) != 2:
        raise AdapterError("embedded signer configuration must contain two keys")

    expected_purposes = {
        "root": ROOT_CERTIFICATE_PURPOSE,
        "leaf": CATALOG_SIGNATURE_PURPOSE,
    }
    result: dict[str, dict[str, object]] = {}
    roles: set[str] = set()
    public_keys: set[bytes] = set()
    for entry in keys:
        if not isinstance(entry, dict) or set(entry) != {"keyID", "publicKey", "purpose", "role"}:
            raise AdapterError("embedded signer key shape is invalid")
        key_id = entry.get("keyID")
        role = entry.get("role")
        purpose = entry.get("purpose")
        if not isinstance(key_id, str) or KEY_ID.fullmatch(key_id) is None:
            raise AdapterError("embedded signer key ID is invalid")
        if role not in expected_purposes or purpose != expected_purposes[role]:
            raise AdapterError("embedded signer key purpose is invalid")
        public_key = _base64url_bytes(entry.get("publicKey"), length=32, label="embedded signer public key")
        if key_id in result or role in roles or public_key in public_keys:
            raise AdapterError("embedded signer configuration duplicates a key")
        result[key_id] = {"publicKey": public_key, "purpose": purpose, "role": role}
        roles.add(role)
        public_keys.add(public_key)
    if roles != {"root", "leaf"}:
        raise AdapterError("embedded signer configuration roles are incomplete")
    return result


def _ssh_string(value: bytes) -> bytes:
    return struct.pack(">I", len(value)) + value


def _read_ssh_string(value: bytes, offset: int) -> tuple[bytes, int]:
    if offset < 0 or len(value) - offset < 4:
        raise AdapterError("SSH agent response is truncated")
    length = struct.unpack(">I", value[offset:offset + 4])[0]
    start = offset + 4
    end = start + length
    if end < start or end > len(value):
        raise AdapterError("SSH agent response string is truncated")
    return value[start:end], end


def _read_exact(connection: socket.socket, length: int) -> bytes:
    data = bytearray()
    while len(data) < length:
        chunk = connection.recv(length - len(data))
        if not chunk:
            raise AdapterError("SSH agent closed an incomplete response")
        data.extend(chunk)
    return bytes(data)


def _agent_socket_path() -> str:
    value = os.environ.get("SSH_AUTH_SOCK")
    if not isinstance(value, str) or not value or not os.path.isabs(value):
        raise AdapterError("SSH agent socket is unavailable")
    try:
        metadata = os.stat(value)
    except OSError as error:
        raise AdapterError("SSH agent socket is unavailable") from error
    if (
        not stat.S_ISSOCK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise AdapterError("SSH agent socket is unsafe")
    return value


def _agent_sign(public_key: bytes, payload: bytes) -> bytes:
    key_blob = _ssh_string(b"ssh-ed25519") + _ssh_string(public_key)
    request = (
        bytes([SSH_AGENTC_SIGN_REQUEST])
        + _ssh_string(key_blob)
        + _ssh_string(payload)
        + struct.pack(">I", 0)
    )
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(SOCKET_TIMEOUT_SECONDS)
            connection.connect(_agent_socket_path())
            connection.sendall(struct.pack(">I", len(request)) + request)
            response_length = struct.unpack(">I", _read_exact(connection, 4))[0]
            if response_length == 0 or response_length > MAX_AGENT_RESPONSE_BYTES:
                raise AdapterError("SSH agent response length is invalid")
            response = _read_exact(connection, response_length)
    except (OSError, struct.error) as error:
        raise AdapterError("SSH agent signing operation failed") from error
    if not response or response[0] != SSH_AGENT_SIGN_RESPONSE:
        raise AdapterError("SSH agent declined the signing operation")
    signature_blob, end = _read_ssh_string(response, 1)
    if end != len(response):
        raise AdapterError("SSH agent response has trailing data")
    algorithm, offset = _read_ssh_string(signature_blob, 0)
    signature, offset = _read_ssh_string(signature_blob, offset)
    if offset != len(signature_blob) or algorithm != b"ssh-ed25519" or len(signature) != 64:
        raise AdapterError("SSH agent returned an invalid Ed25519 signature")
    return signature


def _request_response(configuration: dict[str, dict[str, object]]) -> dict[str, object]:
    data = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if not data or len(data) > MAX_REQUEST_BYTES:
        raise AdapterError("request length is invalid")
    request = _strict_json(data)
    if not isinstance(request, dict):
        raise AdapterError("request is not an object")
    operation = request.get("operation")
    if operation == "public-key":
        expected_fields = {"keyID", "operation", "schemaVersion"}
    elif operation == "sign":
        expected_fields = {"keyID", "operation", "payload", "purpose", "schemaVersion"}
    else:
        raise AdapterError("request operation is unsupported")
    if set(request) != expected_fields or request.get("schemaVersion") != SCHEMA_VERSION:
        raise AdapterError("request shape is invalid")
    key_id = request.get("keyID")
    if not isinstance(key_id, str) or KEY_ID.fullmatch(key_id) is None or key_id not in configuration:
        raise AdapterError("request key is not approved")
    key = configuration[key_id]
    public_key = key["publicKey"]
    if not isinstance(public_key, bytes):
        raise AdapterError("embedded signer key is invalid")
    response: dict[str, object] = {
        "keyID": key_id,
        "operation": operation,
        "publicKey": _base64url(public_key),
        "schemaVersion": SCHEMA_VERSION,
    }
    if operation == "public-key":
        return response

    purpose = request.get("purpose")
    if purpose != key["purpose"]:
        raise AdapterError("request purpose is not approved for this key")
    payload = _base64url_bytes(request.get("payload"), length=None, label="request payload")
    if len(payload) == 0 or len(payload) > MAX_PAYLOAD_BYTES:
        raise AdapterError("request payload length is invalid")
    signature = _agent_sign(public_key, payload)
    response["purpose"] = purpose
    response["signature"] = _base64url(signature)
    return response


def main() -> int:
    try:
        response = _request_response(_load_configuration())
        sys.stdout.buffer.write(_canonical_json(response))
        return 0
    except (AdapterError, OSError, ValueError, struct.error):
        # Do not disclose request, key, agent, or filesystem details on stdout
        # (which is a machine-checked protocol channel), or stderr (which can
        # become a release log).  The signing client reports a generic failure.
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
