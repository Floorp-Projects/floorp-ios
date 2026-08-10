#!/usr/bin/python3 -I
"""Prepare offline materials and a canonical Floorp Notes Sync production-QA recipe.

This command deliberately performs no network access.  It verifies a clean,
detached post-merge iOS worktree, immutable local evidence, repository blobs,
and caller-captured GitHub Actions metadata before materializing the exact
inputs consumed by ``assemble-floorp-notes-sync-production-qa-evidence.py``.

Files are published with no-clobber semantics.  A pre-existing managed file is
accepted only when it is a regular, non-symlink, owner-only file containing the
exact expected bytes.  The integration receipt is never created here; the
assembler remains its sole producer.

The required integration execution capture is canonical JSON with exactly six
root fields: ``schema_version``, ``pull_request``, ``pr_checks``,
``commands``, ``merge_response``, and ``main_ref``.  It records the guarded PR
base/head, all eight PR checks in deterministic UTF-8 bytewise sorted order,
four exact terminal command records, the successful merge response, and the
resulting main ref.  The recipe command list and receipt digest are derived
from this capture.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


GIT = "/usr/bin/git"
READ_CHUNK_BYTES = 1024 * 1024
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_SAFE_INTEGER = 9_007_199_254_740_991
SHA1_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
RUN_PAYLOAD_KEYS = {
    "conclusion",
    "created_at",
    "event",
    "head_branch",
    "head_sha",
    "id",
    "repository",
    "run_attempt",
    "status",
    "updated_at",
    "workflow_path",
}
ARTIFACT_METADATA_KEYS = {
    "artifact_created_at",
    "artifact_expires_at",
    "artifact_id",
    "artifact_name",
    "head_sha",
    "run_id",
}
INTEGRATION_CAPTURE_KEYS = {
    "commands",
    "main_ref",
    "merge_response",
    "pr_checks",
    "pull_request",
    "schema_version",
}
PR_CHECK_NAMES = (
    "Adaptive sidebar UI (iPad (A16))",
    "Adaptive sidebar UI (iPhone 17)",
    "Build and unit test",
    "Notes UI (iPad (A16), en-US)",
    "Notes UI (iPad (A16), ja-JP)",
    "Notes UI (iPhone 17, en-US)",
    "Notes UI (iPhone 17, ja-JP)",
    "Validate workflows",
)
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
}


class PreparationError(Exception):
    """A fail-closed input or publication rejection."""


@dataclass(frozen=True)
class EvidenceFileSpec:
    key: str
    source_relative: str
    target_relative: str
    sha256: str


@dataclass(frozen=True)
class SummarySpec:
    key: str
    target_relative: str
    payload: dict[str, Any]
    sha256: str
    source_artifacts: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class ReleaseAssetSpec:
    role: str
    asset_name: str
    asset_id: int
    sha256: str
    source_relative: str
    target_relative: str


@dataclass(frozen=True)
class RepositoryFileSpec:
    role: str
    repository: str
    worktree: str
    commit_sha: str | None
    path: str
    content_policy: str
    blob_sha: str
    sha256: str
    target_relative: str


@dataclass(frozen=True)
class PreparationContract:
    base_oid: str
    reviewed_head_oid: str
    ios_repository: str
    floorp_repository: str
    todo16_source_sha: str
    desktop_source_sha: str
    desktop_build_number: str
    desktop_run_id: int
    desktop_run_head_sha: str
    desktop_workflow_path: str
    runtime_repository: str
    runtime_source_sha: str
    runtime_tree_sha: str
    runtime_run_id: int
    runtime_run_head_sha: str
    runtime_workflow_path: str
    application_services_repository: str
    application_services_source_sha: str
    application_services_tree_sha: str
    application_services_release_tag: str
    release_id: int
    release_published_at: str
    fixture_sha256: str
    case_set_sha256: str
    endpoint_policy_sha256: str
    g1_issued_at: str
    evidence_files: tuple[EvidenceFileSpec, ...]
    summaries: tuple[SummarySpec, ...]
    release_assets: tuple[ReleaseAssetSpec, ...]
    repository_files: tuple[RepositoryFileSpec, ...]


DEFAULT_EVIDENCE_ROOT = Path(
    "/Users/user/dev-source/floorp-ios-dev/.omo/evidence/"
    "floorp-ios-next-milestone-20260806"
)

PRODUCTION_CONTRACT = PreparationContract(
    base_oid="330870f9d6db91433afe1024ac8200f81d260a42",
    reviewed_head_oid="2d887f482e2b1fefa86115a6f23afea131bc93d9",
    ios_repository="Floorp-Projects/floorp-ios",
    floorp_repository="Floorp-Projects/Floorp",
    todo16_source_sha="18841c0c43d0eda428e1c88170769c1539543848",
    desktop_source_sha="fc244eed70248796fa92ff5821c6046ecd576e7e",
    desktop_build_number="31338438952",
    desktop_run_id=31338438952,
    desktop_run_head_sha="17b47fcb837272040a6231963b5221aaec80fa42",
    desktop_workflow_path=".github/workflows/colocated_runner_test.yml",
    runtime_repository="Floorp-Projects/Floorp-Runtime",
    runtime_source_sha="3bf9399564e59be32f92dcc1b044094881b4fb6a",
    runtime_tree_sha="533f9fdca9bdccb7f3d2a13842be7e2375160ae5",
    runtime_run_id=31330766054,
    runtime_run_head_sha="515da7cf9c7fc258eacd56902448eb10989d17b0",
    runtime_workflow_path=".github/workflows/wrapper-mac-build.yml",
    application_services_repository="Floorp-Projects/application-services",
    application_services_source_sha="b6d29804c391a573ecc0db6c1c4491b3e07a6693",
    application_services_tree_sha="8bfa4a27d5b807b613d577ee49198617aab0e117",
    application_services_release_tag="floorp-ios-155.20260731050244.4",
    release_id=367118816,
    release_published_at="2026-08-08T05:41:30Z",
    fixture_sha256="2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd",
    case_set_sha256="c19ec1a3229b0d09aa424498471941409bc77505862e8aa278aadb3396032802",
    endpoint_policy_sha256="af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
    g1_issued_at="2026-08-09T08:55:09Z",
    evidence_files=(
        EvidenceFileSpec(
            "task16",
            "task-16-attempt-3/task-16-manifest.json",
            "artifacts/task-16-manifest.json",
            "4b506307a780cfac04b28cc226e46d13c0be4ceacd1e80e06211a2c7c8dde3dc",
        ),
        EvidenceFileSpec(
            "task17",
            "task-17-attempt-5/task-17-manifest.json",
            "artifacts/task-17-manifest.json",
            "7e97ec176d944709907e0675731d90ad8ad43f75e00d30f448578f0367b750cf",
        ),
        EvidenceFileSpec(
            "task18",
            "task-18-attempt-10-production/task-18-manifest.json",
            "artifacts/task-18-manifest.json",
            "d55a01faf3755658cca48750e40370aac72e83b87eb9a8fec9ce5f6bb5f77e84",
        ),
        EvidenceFileSpec(
            "task18-verdict",
            "F1-attempt-4/production-t18-validation/verdict-attempt-2.json",
            "artifacts/task-18-execution-verdict.json",
            "0d1606797281d525924f0ff85b15b9697b6bb11de91196704a6d334591baf689",
        ),
    ),
    summaries=(
        SummarySpec(
            "fake-server",
            "artifacts/g2-fake-server-run.json",
            {
                "failed": 0,
                "passed": 24,
                "secrets_retained": False,
                "source_log_sha256": (
                    "676ea1c0523b932618cd85d165be1dca541fb37fb0cf8e8c2443541e6f303f49"
                ),
            },
            "c22f3131a15c35d465bbf61ca2044cba2c785eb86cee0ddeec8559333fb770c3",
            ((
                "task-17-attempt-3/green/task-17-green.log",
                "676ea1c0523b932618cd85d165be1dca541fb37fb0cf8e8c2443541e6f303f49",
            ),),
        ),
        SummarySpec(
            "xpcshell",
            "artifacts/g4-xpcshell-run.json",
            {
                "failed": 0,
                "passed": 108,
                "secrets_retained": False,
                "source_log_sha256": (
                    "c049c1124a4c623601203dc2d34a1acc928a7075b83345c3ed91badad53d12dd"
                ),
            },
            "70d3fcf4d6116bb37330a3c5c13b4da819716378d39e54f9bb1cd2702351860b",
            ((
                "task-18-attempt-10-production/wider/"
                "floorp-notes-xpcshell-post-production.log",
                "c049c1124a4c623601203dc2d34a1acc928a7075b83345c3ed91badad53d12dd",
            ),),
        ),
        SummarySpec(
            "tps",
            "artifacts/g4-tps-run.json",
            {
                "failed": 0,
                "passed": 1,
                "payload_retained": False,
                "secrets_retained": False,
                "source_log_sha256": (
                    "95304333a2213d4cc5b0f3c918c0e09ac82faa68c56b53ae46fe95e1c1bd90ef"
                ),
                "source_summary_sha256": (
                    "16e04d89d63aacf059bb7f559744d42002c2d63c1f1566e349bb611d01f080f8"
                ),
            },
            "f173c9c7113539c3e46eb7b4cb6a8359c7ffbfc749ff0a64325b524ffa551424",
            (
                (
                    "task-18-attempt-10-production/wider/"
                    "tps-production-summary-headed-attempt-9.log",
                    "95304333a2213d4cc5b0f3c918c0e09ac82faa68c56b53ae46fe95e1c1bd90ef",
                ),
                (
                    "task-18-attempt-10-production/wider/"
                    "tps-production-summary-headed-attempt-9.json",
                    "16e04d89d63aacf059bb7f559744d42002c2d63c1f1566e349bb611d01f080f8",
                ),
            ),
        ),
    ),
    release_assets=(
        ReleaseAssetSpec(
            "focus-xcframework",
            "FocusRustComponents.xcframework.zip",
            506076697,
            "d996835e76b7b66e516c4b7ddf6c401d815a1ce60466fbbdca73edd2f2ff2b0a",
            "task-17-attempt-4/wider/release-artifacts-4/"
            "FocusRustComponents.xcframework.zip",
            "captures/g2-FocusRustComponents.xcframework.zip",
        ),
        ReleaseAssetSpec(
            "mozilla-xcframework",
            "MozillaRustComponents.xcframework.zip",
            506076696,
            "579b00cd5823a94101145a4deef7df44e1eeb3929cbe849f53a0f6d008e6f268",
            "task-17-attempt-4/wider/release-artifacts-4/"
            "MozillaRustComponents.xcframework.zip",
            "captures/g2-MozillaRustComponents.xcframework.zip",
        ),
        ReleaseAssetSpec(
            "release-manifest",
            "release-manifest.json",
            506076698,
            "387beac1bb8d4b204b9c8ebdc3797ea75e2466c507ec944b2b5188fea2d6b0dd",
            "task-17-attempt-4/wider/release-artifacts-4/release-manifest.json",
            "captures/g2-release-manifest.json",
        ),
        ReleaseAssetSpec(
            "sha256sums",
            "SHA256SUMS",
            506076695,
            "32db0711e7b5cf6d088ef95b290941be9ba22cfceeadfc35978fa97d05506b8c",
            "task-17-attempt-4/wider/release-artifacts-4/SHA256SUMS",
            "captures/g2-SHA256SUMS",
        ),
        ReleaseAssetSpec(
            "swift-components",
            "swift-components.tar.xz",
            506076699,
            "e9cdae3cbcd19c68d6a1eed78917862f2a6420e2b74fb52e6669f0d641f31433",
            "task-17-attempt-4/wider/release-artifacts-4/swift-components.tar.xz",
            "captures/g2-swift-components.tar.xz",
        ),
    ),
    repository_files=(
        RepositoryFileSpec(
            "todo16-contract",
            "Floorp-Projects/Floorp",
            "floorp",
            "18841c0c43d0eda428e1c88170769c1539543848",
            "docs/development/floorp-notes-sync/prerequisites.json",
            "metadata-json",
            "43d6826903d49b65d71c593a6e4759eaf32d02a2",
            "e8c99a574d1171f2ae8df55782e69bcfa0d517938aea0152ca11d587df33d6ba",
            "captures/g1-todo16-contract.json",
        ),
        RepositoryFileSpec(
            "ios-contract-source",
            "Floorp-Projects/floorp-ios",
            "ios",
            None,
            "docs/floorp-notes-sync-architecture.md",
            "source-code",
            "fb4b79d88c8b25872a03dfb6f1c0e8af8b0c5f6f",
            "5d53eceec02433da317a95734bf424d2f279a13fa09e55fe22861ac4b12489b5",
            "captures/g1-ios-contract-source.md",
        ),
        RepositoryFileSpec(
            "desktop-contract-source",
            "Floorp-Projects/Floorp",
            "floorp",
            "fc244eed70248796fa92ff5821c6046ecd576e7e",
            "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
            "source-code",
            "b2af06eee4342ae7a057976326da059f22455eb6",
            "b420cc063489a51b3741063062532151d44bb4d81eda9d16cb3740652980d8d2",
            "captures/g1-desktop-contract-source.md",
        ),
        RepositoryFileSpec(
            "merge-fixture",
            "Floorp-Projects/floorp-ios",
            "ios",
            None,
            "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
            "metadata-json",
            "fef8f5a0e0e303a3f9106e3ac5ac36a7a67cc6ad",
            "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd",
            "captures/g1-merge-fixture.json",
        ),
        RepositoryFileSpec(
            "g4-attestation-source",
            "Floorp-Projects/floorp-ios",
            "ios",
            None,
            "docs/floorp-notes-sync-g4-attestation.json",
            "metadata-json",
            "9f634bba221d4bbc2b53d0c7439a946fd054f6f8",
            "de1db28ae820f66afc367808f91391202053441d15a4ce017d6cacbc1a7e0dee",
            "captures/g4-attestation-source.json",
        ),
    ),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PreparationError(message)


def canonical_bytes(value: Any) -> bytes:
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        require(abs(value) <= MAX_SAFE_INTEGER, "canonical JSON integer is outside the safe range")
        return str(value).encode("ascii")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if isinstance(value, list):
        return b"[" + b",".join(canonical_bytes(item) for item in value) + b"]"
    if isinstance(value, dict):
        require(all(isinstance(key, str) for key in value), "canonical JSON object keys must be strings")
        keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return b"{" + b",".join(
            canonical_bytes(key) + b":" + canonical_bytes(value[key]) for key in keys
        ) + b"}"
    raise PreparationError(f"unsupported canonical JSON value: {type(value).__name__}")


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def git_blob_sha(raw: bytes) -> str:
    return hashlib.sha1(f"blob {len(raw)}\0".encode("ascii") + raw).hexdigest()


def stable_snapshot(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def open_regular(path: Path, label: str) -> tuple[int, os.stat_result]:
    try:
        lexical = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label}: cannot inspect file ({error})") from error
    require(not stat.S_ISLNK(lexical.st_mode), f"{label}: symlinks are forbidden")
    require(stat.S_ISREG(lexical.st_mode), f"{label}: must be a regular file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise PreparationError(f"{label}: cannot open file ({error})") from error
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or (
        lexical.st_dev,
        lexical.st_ino,
    ) != (opened.st_dev, opened.st_ino):
        os.close(descriptor)
        raise PreparationError(f"{label}: file identity changed while opening")
    return descriptor, opened


def hash_open_file(descriptor: int, before: os.stat_result, label: str) -> tuple[str, int]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    size = 0
    while chunk := os.read(descriptor, READ_CHUNK_BYTES):
        digest.update(chunk)
        size += len(chunk)
    after = os.fstat(descriptor)
    require(stable_snapshot(before) == stable_snapshot(after), f"{label}: file changed while read")
    require(size == before.st_size, f"{label}: file size changed while read")
    return digest.hexdigest(), size


def read_regular_bytes(path: Path, label: str, *, maximum: int = MAX_JSON_BYTES) -> bytes:
    descriptor, before = open_regular(path, label)
    try:
        require(before.st_size <= maximum, f"{label}: file is too large")
        raw = bytearray()
        while chunk := os.read(descriptor, READ_CHUNK_BYTES):
            raw.extend(chunk)
        after = os.fstat(descriptor)
        require(stable_snapshot(before) == stable_snapshot(after), f"{label}: file changed while read")
        return bytes(raw)
    finally:
        os.close(descriptor)


def reject_float(_: str) -> Any:
    raise PreparationError("canonical JSON floating-point values are forbidden")


def reject_constant(_: str) -> Any:
    raise PreparationError("canonical JSON non-finite values are forbidden")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"canonical JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def parse_canonical_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = read_regular_bytes(path, label)
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PreparationError(f"{label}: malformed UTF-8 JSON ({error})") from error
    require(isinstance(payload, dict), f"{label}: root must be an object")
    require(raw == canonical_bytes(payload), f"{label}: input is not canonical JSON")
    return payload, raw


def parse_timestamp(value: Any, label: str) -> datetime:
    require(isinstance(value, str) and TIMESTAMP_PATTERN.fullmatch(value) is not None, f"{label}: timestamp is malformed")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise PreparationError(f"{label}: timestamp is invalid") from error


def format_timestamp(value: datetime) -> str:
    require(value.tzinfo is not None, "internal timestamp is timezone-naive")
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def exact_positive_integer(value: Any, label: str) -> int:
    require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 < value <= MAX_SAFE_INTEGER,
        f"{label}: must be a positive safe integer",
    )
    return value


def absolute_path(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def ensure_private_directory(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        try:
            os.mkdir(path, 0o700)
        except OSError as error:
            raise PreparationError(f"{label}: cannot create private directory ({error})") from error
        metadata = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label}: cannot inspect directory ({error})") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink directory is forbidden")
    require(stat.S_ISDIR(metadata.st_mode), f"{label}: must be a directory")
    require(metadata.st_uid == os.geteuid(), f"{label}: directory is not owned by this user")
    require(stat.S_IMODE(metadata.st_mode) == 0o700, f"{label}: directory mode must be 0700")


def ensure_private_tree(run_dir: Path, target_parent: Path) -> None:
    require(run_dir != Path(run_dir.anchor), "run directory cannot be a filesystem root")
    if not run_dir.exists():
        require(run_dir.parent.is_dir(), "run directory parent does not exist")
    ensure_private_directory(run_dir, "run directory")
    relative = target_parent.relative_to(run_dir)
    current = run_dir
    for part in relative.parts:
        require(part not in ("", ".", ".."), "output parent path is unsafe")
        current /= part
        ensure_private_directory(current, "output directory")


def target_path(material_root: Path, relative: str) -> Path:
    relative_path = Path(relative)
    require(
        not relative_path.is_absolute()
        and bool(relative_path.parts)
        and all(part not in ("", ".", "..") for part in relative_path.parts),
        f"managed path is unsafe: {relative}",
    )
    target = material_root.joinpath(*relative_path.parts)
    require(os.path.commonpath((material_root, target)) == os.fspath(material_root), "managed path escapes output root")
    return target


def verify_existing_mode(metadata: os.stat_result, label: str) -> None:
    require(stat.S_ISREG(metadata.st_mode), f"{label}: existing target is not a regular file")
    require(metadata.st_uid == os.geteuid(), f"{label}: existing target is not owned by this user")
    require(stat.S_IMODE(metadata.st_mode) == 0o600, f"{label}: existing target mode must be 0600")


def publish_bytes_exact(path: Path, raw: bytes, label: str) -> None:
    if os.path.lexists(path):
        descriptor, before = open_regular(path, label)
        try:
            verify_existing_mode(before, label)
            require(before.st_size == len(raw), f"{label}: existing file does not match expected bytes")
            existing = bytearray()
            while chunk := os.read(descriptor, READ_CHUNK_BYTES):
                existing.extend(chunk)
            after = os.fstat(descriptor)
            require(stable_snapshot(before) == stable_snapshot(after), f"{label}: existing file changed while read")
            require(bytes(existing) == raw, f"{label}: existing file does not match expected bytes")
            return
        finally:
            os.close(descriptor)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(raw):
            offset += os.write(descriptor, raw[offset:])
        os.fsync(descriptor)
        verify_existing_mode(os.fstat(descriptor), label)
    except OSError as error:
        raise PreparationError(f"{label}: no-clobber publication failed ({error})") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if sys.exc_info()[0] is not None and created:
            path.unlink(missing_ok=True)


def compare_open_files(
    source_fd: int,
    source_before: os.stat_result,
    target_fd: int,
    target_before: os.stat_result,
    label: str,
) -> None:
    require(source_before.st_size == target_before.st_size, f"{label}: existing file size differs")
    os.lseek(source_fd, 0, os.SEEK_SET)
    while True:
        source_chunk = os.read(source_fd, READ_CHUNK_BYTES)
        target_chunk = os.read(target_fd, READ_CHUNK_BYTES)
        require(source_chunk == target_chunk, f"{label}: existing file does not match expected bytes")
        if not source_chunk:
            break
    require(
        stable_snapshot(source_before) == stable_snapshot(os.fstat(source_fd)),
        f"{label}: source changed while comparing",
    )
    require(
        stable_snapshot(target_before) == stable_snapshot(os.fstat(target_fd)),
        f"{label}: existing target changed while comparing",
    )


def materialize_file(
    source: Path,
    target: Path,
    label: str,
    *,
    expected_sha256: str | None,
) -> str:
    source_fd, source_before = open_regular(source, f"{label} source")
    try:
        actual_sha256, source_size = hash_open_file(source_fd, source_before, f"{label} source")
        if expected_sha256 is not None:
            require(SHA256_PATTERN.fullmatch(expected_sha256) is not None, f"{label}: configured SHA-256 is malformed")
            require(actual_sha256 == expected_sha256, f"{label}: source SHA-256 mismatch")
        if os.path.lexists(target):
            target_fd, target_before = open_regular(target, label)
            try:
                verify_existing_mode(target_before, label)
                compare_open_files(source_fd, source_before, target_fd, target_before, label)
                return actual_sha256
            finally:
                os.close(target_fd)

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        target_fd = -1
        created = False
        try:
            target_fd = os.open(target, flags, 0o600)
            created = True
            os.fchmod(target_fd, 0o600)
            os.lseek(source_fd, 0, os.SEEK_SET)
            copied_digest = hashlib.sha256()
            copied_size = 0
            while chunk := os.read(source_fd, READ_CHUNK_BYTES):
                copied_digest.update(chunk)
                copied_size += len(chunk)
                offset = 0
                while offset < len(chunk):
                    offset += os.write(target_fd, chunk[offset:])
            require(copied_size == source_size, f"{label}: source size changed while copying")
            require(copied_digest.hexdigest() == actual_sha256, f"{label}: source changed while copying")
            require(
                stable_snapshot(source_before) == stable_snapshot(os.fstat(source_fd)),
                f"{label}: source changed while copying",
            )
            os.fsync(target_fd)
            target_after = os.fstat(target_fd)
            verify_existing_mode(target_after, label)
            require(target_after.st_size == source_size, f"{label}: published size mismatch")
        except OSError as error:
            raise PreparationError(f"{label}: no-clobber publication failed ({error})") from error
        finally:
            if target_fd >= 0:
                os.close(target_fd)
            if sys.exc_info()[0] is not None and created:
                target.unlink(missing_ok=True)
        return actual_sha256
    finally:
        os.close(source_fd)


def git_command(
    worktree: Path,
    arguments: Iterable[str],
    label: str,
    *,
    accepted: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[bytes]:
    hardened_configuration = (
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.bare=false",
        "-c",
        f"core.worktree={worktree}",
        "-c",
        "maintenance.auto=false",
        "-c",
        "gc.auto=0",
        "-c",
        "fetch.recurseSubmodules=false",
        "-c",
        "submodule.recurse=false",
        "-c",
        "credential.helper=",
        "-c",
        "core.askPass=",
    )
    try:
        result = subprocess.run(
            [GIT, *hardened_configuration, "-C", os.fspath(worktree), *arguments],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "HOME": os.environ.get("HOME", ""),
                "GCM_INTERACTIVE": "Never",
                "GIT_ALLOW_PROTOCOL": "",
                "GIT_ASKPASS": "/usr/bin/false",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_NO_LAZY_FETCH": "1",
                "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_PAGER": "cat",
                "GIT_TERMINAL_PROMPT": "0",
                "LANG": "C",
                "LC_ALL": "C",
                "PAGER": "cat",
                "PATH": "/usr/bin:/bin",
                "SSH_ASKPASS": "/usr/bin/false",
            },
        )
    except OSError as error:
        raise PreparationError(f"{label}: Git invocation failed ({error})") from error
    require(result.returncode in accepted, f"{label}: Git command failed with exit {result.returncode}")
    return result


def git_text(worktree: Path, arguments: Iterable[str], label: str) -> str:
    raw = git_command(worktree, arguments, label).stdout
    try:
        return raw.decode("utf-8").strip()
    except UnicodeError as error:
        raise PreparationError(f"{label}: Git output is not UTF-8") from error


def validate_git_worktree(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label}: cannot inspect worktree ({error})") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink worktree is forbidden")
    require(stat.S_ISDIR(metadata.st_mode), f"{label}: worktree is not a directory")
    require(git_text(path, ("rev-parse", "--is-inside-work-tree"), label) == "true", f"{label}: not a Git worktree")


def validate_merged_worktree(
    path: Path,
    merged_oid: str,
    contract: PreparationContract,
) -> bytes:
    validate_git_worktree(path, "merged iOS worktree")
    head = git_text(path, ("rev-parse", "--verify", "HEAD"), "merged iOS worktree")
    require(head == merged_oid, "merged iOS worktree: HEAD does not equal --merged-oid")
    detached = git_command(
        path,
        ("symbolic-ref", "-q", "HEAD"),
        "merged iOS worktree",
        accepted=(0, 1),
    )
    require(detached.returncode == 1 and detached.stdout == b"", "merged iOS worktree: HEAD must be detached")
    index_entries = git_command(
        path,
        ("ls-files", "-v", "-z"),
        "merged iOS worktree index",
    ).stdout.split(b"\0")
    for entry in index_entries:
        if not entry:
            continue
        require(len(entry) >= 3 and entry[1:2] == b" ", "merged iOS worktree: malformed index entry")
        tag = chr(entry[0])
        if tag == "S":
            raise PreparationError("merged iOS worktree: skip-worktree index flags are forbidden")
        if tag.islower():
            if tag == "s":
                raise PreparationError(
                    "merged iOS worktree: assume-unchanged/skip-worktree index flags are forbidden"
                )
            raise PreparationError("merged iOS worktree: assume-unchanged index flags are forbidden")
    status = git_command(
        path,
        ("status", "--porcelain=v1", "--untracked-files=all"),
        "merged iOS worktree",
    ).stdout
    require(status == b"", "merged iOS worktree: worktree is dirty")
    parents = git_text(path, ("show", "-s", "--format=%P", merged_oid), "merged iOS worktree").split()
    require(parents == [contract.base_oid], "merged iOS worktree: squash commit parent does not equal guarded base")
    merged_tree = git_text(path, ("rev-parse", f"{merged_oid}^{{tree}}"), "merged iOS worktree")
    reviewed_tree = git_text(
        path,
        ("rev-parse", f"{contract.reviewed_head_oid}^{{tree}}"),
        "merged iOS worktree",
    )
    require(merged_tree == reviewed_tree, "merged iOS worktree: merged tree differs from reviewed head")
    config = git_command(
        path,
        ("show", f"{merged_oid}:firefox-ios/Client/Configuration/FloorpRelease.xcconfig"),
        "FloorpRelease.xcconfig",
    ).stdout
    try:
        text = config.decode("utf-8")
    except UnicodeError as error:
        raise PreparationError("FloorpRelease.xcconfig: content is not UTF-8") from error
    assignments = re.findall(r"(?m)^FLOORP_BUILD_NUMBER[ \t]*=[ \t]*([^\s#]+)[ \t]*$", text)
    require(assignments == ["4"], "FloorpRelease.xcconfig: FLOORP_BUILD_NUMBER must be exactly 4")
    return config


def repository_blob(
    worktree: Path,
    commit_sha: str,
    spec: RepositoryFileSpec,
) -> bytes:
    require(SHA1_PATTERN.fullmatch(commit_sha) is not None, f"{spec.role}: commit SHA is malformed")
    resolved_commit = git_text(
        worktree,
        ("rev-parse", f"{commit_sha}^{{commit}}"),
        f"{spec.role} repository source",
    )
    require(resolved_commit == commit_sha, f"{spec.role}: commit object mismatch")
    blob = git_text(
        worktree,
        ("rev-parse", f"{commit_sha}:{spec.path}"),
        f"{spec.role} repository source",
    )
    require(blob == spec.blob_sha, f"{spec.role}: Git blob SHA mismatch")
    raw = git_command(
        worktree,
        ("cat-file", "blob", blob),
        f"{spec.role} repository source",
    ).stdout
    require(git_blob_sha(raw) == spec.blob_sha, f"{spec.role}: computed Git blob SHA mismatch")
    require(sha256_bytes(raw) == spec.sha256, f"{spec.role}: repository bytes SHA-256 mismatch")
    if spec.role == "g4-attestation-source":
        try:
            parsed = json.loads(
                raw.decode("utf-8"),
                object_pairs_hook=unique_object,
                parse_float=reject_float,
                parse_constant=reject_constant,
            )
        except (UnicodeError, json.JSONDecodeError) as error:
            raise PreparationError("g4-attestation-source: malformed canonical JSON") from error
        require(raw == canonical_bytes(parsed), "g4-attestation-source: JSON is not canonical")
    return raw


def validate_run_payload(
    payload: dict[str, Any],
    *,
    label: str,
    repository: str,
    run_id: int | None,
    head_sha: str,
    workflow_path: str,
    event: str | None = None,
    head_branch: str | None = None,
) -> tuple[datetime, datetime]:
    require(set(payload) == RUN_PAYLOAD_KEYS, f"{label}: fields are not exact")
    exact_positive_integer(payload.get("id"), f"{label}.id")
    exact_positive_integer(payload.get("run_attempt"), f"{label}.run_attempt")
    if run_id is not None:
        require(payload["id"] == run_id, f"{label}: run ID mismatch")
    require(payload.get("repository") == repository, f"{label}: repository mismatch")
    require(payload.get("head_sha") == head_sha, f"{label}: head SHA mismatch")
    require(payload.get("workflow_path") == workflow_path, f"{label}: workflow path mismatch")
    require(payload.get("status") == "completed", f"{label}: run is nonterminal")
    require(payload.get("conclusion") == "success", f"{label}: run did not succeed")
    require(isinstance(payload.get("event"), str) and bool(payload["event"]), f"{label}: event is malformed")
    require(isinstance(payload.get("head_branch"), str) and bool(payload["head_branch"]), f"{label}: head branch is malformed")
    if event is not None:
        require(payload["event"] == event, f"{label}: event mismatch")
    if head_branch is not None:
        require(payload["head_branch"] == head_branch, f"{label}: head branch mismatch")
    created = parse_timestamp(payload.get("created_at"), f"{label}.created_at")
    updated = parse_timestamp(payload.get("updated_at"), f"{label}.updated_at")
    require(updated >= created, f"{label}: updated_at precedes created_at")
    return created, updated


def local_source(role: str, path: str, policy: str, sha256: str) -> dict[str, Any]:
    return {
        "content_policy": policy,
        "kind": "local-file",
        "path": path,
        "role": role,
        "sha256": sha256,
    }


def repository_source(
    spec: RepositoryFileSpec,
    commit_sha: str,
) -> dict[str, Any]:
    return {
        "blob_sha": spec.blob_sha,
        "commit_sha": commit_sha,
        "content_policy": spec.content_policy,
        "kind": "github-repository-file",
        "path": spec.path,
        "repository": spec.repository,
        "role": spec.role,
        "sha256": spec.sha256,
    }


def run_source(role: str, payload: dict[str, Any], raw: bytes) -> dict[str, Any]:
    return {
        "content_policy": "metadata-json",
        "head_sha": payload["head_sha"],
        "kind": "github-actions-run",
        "repository": payload["repository"],
        "role": role,
        "run_id": payload["id"],
        "sha256": sha256_bytes(raw),
        "workflow_path": payload["workflow_path"],
    }


def artifact_source(
    role: str,
    metadata: dict[str, Any],
    repository: str,
    sha256: str,
) -> dict[str, Any]:
    return {
        "artifact_created_at": metadata["artifact_created_at"],
        "artifact_expires_at": metadata["artifact_expires_at"],
        "artifact_id": metadata["artifact_id"],
        "artifact_name": metadata["artifact_name"],
        "content_policy": "test-result-bundle",
        "head_sha": metadata["head_sha"],
        "kind": "github-actions-artifact",
        "repository": repository,
        "role": role,
        "run_id": metadata["run_id"],
        "sha256": sha256,
    }


def release_asset_source(
    spec: ReleaseAssetSpec,
    contract: PreparationContract,
) -> dict[str, Any]:
    return {
        "asset_id": spec.asset_id,
        "asset_name": spec.asset_name,
        "content_policy": "release-binary",
        "kind": "github-release-asset",
        "release_id": contract.release_id,
        "release_immutable": True,
        "release_prerelease": True,
        "release_published_at": contract.release_published_at,
        "release_tag": contract.application_services_release_tag,
        "repository": contract.application_services_repository,
        "role": spec.role,
        "sha256": spec.sha256,
        "source_sha": contract.application_services_source_sha,
    }


def source_entry(bytes_path: str, descriptor: dict[str, Any]) -> dict[str, Any]:
    return {"bytes_path": bytes_path, "descriptor": descriptor}


def role_only(source: dict[str, Any], role: str) -> dict[str, Any]:
    rebound = dict(source)
    rebound["role"] = role
    return rebound


def integration_command_argv(contract: PreparationContract) -> tuple[tuple[str, ...], ...]:
    reviewed = contract.reviewed_head_oid
    return (
        (
            "/opt/homebrew/bin/gh",
            "pr",
            "checks",
            "83",
            "--repo",
            "Floorp-Projects/floorp-ios",
        ),
        (
            "/opt/homebrew/bin/gh",
            "pr",
            "view",
            "83",
            "--repo",
            "Floorp-Projects/floorp-ios",
            "--json",
            "number,baseRefOid,headRefOid",
        ),
        (
            "/opt/homebrew/bin/gh",
            "api",
            "-X",
            "PUT",
            "repos/Floorp-Projects/floorp-ios/pulls/83/merge",
            "-f",
            f"sha={reviewed}",
            "-f",
            "merge_method=squash",
        ),
        (
            "/opt/homebrew/bin/gh",
            "api",
            "repos/Floorp-Projects/floorp-ios/git/ref/heads/main",
        ),
    )


def validate_integration_capture(
    capture: dict[str, Any],
    merged_oid: str,
    contract: PreparationContract,
) -> list[dict[str, Any]]:
    label = "integration execution capture"
    require(set(capture) == INTEGRATION_CAPTURE_KEYS, f"{label}: root fields are not exact")
    schema_version = capture.get("schema_version")
    require(
        isinstance(schema_version, int)
        and not isinstance(schema_version, bool)
        and schema_version == 1,
        f"{label}: schema_version must be integer 1",
    )

    pull_request = capture.get("pull_request")
    require(isinstance(pull_request, dict), f"{label}: pull_request is malformed")
    require(
        set(pull_request) == {"base_oid", "head_oid", "number"},
        f"{label}: pull request fields are not exact",
    )
    number = pull_request.get("number")
    require(
        isinstance(number, int) and not isinstance(number, bool) and number == 83,
        f"{label}: pull request number mismatch",
    )
    require(pull_request.get("base_oid") == contract.base_oid, f"{label}: pull request base mismatch")
    require(
        pull_request.get("head_oid") == contract.reviewed_head_oid,
        f"{label}: pull request head mismatch",
    )

    checks = capture.get("pr_checks")
    require(isinstance(checks, list), f"{label}: PR checks are malformed")
    check_names: list[str] = []
    for index, check in enumerate(checks):
        require(isinstance(check, dict), f"{label}: PR check {index} is malformed")
        require(
            set(check) == {"conclusion", "name"},
            f"{label}: PR check {index} fields are not exact",
        )
        require(check.get("conclusion") == "success", f"{label}: PR checks did not all succeed")
        name = check.get("name")
        require(isinstance(name, str) and bool(name), f"{label}: PR check name is malformed")
        check_names.append(name)
    require(len(check_names) == len(set(check_names)), f"{label}: PR checks contain a duplicate")
    require(
        check_names == sorted(check_names, key=lambda name: name.encode("utf-8")),
        f"{label}: PR checks are not in deterministic UTF-8 sorted order",
    )
    require(tuple(check_names) == PR_CHECK_NAMES, f"{label}: PR checks are not exact")

    commands = capture.get("commands")
    expected_argv = integration_command_argv(contract)
    require(
        isinstance(commands, list) and len(commands) == len(expected_argv),
        f"{label}: command set is not exact",
    )
    for index, (command, expected) in enumerate(zip(commands, expected_argv)):
        require(isinstance(command, dict), f"{label}: command {index} is malformed")
        require(
            set(command) == {"argv", "exit_code", "terminal"},
            f"{label}: command {index} fields are not exact",
        )
        require(command.get("argv") == list(expected), f"{label}: command {index} argv mismatch")
        exit_code = command.get("exit_code")
        require(
            isinstance(exit_code, int)
            and not isinstance(exit_code, bool)
            and exit_code == 0,
            f"{label}: command {index} exit_code must be integer 0",
        )
        require(command.get("terminal") is True, f"{label}: command {index} terminal must be true")

    merge_response = capture.get("merge_response")
    require(isinstance(merge_response, dict), f"{label}: merge response is malformed")
    require(
        set(merge_response) == {"merged", "sha"},
        f"{label}: merge response fields are not exact",
    )
    require(merge_response.get("merged") is True, f"{label}: merge response is not merged")
    require(merge_response.get("sha") == merged_oid, f"{label}: merge response SHA mismatch")

    main_ref = capture.get("main_ref")
    require(isinstance(main_ref, dict), f"{label}: main ref is malformed")
    require(set(main_ref) == {"ref", "sha"}, f"{label}: main ref fields are not exact")
    require(main_ref.get("ref") == "refs/heads/main", f"{label}: main ref name mismatch")
    require(main_ref.get("sha") == merged_oid, f"{label}: main ref SHA mismatch")
    return copy.deepcopy(commands)


def build_release_inputs(
    merged_oid: str,
    contract: PreparationContract,
) -> dict[str, Any]:
    assets = {spec.role: spec.sha256 for spec in contract.release_assets}
    require(set(assets) == set(GATE_SOURCE_ROLES["g2"][2:]), "release asset roles are not exact")
    return {
        "application_services": {
            "artifacts": {
                "focus_xcframework_sha256": assets["focus-xcframework"],
                "mozilla_xcframework_sha256": assets["mozilla-xcframework"],
                "release_manifest_sha256": assets["release-manifest"],
                "sha256sums_sha256": assets["sha256sums"],
                "swift_components_sha256": assets["swift-components"],
            },
            "release_tag": contract.application_services_release_tag,
            "repository": contract.application_services_repository,
            "source_sha": contract.application_services_source_sha,
            "tree_sha": contract.application_services_tree_sha,
        },
        "contract": {
            "case_set_sha256": contract.case_set_sha256,
            "endpoint_policy_sha256": contract.endpoint_policy_sha256,
            "fixture_sha256": contract.fixture_sha256,
        },
        "desktop": {
            "build_number": contract.desktop_build_number,
            "repository": contract.floorp_repository,
            "source_sha": contract.desktop_source_sha,
        },
        "environment": {
            "fxa_configuration": "FxAConfig.Server.release",
            "fxa_hosts": [
                "accounts.firefox.com",
                "api.accounts.firefox.com",
                "oauth.accounts.firefox.com",
                "profile.accounts.firefox.com",
                "static.accounts.firefox.com",
            ],
            "sync_hosts": [
                "event-sync.services.mozilla.com",
                "sync.services.mozilla.com",
                "token.services.mozilla.com",
            ],
            "wire_protocol": "sync15",
        },
        "ios": {
            "build_number": "4",
            "configuration": "FloorpRelease",
            "repository": contract.ios_repository,
            "source_sha": merged_oid,
        },
        "runtime": {
            "repository": contract.runtime_repository,
            "source_sha": contract.runtime_source_sha,
            "tree_sha": contract.runtime_tree_sha,
        },
    }


def validate_artifact_metadata(
    metadata: dict[str, Any],
    g3_run: dict[str, Any],
    merged_oid: str,
) -> tuple[datetime, datetime]:
    require(set(metadata) == ARTIFACT_METADATA_KEYS, "G3 artifact metadata: fields are not exact")
    exact_positive_integer(metadata.get("artifact_id"), "G3 artifact metadata.artifact_id")
    exact_positive_integer(metadata.get("run_id"), "G3 artifact metadata.run_id")
    require(metadata["run_id"] == g3_run["id"], "G3 artifact metadata: run ID mismatch")
    require(metadata.get("head_sha") == merged_oid, "G3 artifact metadata: head SHA mismatch")
    require(
        metadata.get("artifact_name") == "floorp-notes-sync-xcresult",
        "G3 artifact metadata: artifact name mismatch",
    )
    created = parse_timestamp(metadata.get("artifact_created_at"), "G3 artifact created_at")
    expires = parse_timestamp(metadata.get("artifact_expires_at"), "G3 artifact expires_at")
    run_created = parse_timestamp(g3_run["created_at"], "G3 run created_at")
    require(created >= run_created, "G3 artifact metadata: artifact predates its run")
    require(expires > created, "G3 artifact metadata: expiry must be after creation")
    require(
        expires <= created + timedelta(days=7),
        "G3 artifact metadata: expiry exceeds the seven-day evidence lifetime",
    )
    return created, expires


def evidence_by_key(contract: PreparationContract) -> dict[str, EvidenceFileSpec]:
    result = {spec.key: spec for spec in contract.evidence_files}
    require(
        set(result) == {"task16", "task17", "task18", "task18-verdict"},
        "evidence-file contract is not exact",
    )
    return result


def summary_by_key(contract: PreparationContract) -> dict[str, SummarySpec]:
    result = {spec.key: spec for spec in contract.summaries}
    require(set(result) == {"fake-server", "xpcshell", "tps"}, "summary contract is not exact")
    return result


def repository_by_role(contract: PreparationContract) -> dict[str, RepositoryFileSpec]:
    result = {spec.role: spec for spec in contract.repository_files}
    require(
        set(result)
        == {
            "todo16-contract",
            "ios-contract-source",
            "desktop-contract-source",
            "merge-fixture",
            "g4-attestation-source",
        },
        "repository-file contract is not exact",
    )
    return result


def prepare(
    *,
    run_dir: Path,
    merged_ios_worktree: Path,
    floorp_worktree: Path,
    merged_oid: str,
    g3_run_json: Path,
    g3_artifact_metadata_json: Path,
    g3_xcresult_zip: Path,
    desktop_run_json: Path,
    runtime_run_json: Path,
    integration_execution_capture: Path,
    output_recipe: Path,
    evidence_root: Path,
    contract: PreparationContract,
) -> dict[str, Any]:
    require(SHA1_PATTERN.fullmatch(merged_oid) is not None, "--merged-oid is not a lowercase Git SHA")
    for value, label in (
        (contract.base_oid, "guarded base OID"),
        (contract.reviewed_head_oid, "reviewed head OID"),
    ):
        require(SHA1_PATTERN.fullmatch(value) is not None, f"{label} is malformed")

    run_root = absolute_path(run_dir)
    recipe_path = absolute_path(output_recipe)
    try:
        common = os.path.commonpath((run_root, recipe_path))
    except ValueError as error:
        raise PreparationError("output recipe and run directory are on different filesystems") from error
    require(common == os.fspath(run_root) and recipe_path != run_root, "--output-recipe must be under --run-dir")
    material_root = recipe_path.parent
    ensure_private_tree(run_root, material_root)
    ensure_private_directory(target_path(material_root, "artifacts"), "artifacts directory")
    ensure_private_directory(target_path(material_root, "captures"), "captures directory")

    merged_worktree = absolute_path(merged_ios_worktree)
    floorp_tree = absolute_path(floorp_worktree)
    evidence = absolute_path(evidence_root)
    validate_merged_worktree(merged_worktree, merged_oid, contract)
    validate_git_worktree(floorp_tree, "Floorp worktree")

    g3_run, g3_run_raw = parse_canonical_json(absolute_path(g3_run_json), "G3 run capture")
    desktop_run, desktop_run_raw = parse_canonical_json(
        absolute_path(desktop_run_json), "Desktop run capture"
    )
    runtime_run, runtime_run_raw = parse_canonical_json(
        absolute_path(runtime_run_json), "Runtime run capture"
    )
    artifact_metadata, artifact_metadata_raw = parse_canonical_json(
        absolute_path(g3_artifact_metadata_json), "G3 artifact metadata"
    )
    integration_capture, integration_capture_raw = parse_canonical_json(
        absolute_path(integration_execution_capture),
        "integration execution capture",
    )
    commands = validate_integration_capture(integration_capture, merged_oid, contract)

    g3_created, _ = validate_run_payload(
        g3_run,
        label="G3 run capture",
        repository=contract.ios_repository,
        run_id=None,
        head_sha=merged_oid,
        workflow_path=".github/workflows/ci.yml",
        event="push",
        head_branch="main",
    )
    desktop_created, _ = validate_run_payload(
        desktop_run,
        label="Desktop run capture",
        repository=contract.floorp_repository,
        run_id=contract.desktop_run_id,
        head_sha=contract.desktop_run_head_sha,
        workflow_path=contract.desktop_workflow_path,
    )
    runtime_created, _ = validate_run_payload(
        runtime_run,
        label="Runtime run capture",
        repository=contract.runtime_repository,
        run_id=contract.runtime_run_id,
        head_sha=contract.runtime_run_head_sha,
        workflow_path=contract.runtime_workflow_path,
    )
    artifact_created, artifact_expires = validate_artifact_metadata(
        artifact_metadata,
        g3_run,
        merged_oid,
    )

    g4_issued = max(desktop_created, runtime_created, g3_created)
    g4_expires = min(
        desktop_created + timedelta(days=30),
        runtime_created + timedelta(days=30),
        g3_created + timedelta(days=30),
        artifact_expires,
    )
    require(g4_expires > g4_issued, "G4 evidence lifetime is already empty")
    release_published = parse_timestamp(contract.release_published_at, "release published_at")
    g1_issued = parse_timestamp(contract.g1_issued_at, "G1 issued_at")

    evidence_specs = evidence_by_key(contract)
    summary_specs = summary_by_key(contract)
    repository_specs = repository_by_role(contract)
    local_digests: dict[str, str] = {}
    for key, spec in evidence_specs.items():
        local_digests[key] = materialize_file(
            evidence / spec.source_relative,
            target_path(material_root, spec.target_relative),
            f"{key} evidence",
            expected_sha256=spec.sha256,
        )

    for key, spec in summary_specs.items():
        for source_relative, expected_sha in spec.source_artifacts:
            source_fd, source_before = open_regular(
                evidence / source_relative,
                f"{key} summary source artifact",
            )
            try:
                actual, _ = hash_open_file(source_fd, source_before, f"{key} summary source artifact")
            finally:
                os.close(source_fd)
            require(actual == expected_sha, f"{key} summary source artifact SHA-256 mismatch")
        summary_raw = canonical_bytes(spec.payload)
        require(sha256_bytes(summary_raw) == spec.sha256, f"{key} summary canonical SHA-256 mismatch")
        publish_bytes_exact(
            target_path(material_root, spec.target_relative),
            summary_raw,
            f"{key} summary",
        )
        local_digests[key] = spec.sha256

    asset_specs = {spec.role: spec for spec in contract.release_assets}
    require(tuple(asset_specs) == GATE_SOURCE_ROLES["g2"][2:], "release asset roles or order are not exact")
    for spec in contract.release_assets:
        materialize_file(
            evidence / spec.source_relative,
            target_path(material_root, spec.target_relative),
            f"{spec.role} release asset",
            expected_sha256=spec.sha256,
        )

    repository_descriptors: dict[str, dict[str, Any]] = {}
    for spec in contract.repository_files:
        require(spec.worktree in {"ios", "floorp"}, f"{spec.role}: unknown repository worktree")
        selected_tree = merged_worktree if spec.worktree == "ios" else floorp_tree
        commit_sha = merged_oid if spec.commit_sha is None else spec.commit_sha
        raw = repository_blob(selected_tree, commit_sha, spec)
        publish_bytes_exact(
            target_path(material_root, spec.target_relative),
            raw,
            f"{spec.role} repository material",
        )
        repository_descriptors[spec.role] = repository_source(spec, commit_sha)

    materialize_file(
        absolute_path(g3_run_json),
        target_path(material_root, "captures/g3-ci-run.json"),
        "G3 run material",
        expected_sha256=sha256_bytes(g3_run_raw),
    )
    materialize_file(
        absolute_path(desktop_run_json),
        target_path(material_root, "captures/g4-desktop-ci-run.json"),
        "Desktop run material",
        expected_sha256=sha256_bytes(desktop_run_raw),
    )
    materialize_file(
        absolute_path(runtime_run_json),
        target_path(material_root, "captures/g4-runtime-ci-run.json"),
        "Runtime run material",
        expected_sha256=sha256_bytes(runtime_run_raw),
    )
    materialize_file(
        absolute_path(g3_artifact_metadata_json),
        target_path(material_root, "captures/g3-xcresult-metadata.json"),
        "G3 artifact metadata material",
        expected_sha256=sha256_bytes(artifact_metadata_raw),
    )
    materialize_file(
        absolute_path(integration_execution_capture),
        target_path(material_root, "captures/integration-execution-capture.json"),
        "integration execution capture material",
        expected_sha256=sha256_bytes(integration_capture_raw),
    )
    xcresult_sha256 = materialize_file(
        absolute_path(g3_xcresult_zip),
        target_path(material_root, "captures/g3-xcresult.zip"),
        "G3 XCResult material",
        expected_sha256=None,
    )

    release_inputs = build_release_inputs(merged_oid, contract)
    receipt = {
        "commands": commands,
        "repositories": [
            {
                "base_oid": contract.base_oid,
                "head_oid": contract.reviewed_head_oid,
                "merged_oid": merged_oid,
                "name": "floorp-ios",
            }
        ],
        "schema_version": 1,
        "state": "integration_complete",
        "task_id": 19,
    }
    receipt_raw = canonical_bytes(receipt)
    receipt_relative = "artifacts/task-19-integration-receipt.json"
    receipt_path = target_path(material_root, receipt_relative)
    require(not os.path.lexists(receipt_path), "integration receipt already exists; only the assembler may create it")

    g3_run_descriptor = run_source("ci-run", g3_run, g3_run_raw)
    g3_artifact_descriptor = artifact_source(
        "xcresult",
        artifact_metadata,
        contract.ios_repository,
        xcresult_sha256,
    )
    desktop_run_descriptor = run_source("desktop-ci-run", desktop_run, desktop_run_raw)
    runtime_run_descriptor = run_source("runtime-ci-run", runtime_run, runtime_run_raw)

    g1_sources = [
        source_entry(
            evidence_specs["task16"].target_relative,
            local_source(
                "task-manifest",
                evidence_specs["task16"].target_relative,
                "metadata-json",
                local_digests["task16"],
            ),
        ),
        source_entry(repository_specs["todo16-contract"].target_relative, repository_descriptors["todo16-contract"]),
        source_entry(repository_specs["ios-contract-source"].target_relative, repository_descriptors["ios-contract-source"]),
        source_entry(repository_specs["desktop-contract-source"].target_relative, repository_descriptors["desktop-contract-source"]),
        source_entry(repository_specs["merge-fixture"].target_relative, repository_descriptors["merge-fixture"]),
    ]
    g2_sources = [
        source_entry(
            evidence_specs["task17"].target_relative,
            local_source(
                "task-manifest",
                evidence_specs["task17"].target_relative,
                "metadata-json",
                local_digests["task17"],
            ),
        ),
        source_entry(
            summary_specs["fake-server"].target_relative,
            local_source(
                "fake-server-run",
                summary_specs["fake-server"].target_relative,
                "metadata-json",
                local_digests["fake-server"],
            ),
        ),
        *[
            source_entry(spec.target_relative, release_asset_source(spec, contract))
            for spec in contract.release_assets
        ],
    ]
    g3_sources = [
        source_entry(
            receipt_relative,
            local_source(
                "integration-receipt",
                receipt_relative,
                "metadata-json",
                sha256_bytes(receipt_raw),
            ),
        ),
        source_entry("captures/g3-ci-run.json", g3_run_descriptor),
        source_entry("captures/g3-xcresult.zip", g3_artifact_descriptor),
    ]
    g4_sources = [
        source_entry(
            evidence_specs["task18"].target_relative,
            local_source(
                "task-manifest",
                evidence_specs["task18"].target_relative,
                "metadata-json",
                local_digests["task18"],
            ),
        ),
        source_entry(
            evidence_specs["task18-verdict"].target_relative,
            local_source(
                "task18-execution-verdict",
                evidence_specs["task18-verdict"].target_relative,
                "metadata-json",
                local_digests["task18-verdict"],
            ),
        ),
        source_entry("captures/g4-desktop-ci-run.json", desktop_run_descriptor),
        source_entry("captures/g4-runtime-ci-run.json", runtime_run_descriptor),
        source_entry(
            repository_specs["g4-attestation-source"].target_relative,
            repository_descriptors["g4-attestation-source"],
        ),
        source_entry(
            "captures/g3-ci-run.json",
            role_only(g3_run_descriptor, "g4-attestation-ci-run"),
        ),
        source_entry(
            "captures/g3-xcresult.zip",
            role_only(g3_artifact_descriptor, "g4-attestation-xcresult"),
        ),
        source_entry(
            summary_specs["xpcshell"].target_relative,
            local_source(
                "xpcshell-run",
                summary_specs["xpcshell"].target_relative,
                "metadata-json",
                local_digests["xpcshell"],
            ),
        ),
        source_entry(
            summary_specs["tps"].target_relative,
            local_source(
                "tps-run",
                summary_specs["tps"].target_relative,
                "metadata-json",
                local_digests["tps"],
            ),
        ),
    ]
    for gate_name, sources in (
        ("g1", g1_sources),
        ("g2", g2_sources),
        ("g3", g3_sources),
        ("g4", g4_sources),
    ):
        roles = tuple(entry["descriptor"]["role"] for entry in sources)
        require(roles == GATE_SOURCE_ROLES[gate_name], f"{gate_name}: source roles or order drifted")

    recipe = {
        "build_contract_mode": "production-qa",
        "g3_integration_commands": commands,
        "gates": {
            "g1": {
                "issued_at": format_timestamp(g1_issued),
                "sources": g1_sources,
            },
            "g2": {
                "expires_at": format_timestamp(release_published + timedelta(days=30)),
                "issued_at": format_timestamp(release_published),
                "sources": g2_sources,
            },
            "g3": {
                "expires_at": format_timestamp(artifact_expires),
                "issued_at": format_timestamp(artifact_created),
                "sources": g3_sources,
            },
            "g4": {
                "expires_at": format_timestamp(g4_expires),
                "issued_at": format_timestamp(g4_issued),
                "sources": g4_sources,
            },
        },
        "release_inputs": release_inputs,
        "schema_version": 1,
    }
    publish_bytes_exact(recipe_path, canonical_bytes(recipe), "output recipe")
    return recipe


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--merged-ios-worktree", required=True, type=Path)
    parser.add_argument("--floorp-worktree", required=True, type=Path)
    parser.add_argument("--merged-oid", required=True)
    parser.add_argument("--g3-run-json", required=True, type=Path)
    parser.add_argument("--g3-artifact-metadata-json", required=True, type=Path)
    parser.add_argument("--g3-xcresult-zip", required=True, type=Path)
    parser.add_argument("--desktop-run-json", required=True, type=Path)
    parser.add_argument("--runtime-run-json", required=True, type=Path)
    parser.add_argument("--integration-execution-capture", required=True, type=Path)
    parser.add_argument("--output-recipe", required=True, type=Path)
    parser.add_argument(
        "--evidence-root",
        type=Path,
        default=DEFAULT_EVIDENCE_ROOT,
        help="existing orchestration evidence root (default: approved milestone evidence root)",
    )
    arguments = parser.parse_args(argv)
    previous_umask = os.umask(0o077)
    try:
        prepare(
            run_dir=arguments.run_dir,
            merged_ios_worktree=arguments.merged_ios_worktree,
            floorp_worktree=arguments.floorp_worktree,
            merged_oid=arguments.merged_oid,
            g3_run_json=arguments.g3_run_json,
            g3_artifact_metadata_json=arguments.g3_artifact_metadata_json,
            g3_xcresult_zip=arguments.g3_xcresult_zip,
            desktop_run_json=arguments.desktop_run_json,
            runtime_run_json=arguments.runtime_run_json,
            integration_execution_capture=arguments.integration_execution_capture,
            output_recipe=arguments.output_recipe,
            evidence_root=arguments.evidence_root,
            contract=PRODUCTION_CONTRACT,
        )
        print(f"APPROVE: prepared canonical production-QA recipe at {absolute_path(arguments.output_recipe)}")
        return 0
    except PreparationError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError) as error:
        print(f"INPUT_ERROR: preparation dependency failed ({error})", file=sys.stderr)
        return 2
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
