"""Fail-closed loader for a root-owned G5 driver-trust bundle.

This module establishes only the source of trust for the separate driver
admission verifier. It neither receives credentials nor launches a runner,
client, browser, simulator, FxA flow, or Sync request. A successful result is
explicitly not execution authorization and cannot constitute G5 evidence.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Mapping


OWNER_TRUST_ROOT = Path("/opt/floorp-notes-sync/driver-trust")
OWNER_HIGH_WATER_PATH = Path("/private/var/db/floorp-notes-sync/driver-trust-high-water.json")
OWNER_NAMESPACE = "floorp-notes-sync-g5-driver-trust-v1"
AUTHORITY_DOMAIN = "floorp-notes-sync-g5-driver-trust-v1"
OWNER_ROLE = "g5-driver-trust-owner"
DRIVER_ROLE = "driver-admission"
PINNED_SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
MAX_FILE_BYTES = 256 * 1024
MAX_SIGNATURE_BYTES = 16 * 1024
MAX_VALIDITY = timedelta(days=90)
SSH_KEYGEN_TIMEOUT_SECONDS = 5
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
FINGERPRINT = re.compile(r"SHA256:[A-Za-z0-9+/]{43}=?\Z")
LOGIN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?\Z")
KEY_VALUE = re.compile(r"[A-Za-z0-9+/=]+\Z")
_REQUIRED_FILES = (
    "owner-allowed-signers",
    "manifest.json",
    "manifest.sig",
    "allowed-signers",
    "driver-registry.json",
    "revocations.json",
)


class OwnerTrustError(ValueError):
    """The driver-trust source is not independently owner-pinned."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise OwnerTrustError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise OwnerTrustError("owner trust JSON contains a duplicate member")
        result[key] = value
    return result


def reject_float(_: str) -> Any:
    raise OwnerTrustError("owner trust JSON contains a floating-point number")


def reject_constant(_: str) -> Any:
    raise OwnerTrustError("owner trust JSON contains a non-finite number")


def _validate_json_domain(value: Any) -> None:
    if value is None or type(value) is bool:
        return
    if type(value) is int:
        require(abs(value) <= 9_007_199_254_740_991, "owner trust integer exceeds the safe range")
        return
    if type(value) is str:
        require(
            all(not 0xD800 <= ord(character) <= 0xDFFF for character in value),
            "owner trust contains an unpaired Unicode surrogate",
        )
        return
    if type(value) is list:
        for item in value:
            _validate_json_domain(item)
        return
    if type(value) is dict:
        for key, item in value.items():
            require(type(key) is str, "owner trust contains a non-string JSON key")
            _validate_json_domain(key)
            _validate_json_domain(item)
        return
    raise OwnerTrustError(f"owner trust has unsupported JSON type {type(value).__name__}")


def canonical_bytes(value: Any) -> bytes:
    """Encode the restricted JCS-compatible JSON domain used by trust files."""

    _validate_json_domain(value)
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if type(value) is int:
        return str(value).encode("ascii")
    if type(value) is str:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if type(value) is list:
        return b"[" + b",".join(canonical_bytes(item) for item in value) + b"]"
    if type(value) is dict:
        keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return b"{" + b",".join(
            canonical_bytes(key) + b":" + canonical_bytes(value[key]) for key in keys
        ) + b"}"
    raise OwnerTrustError(f"owner trust cannot encode {type(value).__name__}")


def _parse_canonical_json(raw: bytes, label: str) -> dict[str, Any]:
    require(type(raw) is bytes and bool(raw), f"{label} is unavailable")
    require(len(raw) <= MAX_FILE_BYTES, f"{label} exceeds the size limit")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise OwnerTrustError(f"{label} is not valid UTF-8 JSON") from error
    require(type(value) is dict, f"{label} root must be an object")
    require(raw == canonical_bytes(value), f"{label} JSON bytes are not canonical")
    return value


def _exact_object(value: Any, expected: frozenset[str], label: str) -> Mapping[str, Any]:
    require(type(value) is dict, f"{label} must be an object")
    require(set(value) == expected, f"{label} fields are not exact")
    return value


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _require_sha(value: Any, label: str) -> str:
    require(type(value) is str and SHA256.fullmatch(value) is not None, f"{label} is not a SHA-256")
    return value


def _require_login(value: Any, label: str) -> str:
    require(type(value) is str and LOGIN.fullmatch(value) is not None, f"{label} is malformed")
    return value


