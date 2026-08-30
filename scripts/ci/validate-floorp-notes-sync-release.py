#!/usr/bin/python3 -I
"""Validate canonical Floorp Notes Sync G1-G6 release evidence."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import quote


EXPECTED_REPOSITORY = "Floorp-Projects/floorp-ios"
EXPECTED_WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-validation-clock.yml"
EXPECTED_SCHEMA_ID = "https://floorp.app/schemas/floorp-notes-sync-release-evidence-v1.json"
EXPECTED_SCHEMA_SHA256 = "c6db94655222233ab4c0c220ddd491166c8ea4bdeb48effc23d468df2f8326d6"
PRODUCTION_GH_BIN = Path("/opt/homebrew/bin/gh")
PRODUCTION_GH_SHA256 = "6a2ab5fa89553eac1f0df50a26a5eaeea9a665d8971f5a51b32487b72c708f5c"
PRODUCTION_GH_SIZE = 38_983_666
TRUSTED_GH_DIRECTORIES: list[tempfile.TemporaryDirectory[str]] = []
PRODUCTION_SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
PRODUCTION_XCRUN = Path("/usr/bin/xcrun")
TRUSTED_GITHUB_HOST = "github.com"
TODO16_REPOSITORY = "Floorp-Projects/Floorp"
TODO16_MERGED_SHA = "18841c0c43d0eda428e1c88170769c1539543848"
TODO16_TRUST_FILES = {
    "allowed_signers": {
        "path": "docs/development/floorp-notes-sync/allowed-signers",
        "blob_sha": "5abaca8c221feabe792f9bb3ffb65464809bb0f2",
        "sha256": "4acf23f23f9a0c2c449f25df6c7bfd84a9b3ee38953455cf8858711cfd78447e",
    },
    "revocations": {
        "path": "docs/development/floorp-notes-sync/revocations.json",
        "blob_sha": "06274ee5aa9e91f2514bab282b0f6155c75ea62e",
        "sha256": "79f69d733eceb6484f67d6cf7969d01c68b52a245e8b3d72c65d1eb8b40bc3c4",
    },
    "signer_registry": {
        "path": "docs/development/floorp-notes-sync/prerequisites.json",
        "blob_sha": "43d6826903d49b65d71c593a6e4759eaf32d02a2",
        "sha256": "e8c99a574d1171f2ae8df55782e69bcfa0d517938aea0152ca11d587df33d6ba",
    },
}
GITHUB_REDIRECT_ENVIRONMENT = frozenset(
    {
        "ALL_PROXY",
        "CURL_CA_BUNDLE",
        "GH_CONFIG_DIR",
        "GH_HOST",
        "GH_HTTP_UNIX_SOCKET",
        "GITHUB_API_URL",
        "GITHUB_SERVER_URL",
        "GIT_SSL_CAINFO",
        "GIT_SSL_CAPATH",
        "GIT_SSL_NO_VERIFY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "REQUESTS_CA_BUNDLE",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "NODE_EXTRA_CA_CERTS",
        "all_proxy",
        "curl_ca_bundle",
        "gh_config_dir",
        "gh_host",
        "gh_http_unix_socket",
        "github_api_url",
        "github_server_url",
        "git_ssl_cainfo",
        "git_ssl_capath",
        "git_ssl_no_verify",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        "node_extra_ca_certs",
        "requests_ca_bundle",
        "ssl_cert_dir",
        "ssl_cert_file",
    }
)
PRODUCTION_GH_ENVIRONMENT = (
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "GH_TOKEN",
    "GITHUB_TOKEN",
)
FORBIDDEN_METADATA_KEYS = {
    "access_token",
    "refresh_token",
    "oauth_token",
    "authorization_header",
    "cookie_header",
    "set_cookie_header",
    "sync_key",
    "raw_sync_key",
    "notes_payload",
    "note_content",
    "note_title",
    "request_body",
    "response_body",
    "password",
}
GATE_SOURCE_ROLES = {
    "g1": (
        "task-manifest",
        "todo16-contract",
        "ios-contract-source",
        "desktop-contract-source",
        "merge-fixture",
    ),
    "g2": (
        "task-manifest",
        "fake-server-run",
        "focus-xcframework",
        "mozilla-xcframework",
        "release-manifest",
        "sha256sums",
        "swift-components",
    ),
    "g3": ("integration-receipt", "ci-run", "xcresult"),
    "g4": (
        "task-manifest",
        "task18-execution-verdict",
        "desktop-ci-run",
        "runtime-ci-run",
        "g4-attestation-source",
        "g4-attestation-ci-run",
        "g4-attestation-xcresult",
        "xpcshell-run",
        "tps-run",
    ),
    "g5": (
        "task-manifest",
        "ci-run",
        "xcresult",
        "account-isolation-run",
        "proxy-trace",
    ),
}
TASK_BY_GATE = {"g1": 16, "g2": 17, "g4": 18, "g5": 20}
ASSET_ROLE_TO_INPUT = {
    "focus-xcframework": ("FocusRustComponents.xcframework.zip", "focus_xcframework_sha256"),
    "mozilla-xcframework": ("MozillaRustComponents.xcframework.zip", "mozilla_xcframework_sha256"),
    "release-manifest": ("release-manifest.json", "release_manifest_sha256"),
    "sha256sums": ("SHA256SUMS", "sha256sums_sha256"),
    "swift-components": ("swift-components.tar.xz", "swift_components_sha256"),
}
EXPECTED_FIXTURE_SHA256 = "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd"
EXPECTED_CASE_SET_SHA256 = "c19ec1a3229b0d09aa424498471941409bc77505862e8aa278aadb3396032802"
EXPECTED_ENDPOINT_POLICY_SHA256 = "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca"
EXPECTED_RECORD_ID = "e2VjODAzMGY3LWMyMGEtNDY0Zi05YjBlLTEzYTNhOWU5NzM4NH0="
EXPECTED_NOTES_PREF = "floorp.browser.note.memos"
EXPECTED_CONTROL_PREF = "services.sync.prefs.sync.floorp.browser.note.memos"
G4_ATTESTATION_PATH = "docs/floorp-notes-sync-g4-attestation.json"
G4_ATTESTATION_TEST = (
    "ClientTests/FloorpNotesSyncEngineSelectionTests/"
    "testG4AttestationBindsTask18Evidence()"
)
G4_ATTESTATION_XCRESULT_TEST = (
    "FloorpNotesSyncEngineSelectionTests/"
    "testG4AttestationBindsTask18Evidence()"
)
G5_STATIC_PREFLIGHT_XCTEST_SELECTOR = (
    "XCUITests/FloorpNotesSyncTwoClientMatrixTests/"
    "testTwoClientProductionMatrix"
)
G5_STATIC_PREFLIGHT_XCRESULT_TEST = (
    "FloorpNotesSyncTwoClientMatrixTests/"
    "testTwoClientProductionMatrix()"
)
G5_ACTUAL_TWO_CLIENT_XCRESULT_TEST = (
    "FloorpNotesSyncActualG5TwoClientTests/"
    "testActualG5TwoClientProductionMatrix()"
)
G3_CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
G5_CI_WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
G5_CI_EVENT = "workflow_dispatch"
G5_CI_HEAD_BRANCH = "main"
G5_XCRESULT_ARTIFACT_NAME = "floorp-notes-sync-two-client-xcresult"
G5_XCRESULT_ARTIFACT_KIND = "github-actions-artifact"
G5_REQUIRED_SYNC_HOST = "sync.services.mozilla.com"
EXPECTED_FXA_HOSTS = (
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
)
EXPECTED_SYNC_HOSTS = (
    "event-sync.services.mozilla.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
)
PRODUCTION_QA_MODE = "production-qa"
RELEASE_ENABLED_MODE = "release-enabled"
G1_G4_NAMES = ("g1", "g2", "g3", "g4")
G1_G5_NAMES = (*G1_G4_NAMES, "g5")
G6_ROLES = (
    "architecture-owner",
    "security-reviewer",
    "privacy-reviewer",
    "retention-reviewer",
    "rollout-approver",
)
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_XCRESULT_ENTRIES = 200_000
MAX_XCRESULT_BYTES = 16 * 1024 * 1024 * 1024
MAX_XCRESULT_DEPTH = 128
XCRESULT_READ_CHUNK_BYTES = 1024 * 1024
XCRESULT_SECRET_MARKERS = (
    b"authorization: bearer",
    b"access_token",
    b"refresh_token",
    b"raw_sync_key",
)
SUPPORTS_FD_SCANDIR = os.scandir in os.supports_fd
SUPPORTS_DIR_FD_OPEN = os.open in os.supports_dir_fd
SUPPORTS_DIR_FD_STAT = os.stat in os.supports_dir_fd
SIGNATURE_NAMESPACE = "floorp-notes-sync"


class ValidationError(Exception):
    pass


class MalformedError(ValidationError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def reject_float(value: str) -> None:
    raise MalformedError(f"floating-point JSON number is forbidden: {value}")


def reject_constant(value: str) -> None:
    raise MalformedError(f"non-finite JSON number is forbidden: {value}")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MalformedError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_json_domain(value: Any, path: str = "$") -> None:
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if abs(value) > MAX_SAFE_INTEGER:
            raise MalformedError(f"{path}: integer exceeds the RFC 8785 interoperable range")
        return
    if isinstance(value, str):
        if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
            raise MalformedError(f"{path}: unpaired UTF-16 surrogate is forbidden")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            validate_json_domain(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            validate_json_domain(key, f"{path}.<key>")
            validate_json_domain(item, f"{path}.{key}")
        return
    raise MalformedError(f"{path}: unsupported JSON value {type(value).__name__}")


def canonical_bytes(value: Any) -> bytes:
    validate_json_domain(value)
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
        return b"[" + b",".join(canonical_bytes(item) for item in value) + b"]"
    if isinstance(value, dict):
        ordered_keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        members = (
            canonical_bytes(key) + b":" + canonical_bytes(value[key])
            for key in ordered_keys
        )
        return b"{" + b",".join(members) + b"}"
    raise MalformedError(f"unsupported JSON value {type(value).__name__}")


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def file_digest(path: Path, label: str) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise MalformedError(f"{label}: cannot read {path} ({error})") from error


def parse_json_bytes(raw: bytes, *, require_canonical: bool, label: str) -> Any:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise MalformedError(f"{label}: input is not UTF-8") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=unique_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except json.JSONDecodeError as error:
        raise MalformedError(f"{label}: invalid JSON ({error})") from error
    validate_json_domain(value)
    if require_canonical and raw != canonical_bytes(value):
        raise ValidationError(f"{label}: input is not RFC 8785 JCS canonical JSON")
    return value


def load_json(path: Path, *, require_canonical: bool, label: str) -> Any:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise MalformedError(f"{label}: cannot read {path} ({error})") from error
    return parse_json_bytes(raw, require_canonical=require_canonical, label=label)


def load_pinned_schema(repository_root: Path, supplied_path: Path) -> dict[str, Any]:
    canonical_path = repository_root / "docs/floorp-notes-sync-release-evidence.schema.json"
    try:
        resolved_canonical = canonical_path.resolve(strict=True)
        resolved_supplied = supplied_path.resolve(strict=True)
        raw = resolved_canonical.read_bytes()
    except OSError as error:
        raise MalformedError(f"schema: cannot resolve or read the repository schema ({error})") from error
    check(
        resolved_supplied == resolved_canonical,
        "schema: --schema must resolve to the canonical repository schema path",
    )
    check(
        hashlib.sha256(raw).hexdigest() == EXPECTED_SCHEMA_SHA256,
        "schema: canonical repository schema digest does not match the pinned SHA-256",
    )
    schema = parse_json_bytes(raw, require_canonical=False, label="schema")
    if not isinstance(schema, dict):
        raise MalformedError("schema: root must be an object")
    check(schema.get("$id") == EXPECTED_SCHEMA_ID, "schema: unexpected schema ID")
    return schema


def same_json_value(left: Any, right: Any) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    return type(left) is type(right) and left == right


def resolve_ref(root_schema: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise MalformedError(f"schema uses unsupported reference: {reference}")
    node: Any = root_schema
    for raw_part in reference[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or part not in node:
            raise MalformedError(f"schema reference does not resolve: {reference}")
        node = node[part]
    if not isinstance(node, dict):
        raise MalformedError(f"schema reference is not an object: {reference}")
    return node


def is_json_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    raise MalformedError(f"schema uses unsupported type: {expected}")


def validate_schema_instance(
    value: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    path: str = "$",
) -> None:
    if "oneOf" in schema:
        alternatives = schema["oneOf"]
        if not isinstance(alternatives, list) or not alternatives or not all(
            isinstance(candidate, dict) for candidate in alternatives
        ):
            raise MalformedError(f"{path}: schema oneOf must be a non-empty array of objects")
        matches = 0
        for candidate in alternatives:
            try:
                validate_schema_instance(value, candidate, root_schema, path)
            except MalformedError:
                raise
            except ValidationError:
                continue
            matches += 1
        if matches != 1:
            raise ValidationError(f"{path}: expected exactly one schema alternative")
    if "$ref" in schema:
        validate_schema_instance(value, resolve_ref(root_schema, schema["$ref"]), root_schema, path)
        return
    if "const" in schema and not same_json_value(value, schema["const"]):
        raise ValidationError(f"{path}: value does not match schema const")
    if "enum" in schema and not any(same_json_value(value, candidate) for candidate in schema["enum"]):
        raise ValidationError(f"{path}: value is not in schema enum")
    expected_type = schema.get("type")
    if expected_type is not None:
        expected_types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(is_json_type(value, candidate) for candidate in expected_types):
            raise ValidationError(f"{path}: expected {' or '.join(expected_types)}")
    if isinstance(value, dict):
        required = schema.get("required", [])
        for name in required:
            if name not in value:
                raise ValidationError(f"{path}: missing required field {name}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for name, item in value.items():
            if name in properties:
                validate_schema_instance(item, properties[name], root_schema, f"{path}.{name}")
            elif additional is False:
                raise ValidationError(f"{path}: unexpected field {name}")
            elif isinstance(additional, dict):
                validate_schema_instance(item, additional, root_schema, f"{path}.{name}")
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            raise ValidationError(f"{path}: fewer than minProperties")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise ValidationError(f"{path}: fewer than minItems")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ValidationError(f"{path}: more than maxItems")
        if schema.get("uniqueItems"):
            encoded = [canonical_bytes(item) for item in value]
            if len(encoded) != len(set(encoded)):
                raise ValidationError(f"{path}: array items are not unique")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(value):
                validate_schema_instance(item, item_schema, root_schema, f"{path}[{index}]")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise ValidationError(f"{path}: string is shorter than minLength")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise ValidationError(f"{path}: string is longer than maxLength")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            raise ValidationError(f"{path}: string does not match schema pattern")
    if isinstance(value, int) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ValidationError(f"{path}: integer is below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            raise ValidationError(f"{path}: integer is above maximum")


def parse_timestamp(value: str, label: str) -> datetime:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError) as error:
        raise ValidationError(f"{label}: timestamp is not whole-second RFC 3339 UTC") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ValidationError(f"{label}: timestamp is not canonical RFC 3339 UTC")
    return parsed


def parse_http_date(value: str) -> datetime:
    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError) as error:
        raise ValidationError("validation clock: invalid GitHub HTTP Date") from error
    check(parsed is not None and parsed.tzinfo is not None, "validation clock: GitHub HTTP Date has no timezone")
    normalized = parsed.astimezone(timezone.utc).replace(microsecond=0)
    check(format_datetime(normalized, usegmt=True) == value, "validation clock: GitHub HTTP Date is not canonical")
    return normalized


def select_gh_executable(test_gh_bin: Path | None) -> Path:
    if test_gh_bin is not None:
        check(test_gh_bin.is_absolute(), "test GitHub CLI path must be absolute")
        try:
            selected = test_gh_bin.resolve(strict=True)
        except OSError as error:
            raise ValidationError("test GitHub CLI executable is unavailable") from error
        check(
            selected != PRODUCTION_GH_BIN.resolve(strict=False),
            "test GitHub CLI injection requires a non-production executable path",
        )
        check(selected.is_file() and os.access(selected, os.X_OK), "trusted GitHub CLI executable is unavailable")
        return selected

    try:
        source = PRODUCTION_GH_BIN.resolve(strict=True)
        source_fd = os.open(
            source,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as error:
        raise ValidationError("trusted GitHub CLI executable is unavailable") from error
    temporary = tempfile.TemporaryDirectory(prefix="floorp-trusted-gh-")
    target = Path(temporary.name) / "gh"
    target_fd = -1
    try:
        before = os.fstat(source_fd)
        check(stat.S_ISREG(before.st_mode), "trusted GitHub CLI is not a regular file")
        check(before.st_size == PRODUCTION_GH_SIZE, "trusted GitHub CLI size mismatch")
        check(before.st_mode & 0o222 == 0, "trusted GitHub CLI source is writable")
        target_fd = os.open(
            target,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o500,
        )
        digest = hashlib.sha256()
        size = 0
        while chunk := os.read(source_fd, 1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
            offset = 0
            while offset < len(chunk):
                offset += os.write(target_fd, chunk[offset:])
        after = os.fstat(source_fd)
        check(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            "trusted GitHub CLI changed while it was copied",
        )
        check(size == PRODUCTION_GH_SIZE, "trusted GitHub CLI copied size mismatch")
        check(digest.hexdigest() == PRODUCTION_GH_SHA256, "trusted GitHub CLI digest mismatch")
        os.fsync(target_fd)
        os.fchmod(target_fd, 0o500)
    finally:
        os.close(source_fd)
        if target_fd >= 0:
            os.close(target_fd)
    TRUSTED_GH_DIRECTORIES.append(temporary)
    return target


def trusted_gh_environment(test_environment: Mapping[str, str] | None = None) -> dict[str, str]:
    redirected = sorted(name for name in GITHUB_REDIRECT_ENVIRONMENT if os.environ.get(name))
    check(
        not redirected,
        f"trusted GitHub API redirect environment is forbidden: {', '.join(redirected)}",
    )
    environment = {
        name: os.environ[name]
        for name in PRODUCTION_GH_ENVIRONMENT
        if os.environ.get(name)
    }
    environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if test_environment is not None:
        redirected_test = sorted(
            name for name in GITHUB_REDIRECT_ENVIRONMENT if test_environment.get(name)
        )
        check(
            not redirected_test,
            f"trusted GitHub API redirect environment is forbidden: {', '.join(redirected_test)}",
        )
        environment.update(test_environment)
    environment["GH_PROMPT_DISABLED"] = "1"
    return environment


def run_gh_api(
    gh_bin: Path,
    arguments: list[str],
    label: str,
    environment: Mapping[str, str],
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            [str(gh_bin), "api", "--hostname", TRUSTED_GITHUB_HOST, *arguments],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=30,
            env=dict(environment),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ValidationError(f"trusted GitHub API {label} request failed") from error
    check(result.returncode == 0, f"trusted GitHub API {label} request failed")
    return result


def gh_api_json(
    gh_bin: Path,
    arguments: list[str],
    label: str,
    environment: Mapping[str, str],
) -> Any:
    result = run_gh_api(gh_bin, arguments, label, environment)
    try:
        return json.loads(
            result.stdout,
            object_pairs_hook=unique_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, MalformedError) as error:
        raise ValidationError(f"trusted GitHub API {label} returned malformed JSON") from error


def gh_api_json_with_date(
    gh_bin: Path,
    endpoint: str,
    label: str,
    environment: Mapping[str, str],
) -> tuple[Any, str]:
    result = run_gh_api(
        gh_bin,
        ["--include", "--method", "GET", endpoint],
        label,
        environment,
    )
    normalized = result.stdout.replace("\r\n", "\n")
    header_text, separator, body = normalized.rpartition("\n\n")
    check(bool(separator), f"trusted GitHub API {label} omitted HTTP headers")
    final_headers = header_text.split("\n\n")[-1].splitlines()
    status_lines = [line for line in final_headers if line.startswith("HTTP/")]
    check(
        len(status_lines) == 1 and re.fullmatch(r"HTTP/[^ ]+ 200(?: .*)?", status_lines[0]) is not None,
        f"trusted GitHub API {label} did not return HTTP 200",
    )
    dates = [line.split(":", 1)[1].strip() for line in final_headers if line.lower().startswith("date:")]
    check(len(dates) == 1, f"trusted GitHub API {label} must return exactly one HTTP Date")
    try:
        payload = json.loads(
            body.strip(),
            object_pairs_hook=unique_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, MalformedError) as error:
        raise ValidationError(f"trusted GitHub API {label} returned malformed JSON") from error
    return payload, dates[0]


def gh_api_download_digest(
    gh_bin: Path,
    endpoint: str,
    label: str,
    environment: Mapping[str, str],
    *,
    release_asset: bool = False,
    require_xcresult: bool = False,
    required_xcresult_test: str | None = None,
) -> str:
    with tempfile.TemporaryFile() as output:
        command = [
            str(gh_bin),
            "api",
            "--hostname",
            TRUSTED_GITHUB_HOST,
            "--method",
            "GET",
        ]
        if release_asset:
            # The release-asset endpoint serves the binary only when the
            # octet-stream Accept header is sent; the Actions artifact ZIP
            # endpoint rejects that header with HTTP 415 and is fetched
            # without it.
            command += ["-H", "Accept: application/octet-stream"]
        command.append(endpoint)
        try:
            result = subprocess.run(
                command,
                stdout=output,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                timeout=600,
                env=dict(environment),
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ValidationError(f"trusted GitHub API {label} download failed") from error
        check(result.returncode == 0, f"trusted GitHub API {label} download failed")
        if require_xcresult:
            output.seek(0)
            validate_xcresult_archive(
                output,
                label,
                required_test=required_xcresult_test,
            )
        output.seek(0)
        hasher = hashlib.sha256()
        while chunk := output.read(1024 * 1024):
            hasher.update(chunk)
        return hasher.hexdigest()


def validate_xcresult_archive(
    archive: Any,
    label: str,
    *,
    required_test: str | None = None,
    test_results: Mapping[str, str | list[str]] | None = None,
) -> None:
    try:
        with zipfile.ZipFile(archive) as bundle:
            entries = bundle.infolist()
            check(
                0 < len(entries) <= MAX_XCRESULT_ENTRIES,
                f"{label}: xcresult ZIP entry count is invalid",
            )
            check(
                all(0 <= entry.file_size <= MAX_XCRESULT_BYTES for entry in entries),
                f"{label}: xcresult ZIP member size is invalid",
            )
            check(
                sum(entry.file_size for entry in entries) <= MAX_XCRESULT_BYTES,
                f"{label}: xcresult ZIP is too large",
            )
            paths: list[str] = []
            total_uncompressed_size = 0
            for entry in entries:
                path = entry.filename
                parts = tuple(part for part in path.split("/") if part)
                check(bool(parts), f"{label}: xcresult ZIP contains an empty path")
                check(
                    not path.startswith("/") and ".." not in parts,
                    f"{label}: xcresult ZIP contains an unsafe path",
                )
                unix_mode = (entry.external_attr >> 16) & 0o170000
                check(unix_mode != stat.S_IFLNK, f"{label}: xcresult ZIP contains a symlink")
                lowered = {part.lower() for part in parts}
                check(
                    not lowered.intersection({"attachments", "screenshots"}),
                    f"{label}: xcresult ZIP contains content-bearing attachments",
                )
                if not entry.is_dir():
                    entry_size = 0
                    secret_tail = b""
                    maximum_marker_length = max(map(len, XCRESULT_SECRET_MARKERS))
                    with bundle.open(entry) as stream:
                        while chunk := stream.read(XCRESULT_READ_CHUNK_BYTES):
                            entry_size += len(chunk)
                            total_uncompressed_size += len(chunk)
                            check(
                                total_uncompressed_size <= MAX_XCRESULT_BYTES,
                                f"{label}: xcresult ZIP is too large",
                            )
                            scan_window = (secret_tail + chunk).lower()
                            check(
                                not any(
                                    marker in scan_window
                                    for marker in XCRESULT_SECRET_MARKERS
                                ),
                                f"{label}: xcresult ZIP contains secret metadata",
                            )
                            secret_tail = scan_window[-(maximum_marker_length - 1):]
                    check(
                        entry_size == entry.file_size,
                        f"{label}: xcresult ZIP member size changed while reading",
                    )
                paths.append(path.rstrip("/"))
    except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise ValidationError(f"{label}: artifact is not a valid xcresult ZIP") from error
    roots = {path.split("/", 1)[0] for path in paths}
    if len(roots) == 1 and next(iter(roots)).endswith(".xcresult"):
        root = next(iter(roots))
        prefix = f"{root}/"
    elif roots <= {"Data", "Info.plist"}:
        # actions/upload-artifact archives a single directory as its
        # contents, so a live GitHub artifact of an xcresult bundle has
        # Data/ and Info.plist at the ZIP root instead of a .xcresult
        # wrapper directory. The bundle content is identical.
        root = ""
        prefix = ""
    else:
        check(False, f"{label}: ZIP root is not one xcresult")
    check(f"{prefix}Info.plist" in paths, f"{label}: xcresult ZIP is missing Info.plist")
    check(any(path.startswith(f"{prefix}Data/") for path in paths), f"{label}: xcresult ZIP is missing Data")
    if required_test is not None:
        if test_results is None:
            test_results = xcresult_test_results(archive, root, label)
        observed = test_results.get(required_test)
        matching = [observed] if isinstance(observed, str) else observed
        check(
            isinstance(matching, list)
            and bool(matching)
            and all(result == "Passed" for result in matching),
            f"{label}: required XCTest did not have Passed result nodes",
        )


def xcresult_test_results(
    archive: Any,
    root: str,
    label: str,
) -> dict[str, list[str]]:
    try:
        archive.seek(0)
    except (AttributeError, OSError) as error:
        raise ValidationError(f"{label}: xcresult ZIP cannot be rewound") from error
    with tempfile.TemporaryDirectory(prefix="floorp-xcresult-") as temporary:
        extraction_root = Path(temporary)
        try:
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(extraction_root)
        except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
            raise ValidationError(f"{label}: xcresult ZIP extraction failed") from error
        result_path = extraction_root / root
        check(result_path.is_dir(), f"{label}: extracted xcresult root is missing")
        environment = {
            name: os.environ[name]
            for name in ("HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR")
            if os.environ.get(name)
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        try:
            completed = subprocess.run(
                [
                    str(PRODUCTION_XCRUN),
                    "xcresulttool",
                    "get",
                    "test-results",
                    "tests",
                    "--path",
                    str(result_path),
                    "--format",
                    "json",
                ],
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                timeout=120,
                env=environment,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ValidationError(f"{label}: xcresulttool execution failed") from error
        check(completed.returncode == 0, f"{label}: xcresulttool rejected the result bundle")
        try:
            payload = json.loads(completed.stdout, object_pairs_hook=unique_object)
        except (json.JSONDecodeError, MalformedError) as error:
            raise ValidationError(f"{label}: xcresulttool returned malformed JSON") from error

    check(isinstance(payload, dict), f"{label}: xcresulttool root is malformed")
    roots = payload.get("testNodes")
    check(isinstance(roots, list), f"{label}: xcresulttool testNodes are missing")
    results: dict[str, list[str]] = {}
    pending = [(node, 1) for node in roots]
    visited = 0
    while pending:
        node, depth = pending.pop()
        visited += 1
        check(visited <= MAX_XCRESULT_ENTRIES, f"{label}: xcresult test-node count exceeds limit")
        check(depth <= MAX_XCRESULT_DEPTH, f"{label}: xcresult test-node depth exceeds limit")
        check(isinstance(node, dict), f"{label}: xcresult test node is malformed")
        children = node.get("children", [])
        check(isinstance(children, list), f"{label}: xcresult test-node children are malformed")
        pending.extend((child, depth + 1) for child in children)
        if node.get("nodeType") != "Test Case":
            continue
        identifier = node.get("nodeIdentifier")
        result = node.get("result")
        check(isinstance(identifier, str) and bool(identifier), f"{label}: XCTest identifier is malformed")
        check(isinstance(result, str) and bool(result), f"{label}: XCTest result is malformed")
        results.setdefault(identifier, []).append(result)
    return results


def live_repository_name(run: dict[str, Any]) -> str:
    repository = run.get("repository")
    if isinstance(repository, dict):
        return repository.get("full_name", "")
    return repository if isinstance(repository, str) else ""


def live_workflow_path(run: dict[str, Any]) -> str:
    path = run.get("path")
    if not isinstance(path, str):
        return ""
    return path.split("@", 1)[0]


def normalize_live_run(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "api_url": run.get("url"),
        "attempt": run.get("run_attempt"),
        "conclusion": run.get("conclusion"),
        "created_at": run.get("created_at"),
        "event": run.get("event"),
        "head_sha": run.get("head_sha"),
        "html_url": run.get("html_url"),
        "id": run.get("id"),
        "repository": live_repository_name(run),
        "status": run.get("status"),
        "updated_at": run.get("updated_at"),
        "workflow_id": run.get("workflow_id"),
        "workflow_path": live_workflow_path(run),
    }


def normalize_live_job(job: dict[str, Any]) -> dict[str, Any]:
    return {
        "completed_at": job.get("completed_at"),
        "conclusion": job.get("conclusion"),
        "id": job.get("id"),
        "name": job.get("name"),
        "run_attempt": job.get("run_attempt"),
        "run_id": job.get("run_id"),
        "started_at": job.get("started_at"),
        "status": job.get("status"),
    }


def fetch_live_clock(
    clock: dict[str, Any],
    gh_bin: Path,
    gh_environment: Mapping[str, str],
) -> tuple[dict[str, Any], list[dict[str, Any]], datetime]:
    manifest_run = clock["run"]
    run_id = manifest_run["id"]
    endpoint = f"repos/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
    live_run_value, live_http_date = gh_api_json_with_date(
        gh_bin,
        endpoint,
        "run",
        gh_environment,
    )
    check(isinstance(live_run_value, dict), "trusted GitHub API run response is not an object")
    live_run = normalize_live_run(live_run_value)
    for field, expected_value in manifest_run.items():
        check(live_run.get(field) == expected_value, f"live GitHub run {field} differs from the manifest")

    attempt = manifest_run["attempt"]
    jobs_endpoint = f"repos/{EXPECTED_REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}/jobs"
    jobs_response = gh_api_json(
        gh_bin,
        ["--method", "GET", jobs_endpoint, "-f", "per_page=100"],
        "jobs",
        gh_environment,
    )
    check(isinstance(jobs_response, dict), "trusted GitHub API jobs response is not an object")
    live_job_values = jobs_response.get("jobs")
    check(
        isinstance(live_job_values, list) and all(isinstance(job, dict) for job in live_job_values),
        "trusted GitHub API jobs response omitted a valid jobs array",
    )
    check(
        jobs_response.get("total_count") == len(live_job_values),
        "trusted GitHub API jobs response is incomplete",
    )
    live_jobs = [normalize_live_job(job) for job in live_job_values]
    manifest_jobs = sorted(clock["jobs"], key=lambda job: job["id"])
    check(
        sorted(live_jobs, key=lambda job: job["id"] if isinstance(job["id"], int) else -1) == manifest_jobs,
        "live GitHub jobs differ from the manifest",
    )
    return live_run, live_jobs, parse_http_date(live_http_date)


def validate_clock(
    clock: dict[str, Any],
    schema: dict[str, Any],
    expected_head: str,
    expected_workflow_id: int | None,
    gh_bin: Path,
    gh_environment: Mapping[str, str],
) -> datetime:
    clock_schema = {"$ref": "#/$defs/validationClockManifest"}
    validate_schema_instance(clock, clock_schema, schema, "$clock")
    check(clock["repository"] == EXPECTED_REPOSITORY, "validation clock: wrong repository")
    check(clock["workflow"]["path"] == EXPECTED_WORKFLOW_PATH, "validation clock: wrong workflow path")
    check(clock["expected_head_sha"] == expected_head, "validation clock: wrong expected head")
    check(clock["max_age_seconds"] == 300, "validation clock: freshness window must be 300 seconds")

    run = clock["run"]
    run_id = run["id"]
    check(run["repository"] == EXPECTED_REPOSITORY, "validation clock: run repository mismatch")
    check(run["workflow_id"] == clock["workflow"]["id"], "validation clock: workflow ID mismatch")
    if expected_workflow_id is not None:
        check(run["workflow_id"] == expected_workflow_id, "validation clock: unexpected workflow ID")
    check(run["workflow_path"] == EXPECTED_WORKFLOW_PATH, "validation clock: run workflow path mismatch")
    check(run["event"] == "workflow_dispatch", "validation clock: event is not workflow_dispatch")
    check(run["head_sha"] == expected_head, "validation clock: run head mismatch")
    check(run["status"] == "completed", "validation clock: run is nonterminal")
    check(run["conclusion"] == "success", "validation clock: run did not succeed")
    expected_api_url = f"https://api.github.com/repos/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
    expected_html_url = f"https://github.com/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
    check(run["api_url"] == expected_api_url, "validation clock: run API URL mismatch")
    check(run["html_url"] == expected_html_url, "validation clock: run HTML URL mismatch")

    check(len(clock["jobs"]) == 1, "validation clock: expected exactly one validation-clock job")
    check(clock["jobs"][0]["name"] == "validation-clock", "validation clock: unexpected job name")
    check(clock["jobs"][0]["conclusion"] == "success", "validation clock: validation-clock job did not succeed")

    _, _, trusted_now = fetch_live_clock(clock, gh_bin, gh_environment)
    captured_at = parse_http_date(clock["github_http_date"])
    capture_age = (trusted_now - captured_at).total_seconds()
    check(
        0 <= capture_age <= clock["max_age_seconds"],
        "validation clock: captured GitHub HTTP Date is stale or in the future",
    )
    created_at = parse_timestamp(run["created_at"], "validation clock run.created_at")
    updated_at = parse_timestamp(run["updated_at"], "validation clock run.updated_at")
    check(created_at <= updated_at, "validation clock: run updated before it was created")
    skew = (updated_at - trusted_now).total_seconds()
    check(-300 <= skew <= 300, "validation clock: run is stale or more than five minutes in the future")

    job_ids: set[int] = set()
    for index, job in enumerate(clock["jobs"]):
        label = f"validation clock jobs[{index}]"
        check(job["id"] not in job_ids, f"{label}: duplicate job ID")
        job_ids.add(job["id"])
        check(job["run_id"] == run_id, f"{label}: run ID mismatch")
        check(job["run_attempt"] == run["attempt"], f"{label}: run attempt mismatch")
        check(job["status"] == "completed", f"{label}: job is nonterminal")
        check(job["conclusion"] == "success", f"{label}: job did not succeed")
        started_at = parse_timestamp(job["started_at"], f"{label}.started_at")
        completed_at = parse_timestamp(job["completed_at"], f"{label}.completed_at")
        check(started_at <= completed_at, f"{label}: completion precedes start")
        check(completed_at <= trusted_now + timedelta(seconds=300), f"{label}: completion is in the future")
    return trusted_now


def validate_mode_gate_semantics(evidence: dict[str, Any], require_g6: bool) -> None:
    mode = evidence.get("build_contract_mode")
    gates = evidence.get("gates")
    check(mode in (PRODUCTION_QA_MODE, RELEASE_ENABLED_MODE), "unsupported build contract mode")
    check(isinstance(gates, dict), "evidence gates must be an object")
    gate_names = set(gates)
    if mode == PRODUCTION_QA_MODE:
        expected_names = set(G1_G4_NAMES)
        check(gate_names == expected_names, "production-qa evidence must contain exactly G1-G4")
        check(not require_g6, "G6 cannot be required for production-qa evidence")
    else:
        required_names = set(G1_G5_NAMES)
        allowed_names = required_names | {"g6"}
        check(
            gate_names in (required_names, allowed_names),
            "release-enabled evidence must contain exactly G1-G5 or G1-G6",
        )
        if require_g6:
            check(gate_names == allowed_names, "G6 is required but absent")
    for name in sorted(gate_names):
        gate = gates[name]
        check(isinstance(gate, dict), f"{name}: gate must be an object")
        check(gate.get("status") == "passed", f"{name}: required gate status is not passed")


def validate_release_contract(
    evidence: dict[str, Any],
    trusted_now: datetime,
    expected_ios_build_number: str,
) -> None:
    inputs = evidence["release_inputs"]
    contract = inputs["contract"]
    environment = inputs["environment"]
    check(contract["fixture_sha256"] == EXPECTED_FIXTURE_SHA256, "release inputs: wrong fixture digest")
    check(contract["case_set_sha256"] == EXPECTED_CASE_SET_SHA256, "release inputs: wrong case-set digest")
    check(
        contract["endpoint_policy_sha256"] == EXPECTED_ENDPOINT_POLICY_SHA256,
        "release inputs: wrong endpoint-policy digest",
    )
    check(environment["fxa_configuration"] == "FxAConfig.Server.release", "release inputs: wrong FxA authority")
    check(tuple(environment["fxa_hosts"]) == EXPECTED_FXA_HOSTS, "release inputs: wrong FxA host policy")
    check(tuple(environment["sync_hosts"]) == EXPECTED_SYNC_HOSTS, "release inputs: wrong Sync host policy")
    check(environment["wire_protocol"] == "sync15", "release inputs: wrong Sync wire protocol")
    check(
        inputs["ios"]["build_number"] == expected_ios_build_number,
        "release inputs: iOS FloorpRelease build number does not match the reviewed source",
    )

    mode = evidence["build_contract_mode"]
    gates = evidence["gates"]
    check(mode in (PRODUCTION_QA_MODE, RELEASE_ENABLED_MODE), "unsupported build contract mode")
    g1_contract = gates["g1"]["contract"]
    expected_g1_contract = {
        "case_set_sha256": contract["case_set_sha256"],
        "control_pref_name": EXPECTED_CONTROL_PREF,
        "control_pref_value": True,
        "desktop_contract_sha": inputs["desktop"]["source_sha"],
        "fixture_sha256": contract["fixture_sha256"],
        "ios_contract_sha": inputs["ios"]["source_sha"],
        "notes_pref_name": EXPECTED_NOTES_PREF,
        "record_id": EXPECTED_RECORD_ID,
    }
    check(g1_contract == expected_g1_contract, "G1 contract is mixed or does not match the pinned wire contract")
    check(
        gates["g2"]["application_services"] == inputs["application_services"],
        "G2 Application Services input is mixed",
    )
    check(gates["g3"]["candidate"] == inputs["ios"], "G3 iOS candidate is mixed")
    check(gates["g4"]["desktop"] == inputs["desktop"], "G4 Desktop input is mixed")
    check(gates["g4"]["runtime"] == inputs["runtime"], "G4 Runtime input is mixed")

    validate_gate_time("G1", gates["g1"], trusted_now, None)
    validate_gate_time("G2", gates["g2"], trusted_now, 30)
    validate_gate_time("G3", gates["g3"], trusted_now, 7)
    validate_gate_time("G4", gates["g4"], trusted_now, 30)

    if mode == PRODUCTION_QA_MODE:
        check(set(gates) == set(G1_G4_NAMES), "production-qa evidence must contain exactly G1-G4")
        g1_g4 = {name: gates[name] for name in G1_G4_NAMES}
        expected_g1_g4_digest = digest({"gates": g1_g4, "release_inputs": inputs})
        check(
            evidence["g1_g4_digest_sha256"] == expected_g1_g4_digest,
            "combined G1-G4 digest does not match canonical inputs and gates",
        )
        return

    allowed_release_gates = set(G1_G5_NAMES) | ({"g6"} if "g6" in gates else set())
    check(set(gates) == allowed_release_gates, "release-enabled evidence must contain G1-G5 and optional G6")
    check(gates["g5"]["ios"] == inputs["ios"], "G5 iOS input is mixed")
    check(gates["g5"]["desktop"] == inputs["desktop"], "G5 Desktop input is mixed")
    check(gates["g5"]["runtime"] == inputs["runtime"], "G5 Runtime input is mixed")
    expected_g5_as = {
        "mozilla_xcframework_sha256": inputs["application_services"]["artifacts"]["mozilla_xcframework_sha256"],
        "release_tag": inputs["application_services"]["release_tag"],
        "source_sha": inputs["application_services"]["source_sha"],
    }
    check(gates["g5"]["application_services"] == expected_g5_as, "G5 Application Services input is mixed")

    validate_gate_time("G5", gates["g5"], trusted_now, 7)

    g1_g5 = {name: gates[name] for name in G1_G5_NAMES}
    expected_g1_g5_digest = digest({"gates": g1_g5, "release_inputs": inputs})
    check(
        evidence["g1_g5_digest_sha256"] == expected_g1_g5_digest,
        "combined G1-G5 digest does not match canonical inputs and gates",
    )


def validate_bound_source_files(fixture_path: Path, endpoint_policy_path: Path) -> None:
    check(file_digest(fixture_path, "merge fixture") == EXPECTED_FIXTURE_SHA256, "merge fixture source digest drift")
    fixture = load_json(fixture_path, require_canonical=False, label="merge fixture")
    check(isinstance(fixture, dict), "merge fixture: root must be an object")
    case_names = fixture.get("requiredCaseNames")
    check(
        isinstance(case_names, list) and all(isinstance(name, str) for name in case_names),
        "merge fixture: requiredCaseNames is malformed",
    )
    check(len(case_names) == len(set(case_names)), "merge fixture: requiredCaseNames contains duplicates")
    check(digest(case_names) == EXPECTED_CASE_SET_SHA256, "merge fixture: required case-set digest drift")
    check(
        file_digest(endpoint_policy_path, "endpoint policy") == EXPECTED_ENDPOINT_POLICY_SHA256,
        "endpoint-policy source digest drift",
    )
    endpoint_policy = load_json(endpoint_policy_path, require_canonical=False, label="endpoint policy")
    check(isinstance(endpoint_policy, dict), "endpoint policy: root must be an object")


def load_floorp_release_build_number(configuration_path: Path) -> str:
    try:
        metadata = configuration_path.lstat()
        check(not stat.S_ISLNK(metadata.st_mode), "FloorpRelease configuration must not be a symlink")
        check(stat.S_ISREG(metadata.st_mode), "FloorpRelease configuration is not a regular file")
        text = configuration_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValidationError("FloorpRelease configuration is unavailable") from error
    matches = re.findall(
        r"^FLOORP_BUILD_NUMBER[ \t]*=[ \t]*([1-9][0-9]*)[ \t]*$",
        text,
        flags=re.MULTILINE,
    )
    check(len(matches) == 1, "FloorpRelease build number source is not exact")
    return matches[0]


def git_blob_sha(raw: bytes) -> str:
    header = f"blob {len(raw)}\0".encode("ascii")
    return hashlib.sha1(header + raw).hexdigest()


def source_identity_key(source: dict[str, Any]) -> str:
    identity = {name: value for name, value in source.items() if name != "sha256"}
    return digest(identity)


def validate_relative_path(value: str, label: str) -> tuple[str, ...]:
    check(isinstance(value, str) and bool(value), f"{label}: path is empty")
    check(not value.startswith("/"), f"{label}: absolute paths are forbidden")
    parts = tuple(value.split("/"))
    check(all(part not in ("", ".", "..") for part in parts), f"{label}: unsafe relative path")
    return parts


def checked_local_path(base: Path, relative: str, label: str) -> Path:
    parts = validate_relative_path(relative, label)
    root = base.resolve(strict=True)
    current = root
    for part in parts:
        current = current / part
        try:
            mode = os.lstat(current).st_mode
        except OSError as error:
            raise ValidationError(f"{label}: local artifact is unavailable") from error
        check(not stat.S_ISLNK(mode), f"{label}: symlinks are forbidden")
    try:
        resolved = current.resolve(strict=True)
    except OSError as error:
        raise ValidationError(f"{label}: local artifact is unavailable") from error
    check(
        os.path.commonpath((str(root), str(resolved))) == str(root),
        f"{label}: local artifact escapes the evidence directory",
    )
    return resolved


def read_local_file(base: Path, relative: str, label: str) -> bytes:
    path = checked_local_path(base, relative, label)
    check(path.is_file(), f"{label}: local artifact is not a regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValidationError(f"{label}: local artifact cannot be opened") from error
    try:
        before = os.fstat(descriptor)
        check(stat.S_ISREG(before.st_mode), f"{label}: local artifact is not a regular file")
        check(before.st_size <= 32 * 1024 * 1024, f"{label}: local metadata artifact is too large")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read()
        after = os.fstat(descriptor)
        check(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"{label}: local artifact changed while it was read",
        )
        return raw
    finally:
        os.close(descriptor)


def filesystem_identity(metadata: os.stat_result) -> tuple[int, int, int]:
    return (metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode))


def stable_directory_snapshot(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def stable_file_snapshot(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def open_directory_component(parent_fd: int, name: str, label: str) -> int:
    try:
        entry_before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise ValidationError(f"{label}: .xcresult directory entry is unavailable") from error
    check(stat.S_ISDIR(entry_before.st_mode), f"{label}: .xcresult contains a non-directory component")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise ValidationError(f"{label}: .xcresult directory changed during open") from error
    try:
        opened = os.fstat(descriptor)
        entry_after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        check(stat.S_ISDIR(opened.st_mode), f"{label}: opened .xcresult entry is not a directory")
        check(
            filesystem_identity(entry_before)
            == filesystem_identity(opened)
            == filesystem_identity(entry_after),
            f"{label}: .xcresult directory identity changed during open",
        )
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_relative_directory(base: Path, relative: str, label: str) -> int:
    parts = validate_relative_path(relative, label)
    check(parts[-1].endswith(".xcresult"), f"{label}: test result directory must end in .xcresult")
    check(hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"), f"{label}: secure directory open is unavailable")
    check(SUPPORTS_FD_SCANDIR, f"{label}: fd-relative directory scanning is unavailable")
    check(SUPPORTS_DIR_FD_OPEN, f"{label}: fd-relative open is unavailable")
    check(SUPPORTS_DIR_FD_STAT, f"{label}: fd-relative stat is unavailable")
    root = base.resolve(strict=True)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        current_fd = os.open(root, flags)
    except OSError as error:
        raise ValidationError(f"{label}: evidence directory cannot be opened securely") from error
    try:
        opened_root = os.fstat(current_fd)
        path_root = os.stat(root, follow_symlinks=False)
        check(stat.S_ISDIR(opened_root.st_mode), f"{label}: evidence root is not a directory")
        check(
            filesystem_identity(opened_root) == filesystem_identity(path_root),
            f"{label}: evidence root identity changed during open",
        )
        for part in parts:
            parent_before = stable_directory_snapshot(os.fstat(current_fd))
            child_fd = open_directory_component(current_fd, part, label)
            try:
                check(
                    parent_before == stable_directory_snapshot(os.fstat(current_fd)),
                    f"{label}: parent directory changed during traversal",
                )
            except BaseException:
                os.close(child_fd)
                raise
            os.close(current_fd)
            current_fd = child_fd
        return current_fd
    except BaseException:
        os.close(current_fd)
        raise


def open_regular_file(parent_fd: int, name: str, label: str) -> tuple[int, os.stat_result]:
    try:
        entry_before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise ValidationError(f"{label}: .xcresult file entry is unavailable") from error
    check(stat.S_ISREG(entry_before.st_mode), f"{label}: .xcresult contains a non-regular file")
    flags = (
        os.O_RDONLY
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise ValidationError(f"{label}: .xcresult file changed during open") from error
    try:
        opened = os.fstat(descriptor)
        entry_after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        check(stat.S_ISREG(opened.st_mode), f"{label}: opened .xcresult entry is not a regular file")
        check(
            filesystem_identity(entry_before)
            == filesystem_identity(opened)
            == filesystem_identity(entry_after),
            f"{label}: .xcresult file identity changed during open",
        )
        return descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def bounded_directory_names(directory_fd: int, label: str) -> list[str]:
    names: list[str] = []
    with os.scandir(directory_fd) as iterator:
        for entry in iterator:
            names.append(entry.name)
            check(
                len(names) <= MAX_XCRESULT_ENTRIES,
                f"{label}: .xcresult entry count exceeds limit",
            )
    names.sort()
    return names


def hash_xcresult_directory(
    directory_fd: int,
    prefix: tuple[str, ...],
    files: list[dict[str, Any]],
    directories: set[str],
    seen_directories: set[tuple[int, int]],
    state: dict[str, int],
    label: str,
) -> None:
    check(len(prefix) <= MAX_XCRESULT_DEPTH, f"{label}: .xcresult nesting is too deep")
    before = os.fstat(directory_fd)
    check(stat.S_ISDIR(before.st_mode), f"{label}: .xcresult traversal left a directory")
    directory_identity = (before.st_dev, before.st_ino)
    check(directory_identity not in seen_directories, f"{label}: .xcresult directory identity is repeated")
    seen_directories.add(directory_identity)
    names = bounded_directory_names(directory_fd, label)
    check(len(names) == len(set(names)), f"{label}: .xcresult contains duplicate names")
    state["entries"] += len(names)
    check(state["entries"] <= MAX_XCRESULT_ENTRIES, f"{label}: .xcresult entry count exceeds limit")
    for name in names:
        check(isinstance(name, str) and name not in ("", ".", "..") and "/" not in name, f"{label}: unsafe entry name")
        relative_parts = (*prefix, name)
        relative = "/".join(relative_parts)
        lowered_parts = {part.lower() for part in relative_parts}
        check(
            not lowered_parts.intersection({"attachments", "screenshots"}),
            f"{label}: .xcresult contains content-bearing attachments",
        )
        try:
            entry = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as error:
            raise ValidationError(f"{label}: .xcresult entry changed during traversal") from error
        check(not stat.S_ISLNK(entry.st_mode), f"{label}: .xcresult contains a symlink")
        if stat.S_ISDIR(entry.st_mode):
            directories.add(relative)
            child_fd = open_directory_component(directory_fd, name, label)
            try:
                child_identity = filesystem_identity(os.fstat(child_fd))
                hash_xcresult_directory(
                    child_fd,
                    relative_parts,
                    files,
                    directories,
                    seen_directories,
                    state,
                    label,
                )
                entry_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                check(
                    filesystem_identity(entry_after) == child_identity,
                    f"{label}: .xcresult directory entry changed after traversal",
                )
            finally:
                os.close(child_fd)
            continue
        check(stat.S_ISREG(entry.st_mode), f"{label}: .xcresult contains a non-regular file")
        file_fd, file_before = open_regular_file(directory_fd, name, label)
        try:
            check(
                state["bytes"] + file_before.st_size <= MAX_XCRESULT_BYTES,
                f"{label}: .xcresult is too large",
            )
            hasher = hashlib.sha256()
            size = 0
            secret_tail = b""
            maximum_marker_length = max(map(len, XCRESULT_SECRET_MARKERS))
            while chunk := os.read(file_fd, XCRESULT_READ_CHUNK_BYTES):
                hasher.update(chunk)
                size += len(chunk)
                check(state["bytes"] + size <= MAX_XCRESULT_BYTES, f"{label}: .xcresult is too large")
                scan_window = (secret_tail + chunk).lower()
                for marker in XCRESULT_SECRET_MARKERS:
                    check(marker not in scan_window, f"{label}: .xcresult contains forbidden secret metadata")
                secret_tail = scan_window[-(maximum_marker_length - 1):]
            file_after = os.fstat(file_fd)
            check(size == file_before.st_size, f"{label}: .xcresult file size changed while hashing")
            check(
                stable_file_snapshot(file_before) == stable_file_snapshot(file_after),
                f"{label}: .xcresult file changed while hashing",
            )
            entry_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            check(
                filesystem_identity(entry_after) == filesystem_identity(file_after),
                f"{label}: .xcresult file entry changed after hashing",
            )
        finally:
            os.close(file_fd)
        state["bytes"] += size
        files.append({"path": relative, "sha256": hasher.hexdigest(), "size": size})
    names_after = bounded_directory_names(directory_fd, label)
    check(names_after == names, f"{label}: .xcresult directory entries changed while hashing")
    after = os.fstat(directory_fd)
    check(
        stable_directory_snapshot(before) == stable_directory_snapshot(after),
        f"{label}: .xcresult directory changed while hashing",
    )


def local_directory_digest(base: Path, relative: str, label: str) -> str:
    root_fd = open_relative_directory(base, relative, label)
    files: list[dict[str, Any]] = []
    directories: set[str] = set()
    state = {"bytes": 0, "entries": 1}
    try:
        hash_xcresult_directory(root_fd, (), files, directories, set(), state, label)
    except OSError as error:
        raise ValidationError(f"{label}: .xcresult changed during hashing") from error
    finally:
        os.close(root_fd)
    check(bool(files), f"{label}: .xcresult contains no files")
    check("Info.plist" in {item["path"] for item in files}, f"{label}: .xcresult is missing Info.plist")
    check("Data" in directories, f"{label}: .xcresult is missing Data")
    check(any(item["path"].startswith("Data/") for item in files), f"{label}: .xcresult Data is empty")
    files.sort(key=lambda item: item["path"])
    return digest({"files": files})


def validate_metadata_value(value: Any, label: str, *, network_only: bool = False) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = key.lower().replace("-", "_")
            check(normalized not in FORBIDDEN_METADATA_KEYS, f"{label}: forbidden secret/content field {key}")
            if network_only:
                check(
                    normalized not in {"headers", "request_headers", "response_headers", "body"},
                    f"{label}: network evidence must contain metadata only",
                )
            validate_metadata_value(item, f"{label}.{key}", network_only=network_only)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            validate_metadata_value(item, f"{label}[{index}]", network_only=network_only)
    elif isinstance(value, str):
        check(
            re.search(r"(?i)authorization\s*:\s*bearer\s+\S+", value) is None,
            f"{label}: bearer authorization data is forbidden",
        )
        check(
            re.search(r"(?i)(?:access|refresh)[_-]?token\s*[:=]\s*[A-Za-z0-9._~-]{8,}", value) is None,
            f"{label}: OAuth token data is forbidden",
        )


def validate_content_policy(raw: bytes, policy: str, label: str) -> Any | None:
    if policy not in ("metadata-json", "network-metadata-json"):
        return None
    value = parse_json_bytes(raw, require_canonical=False, label=label)
    validate_metadata_value(value, label, network_only=policy == "network-metadata-json")
    return value


def fetch_github_repository_file(
    source: dict[str, Any],
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    label: str,
) -> bytes:
    repository = source["repository"]
    path = source["path"]
    commit = source["commit_sha"]
    endpoint = f"repos/{repository}/contents/{quote(path, safe='/')}?ref={quote(commit, safe='')}"
    metadata = gh_api_json(gh_bin, ["--method", "GET", endpoint], f"{label} path", gh_environment)
    check(isinstance(metadata, dict), f"{label}: GitHub path response is not an object")
    check(metadata.get("type") == "file", f"{label}: GitHub object is not a file")
    check(metadata.get("path") == path, f"{label}: GitHub path differs from evidence")
    check(metadata.get("sha") == source["blob_sha"], f"{label}: GitHub blob differs from evidence")
    blob = gh_api_json(
        gh_bin,
        ["--method", "GET", f"repos/{repository}/git/blobs/{source['blob_sha']}"],
        f"{label} blob",
        gh_environment,
    )
    check(isinstance(blob, dict), f"{label}: GitHub blob response is not an object")
    check(blob.get("sha") == source["blob_sha"], f"{label}: GitHub blob SHA mismatch")
    check(blob.get("encoding") == "base64", f"{label}: GitHub blob is not base64 encoded")
    try:
        encoded = blob.get("content", "")
        check(isinstance(encoded, str), f"{label}: GitHub blob content is malformed")
        raw = base64.b64decode("".join(encoded.split()), validate=True)
    except (binascii.Error, ValueError, TypeError) as error:
        raise ValidationError(f"{label}: GitHub blob content is malformed") from error
    check(git_blob_sha(raw) == source["blob_sha"], f"{label}: Git blob bytes do not match the blob SHA")
    return raw


def normalized_artifact_run(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "conclusion": run.get("conclusion"),
        "created_at": run.get("created_at"),
        "event": run.get("event"),
        "head_branch": run.get("head_branch"),
        "head_sha": run.get("head_sha"),
        "id": run.get("id"),
        "repository": live_repository_name(run),
        "run_attempt": run.get("run_attempt"),
        "status": run.get("status"),
        "updated_at": run.get("updated_at"),
        "workflow_path": live_workflow_path(run),
    }


def fetch_github_actions_run(
    source: dict[str, Any],
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    label: str,
) -> bytes:
    endpoint = f"repos/{source['repository']}/actions/runs/{source['run_id']}"
    value = gh_api_json(gh_bin, ["--method", "GET", endpoint], label, gh_environment)
    check(isinstance(value, dict), f"{label}: GitHub run response is not an object")
    normalized = normalized_artifact_run(value)
    check(normalized["id"] == source["run_id"], f"{label}: run ID mismatch")
    check(normalized["repository"] == source["repository"], f"{label}: repository mismatch")
    check(normalized["workflow_path"] == source["workflow_path"], f"{label}: workflow mismatch")
    check(normalized["head_sha"] == source["head_sha"], f"{label}: head SHA mismatch")
    check(normalized["status"] == "completed", f"{label}: run is nonterminal")
    check(normalized["conclusion"] == "success", f"{label}: run did not succeed")
    return canonical_bytes(normalized)


def resolve_release_tag(
    repository: str,
    tag: str,
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    label: str,
) -> str:
    reference = gh_api_json(
        gh_bin,
        ["--method", "GET", f"repos/{repository}/git/ref/tags/{quote(tag, safe='')}"],
        f"{label} tag",
        gh_environment,
    )
    check(isinstance(reference, dict) and isinstance(reference.get("object"), dict), f"{label}: tag is malformed")
    target = reference["object"]
    for _ in range(4):
        target_type = target.get("type")
        target_sha = target.get("sha")
        check(isinstance(target_sha, str), f"{label}: tag target SHA is malformed")
        if target_type == "commit":
            return target_sha
        check(target_type == "tag", f"{label}: tag does not resolve to a commit")
        annotated = gh_api_json(
            gh_bin,
            ["--method", "GET", f"repos/{repository}/git/tags/{target_sha}"],
            f"{label} annotated tag",
            gh_environment,
        )
        check(
            isinstance(annotated, dict) and isinstance(annotated.get("object"), dict),
            f"{label}: annotated tag is malformed",
        )
        target = annotated["object"]
    raise ValidationError(f"{label}: tag indirection is too deep")


def verify_github_release_asset(
    source: dict[str, Any],
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    label: str,
) -> str:
    release = gh_api_json(
        gh_bin,
        ["--method", "GET", f"repos/{source['repository']}/releases/{source['release_id']}"],
        f"{label} release",
        gh_environment,
    )
    check(isinstance(release, dict), f"{label}: release response is not an object")
    check(release.get("id") == source["release_id"], f"{label}: release ID mismatch")
    check(release.get("tag_name") == source["release_tag"], f"{label}: release tag mismatch")
    check(release.get("draft") is False, f"{label}: release draft state mismatch")
    expected_prerelease = source.get("release_prerelease")
    expected_immutable = source.get("release_immutable")
    check(expected_prerelease is True, f"{label}: pinned release must be prerelease")
    check(expected_immutable is True, f"{label}: pinned release must be immutable")
    check(
        release.get("prerelease") is expected_prerelease,
        f"{label}: release prerelease state mismatch",
    )
    check(
        release.get("immutable") is expected_immutable,
        f"{label}: release immutable state mismatch",
    )
    check(
        release.get("published_at") == source.get("release_published_at"),
        f"{label}: release published time mismatch",
    )
    assets = release.get("assets")
    check(isinstance(assets, list), f"{label}: release assets are malformed")
    matching = [asset for asset in assets if isinstance(asset, dict) and asset.get("id") == source["asset_id"]]
    check(len(matching) == 1, f"{label}: release asset ID is not unique")
    check(matching[0].get("name") == source["asset_name"], f"{label}: release asset name mismatch")
    check(
        resolve_release_tag(
            source["repository"],
            source["release_tag"],
            gh_bin,
            gh_environment,
            label,
        )
        == source["source_sha"],
        f"{label}: release tag source mismatch",
    )
    return gh_api_download_digest(
        gh_bin,
        f"repos/{source['repository']}/releases/assets/{source['asset_id']}",
        label,
        gh_environment,
        release_asset=True,
    )


def required_xcresult_test_for_source(source: Mapping[str, Any]) -> str | None:
    if source.get("role") == "g4-attestation-xcresult":
        return G4_ATTESTATION_XCRESULT_TEST
    if source.get("artifact_name") == G5_XCRESULT_ARTIFACT_NAME:
        return G5_ACTUAL_TWO_CLIENT_XCRESULT_TEST
    return None


def verify_github_actions_artifact(
    source: dict[str, Any],
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    label: str,
) -> str:
    run_source = {
        "head_sha": source["head_sha"],
        "repository": source["repository"],
        "run_id": source["run_id"],
        "workflow_path": source.get("workflow_path", ".github/workflows/ci.yml"),
    }
    run = gh_api_json(
        gh_bin,
        ["--method", "GET", f"repos/{source['repository']}/actions/runs/{source['run_id']}"],
        f"{label} run",
        gh_environment,
    )
    check(isinstance(run, dict), f"{label}: run response is not an object")
    normalized = normalized_artifact_run(run)
    check(normalized["id"] == run_source["run_id"], f"{label}: run ID mismatch")
    check(normalized["repository"] == run_source["repository"], f"{label}: repository mismatch")
    check(normalized["head_sha"] == run_source["head_sha"], f"{label}: head SHA mismatch")
    check(
        normalized["workflow_path"] == run_source["workflow_path"],
        f"{label}: workflow path mismatch",
    )
    check(
        normalized["status"] == "completed" and normalized["conclusion"] == "success",
        f"{label}: run did not succeed",
    )
    artifact = gh_api_json(
        gh_bin,
        ["--method", "GET", f"repos/{source['repository']}/actions/artifacts/{source['artifact_id']}"],
        f"{label} metadata",
        gh_environment,
    )
    check(isinstance(artifact, dict), f"{label}: artifact response is not an object")
    check(artifact.get("id") == source["artifact_id"], f"{label}: artifact ID mismatch")
    check(artifact.get("name") == source["artifact_name"], f"{label}: artifact name mismatch")
    check(artifact.get("expired") is False, f"{label}: artifact is expired")
    check(
        artifact.get("created_at") == source.get("artifact_created_at"),
        f"{label}: artifact created time mismatch",
    )
    check(
        artifact.get("expires_at") == source.get("artifact_expires_at"),
        f"{label}: artifact expiration time mismatch",
    )
    workflow_run = artifact.get("workflow_run")
    check(
        isinstance(workflow_run, dict) and workflow_run.get("id") == source["run_id"],
        f"{label}: artifact run mismatch",
    )
    return gh_api_download_digest(
        gh_bin,
        f"repos/{source['repository']}/actions/artifacts/{source['artifact_id']}/zip",
        label,
        gh_environment,
        require_xcresult=True,
        required_xcresult_test=required_xcresult_test_for_source(source),
    )


def verify_artifact_source(
    source: dict[str, Any],
    evidence_directory: Path,
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    test_remote_artifacts: Mapping[str, bytes] | None,
    test_xcresult_results: Mapping[str, str | list[str]] | None,
    label: str,
) -> Any | None:
    kind = source["kind"]
    raw: bytes | None = None
    actual_digest: str
    if kind == "local-file":
        raw = read_local_file(evidence_directory, source["path"], label)
        actual_digest = hashlib.sha256(raw).hexdigest()
    elif kind == "local-directory":
        actual_digest = local_directory_digest(evidence_directory, source["path"], label)
    elif test_remote_artifacts is not None:
        key = source_identity_key(source)
        check(key in test_remote_artifacts, f"{label}: test remote artifact is unavailable")
        raw = test_remote_artifacts[key]
        if kind == "github-actions-artifact":
            required_test = required_xcresult_test_for_source(source)
            validate_xcresult_archive(
                io.BytesIO(raw),
                label,
                required_test=required_test,
                test_results=test_xcresult_results if required_test is not None else None,
            )
        actual_digest = hashlib.sha256(raw).hexdigest()
    elif kind == "github-repository-file":
        raw = fetch_github_repository_file(source, gh_bin, gh_environment, label)
        actual_digest = hashlib.sha256(raw).hexdigest()
    elif kind == "github-actions-run":
        raw = fetch_github_actions_run(source, gh_bin, gh_environment, label)
        actual_digest = hashlib.sha256(raw).hexdigest()
    elif kind == "github-actions-artifact":
        actual_digest = verify_github_actions_artifact(source, gh_bin, gh_environment, label)
    elif kind == "github-release-asset":
        actual_digest = verify_github_release_asset(source, gh_bin, gh_environment, label)
    else:
        raise ValidationError(f"{label}: unsupported artifact source kind")
    check(actual_digest == source["sha256"], f"{label}: artifact bytes do not match SHA-256")
    if raw is None:
        return None
    if source.get("role") == "g4-attestation-source":
        payload = parse_json_bytes(raw, require_canonical=True, label=label)
        validate_metadata_value(payload, label, network_only=False)
    else:
        payload = validate_content_policy(raw, source["content_policy"], label)
    if kind == "github-actions-run":
        check(isinstance(payload, dict), f"{label}: run metadata is not an object")
        check(payload.get("id") == source["run_id"], f"{label}: run ID mismatch")
        check(payload.get("repository") == source["repository"], f"{label}: repository mismatch")
        check(payload.get("workflow_path") == source["workflow_path"], f"{label}: workflow mismatch")
        check(payload.get("head_sha") == source["head_sha"], f"{label}: head SHA mismatch")
        check(payload.get("status") == "completed", f"{label}: run is nonterminal")
        check(payload.get("conclusion") == "success", f"{label}: run did not succeed")
    return payload


def manifest_repository(manifest: dict[str, Any], name: str, label: str) -> dict[str, Any]:
    repositories = manifest.get("repositories")
    check(isinstance(repositories, list), f"{label}: repositories must be an array")
    matches = [entry for entry in repositories if isinstance(entry, dict) and entry.get("name") == name]
    check(len(matches) == 1, f"{label}: expected exactly one {name} repository entry")
    return matches[0]


def validate_terminal_commands(
    record: dict[str, Any],
    label: str,
    *,
    require_identity: bool = False,
) -> None:
    commands = record.get("commands")
    check(isinstance(commands, list) and bool(commands), f"{label}: commands must be non-empty")
    for index, command in enumerate(commands):
        check(isinstance(command, dict), f"{label}: command {index} is malformed")
        if require_identity:
            argv = command.get("argv")
            check(
                isinstance(argv, list)
                and bool(argv)
                and all(isinstance(argument, str) and bool(argument) for argument in argv),
                f"{label}: command {index} argv is malformed",
            )
            check(
                set(command) == {"argv", "exit_code", "terminal"},
                f"{label}: command {index} fields are not exact",
            )
        exit_code = command.get("exit_code")
        check(
            isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code == 0,
            f"{label}: command {index} did not pass",
        )
        check(command.get("terminal") is True, f"{label}: command {index} is nonterminal")


def validate_task_manifest(
    gate_name: str,
    manifest: Any,
    inputs: dict[str, Any],
) -> dict[str, Any]:
    label = f"{gate_name} task manifest"
    check(isinstance(manifest, dict), f"{label}: root must be an object")
    check(manifest.get("task_id") == TASK_BY_GATE[gate_name], f"{label}: wrong task ID")
    expected_state = "g5_completed" if gate_name == "g5" else "completed"
    check(
        manifest.get("state") == expected_state,
        f"{label}: state is not {expected_state}",
    )
    validate_terminal_commands(manifest, label)
    if gate_name == "g1":
        floorp = manifest_repository(manifest, "Floorp", label)
        check(floorp.get("merged_oid") == TODO16_MERGED_SHA, f"{label}: Todo 16 merged provenance mismatch")
    elif gate_name == "g2":
        services = manifest_repository(manifest, "application-services", label)
        check(
            services.get("merged_oid") == inputs["application_services"]["source_sha"],
            f"{label}: Application Services provenance mismatch",
        )
    elif gate_name == "g4":
        desktop = manifest_repository(manifest, "Floorp", label)
        runtime = manifest_repository(manifest, "Floorp-Runtime", label)
        check(desktop.get("merged_oid") == inputs["desktop"]["source_sha"], f"{label}: Desktop provenance mismatch")
        check(runtime.get("merged_oid") == inputs["runtime"]["source_sha"], f"{label}: Runtime provenance mismatch")
    elif gate_name == "g5":
        ios = manifest_repository(manifest, "floorp-ios", label)
        check(
            ios.get("head_oid") == inputs["ios"]["source_sha"],
            f"{label}: iOS candidate provenance mismatch",
        )
        check("merged_oid" not in ios, f"{label}: G5 operation must not claim a merged OID")
    return manifest


def validate_integration_receipt(
    receipt: Any,
    inputs: dict[str, Any],
) -> dict[str, Any]:
    label = "G3 integration receipt"
    check(isinstance(receipt, dict), f"{label}: root must be an object")
    check(
        set(receipt) == {"commands", "repositories", "schema_version", "state", "task_id"},
        f"{label}: root fields are not exact",
    )
    schema_version = receipt.get("schema_version")
    check(
        isinstance(schema_version, int)
        and not isinstance(schema_version, bool)
        and schema_version == 1,
        f"{label}: schema version mismatch",
    )
    check(receipt.get("task_id") == 19, f"{label}: wrong task ID")
    check(receipt.get("state") == "integration_complete", f"{label}: state is not integration_complete")
    validate_terminal_commands(receipt, label, require_identity=True)
    repositories = receipt.get("repositories")
    check(isinstance(repositories, list) and len(repositories) == 1, f"{label}: repository set is not exact")
    ios = manifest_repository(receipt, "floorp-ios", label)
    check(
        set(ios) == {"base_oid", "head_oid", "merged_oid", "name"},
        f"{label}: repository fields are not exact",
    )
    for field in ("base_oid", "head_oid", "merged_oid"):
        check(
            isinstance(ios.get(field), str) and re.fullmatch(r"[0-9a-f]{40}", ios[field]) is not None,
            f"{label}: {field} is not a Git SHA",
        )
    check(
        ios["merged_oid"] == inputs["ios"]["source_sha"],
        f"{label}: merged iOS provenance mismatch",
    )
    return receipt


def require_source(
    sources: dict[str, dict[str, Any]],
    role: str,
    kinds: tuple[str, ...],
    policy: str,
    label: str,
) -> dict[str, Any]:
    source = sources[role]
    check(source["kind"] in kinds, f"{label}: {role} has the wrong provenance kind")
    check(source["content_policy"] == policy, f"{label}: {role} has the wrong content policy")
    return source


def validate_passed_summary(
    payload: Any,
    label: str,
    *,
    require_payload_redaction: bool = False,
) -> None:
    check(isinstance(payload, dict), f"{label}: summary must be an object")
    passed = payload.get("passed")
    check(isinstance(passed, int) and not isinstance(passed, bool) and passed > 0, f"{label}: no passing tests")
    check(payload.get("failed") == 0, f"{label}: failures were reported")
    check(payload.get("secrets_retained") is False, f"{label}: secret-retention proof is missing")
    if require_payload_redaction:
        check(payload.get("payload_retained") is False, f"{label}: Notes payload-retention proof is missing")


def validate_gate_source_semantics(
    gate_name: str,
    gate: dict[str, Any],
    sources: dict[str, dict[str, Any]],
    manifest: dict[str, Any],
    inputs: dict[str, Any],
    payloads: dict[str, Any | None],
) -> None:
    label = f"{gate_name} retrievable artifact provenance"
    provenance_role = "integration-receipt" if gate_name == "g3" else "task-manifest"
    provenance_source = require_source(
        sources,
        provenance_role,
        ("local-file",),
        "metadata-json",
        label,
    )
    if gate_name == "g3":
        check(
            provenance_source["path"] == "artifacts/task-19-integration-receipt.json",
            f"{label}: integration receipt path is not canonical",
        )
    if gate_name == "g1":
        todo16 = require_source(sources, "todo16-contract", ("github-repository-file",), "metadata-json", label)
        check(
            (
                todo16["repository"],
                todo16["commit_sha"],
                todo16["path"],
            )
            == (
                TODO16_REPOSITORY,
                TODO16_MERGED_SHA,
                TODO16_TRUST_FILES["signer_registry"]["path"],
            ),
            f"{label}: Todo 16 contract object is not canonical",
        )
        todo16_payload = payloads["todo16-contract"]
        check(isinstance(todo16_payload, dict), f"{label}: Todo 16 contract is not JSON")
        production = todo16_payload.get("production_environment")
        check(isinstance(production, dict), f"{label}: Todo 16 production authority is missing")
        check(production.get("status") == "approved", f"{label}: production authority is not approved")
        check(production.get("fxa_configuration") == "FxAConfig.Server.release", f"{label}: FxA authority mismatch")
        check(tuple(production.get("fxa_hosts", ())) == EXPECTED_FXA_HOSTS, f"{label}: FxA hosts mismatch")
        check(tuple(production.get("sync_hosts", ())) == EXPECTED_SYNC_HOSTS, f"{label}: Sync hosts mismatch")
        check(production.get("wire") == "sync15", f"{label}: wire protocol mismatch")
        check(production.get("application_record_id") == EXPECTED_RECORD_ID, f"{label}: record ID mismatch")
        check(
            production.get("endpoint_policy_sha256") == EXPECTED_ENDPOINT_POLICY_SHA256,
            f"{label}: endpoint policy mismatch",
        )
        g6_authority = todo16_payload.get("g6")
        check(isinstance(g6_authority, dict), f"{label}: G6 authority is missing")
        check(
            g6_authority.get("allowed_signers_path") == TODO16_TRUST_FILES["allowed_signers"]["path"],
            f"{label}: G6 allowed-signers path mismatch",
        )
        check(
            g6_authority.get("revocations_path") == TODO16_TRUST_FILES["revocations"]["path"],
            f"{label}: G6 revocations path mismatch",
        )
        ios_source = require_source(sources, "ios-contract-source", ("github-repository-file",), "source-code", label)
        check(
            (ios_source["repository"], ios_source["commit_sha"], ios_source["path"])
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                "docs/floorp-notes-sync-architecture.md",
            ),
            f"{label}: iOS contract source is not bound to the candidate",
        )
        desktop_source = require_source(
            sources,
            "desktop-contract-source",
            ("github-repository-file",),
            "source-code",
            label,
        )
        check(
            (desktop_source["repository"], desktop_source["commit_sha"], desktop_source["path"])
            == (
                inputs["desktop"]["repository"],
                inputs["desktop"]["source_sha"],
                "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
            ),
            f"{label}: Desktop contract source is not bound to the candidate",
        )
        fixture = require_source(sources, "merge-fixture", ("github-repository-file",), "metadata-json", label)
        check(
            (fixture["repository"], fixture["commit_sha"], fixture["path"], fixture["sha256"])
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
                inputs["contract"]["fixture_sha256"],
            ),
            f"{label}: merge fixture is not bound to the candidate",
        )
    elif gate_name == "g2":
        fake_server = require_source(sources, "fake-server-run", ("local-file",), "metadata-json", label)
        check(fake_server["sha256"] == gate["fake_server_run_sha256"], f"{label}: fake-server digest mismatch")
        validate_passed_summary(payloads["fake-server-run"], f"{label}: fake-server")
        for role, (asset_name, input_name) in ASSET_ROLE_TO_INPUT.items():
            asset = require_source(sources, role, ("github-release-asset",), "release-binary", label)
            check(
                asset["repository"] == inputs["application_services"]["repository"],
                f"{label}: asset repository mismatch",
            )
            check(
                asset["release_tag"] == inputs["application_services"]["release_tag"],
                f"{label}: asset tag mismatch",
            )
            check(
                asset["source_sha"] == inputs["application_services"]["source_sha"],
                f"{label}: asset source mismatch",
            )
            check(asset["asset_name"] == asset_name, f"{label}: asset name mismatch")
            check(
                asset["sha256"] == inputs["application_services"]["artifacts"][input_name],
                f"{label}: asset digest mismatch",
            )
    elif gate_name == "g3":
        ci_run = require_source(sources, "ci-run", ("github-actions-run",), "metadata-json", label)
        ci_run_payload = payloads["ci-run"]
        check(isinstance(ci_run_payload, dict), f"{label}: iOS CI run metadata is malformed")
        check(
            (ci_run_payload.get("event"), ci_run_payload.get("head_branch")) == ("push", "main"),
            f"{label}: iOS CI run is not a main push",
        )
        check(
            (ci_run["repository"], ci_run["head_sha"], ci_run["workflow_path"])
            == (inputs["ios"]["repository"], inputs["ios"]["source_sha"], G3_CI_WORKFLOW_PATH),
            f"{label}: iOS CI run is not bound to the candidate",
        )
        xcresult = require_source(
            sources,
            "xcresult",
            ("github-actions-artifact",),
            "test-result-bundle",
            label,
        )
        check(
            (
                xcresult["repository"],
                xcresult["head_sha"],
                xcresult["run_id"],
            )
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                ci_run["run_id"],
            ),
            f"{label}: xcresult artifact is not bound to the iOS CI run",
        )
        check(
            xcresult["artifact_name"] == "floorp-notes-sync-xcresult",
            f"{label}: xcresult artifact name is not canonical",
        )
        check(xcresult["sha256"] == gate["xcresult_sha256"], f"{label}: xcresult digest mismatch")
    elif gate_name == "g4":
        desktop_manifest = manifest_repository(manifest, "Floorp", label)
        runtime_manifest = manifest_repository(manifest, "Floorp-Runtime", label)
        desktop_run = require_source(sources, "desktop-ci-run", ("github-actions-run",), "metadata-json", label)
        runtime_run = require_source(sources, "runtime-ci-run", ("github-actions-run",), "metadata-json", label)
        desktop_run_payload = payloads["desktop-ci-run"]
        check(isinstance(desktop_run_payload, dict), f"{label}: Desktop CI run metadata is malformed")
        check(
            inputs["desktop"]["build_number"] == str(desktop_run_payload.get("id")),
            f"{label}: Desktop build number is not bound to the CI run ID",
        )
        check(
            (desktop_run["repository"], desktop_run["head_sha"], desktop_run["workflow_path"])
            == (
                inputs["desktop"]["repository"],
                desktop_manifest.get("head_oid"),
                ".github/workflows/colocated_runner_test.yml",
            ),
            f"{label}: Desktop CI run is not bound to the reviewed head",
        )
        check(
            (runtime_run["repository"], runtime_run["head_sha"], runtime_run["workflow_path"])
            == (
                inputs["runtime"]["repository"],
                runtime_manifest.get("head_oid"),
                ".github/workflows/wrapper-mac-build.yml",
            ),
            f"{label}: Runtime CI run is not bound to the reviewed head",
        )
        attestation_source = require_source(
            sources,
            "g4-attestation-source",
            ("github-repository-file",),
            "metadata-json",
            label,
        )
        check(
            (
                attestation_source["repository"],
                attestation_source["commit_sha"],
                attestation_source["path"],
            )
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                G4_ATTESTATION_PATH,
            ),
            f"{label}: G4 attestation source is not bound to the merged iOS candidate",
        )
        attestation_run = require_source(
            sources,
            "g4-attestation-ci-run",
            ("github-actions-run",),
            "metadata-json",
            label,
        )
        attestation_run_payload = payloads["g4-attestation-ci-run"]
        check(isinstance(attestation_run_payload, dict), f"{label}: G4 attestation run is malformed")
        check(
            (attestation_run_payload.get("event"), attestation_run_payload.get("head_branch"))
            == ("push", "main"),
            f"{label}: G4 attestation run is not a main push",
        )
        check(
            (
                attestation_run["repository"],
                attestation_run["head_sha"],
                attestation_run["workflow_path"],
            )
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                ".github/workflows/ci.yml",
            ),
            f"{label}: G4 attestation run is not bound to the merged iOS candidate",
        )
        attestation_xcresult = require_source(
            sources,
            "g4-attestation-xcresult",
            ("github-actions-artifact",),
            "test-result-bundle",
            label,
        )
        check(
            (
                attestation_xcresult["repository"],
                attestation_xcresult["head_sha"],
                attestation_xcresult["run_id"],
                attestation_xcresult["artifact_name"],
            )
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                attestation_run["run_id"],
                "floorp-notes-sync-xcresult",
            ),
            f"{label}: G4 attestation xcresult is not bound to the attestation run",
        )
        xpcshell = require_source(sources, "xpcshell-run", ("local-file",), "metadata-json", label)
        tps = require_source(sources, "tps-run", ("local-file",), "metadata-json", label)
        check(xpcshell["sha256"] == gate["xpcshell_run_sha256"], f"{label}: xpcshell digest mismatch")
        check(tps["sha256"] == gate["tps_run_sha256"], f"{label}: TPS digest mismatch")
        validate_passed_summary(payloads["xpcshell-run"], f"{label}: xpcshell")
        validate_passed_summary(
            payloads["tps-run"],
            f"{label}: TPS",
            require_payload_redaction=True,
        )
        expected_attestation = {
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
                "execution_verdict_sha256": sources["task18-execution-verdict"]["sha256"],
                "task_manifest_sha256": sources["task-manifest"]["sha256"],
                "tps_sha256": tps["sha256"],
                "xpcshell_sha256": xpcshell["sha256"],
            },
            "task_id": 18,
        }
        check(
            payloads["g4-attestation-source"] == expected_attestation,
            f"{label}: G4 external attestation does not bind the exact producer records",
        )
        execution_verdict = require_source(
            sources,
            "task18-execution-verdict",
            ("local-file",),
            "metadata-json",
            label,
        )
        check(
            execution_verdict["sha256"]
            == expected_attestation["summaries"]["execution_verdict_sha256"],
            f"{label}: Task 18 execution verdict digest is not attested",
        )
        check(
            payloads["task18-execution-verdict"]
            == {
                "errors": [],
                "tasks": [
                    {"completion_claim_count": 1, "id": 16, "state": "completed"},
                    {"completion_claim_count": 1, "id": 18, "state": "completed"},
                ],
                "verdict": "APPROVE",
            },
            f"{label}: Task 18 execution-validator verdict is not the exact APPROVE record",
        )
    elif gate_name == "g5":
        ci_run = require_source(sources, "ci-run", ("github-actions-run",), "metadata-json", label)
        check(
            (ci_run["repository"], ci_run["head_sha"], ci_run["workflow_path"])
            == (inputs["ios"]["repository"], inputs["ios"]["source_sha"], G5_CI_WORKFLOW_PATH),
            f"{label}: two-client CI run is not bound to the candidate",
        )
        xcresult = require_source(
            sources,
            "xcresult",
            ("github-actions-artifact",),
            "test-result-bundle",
            label,
        )
        check(
            (
                xcresult["repository"],
                xcresult["head_sha"],
                xcresult["run_id"],
            )
            == (
                inputs["ios"]["repository"],
                inputs["ios"]["source_sha"],
                ci_run["run_id"],
            ),
            f"{label}: xcresult artifact is not bound to the two-client CI run",
        )
        check(
            xcresult["artifact_name"] == G5_XCRESULT_ARTIFACT_NAME,
            f"{label}: two-client xcresult artifact name is not canonical",
        )
        ci_run_payload = payloads["ci-run"]
        check(isinstance(ci_run_payload, dict), f"{label}: two-client CI run metadata is malformed")
        check(
            (ci_run_payload.get("event"), ci_run_payload.get("head_branch"))
            == (G5_CI_EVENT, G5_CI_HEAD_BRANCH),
            f"{label}: two-client CI run is not an explicit main dispatch",
        )
        isolation = require_source(sources, "account-isolation-run", ("local-file",), "metadata-json", label)
        proxy = require_source(sources, "proxy-trace", ("local-file",), "network-metadata-json", label)
        check(isolation["sha256"] == gate["account_isolation_run_sha256"], f"{label}: isolation digest mismatch")
        check(proxy["sha256"] == gate["proxy_trace_sha256"], f"{label}: proxy digest mismatch")
        isolation_payload = payloads["account-isolation-run"]
        check(isinstance(isolation_payload, dict), f"{label}: isolation summary is malformed")
        expected_isolation = {
            "accounts": 2,
            "base_advanced_after_upload": True,
            "cleanup_completed": True,
            "fixture_sha256": EXPECTED_FIXTURE_SHA256,
            "isolated": True,
            "local_only_fallback_succeeded": True,
            "payload_retained": False,
            "rollback_succeeded": True,
            "secrets_retained": False,
        }
        check(
            isolation_payload == expected_isolation,
            f"{label}: isolation, cleanup, rollback, or local-only fallback proof is incomplete",
        )
        proxy_payload = payloads["proxy-trace"]
        check(isinstance(proxy_payload, dict), f"{label}: proxy summary is malformed")
        hosts = proxy_payload.get("hosts")
        check(
            isinstance(hosts, list)
            and bool(hosts)
            and all(isinstance(host, str) for host in hosts)
            and len(hosts) == len(set(hosts)),
            f"{label}: proxy hosts are malformed or duplicated",
        )
        check(
            set(hosts) <= set(EXPECTED_FXA_HOSTS) | set(EXPECTED_SYNC_HOSTS),
            f"{label}: proxy trace contains an unapproved host",
        )
        check(
            G5_REQUIRED_SYNC_HOST in hosts,
            f"{label}: proxy trace does not prove an approved Sync host",
        )
        expected_proxy = {
            "endpoint_policy_sha256": EXPECTED_ENDPOINT_POLICY_SHA256,
            "hosts": hosts,
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        }
        check(
            proxy_payload == expected_proxy,
            f"{label}: proxy trace lacks exact metadata-only TLS evidence",
        )


def validate_artifact_bound_gate_time(
    gate_name: str,
    gate: dict[str, Any],
    sources: dict[str, dict[str, Any]],
    payloads: dict[str, Any | None],
    trusted_now: datetime,
) -> None:
    max_age_days: int
    raw_anchors: list[Any]
    if gate_name == "g2":
        max_age_days = 30
        raw_anchors = [
            sources[role].get("release_published_at")
            for role in ASSET_ROLE_TO_INPUT
        ]
        check(len(set(raw_anchors)) == 1, "G2: release artifact times are mixed")
    elif gate_name in ("g3", "g5"):
        max_age_days = 7
        xcresult = sources["xcresult"]
        raw_anchors = [xcresult.get("artifact_created_at")]
    elif gate_name == "g4":
        max_age_days = 30
        desktop_run = payloads.get("desktop-ci-run")
        runtime_run = payloads.get("runtime-ci-run")
        attestation_run = payloads.get("g4-attestation-ci-run")
        check(isinstance(desktop_run, dict), "G4: Desktop CI artifact time is unavailable")
        check(isinstance(runtime_run, dict), "G4: Runtime CI artifact time is unavailable")
        check(isinstance(attestation_run, dict), "G4: attestation CI artifact time is unavailable")
        raw_anchors = [
            desktop_run.get("created_at"),
            runtime_run.get("created_at"),
            attestation_run.get("created_at"),
        ]
    else:
        return

    anchors = [
        parse_timestamp(raw, f"{gate_name.upper()} artifact time")
        for raw in raw_anchors
    ]
    issued_at = parse_timestamp(gate["issued_at"], f"{gate_name.upper()}.issued_at")
    check(
        issued_at == max(anchors),
        f"{gate_name.upper()}: issued_at does not match the XCResult artifact time"
        if gate_name in ("g3", "g5")
        else f"{gate_name.upper()}: issued_at does not match the artifact time",
    )
    expires_at = parse_timestamp(gate["expires_at"], f"{gate_name.upper()}.expires_at")
    artifact_deadline = min(anchor + timedelta(days=max_age_days) for anchor in anchors)
    if gate_name in ("g3", "g5"):
        xcresult_deadline = parse_timestamp(
            sources["xcresult"].get("artifact_expires_at"),
            f"{gate_name.upper()} XCResult artifact time",
        )
        artifact_deadline = min(artifact_deadline, xcresult_deadline)
    elif gate_name == "g4":
        attestation_deadline = parse_timestamp(
            sources["g4-attestation-xcresult"].get("artifact_expires_at"),
            "G4 attestation XCResult artifact time",
        )
        artifact_deadline = min(artifact_deadline, attestation_deadline)
    check(
        expires_at <= artifact_deadline,
        f"{gate_name.upper()}: expiration exceeds the XCResult artifact time lifetime"
        if gate_name in ("g3", "g4", "g5")
        else f"{gate_name.upper()}: expiration exceeds the artifact time lifetime",
    )
    check(
        trusted_now <= artifact_deadline,
        f"{gate_name.upper()}: artifact time exceeds maximum age",
    )


def validate_gate_artifacts(
    evidence: dict[str, Any],
    evidence_directory: Path,
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    test_remote_artifacts: Mapping[str, bytes] | None,
    test_xcresult_results: Mapping[str, str | list[str]] | None,
    trusted_now: datetime,
) -> None:
    inputs = evidence["release_inputs"]
    for gate_name in G1_G5_NAMES:
        if gate_name not in evidence["gates"]:
            continue
        gate = evidence["gates"][gate_name]
        artifact = gate["artifact"]
        sources_list = artifact.get("sources")
        check(isinstance(sources_list, list), f"{gate_name}: retrievable artifact provenance is missing")
        roles = tuple(source.get("role") for source in sources_list if isinstance(source, dict))
        check(
            roles == GATE_SOURCE_ROLES[gate_name],
            f"{gate_name}: retrievable artifact provenance roles are not exact",
        )
        check(
            artifact.get("sha256") == digest({"sources": sources_list}),
            f"{gate_name}: artifact bundle digest mismatch",
        )
        sources = {source["role"]: source for source in sources_list}
        payloads: dict[str, Any | None] = {}
        for source in sources_list:
            payloads[source["role"]] = verify_artifact_source(
                source,
                evidence_directory,
                gh_bin,
                gh_environment,
                test_remote_artifacts,
                test_xcresult_results,
                f"{gate_name} {source['role']}",
            )
        if gate_name == "g3":
            manifest = validate_integration_receipt(payloads["integration-receipt"], inputs)
        else:
            manifest = validate_task_manifest(gate_name, payloads["task-manifest"], inputs)
        validate_gate_source_semantics(gate_name, gate, sources, manifest, inputs, payloads)
        validate_artifact_bound_gate_time(gate_name, gate, sources, payloads, trusted_now)

    if "g3" in evidence["gates"] and "g4" in evidence["gates"]:
        g3_sources = {
            source["role"]: source
            for source in evidence["gates"]["g3"]["artifact"]["sources"]
        }
        g4_sources = {
            source["role"]: source
            for source in evidence["gates"]["g4"]["artifact"]["sources"]
        }
        for g3_role, g4_role in (
            ("ci-run", "g4-attestation-ci-run"),
            ("xcresult", "g4-attestation-xcresult"),
        ):
            g3_source = {key: value for key, value in g3_sources[g3_role].items() if key != "role"}
            g4_source = {key: value for key, value in g4_sources[g4_role].items() if key != "role"}
            check(
                g4_source == g3_source,
                f"G4 external attestation does not reuse the exact G3 {g3_role}",
            )


def validate_gate_time(name: str, gate: dict[str, Any], trusted_now: datetime, max_age_days: int | None) -> None:
    issued_at = parse_timestamp(gate["issued_at"], f"{name}.issued_at")
    check(issued_at <= trusted_now, f"{name}: evidence is from the future")
    if max_age_days is None:
        return
    expires_at = parse_timestamp(gate["expires_at"], f"{name}.expires_at")
    check(expires_at > issued_at, f"{name}: expiration does not follow issuance")
    check(expires_at <= issued_at + timedelta(days=max_age_days), f"{name}: expiration exceeds maximum lifetime")
    check(trusted_now <= expires_at, f"{name}: evidence is expired")
    check(trusted_now <= issued_at + timedelta(days=max_age_days), f"{name}: evidence exceeds maximum age")


def load_revocations(raw: bytes, trusted_now: datetime) -> tuple[set[str], set[str]]:
    registry = parse_json_bytes(raw, require_canonical=False, label="G6 revocations")
    check(isinstance(registry, dict), "G6 revocations: root must be an object")
    allowed_root = {"schema_version", "note", "revocations"}
    check(set(registry) <= allowed_root, "G6 revocations: unexpected root field")
    check(registry.get("schema_version") == 1, "G6 revocations: schema_version must be 1")
    entries = registry.get("revocations")
    check(isinstance(entries, list), "G6 revocations: revocations must be an array")
    revoked_keys: set[str] = set()
    revoked_approvals: set[str] = set()
    seen: set[tuple[str, str]] = set()
    for index, entry in enumerate(entries):
        label = f"G6 revocations[{index}]"
        check(isinstance(entry, dict), f"{label}: entry must be an object")
        check(
            set(entry) == {"identifier", "kind", "reason", "revoked_at"},
            f"{label}: entry fields are not exact",
        )
        kind = entry["kind"]
        identifier = entry["identifier"]
        check(kind in ("key", "approval"), f"{label}: unknown revocation kind")
        check(isinstance(entry["reason"], str) and bool(entry["reason"]), f"{label}: reason is empty")
        revoked_at = parse_timestamp(entry["revoked_at"], f"{label}.revoked_at")
        check(revoked_at <= trusted_now, f"{label}: revocation is from the future")
        if kind == "key":
            check(
                isinstance(identifier, str) and re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", identifier) is not None,
                f"{label}: invalid key fingerprint",
            )
            revoked_keys.add(identifier)
        else:
            check(
                isinstance(identifier, str) and re.fullmatch(r"[0-9a-f]{64}", identifier) is not None,
                f"{label}: invalid approval digest",
            )
            revoked_approvals.add(identifier)
        check((kind, identifier) not in seen, f"{label}: duplicate revocation")
        seen.add((kind, identifier))
    return revoked_keys, revoked_approvals


def load_signer_registry(raw: bytes) -> dict[str, tuple[str, str]]:
    registry = parse_json_bytes(raw, require_canonical=False, label="G6 signer registry")
    check(isinstance(registry, dict), "G6 signer registry: root must be an object")
    entries = registry.get("role_registry")
    check(isinstance(entries, list), "G6 signer registry: role_registry must be an array")
    roles: dict[str, tuple[str, str]] = {}
    for index, entry in enumerate(entries):
        label = f"G6 signer registry role_registry[{index}]"
        check(isinstance(entry, dict), f"{label}: entry must be an object")
        check(
            {"role", "login", "key_fingerprint"} <= set(entry),
            f"{label}: required identity fields are missing",
        )
        role = entry["role"]
        login = entry["login"]
        fingerprint = entry["key_fingerprint"]
        check(role in G6_ROLES, f"{label}: unexpected role")
        check(role not in roles, f"{label}: duplicate role")
        check(
            isinstance(login, str)
            and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", login) is not None,
            f"{label}: invalid or pending GitHub login",
        )
        check(
            isinstance(fingerprint, str)
            and re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", fingerprint) is not None,
            f"{label}: invalid or pending key fingerprint",
        )
        roles[role] = (login, fingerprint)
    check(tuple(roles) == G6_ROLES, "G6 signer registry must contain the five Todo 16 roles in canonical order")
    return roles


def signer_fingerprint(ssh_keygen: Path, key_type: str, key_value: str) -> str:
    with tempfile.TemporaryDirectory() as temporary:
        public_key = Path(temporary) / "signer.pub"
        public_key.write_text(f"{key_type} {key_value}\n", encoding="utf-8")
        result = subprocess.run(
            [str(ssh_keygen), "-lf", str(public_key)],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        raise ValidationError("G6 allowed-signers contains an invalid public key")
    fields = result.stdout.split()
    check(len(fields) >= 2 and fields[1].startswith("SHA256:"), "G6 signer fingerprint could not be read")
    return fields[1]


def load_allowed_signers(raw: bytes, ssh_keygen: Path) -> list[tuple[set[str], str, str]]:
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationError("G6 allowed-signers is not UTF-8") from error
    signers: list[tuple[set[str], str, str]] = []
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        check(len(fields) == 3, f"G6 allowed-signers line {line_number} is not principal/keytype/key")
        principals, key_type, key_value = fields
        check(key_type == "ssh-ed25519", f"G6 allowed-signers line {line_number} is not an Ed25519 key")
        check(
            re.fullmatch(r"[A-Za-z0-9+/=]+", key_value) is not None,
            f"G6 allowed-signers line {line_number} has invalid key",
        )
        principal_set = set(principals.split(","))
        check(all(principal_set), f"G6 allowed-signers line {line_number} has an empty principal")
        fingerprint = signer_fingerprint(ssh_keygen, key_type, key_value)
        signers.append((principal_set, fingerprint, line))
    check(bool(signers), "G6 allowed-signers has no usable trust anchor")
    return signers


def verify_approval_signature(
    approval: dict[str, Any],
    trusted_lines: list[str],
    ssh_keygen: Path,
) -> None:
    payload = canonical_bytes(approval["payload"])
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        allowed = directory / "allowed-signers"
        signature = directory / "approval.sig"
        allowed.write_text("\n".join(trusted_lines) + "\n", encoding="utf-8")
        signature.write_text(approval["signature"], encoding="ascii")
        result = subprocess.run(
            [
                str(ssh_keygen),
                "-Y",
                "verify",
                "-f",
                str(allowed),
                "-I",
                approval["payload"]["github_login"],
                "-n",
                SIGNATURE_NAMESPACE,
                "-s",
                str(signature),
            ],
            input=payload,
            capture_output=True,
        )
    check(result.returncode == 0, f"G6 {approval['payload']['role']}: bad detached signature")


def validate_g6(
    evidence: dict[str, Any],
    trusted_now: datetime,
    trust_bundle: Mapping[str, bytes],
    ssh_keygen: Path,
) -> None:
    check(ssh_keygen.is_file(), "G6 verification requires the pinned /usr/bin/ssh-keygen")
    check(set(trust_bundle) == set(TODO16_TRUST_FILES), "G6 canonical trust bundle is incomplete")
    signers = load_allowed_signers(trust_bundle["allowed_signers"], ssh_keygen)
    revoked_keys, revoked_approvals = load_revocations(trust_bundle["revocations"], trusted_now)
    signer_registry = load_signer_registry(trust_bundle["signer_registry"])
    gate = evidence["gates"]["g6"]
    approvals = gate["approvals"]
    roles = tuple(approval["payload"]["role"] for approval in approvals)
    check(roles == G6_ROLES, "G6 approvals must contain the five Todo 16 roles in canonical order")

    issued_values: list[datetime] = []
    expiry_values: list[datetime] = []
    approval_digests: set[str] = set()
    for approval in approvals:
        payload = approval["payload"]
        role = payload["role"]
        check(payload["g1_g5_digest_sha256"] == evidence["g1_g5_digest_sha256"], f"G6 {role}: G1-G5 digest mismatch")
        check(payload["release_inputs"] == evidence["release_inputs"], f"G6 {role}: mixed release inputs")
        issued_at = parse_timestamp(payload["issued_at"], f"G6 {role}.issued_at")
        expires_at = parse_timestamp(payload["expires_at"], f"G6 {role}.expires_at")
        check(issued_at <= trusted_now, f"G6 {role}: approval is from the future")
        check(expires_at > issued_at, f"G6 {role}: expiration does not follow issuance")
        check(expires_at <= issued_at + timedelta(days=90), f"G6 {role}: expiration exceeds 90 days")
        check(trusted_now <= expires_at, f"G6 {role}: approval is expired")
        issued_values.append(issued_at)
        expiry_values.append(expires_at)

        fingerprint = payload["key_fingerprint"]
        registered_login, registered_fingerprint = signer_registry[role]
        check(payload["github_login"] == registered_login, f"G6 {role}: login does not match the Todo 16 registry")
        check(fingerprint == registered_fingerprint, f"G6 {role}: key does not match the Todo 16 registry")
        check(fingerprint not in revoked_keys, f"G6 {role}: signer key is revoked")
        approval_digest = digest(approval)
        check(approval_digest not in revoked_approvals, f"G6 {role}: approval is revoked")
        check(approval_digest not in approval_digests, f"G6 {role}: duplicate approval")
        approval_digests.add(approval_digest)
        trusted_lines = [
            line
            for principals, candidate_fingerprint, line in signers
            if payload["github_login"] in principals and fingerprint == candidate_fingerprint
        ]
        check(bool(trusted_lines), f"G6 {role}: login and fingerprint are not trusted together")
        verify_approval_signature(approval, trusted_lines, ssh_keygen)

    gate_issued_at = parse_timestamp(gate["issued_at"], "G6.issued_at")
    gate_expires_at = parse_timestamp(gate["expires_at"], "G6.expires_at")
    check(gate_issued_at == max(issued_values), "G6 aggregate issued_at must equal the latest approval issuance")
    check(gate_expires_at == min(expiry_values), "G6 aggregate expires_at must equal the earliest approval expiration")
    expected_artifact_digest = digest({"approvals": approvals})
    check(gate["artifact"]["sha256"] == expected_artifact_digest, "G6 approval artifact digest mismatch")


def load_canonical_g6_trust(
    gh_bin: Path,
    gh_environment: Mapping[str, str],
    test_trust_bundle: Mapping[str, bytes] | None,
) -> dict[str, bytes]:
    if test_trust_bundle is not None:
        check(set(test_trust_bundle) == set(TODO16_TRUST_FILES), "test G6 trust bundle is incomplete")
        return dict(test_trust_bundle)
    comparison = gh_api_json(
        gh_bin,
        [
            "--method",
            "GET",
            f"repos/{TODO16_REPOSITORY}/compare/{TODO16_MERGED_SHA}...main",
        ],
        "G6 Todo 16 merged provenance",
        gh_environment,
    )
    check(isinstance(comparison, dict), "G6 Todo 16 merged provenance is malformed")
    merge_base = comparison.get("merge_base_commit")
    check(
        isinstance(merge_base, dict) and merge_base.get("sha") == TODO16_MERGED_SHA,
        "G6 Todo 16 commit is not an ancestor of Floorp main",
    )
    check(
        comparison.get("status") in ("ahead", "identical"),
        "G6 Todo 16 merged provenance has unexpected compare status",
    )
    trust_bundle: dict[str, bytes] = {}
    for name, provenance in TODO16_TRUST_FILES.items():
        source = {
            "blob_sha": provenance["blob_sha"],
            "commit_sha": TODO16_MERGED_SHA,
            "path": provenance["path"],
            "repository": TODO16_REPOSITORY,
        }
        raw = fetch_github_repository_file(
            source,
            gh_bin,
            gh_environment,
            f"G6 Todo 16 {name}",
        )
        check(
            hashlib.sha256(raw).hexdigest() == provenance["sha256"],
            f"G6 Todo 16 {name}: pinned SHA-256 mismatch",
        )
        trust_bundle[name] = raw
    return trust_bundle


def validate_same_release(evidence: dict[str, Any]) -> None:
    gate_digests = {
        name: gate["artifact"]["sha256"]
        for name, gate in evidence["gates"].items()
    }
    check(len(gate_digests) == len(set(gate_digests.values())), "gate artifact digests are not unique")
    expected = digest(
        {
            "gate_artifact_digests": gate_digests,
            "release_inputs": evidence["release_inputs"],
        }
    )
    check(
        evidence["same_release_key_sha256"] == expected,
        "same-release key does not match canonical inputs and gate artifacts",
    )


def main(
    argv: list[str] | None = None,
    *,
    test_gh_bin: Path | None = None,
    test_gh_environment: Mapping[str, str] | None = None,
    test_remote_artifacts: Mapping[str, bytes] | None = None,
    test_xcresult_results: Mapping[str, str | list[str]] | None = None,
    test_g6_trust_bundle: Mapping[str, bytes] | None = None,
    test_ssh_keygen: Path | None = None,
    test_expected_ios_build_number: str | None = None,
) -> int:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--validation-clock-manifest", required=True, type=Path)
    parser.add_argument("--canonicalization", choices=["rfc8785-jcs"], default="rfc8785-jcs")
    parser.add_argument("--require-g6", action="store_true")
    parser.add_argument("--expected-workflow-id", type=int)
    parser.add_argument(
        "--fixture",
        type=Path,
        default=repository_root / "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
    )
    parser.add_argument(
        "--endpoint-policy",
        type=Path,
        default=repository_root / "docs/floorp-release-endpoints.json",
    )
    arguments = parser.parse_args(argv)
    try:
        schema = load_pinned_schema(repository_root, arguments.schema)
        validate_bound_source_files(arguments.fixture, arguments.endpoint_policy)
        expected_ios_build_number = test_expected_ios_build_number or load_floorp_release_build_number(
            repository_root / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
        )
        check(
            re.fullmatch(r"[1-9][0-9]*", expected_ios_build_number) is not None,
            "FloorpRelease build number authority is malformed",
        )
        evidence = load_json(arguments.evidence, require_canonical=True, label="evidence")
        clock = load_json(
            arguments.validation_clock_manifest,
            require_canonical=True,
            label="validation clock",
        )
        if not isinstance(evidence, dict) or not isinstance(clock, dict):
            raise ValidationError("evidence and validation clock roots must be objects")
        validate_mode_gate_semantics(evidence, arguments.require_g6)
        validate_schema_instance(evidence, schema, schema)
        gh_bin = select_gh_executable(test_gh_bin)
        gh_environment = trusted_gh_environment(test_gh_environment)
        trusted_now = validate_clock(
            clock,
            schema,
            evidence["release_inputs"]["ios"]["source_sha"],
            arguments.expected_workflow_id,
            gh_bin,
            gh_environment,
        )
        validate_release_contract(evidence, trusted_now, expected_ios_build_number)
        validate_gate_artifacts(
            evidence,
            arguments.evidence.resolve(strict=True).parent,
            gh_bin,
            gh_environment,
            test_remote_artifacts,
            test_xcresult_results,
            trusted_now,
        )
        mode = evidence["build_contract_mode"]
        has_g6 = "g6" in evidence["gates"]
        if arguments.require_g6:
            check(mode == RELEASE_ENABLED_MODE, "G6 cannot be required for production-qa evidence")
            check(has_g6, "G6 is required but absent")
        if has_g6:
            ssh_keygen = test_ssh_keygen or PRODUCTION_SSH_KEYGEN
            check(ssh_keygen.is_absolute(), "G6 ssh-keygen path must be absolute")
            if test_ssh_keygen is None:
                check(
                    ssh_keygen.resolve(strict=True) == PRODUCTION_SSH_KEYGEN,
                    "G6 ssh-keygen does not match the pinned production executable",
                )
            trust_bundle = load_canonical_g6_trust(
                gh_bin,
                gh_environment,
                test_g6_trust_bundle,
            )
            validate_g6(
                evidence,
                trusted_now,
                trust_bundle,
                ssh_keygen,
            )
        validate_same_release(evidence)
        if mode == PRODUCTION_QA_MODE:
            result_label = "G1-G4 production-qa"
        else:
            result_label = "G1-G6 release-enabled" if has_g6 else "G1-G5 release-enabled capability"
        print(f"APPROVE: valid {result_label} Floorp Notes Sync release evidence")
        return 0
    except MalformedError as error:
        print(f"INPUT_ERROR: {error}", file=sys.stderr)
        return 2
    except ValidationError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"INPUT_ERROR: validation dependency failed ({error})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
