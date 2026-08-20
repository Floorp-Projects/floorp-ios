"""Fail-closed verifier for a future signed G5 external-driver admission.

This module validates caller-supplied public metadata and an SSH detached
signature. It never starts a runner, invokes a driver, receives credentials,
launches a client, contacts FxA/Sync, or turns a valid admission into G5
authorization. Production callers must separately pin an owner-approved trust
bundle before they may use this library for an actual-run path.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Mapping


NAMESPACE = "floorp-notes-sync-g5-driver-admission-v1"
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_DOCUMENT_BYTES = 256 * 1024
MAX_JSON_DEPTH = 16
MAX_LEASE = timedelta(hours=1)
EXPECTED_REPOSITORY = "Floorp-Projects/floorp-ios"
EXPECTED_WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
EXPECTED_DRIVER_INTERFACE = "metadata-only-g5-receipt-v1"
DRIVER_ROLE = "driver-admission"
MAX_SIGNATURE_BYTES = 16 * 1024
MAX_ALLOWED_SIGNERS = 1
SSH_KEYGEN_TIMEOUT_SECONDS = 5
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
FINGERPRINT = re.compile(r"SHA256:[A-Za-z0-9+/]{43}\Z")
LOGIN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\Z")
LEASE_ID = re.compile(r"g5-driver-lease-[0-9a-f]{16}\Z")
SSH_SIGNATURE_ARMOR = re.compile(
    r"\A-----BEGIN SSH SIGNATURE-----\n(?:[A-Za-z0-9+/=]+\n)+-----END SSH SIGNATURE-----\n\Z"
)
FORBIDDEN_FIELD_PARTS = frozenset(
    {
        "authorization",
        "body",
        "content",
        "cookie",
        "credential",
        "key",
        "note",
        "password",
        "payload",
        "secret",
        "session",
        "token",
    }
)
# These are names required by the strictly validated, public schema below.
# Do not add broad key-name exemptions here: this recursive screen is a
# defense-in-depth guard against accidentally carrying account or session data.
SAFE_FIELD_PATHS = frozenset(
    {
        ("signer", "key_fingerprint"),
    }
)
DANGEROUS_VALUE = re.compile(
    r"(?:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|://|[?#]|\b(?:authorization|bearer|oauth|token|cookie|password|credential|secret)\b)",
    re.IGNORECASE,
)


class DriverAdmissionError(ValueError):
    """A signed external-driver admission is malformed, untrusted, or unsafe."""


def reject(message: str) -> None:
    raise DriverAdmissionError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        reject(message)


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def field_parts(name: str) -> tuple[str, ...]:
    expanded = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower().replace("-", "_")
    return tuple(part for part in expanded.split("_") if part)


def reject_sensitive_values(
    value: Any,
    *,
    path: tuple[str, ...] = (),
    depth: int = 0,
) -> None:
    require(depth <= MAX_JSON_DEPTH, "admission exceeds the nesting-depth limit")
    if type(value) is dict:
        for key, child in value.items():
            require(type(key) is str, "admission has a non-string field name")
            child_path = (*path, key)
            require(
                child_path in SAFE_FIELD_PATHS
                or not any(part in FORBIDDEN_FIELD_PARTS for part in field_parts(key)),
                "admission contains a credential or content-like field",
            )
            reject_sensitive_values(child, path=child_path, depth=depth + 1)
        return
    if type(value) is list:
        for child in value:
            reject_sensitive_values(child, path=path, depth=depth + 1)
        return
    if type(value) is str:
        require(not DANGEROUS_VALUE.search(value), "admission contains a dangerous value")


def validate_json_domain(value: Any, *, depth: int = 0) -> None:
    require(depth <= MAX_JSON_DEPTH, "admission exceeds the nesting-depth limit")
    if value is None or type(value) is bool:
        return
    if type(value) is int:
        require(abs(value) <= MAX_SAFE_INTEGER, "admission integer exceeds the interoperable range")
        return
    if type(value) is str:
        require(
            all(not 0xD800 <= ord(character) <= 0xDFFF for character in value),
            "admission contains an unpaired Unicode surrogate",
        )
        return
    if type(value) is list:
        for child in value:
            validate_json_domain(child, depth=depth + 1)
        return
    if type(value) is dict:
        for key, child in value.items():
            require(type(key) is str, "admission JSON object has a non-string key")
            validate_json_domain(key, depth=depth + 1)
            validate_json_domain(child, depth=depth + 1)
        return
    reject(f"admission has unsupported JSON type {type(value).__name__}")


def canonical_bytes(value: Any) -> bytes:
    """Encode a strict RFC-8785-compatible subset used by this contract."""
    validate_json_domain(value)
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
        return b"[" + b",".join(canonical_bytes(child) for child in value) + b"]"
    if type(value) is dict:
        ordered = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return b"{" + b",".join(
            canonical_bytes(key) + b":" + canonical_bytes(value[key]) for key in ordered
        ) + b"}"
    reject(f"admission cannot encode {type(value).__name__}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            reject("admission contains a duplicate JSON field")
        result[key] = value
    return result


def reject_float(_: str) -> None:
    reject("admission must not contain floating-point values")


def reject_constant(_: str) -> None:
    reject("admission must not contain non-finite JSON constants")


def parse_driver_admission_bytes(raw: bytes) -> dict[str, Any]:
    require(type(raw) is bytes, "admission bytes must be immutable bytes")
    require(bool(raw), "admission is empty")
    require(len(raw) <= MAX_DOCUMENT_BYTES, "admission exceeds the size limit")
    try:
        document = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise DriverAdmissionError("admission is not valid UTF-8 JSON") from error
    require(type(document) is dict, "admission root must be an object")
    require(raw == canonical_bytes(document), "admission JSON bytes are not canonical")
    return document


def exact_object(value: Any, fields: frozenset[str], label: str) -> dict[str, Any]:
    require(type(value) is dict, f"{label} must be a plain JSON object")
    require(set(value) == fields, f"{label} fields are not exact")
    return value


def plain_sha(value: Any, length: int, label: str) -> str:
    pattern = SHA1 if length == 40 else SHA256
    require(type(value) is str and pattern.fullmatch(value) is not None, f"{label} is not a lowercase SHA")
    return value


def positive_int(value: Any, label: str) -> int:
    require(type(value) is int and 0 < value <= MAX_SAFE_INTEGER, f"{label} must be a positive safe integer")
    return value


def parse_timestamp(value: Any, label: str) -> datetime:
    require(type(value) is str and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is not None, f"{label} is not whole-second RFC3339 UTC")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise DriverAdmissionError(f"{label} is not a valid timestamp") from error


def canonical_run_binding(value: Any, label: str) -> dict[str, object]:
    binding = exact_object(
        value,
        frozenset({"head_sha", "repository", "run_attempt", "run_id", "workflow_path"}),
        label,
    )
    require(binding["repository"] == EXPECTED_REPOSITORY, f"{label} repository is not floorp-ios")
    require(binding["workflow_path"] == EXPECTED_WORKFLOW_PATH, f"{label} workflow path is not canonical")
    return {
        "head_sha": plain_sha(binding["head_sha"], 40, f"{label}.head_sha"),
        "repository": EXPECTED_REPOSITORY,
        "run_attempt": positive_int(binding["run_attempt"], f"{label}.run_attempt"),
        "run_id": positive_int(binding["run_id"], f"{label}.run_id"),
        "workflow_path": EXPECTED_WORKFLOW_PATH,
    }


def require_same_run(left: dict[str, object], right: Any, label: str) -> None:
    require(left == canonical_run_binding(right, label), f"{label} does not match the expected workflow run")


def canonical_release_binding(value: Any, label: str) -> dict[str, str]:
    release = exact_object(
        value,
        frozenset({"g1_g4_digest_sha256", "release_inputs_sha256"}),
        label,
    )
    return {
        "g1_g4_digest_sha256": plain_sha(
            release["g1_g4_digest_sha256"], 64, f"{label}.g1_g4_digest_sha256"
        ),
        "release_inputs_sha256": plain_sha(
            release["release_inputs_sha256"], 64, f"{label}.release_inputs_sha256"
        ),
    }


def require_same_release(left: dict[str, str], right: Any, label: str) -> None:
    require(
        left == canonical_release_binding(right, label),
        f"{label} does not match the expected G1-G4 and release-input bindings",
    )


def validate_payload(value: Any, expected_run_binding: Any, trusted_now: datetime) -> dict[str, Any]:
    payload = exact_object(
        value,
        frozenset({"driver", "lease", "release", "run_binding", "schema_version", "signer"}),
        "driver admission payload",
    )
    require(type(payload["schema_version"]) is int and payload["schema_version"] == 1, "driver admission schema is unsupported")

    driver = exact_object(payload["driver"], frozenset({"binary_sha256", "interface"}), "driver")
    binary_sha256 = plain_sha(driver["binary_sha256"], 64, "driver.binary_sha256")
    require(driver["interface"] == EXPECTED_DRIVER_INTERFACE, "driver interface is not metadata-only G5 receipt v1")

    lease = exact_object(
        payload["lease"],
        frozenset({"ephemeral", "expires_at", "id", "issued_at", "watchdog_cleanup_required"}),
        "driver lease",
    )
    require(lease["ephemeral"] is True, "driver lease is not ephemeral")
    require(lease["watchdog_cleanup_required"] is True, "driver lease lacks an independent cleanup watchdog")
    require(type(lease["id"]) is str and LEASE_ID.fullmatch(lease["id"]) is not None, "driver lease ID is malformed")
    issued_at = parse_timestamp(lease["issued_at"], "driver lease issued_at")
    expires_at = parse_timestamp(lease["expires_at"], "driver lease expires_at")
    require(issued_at <= trusted_now, "driver lease is from the future")
    require(expires_at > issued_at, "driver lease expiration does not follow issuance")
    require(expires_at <= issued_at + MAX_LEASE, "driver lease exceeds the maximum lifetime")
    require(trusted_now < expires_at, "driver lease is expired")

    release_binding = canonical_release_binding(payload["release"], "driver release binding")

    run_binding = canonical_run_binding(payload["run_binding"], "driver run binding")
    require_same_run(run_binding, expected_run_binding, "driver run binding")

    signer = exact_object(
        payload["signer"],
        frozenset({"github_login", "key_fingerprint", "role"}),
        "driver signer",
    )
    require(signer["role"] == DRIVER_ROLE, "driver signer role is not canonical")
    require(type(signer["github_login"]) is str and LOGIN.fullmatch(signer["github_login"]) is not None, "driver signer login is malformed")
    require(type(signer["key_fingerprint"]) is str and FINGERPRINT.fullmatch(signer["key_fingerprint"]) is not None, "driver signer fingerprint is malformed")

    return {
        "binary_sha256": binary_sha256,
        "lease": {
            "expires_at": lease["expires_at"],
            "id": lease["id"],
            "issued_at": lease["issued_at"],
        },
        "release": release_binding,
        "run_binding": run_binding,
        "signer": {
            "github_login": signer["github_login"],
            "key_fingerprint": signer["key_fingerprint"],
            "role": DRIVER_ROLE,
        },
    }


def parse_trust_json(raw: bytes, label: str) -> dict[str, Any]:
    require(type(raw) is bytes and bool(raw), f"{label} is unavailable")
    require(len(raw) <= MAX_DOCUMENT_BYTES, f"{label} exceeds the size limit")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise DriverAdmissionError(f"{label} is not valid UTF-8 JSON") from error
    require(type(value) is dict, f"{label} root must be an object")
    require(raw == canonical_bytes(value), f"{label} JSON bytes are not canonical")
    return value


def load_registry(raw: bytes) -> tuple[str, str]:
    registry = parse_trust_json(raw, "driver signer registry")
    root = exact_object(registry, frozenset({"driver_registry", "schema_version"}), "driver signer registry")
    require(type(root["schema_version"]) is int and root["schema_version"] == 1, "driver signer registry schema is unsupported")
    entries = root["driver_registry"]
    require(type(entries) is list and len(entries) == 1, "driver signer registry must contain exactly one driver-admission role")
    entry = exact_object(
        entries[0],
        frozenset({"authority", "key_fingerprint", "login", "role"}),
        "driver signer registry entry",
    )
    require(entry["role"] == DRIVER_ROLE, "driver signer registry role is not canonical")
    require(type(entry["authority"]) is str and bool(entry["authority"]), "driver signer authority is empty")
    require(type(entry["login"]) is str and LOGIN.fullmatch(entry["login"]) is not None, "driver signer registry login is malformed")
    require(type(entry["key_fingerprint"]) is str and FINGERPRINT.fullmatch(entry["key_fingerprint"]) is not None, "driver signer registry fingerprint is malformed")
    return entry["login"], entry["key_fingerprint"]


def load_revocations(raw: bytes, trusted_now: datetime) -> tuple[set[str], set[str]]:
    registry = parse_trust_json(raw, "driver admission revocations")
    root = exact_object(registry, frozenset({"revocations", "schema_version"}), "driver admission revocations")
    require(type(root["schema_version"]) is int and root["schema_version"] == 1, "driver admission revocations schema is unsupported")
    entries = root["revocations"]
    require(type(entries) is list, "driver admission revocations must be an array")
    revoked_keys: set[str] = set()
    revoked_admissions: set[str] = set()
    seen: set[tuple[str, str]] = set()
    for index, value in enumerate(entries):
        entry = exact_object(value, frozenset({"identifier", "kind", "reason", "revoked_at"}), f"driver revocation[{index}]")
        kind = entry["kind"]
        identifier = entry["identifier"]
        require(kind in ("admission", "key"), f"driver revocation[{index}] has unknown kind")
        require(type(entry["reason"]) is str and bool(entry["reason"]), f"driver revocation[{index}] reason is empty")
        require(parse_timestamp(entry["revoked_at"], f"driver revocation[{index}] revoked_at") <= trusted_now, f"driver revocation[{index}] is from the future")
        if kind == "key":
            require(type(identifier) is str and FINGERPRINT.fullmatch(identifier) is not None, f"driver revocation[{index}] key fingerprint is malformed")
            revoked_keys.add(identifier)
        else:
            require(type(identifier) is str and SHA256.fullmatch(identifier) is not None, f"driver revocation[{index}] admission digest is malformed")
            revoked_admissions.add(identifier)
        require((kind, identifier) not in seen, f"driver revocation[{index}] is duplicated")
        seen.add((kind, identifier))
    return revoked_keys, revoked_admissions


def signer_fingerprint(ssh_keygen: Path, key_type: str, key_value: str) -> str:
    with tempfile.TemporaryDirectory() as temporary:
        public_key = Path(temporary) / "driver-admission.pub"
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
            raise DriverAdmissionError("driver allowed-signers fingerprint lookup timed out") from error
    require(result.returncode == 0, "driver allowed-signers has an invalid public key")
    fields = result.stdout.split()
    require(len(fields) >= 2 and FINGERPRINT.fullmatch(fields[1]) is not None, "driver allowed-signers fingerprint could not be read")
    return fields[1]


def load_allowed_signers(raw: bytes, ssh_keygen: Path) -> list[tuple[set[str], str, str]]:
    require(type(raw) is bytes and bool(raw), "driver allowed-signers is unavailable")
    require(len(raw) <= MAX_DOCUMENT_BYTES, "driver allowed-signers exceeds the size limit")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise DriverAdmissionError("driver allowed-signers is not UTF-8") from error
    signers: list[tuple[set[str], str, str]] = []
    for number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        require(
            len(signers) < MAX_ALLOWED_SIGNERS,
            "driver allowed-signers must contain exactly one driver-admission trust anchor",
        )
        fields = line.split()
        require(len(fields) == 3, f"driver allowed-signers line {number} is malformed")
        principals, key_type, key_value = fields
        require(key_type == "ssh-ed25519", f"driver allowed-signers line {number} is not Ed25519")
        require(re.fullmatch(r"[A-Za-z0-9+/=]+", key_value) is not None, f"driver allowed-signers line {number} key is malformed")
        principal_set = set(principals.split(","))
        require(all(LOGIN.fullmatch(principal) is not None for principal in principal_set), f"driver allowed-signers line {number} has an invalid principal")
        signers.append((principal_set, signer_fingerprint(ssh_keygen, key_type, key_value), line))
    require(
        len(signers) == MAX_ALLOWED_SIGNERS,
        "driver allowed-signers must contain exactly one driver-admission trust anchor",
    )
    return signers


def signature_armor_bytes(signature: Any) -> bytes:
    require(type(signature) is str, "driver admission signature must be text")
    try:
        signature_bytes = signature.encode("ascii")
    except UnicodeEncodeError as error:
        raise DriverAdmissionError("driver admission signature is not ASCII") from error
    require(
        bool(signature_bytes) and len(signature_bytes) <= MAX_SIGNATURE_BYTES,
        "driver admission signature exceeds the size limit",
    )
    require(
        SSH_SIGNATURE_ARMOR.fullmatch(signature) is not None,
        "driver admission signature armor is malformed",
    )
    return signature_bytes


def verify_signature(
    payload: dict[str, Any],
    signature_bytes: bytes,
    trusted_lines: list[str],
    ssh_keygen: Path,
) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        allowed = directory / "allowed-signers"
        signature_path = directory / "driver-admission.sig"
        allowed.write_text("\n".join(trusted_lines) + "\n", encoding="utf-8")
        signature_path.write_bytes(signature_bytes)
        try:
            result = subprocess.run(
                [
                    str(ssh_keygen),
                    "-Y",
                    "verify",
                    "-f",
                    str(allowed),
                    "-I",
                    payload["signer"]["github_login"],
                    "-n",
                    NAMESPACE,
                    "-s",
                    str(signature_path),
                ],
                input=canonical_bytes(payload),
                capture_output=True,
                check=False,
                timeout=SSH_KEYGEN_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise DriverAdmissionError("driver admission signature verification timed out") from error
    require(result.returncode == 0, "driver admission has a bad detached signature")


def _validate_driver_admission(
    document: Any,
    *,
    trust_bundle: Mapping[str, bytes],
    expected_run_binding: Mapping[str, Any],
    expected_release_binding: Mapping[str, Any],
    trusted_now: datetime,
    ssh_keygen: Path,
) -> dict[str, object]:
    """Validate an already-parsed admission without granting authorization."""
    require(type(document) is dict, "driver admission must be a plain JSON object")
    root = exact_object(document, frozenset({"payload", "signature"}), "driver admission")
    reject_sensitive_values(root["payload"])
    signature_bytes = signature_armor_bytes(root["signature"])
    require(ssh_keygen == Path("/usr/bin/ssh-keygen") and ssh_keygen.is_file(), "driver admission requires the pinned ssh-keygen")
    require(type(trusted_now) is datetime and trusted_now.tzinfo is not None, "driver admission trusted clock is invalid")
    require(set(trust_bundle) == {"allowed_signers", "driver_registry", "revocations"}, "driver admission trust bundle is incomplete")
    payload = validate_payload(root["payload"], expected_run_binding, trusted_now.astimezone(timezone.utc))
    require_same_release(payload["release"], expected_release_binding, "driver release binding")
    registered_login, registered_fingerprint = load_registry(trust_bundle["driver_registry"])
    require(payload["signer"]["github_login"] == registered_login, "driver signer login is not registered")
    require(payload["signer"]["key_fingerprint"] == registered_fingerprint, "driver signer fingerprint is not registered")
    revoked_keys, revoked_admissions = load_revocations(trust_bundle["revocations"], trusted_now.astimezone(timezone.utc))
    require(payload["signer"]["key_fingerprint"] not in revoked_keys, "driver signer key is revoked")
    admission_digest = digest(root["payload"])
    require(admission_digest not in revoked_admissions, "driver admission is revoked")
    signers = load_allowed_signers(trust_bundle["allowed_signers"], ssh_keygen)
    trusted_lines = [
        line
        for principals, fingerprint, line in signers
        if payload["signer"]["github_login"] in principals and payload["signer"]["key_fingerprint"] == fingerprint
    ]
    require(bool(trusted_lines), "driver signer is not trusted together with its login and fingerprint")
    verify_signature(root["payload"], signature_bytes, trusted_lines, ssh_keygen)
    return {
        "admission_digest_sha256": admission_digest,
        "driver_binary_sha256": payload["binary_sha256"],
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
        "release_binding": payload["release"],
        "run_binding": payload["run_binding"],
        "status": "driver-admission-valid",
    }


def validate_driver_admission(
    raw: bytes,
    *,
    trust_bundle: Mapping[str, bytes],
    expected_run_binding: Mapping[str, Any],
    expected_release_binding: Mapping[str, Any],
    trusted_now: datetime,
    ssh_keygen: Path,
) -> dict[str, object]:
    """Apply the raw canonical-input boundary without granting G5 authorization.

    A future orchestration layer must call this raw-byte entry point rather
    than pre-parsing an admission. This routine remains metadata-only: it
    neither invokes nor authorizes an external driver.
    """

    return _validate_driver_admission(
        parse_driver_admission_bytes(raw),
        trust_bundle=trust_bundle,
        expected_run_binding=expected_run_binding,
        expected_release_binding=expected_release_binding,
        trusted_now=trusted_now,
        ssh_keygen=ssh_keygen,
    )
