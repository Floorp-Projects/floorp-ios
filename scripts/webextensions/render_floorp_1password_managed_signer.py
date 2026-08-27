#!/usr/bin/env python3
"""Render a pinned, non-exporting 1Password SSH-agent catalog signer.

The output is an owner-controlled executable outside the source checkout. It
contains only the public root/leaf keys, stable key IDs, and the two allowed
purposes.  It contains no private key and is later pinned by SHA-256 when
``sign_curated_catalog.py`` invokes it.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ROOT_CERTIFICATE_PURPOSE = "floorp-curated-catalog/root-leaf-certificate/v1"
CATALOG_SIGNATURE_PURPOSE = "floorp-curated-catalog/leaf-catalog/v1"
CONFIGURATION_PLACEHOLDER = b"__FLOORP_CATALOG_SIGNER_CONFIGURATION_V1__"
KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,96}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = Path(__file__).with_name("floorp_1password_ssh_agent_signer.py")


class RenderError(RuntimeError):
    """The public signer configuration cannot safely be rendered."""


def _require_owner_controlled_directory(directory: Path) -> Path:
    """Return a safe resolved output parent or reject a path-replacement race."""

    try:
        resolved = directory.resolve(strict=True)
    except OSError as error:
        raise RenderError("managed signer output parent must already exist") from error
    expected_uid = os.geteuid()
    current = resolved
    while True:
        try:
            metadata = current.stat()
        except OSError as error:
            raise RenderError("cannot inspect managed signer output parent") from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise RenderError("managed signer output parent must be a directory")
        if metadata.st_uid not in {0, expected_uid}:
            raise RenderError("managed signer output parent must be owner-controlled")
        writable_by_group_or_other = metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        root_sticky_directory = metadata.st_uid == 0 and bool(metadata.st_mode & stat.S_ISVTX)
        if writable_by_group_or_other and not root_sticky_directory:
            raise RenderError("managed signer output parent must be owner-controlled")
        if current.parent == current:
            return resolved
        current = current.parent


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def base64url_bytes(value: str, *, label: str) -> bytes:
    if re.fullmatch(r"[A-Za-z0-9_-]+", value) is None:
        raise RenderError(f"{label} must be canonical base64url")
    try:
        decoded = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except (TypeError, ValueError) as error:
        raise RenderError(f"{label} must be canonical base64url") from error
    if len(decoded) != 32 or base64url(decoded) != value:
        raise RenderError(f"{label} must be a canonical raw 32-byte public key")
    return decoded


def safe_key_id(value: str, *, label: str) -> str:
    if KEY_ID.fullmatch(value) is None:
        raise RenderError(f"{label} is not a safe key ID")
    return value


def build_configuration(
    *,
    root_key_id: str,
    root_public_key: str,
    leaf_key_id: str,
    leaf_public_key: str,
    expected_root_public_key_sha256: str,
) -> bytes:
    root_key_id = safe_key_id(root_key_id, label="root key ID")
    leaf_key_id = safe_key_id(leaf_key_id, label="leaf key ID")
    root = base64url_bytes(root_public_key, label="root public key")
    leaf = base64url_bytes(leaf_public_key, label="leaf public key")
    if root_key_id == leaf_key_id or root == leaf:
        raise RenderError("root and leaf signing identities must be distinct")
    if SHA256.fullmatch(expected_root_public_key_sha256) is None:
        raise RenderError("expected root public-key SHA-256 is invalid")
    if hashlib.sha256(root).hexdigest() != expected_root_public_key_sha256:
        raise RenderError("root public key does not match the approved trust-anchor digest")
    return canonical_json({
        "keys": [
            {
                "keyID": root_key_id,
                "publicKey": root_public_key,
                "purpose": ROOT_CERTIFICATE_PURPOSE,
                "role": "root",
            },
            {
                "keyID": leaf_key_id,
                "publicKey": leaf_public_key,
                "purpose": CATALOG_SIGNATURE_PURPOSE,
                "role": "leaf",
            },
        ],
        "schemaVersion": SCHEMA_VERSION,
    })


def _require_output_outside_checkout(output: Path) -> Path:
    if not output.is_absolute():
        raise RenderError("managed signer output must use an absolute path")
    if output.is_symlink():
        raise RenderError("managed signer output must not be a symlink")
    resolved = output.resolve()
    try:
        resolved.relative_to(REPOSITORY_ROOT)
    except ValueError:
        pass
    else:
        raise RenderError("managed signer output must be outside the source checkout")
    if resolved.exists() or resolved.is_symlink():
        raise RenderError("managed signer renderer refuses to overwrite output")
    _require_owner_controlled_directory(resolved.parent)
    return resolved


def _write_new_executable(path: Path, data: bytes) -> None:
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o700)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o700)
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        try:
            path.unlink()
        except OSError:
            pass
        raise RenderError("cannot create managed signer output") from error


def render(
    *,
    output: Path,
    root_key_id: str,
    root_public_key: str,
    leaf_key_id: str,
    leaf_public_key: str,
    expected_root_public_key_sha256: str,
) -> dict[str, str]:
    configuration = build_configuration(
        root_key_id=root_key_id,
        root_public_key=root_public_key,
        leaf_key_id=leaf_key_id,
        leaf_public_key=leaf_public_key,
        expected_root_public_key_sha256=expected_root_public_key_sha256,
    )
    try:
        template = TEMPLATE.read_bytes()
    except OSError as error:
        raise RenderError("cannot read checked-in managed signer template") from error
    if template.count(CONFIGURATION_PLACEHOLDER) != 1:
        raise RenderError("managed signer template has an invalid configuration marker")
    rendered = template.replace(CONFIGURATION_PLACEHOLDER, base64url(configuration).encode("ascii"))
    if CONFIGURATION_PLACEHOLDER in rendered:
        raise RenderError("managed signer configuration was not rendered")
    target = _require_output_outside_checkout(output)
    _write_new_executable(target, rendered)
    return {
        "adapterSHA256": hashlib.sha256(rendered).hexdigest(),
        "output": str(target),
        "rootPublicKeySHA256": expected_root_public_key_sha256,
        "status": "rendered",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--root-key-id", required=True)
    parser.add_argument("--root-public-key", required=True)
    parser.add_argument("--leaf-key-id", required=True)
    parser.add_argument("--leaf-public-key", required=True)
    parser.add_argument("--expected-root-public-key-sha256", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        result = render(
            output=arguments.output,
            root_key_id=arguments.root_key_id,
            root_public_key=arguments.root_public_key,
            leaf_key_id=arguments.leaf_key_id,
            leaf_public_key=arguments.leaf_public_key,
            expected_root_public_key_sha256=arguments.expected_root_public_key_sha256,
        )
    except (RenderError, OSError, ValueError) as error:
        print(f"1Password managed signer rendering failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