def _require_fingerprint(value: Any, label: str) -> str:
    require(type(value) is str and FINGERPRINT.fullmatch(value) is not None, f"{label} is malformed")
    return value


def _parse_timestamp(value: Any, label: str) -> datetime:
    require(type(value) is str and value.endswith("Z"), f"{label} is not a UTC timestamp")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise OwnerTrustError(f"{label} is not RFC 3339 whole-second UTC") from error


def _secure_open_flags(*, directory: bool) -> int:
    no_follow = getattr(os, "O_NOFOLLOW", None)
    require(type(no_follow) is int and no_follow != 0, "owner trust requires O_NOFOLLOW support")
    flags = os.O_RDONLY | no_follow
    if directory:
        directory_flag = getattr(os, "O_DIRECTORY", None)
        require(type(directory_flag) is int and directory_flag != 0, "owner trust requires O_DIRECTORY support")
        flags |= directory_flag
    return flags


def _require_safe_directory(metadata: os.stat_result, label: str, required_owner_uid: int) -> None:
    require(stat.S_ISDIR(metadata.st_mode), f"{label} is not a directory")
    require(metadata.st_uid == required_owner_uid, f"{label} has the wrong owner")
    require(
        metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
        f"{label} is group/world writable",
    )


def _open_root_directory(
    root: Path, required_owner_uid: int, *, verify_ancestors: bool
) -> int:
    require(root.is_absolute(), "owner trust root must be absolute")
    flags = _secure_open_flags(directory=True)
    if not verify_ancestors:
        try:
            descriptor = os.open(root, flags)
        except OSError as error:
            raise OwnerTrustError("owner trust root is unavailable") from error
        try:
            _require_safe_directory(os.fstat(descriptor), "owner trust root", required_owner_uid)
            return descriptor
        except Exception:
            os.close(descriptor)
            raise
    try:
        descriptor = os.open(Path("/"), flags)
    except OSError as error:
        raise OwnerTrustError("owner trust filesystem root is unavailable") from error
    try:
        _require_safe_directory(os.fstat(descriptor), "owner trust filesystem root", required_owner_uid)
        for component in root.parts[1:]:
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                raise OwnerTrustError("owner trust root is unavailable") from error
            os.close(descriptor)
            descriptor = child
            _require_safe_directory(os.fstat(descriptor), "owner trust directory", required_owner_uid)
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _read_root_owned_regular(
    root_descriptor: int, name: str, required_owner_uid: int, label: str
) -> bytes:
    require(name and "/" not in name and name not in {".", ".."}, "owner trust requested an unsafe file")
    try:
        descriptor = os.open(name, _secure_open_flags(directory=False), dir_fd=root_descriptor)
    except OSError as error:
        raise OwnerTrustError(f"{label} is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode), f"{label} is not regular")
        require(metadata.st_uid == required_owner_uid, f"{label} has the wrong owner")
        require(
            metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0,
            f"{label} is group/world writable",
        )
        require(metadata.st_nlink == 1, f"{label} has unexpected hard links")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            total += len(chunk)
            require(total <= MAX_FILE_BYTES, f"{label} exceeds the size limit")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _read_high_water(
    path: Path, required_owner_uid: int, *, verify_ancestors: bool
) -> bytes:
    require(path.is_absolute(), "owner trust high-water path must be absolute")
    parent_descriptor = _open_root_directory(
        path.parent, required_owner_uid, verify_ancestors=verify_ancestors
    )
    try:
        return _read_root_owned_regular(
            parent_descriptor, path.name, required_owner_uid, "owner trust external high-water state"
        )
    finally:
        os.close(parent_descriptor)


def _fingerprint_public_key(key_type: str, key_value: str, ssh_keygen: Path) -> str:
    require(ssh_keygen == PINNED_SSH_KEYGEN and ssh_keygen.is_file(), "owner trust requires pinned ssh-keygen")
    with tempfile.TemporaryDirectory() as temporary:
        public_key = Path(temporary) / "trust-key.pub"
        public_key.write_text(f"{key_type} {key_value}\n", encoding="ascii")
        try:
            result = subprocess.run(
                [str(ssh_keygen), "-lf", str(public_key)],
                capture_output=True,
                text=True,
                check=False,
                timeout=SSH_KEYGEN_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise OwnerTrustError("owner trust fingerprint lookup timed out") from error
    require(result.returncode == 0, "owner trust public key is invalid")
    fields = result.stdout.split()
    require(len(fields) >= 2 and FINGERPRINT.fullmatch(fields[1]) is not None, "owner trust fingerprint is invalid")
    return fields[1]


def _load_single_allowed_signer(raw: bytes, label: str, ssh_keygen: Path) -> tuple[str, str, str]:
    require(type(raw) is bytes and bool(raw), f"{label} is unavailable")
    require(len(raw) <= MAX_FILE_BYTES, f"{label} exceeds the size limit")
    try:
        lines = [line.strip() for line in raw.decode("utf-8").splitlines() if line.strip()]
    except UnicodeDecodeError as error:
        raise OwnerTrustError(f"{label} is not UTF-8") from error
    require(len(lines) == 1, f"{label} must contain exactly one signer")
    fields = lines[0].split()
    require(len(fields) == 3, f"{label} is malformed")
    principal, key_type, key_value = fields
    require(
        "," not in principal and _require_login(principal, f"{label} principal") == principal,
        f"{label} must have one valid principal",
    )
    require(key_type == "ssh-ed25519", f"{label} must use Ed25519")
    require(KEY_VALUE.fullmatch(key_value) is not None, f"{label} key is malformed")
    return principal, _fingerprint_public_key(key_type, key_value, ssh_keygen), lines[0]


def _verify_owner_signature(
    manifest: Mapping[str, Any], signature: bytes, owner_line: str, ssh_keygen: Path
) -> None:
    require(ssh_keygen == PINNED_SSH_KEYGEN and ssh_keygen.is_file(), "owner trust requires pinned ssh-keygen")
    require(bool(signature) and len(signature) <= MAX_SIGNATURE_BYTES, "owner trust signature is invalid")
    try:
        signature.decode("ascii")
    except UnicodeDecodeError as error:
        raise OwnerTrustError("owner trust signature is not ASCII") from error
    owner = manifest["owner"]
    assert isinstance(owner, Mapping)
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        allowed = directory / "owner-allowed-signers"
        signature_path = directory / "manifest.sig"
        allowed.write_text(owner_line + "\n", encoding="ascii")
        signature_path.write_bytes(signature)
        try:
            result = subprocess.run(
                [
                    str(ssh_keygen),
                    "-Y",
                    "verify",
                    "-f",
                    str(allowed),
                    "-I",
                    str(owner["login"]),
                    "-n",
                    OWNER_NAMESPACE,
                    "-s",
                    str(signature_path),
                ],
                input=canonical_bytes(manifest),
                capture_output=True,
                check=False,
                timeout=SSH_KEYGEN_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise OwnerTrustError("owner trust signature verification timed out") from error
    require(result.returncode == 0, "owner trust has a bad detached signature")


def _validate_manifest(
    raw: bytes,
    *,
    owner_principal: str,
    owner_fingerprint: str,
    signature: bytes,
    owner_line: str,
    trusted_now: datetime,
    ssh_keygen: Path,
) -> dict[str, Any]:
    manifest = _parse_canonical_json(raw, "owner trust manifest")
    root = _exact_object(
        manifest,
        frozenset(
            {
                "authority_domain",
                "driver_signer",
                "expires_at",
                "files",
                "issued_at",
                "owner",
                "previous_manifest_sha256",
                "schema_version",
                "version",
            }
        ),
        "owner trust manifest",
    )
    require(root["authority_domain"] == AUTHORITY_DOMAIN, "owner trust authority domain is wrong")
    require(type(root["schema_version"]) is int and root["schema_version"] == 1, "owner trust schema is unsupported")
    require(type(root["version"]) is int and root["version"] > 0, "owner trust version is invalid")
    previous = root["previous_manifest_sha256"]
    if root["version"] == 1:
        require(previous is None, "owner trust v1 must not contain a previous digest")
    else:
        _require_sha(previous, "owner trust previous manifest digest")
    owner = _exact_object(root["owner"], frozenset({"key_fingerprint", "login", "role"}), "owner trust owner")
    require(owner["role"] == OWNER_ROLE, "owner trust owner role is not distinct")
    require(
        _require_login(owner["login"], "owner trust owner login") == owner_principal,
        "owner trust owner principal is not pinned",
    )
    require(
        _require_fingerprint(owner["key_fingerprint"], "owner trust owner fingerprint") == owner_fingerprint,
        "owner trust owner fingerprint is not pinned",
    )
    driver = _exact_object(root["driver_signer"], frozenset({"key_fingerprint", "login"}), "owner trust driver signer")
    driver_login = _require_login(driver["login"], "owner trust driver login")
    driver_fingerprint = _require_fingerprint(driver["key_fingerprint"], "owner trust driver fingerprint")
    require(driver_login != owner_principal, "owner and driver must use distinct principals")
    require(driver_fingerprint != owner_fingerprint, "owner and driver must use distinct keys")
    files = _exact_object(
        root["files"],
        frozenset({"allowed_signers_sha256", "driver_registry_sha256", "revocations_sha256"}),
        "owner trust file digests",
    )
    for field, value in files.items():
        _require_sha(value, f"owner trust {field}")
    issued_at = _parse_timestamp(root["issued_at"], "owner trust issued_at")
    expires_at = _parse_timestamp(root["expires_at"], "owner trust expires_at")
    now = trusted_now.astimezone(timezone.utc)
    require(issued_at <= now, "owner trust is from the future")
    require(expires_at > issued_at, "owner trust expires before it was issued")
    require(expires_at <= issued_at + MAX_VALIDITY, "owner trust validity exceeds the maximum")
    require(now < expires_at, "owner trust is expired")
    _verify_owner_signature(manifest, signature, owner_line, ssh_keygen)
    return dict(manifest)


def _validate_high_water(raw: bytes, manifest_raw: bytes, version: int) -> None:
    state = _parse_canonical_json(raw, "owner trust external high-water state")
    root = _exact_object(
        state,
        frozenset({"manifest_sha256", "schema_version", "version"}),
        "owner trust external high-water state",
    )
    require(type(root["schema_version"]) is int and root["schema_version"] == 1, "owner trust high-water schema is unsupported")
    require(type(root["version"]) is int and root["version"] == version, "owner trust high-water version does not match")
    require(
        _require_sha(root["manifest_sha256"], "owner trust high-water manifest digest") == _sha256(manifest_raw),
        "owner trust high-water manifest digest does not match",
    )


def _validate_revocations(raw: bytes, driver_fingerprint: str, trusted_now: datetime) -> None:
    document = _parse_canonical_json(raw, "owner trust revocations")
    root = _exact_object(document, frozenset({"revocations", "schema_version"}), "owner trust revocations")
    require(type(root["schema_version"]) is int and root["schema_version"] == 1, "owner trust revocation schema is unsupported")
    entries = root["revocations"]
    require(type(entries) is list, "owner trust revocations must be an array")
    seen: set[tuple[str, str]] = set()
    now = trusted_now.astimezone(timezone.utc)
    for index, item in enumerate(entries):
        entry = _exact_object(
            item,
            frozenset({"identifier", "kind", "reason", "revoked_at"}),
            f"owner trust revocation[{index}]",
        )
        require(entry["kind"] in {"admission", "key"}, f"owner trust revocation[{index}] kind is invalid")
        identifier = entry["identifier"]
        if entry["kind"] == "key":
            _require_fingerprint(identifier, f"owner trust revocation[{index}] key")
        else:
            _require_sha(identifier, f"owner trust revocation[{index}] admission")
        require(type(entry["reason"]) is str and bool(entry["reason"]), f"owner trust revocation[{index}] reason is empty")
        require(
            _parse_timestamp(entry["revoked_at"], f"owner trust revocation[{index}] time") <= now,
            f"owner trust revocation[{index}] is from the future",
        )
        marker = (entry["kind"], identifier)
        require(marker not in seen, f"owner trust revocation[{index}] is duplicated")
        seen.add(marker)
        require(
            not (entry["kind"] == "key" and identifier == driver_fingerprint),
            "owner trust driver key is revoked",
        )


def _validate_driver_bundle(
    bundle: Mapping[str, bytes], manifest: Mapping[str, Any], trusted_now: datetime, ssh_keygen: Path
) -> None:
    files = manifest["files"]
    assert isinstance(files, Mapping)
    expected = {
        "allowed_signers": files["allowed_signers_sha256"],
        "driver_registry": files["driver_registry_sha256"],
        "revocations": files["revocations_sha256"],
    }
    for name, expected_digest in expected.items():
        require(_sha256(bundle[name]) == expected_digest, f"owner trust {name} digest does not match")
    registry_document = _parse_canonical_json(bundle["driver_registry"], "owner trust driver registry")
    registry = _exact_object(
        registry_document, frozenset({"driver_registry", "schema_version"}), "owner trust driver registry"
    )
    require(type(registry["schema_version"]) is int and registry["schema_version"] == 1, "owner trust driver registry schema is unsupported")
    entries = registry["driver_registry"]
    require(type(entries) is list and len(entries) == 1, "owner trust must contain one driver registry entry")
    entry = _exact_object(
        entries[0],
        frozenset({"authority", "key_fingerprint", "login", "role"}),
        "owner trust driver registry entry",
    )
    require(entry["role"] == DRIVER_ROLE, "owner trust driver registry role is wrong")
    require(type(entry["authority"]) is str and bool(entry["authority"]), "owner trust driver authority is empty")
    driver = manifest["driver_signer"]
    assert isinstance(driver, Mapping)
    login = _require_login(entry["login"], "owner trust driver registry login")
    fingerprint = _require_fingerprint(entry["key_fingerprint"], "owner trust driver registry fingerprint")
    require(login == driver["login"], "owner trust driver registry login does not match")
    require(fingerprint == driver["key_fingerprint"], "owner trust driver registry fingerprint does not match")
    allowed_login, allowed_fingerprint, _ = _load_single_allowed_signer(
        bundle["allowed_signers"], "owner trust driver allowed-signers", ssh_keygen
    )
    require(allowed_login == login and allowed_fingerprint == fingerprint, "owner trust driver key is not pinned")
    _validate_revocations(bundle["revocations"], fingerprint, trusted_now)


def _load_owner_pinned_driver_trust_from_root(
    root: Path,
    *,
    high_water_path: Path,
    trusted_now: datetime,
    ssh_keygen: Path,
    required_owner_uid: int,
    verify_ancestors: bool = False,
) -> dict[str, object]:
    """Private testable loader; production uses the fixed public entry point."""

    require(type(trusted_now) is datetime and trusted_now.tzinfo is not None, "owner trust clock is invalid")
    require(type(required_owner_uid) is int and required_owner_uid >= 0, "owner trust owner UID is invalid")
    root_descriptor = _open_root_directory(root, required_owner_uid, verify_ancestors=verify_ancestors)
    try:
        raw = {
            name: _read_root_owned_regular(root_descriptor, name, required_owner_uid, f"owner trust {name}")
            for name in _REQUIRED_FILES
        }
    finally:
        os.close(root_descriptor)
    owner_principal, owner_fingerprint, owner_line = _load_single_allowed_signer(
        raw["owner-allowed-signers"], "owner trust owner allowed-signers", ssh_keygen
    )
    manifest = _validate_manifest(
        raw["manifest.json"],
        owner_principal=owner_principal,
        owner_fingerprint=owner_fingerprint,
        signature=raw["manifest.sig"],
        owner_line=owner_line,
        trusted_now=trusted_now,
        ssh_keygen=ssh_keygen,
    )
    _validate_high_water(
        _read_high_water(high_water_path, required_owner_uid, verify_ancestors=verify_ancestors),
        raw["manifest.json"],
        manifest["version"],
    )
    trust_bundle = {
        "allowed_signers": raw["allowed-signers"],
        "driver_registry": raw["driver-registry.json"],
        "revocations": raw["revocations.json"],
    }
    _validate_driver_bundle(trust_bundle, manifest, trusted_now, ssh_keygen)
    driver = manifest["driver_signer"]
    assert isinstance(driver, Mapping)
    return {
        "driver_key_fingerprint": driver["key_fingerprint"],
        "driver_login": driver["login"],
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
        "status": "owner-pinned-driver-trust-valid",
        "trust_bundle": trust_bundle,
        "trust_manifest_sha256": _sha256(raw["manifest.json"]),
        "trust_version": manifest["version"],
    }


def load_owner_pinned_driver_trust(*, trusted_now: datetime) -> dict[str, object]:
    """Load only the fixed, root-owned driver trust source.

    The public interface intentionally accepts neither a filesystem path nor
    arbitrary trust bytes. A future broker must independently provide the
    trusted clock and separately validate its run, binary, lease, and cleanup
    facts before it can consider execution.
    """

    return _load_owner_pinned_driver_trust_from_root(
        OWNER_TRUST_ROOT,
        high_water_path=OWNER_HIGH_WATER_PATH,
        trusted_now=trusted_now,
        ssh_keygen=PINNED_SSH_KEYGEN,
        required_owner_uid=0,
        verify_ancestors=True,
    )
