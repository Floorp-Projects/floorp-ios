#!/usr/bin/python3 -I
"""Prepare and attest deterministic generated inputs in an exact Git snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import BinaryIO


SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
NODE_VERSION = "24.18.1"
NODE_ARCHIVE_NAME = f"node-v{NODE_VERSION}-darwin-arm64.tar.gz"
NODE_ARCHIVE_URL = f"https://nodejs.org/download/release/v{NODE_VERSION}/{NODE_ARCHIVE_NAME}"
NODE_ARCHIVE_SHA256 = "eb02f7fab96d3d67de40c5ec8566096fcb4c2026728787683ae5a97eb612b941"
NIMBUS_FML_LOCK_RELATIVE = "scripts/staging/nimbus-fml-binary.lock.json"
NIMBUS_FML_ARCHES = {
    "arm64": "aarch64-apple-darwin",
    "x86_64": "x86_64-apple-darwin",
}
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
READ_SIZE = 1024 * 1024
MAX_MANIFEST_SIZE = 16 * 1024 * 1024
WEBPACK_OUTPUTS = (
    "AddressFormManager.js",
    "AllFramesAtDocumentEnd.js",
    "AllFramesAtDocumentStart.js",
    "AutofillAllFramesAtDocumentStart.js",
    "MainFrameAtDocumentEnd.js",
    "MainFrameAtDocumentStart.js",
    "NightModeAllFramesAtDocumentStart.js",
    "TranslationsEngine.js",
    "WebcompatAllFramesAtDocumentStart.js",
    "translations-engine.worker.js",
)
WEBPACK_SIDECARS = ("MainFrameAtDocumentStart.js.LICENSE.txt",)
GENERATED_PATHS = tuple(
    f"firefox-ios/Client/Assets/{name}" for name in (*WEBPACK_OUTPUTS, *WEBPACK_SIDECARS)
) + (
    "firefox-ios/Client/Generated/FxNimbus.swift",
    "firefox-ios/Client/Generated/FxNimbusMessaging.swift",
    "firefox-ios/Client/Generated/Metrics/Metrics.swift",
    "firefox-ios/Storage/Generated/Metrics.swift",
    "firefox-ios/bin/nimbus-fml.sh",
)
MANIFEST_KEYS = {
    "generated_files",
    "schema_version",
    "source_archive_sha256",
    "source_sha",
    "tools",
}
TOOLS_KEYS = {
    "glean_parser_requirement",
    "glean_parser_version",
    "glean_python",
    "installed_packages",
    "nimbus_binary",
    "nimbus_script_sha256",
    "node_archive",
    "node",
    "npm",
}
NIMBUS_MANIFEST_KEYS = {
    "archive_sha256",
    "executable_arch",
    "executable_sha256",
    "url",
    "version",
}
TOOL_RECORD_KEYS = {
    "path",
    "resolved_path",
    "sha256",
    "size",
    "version",
}
NODE_ARCHIVE_KEYS = {
    "name",
    "sha256",
    "url",
}
NIMBUS_BINARY_KEYS = {
    "archive_sha256",
    "checksum_url",
    "executables",
    "schema_version",
    "url",
    "version",
}


class PreparationError(Exception):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_float(value):
    raise ValueError(f"JSON number is not an integer: {value!r}")


def reject_constant(value):
    raise ValueError(f"JSON constant is forbidden: {value!r}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PreparationError(message)


def sha256_stream(handle: BinaryIO) -> str:
    digest = hashlib.sha256()
    while chunk := handle.read(READ_SIZE):
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    with path.open("rb") as handle:
        return sha256_stream(handle)


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def safe_relative(value: object, label: str) -> Path:
    require(isinstance(value, str), f"{label}: path must be a string")
    pure = PurePosixPath(value)
    require(
        bool(pure.parts)
        and not pure.is_absolute()
        and all(part not in ("", ".", "..") for part in pure.parts),
        f"{label}: unsafe path",
    )
    return Path(*pure.parts)


def under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return path != root
    except ValueError:
        return False


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label}: cannot inspect ({error})") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink is forbidden")
    require(stat.S_ISREG(metadata.st_mode), f"{label}: must be a regular file")
    return metadata


def private_directory(path: Path, label: str, *, create: bool) -> None:
    if create:
        try:
            path.mkdir(mode=0o700)
        except OSError as error:
            raise PreparationError(f"{label}: cannot create ({error})") from error
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label}: cannot inspect ({error})") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink is forbidden")
    require(stat.S_ISDIR(metadata.st_mode), f"{label}: must be a directory")
    require(stat.S_IMODE(metadata.st_mode) == 0o700, f"{label}: mode must be 0700")


def run(
    arguments: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    label: str,
    capture: bool = False,
) -> str:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=environment,
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            text=True,
        )
    except OSError as error:
        raise PreparationError(f"{label}: execution failed ({error})") from error
    if result.returncode != 0:
        detail = ""
        if capture:
            detail = f" ({(result.stderr or result.stdout).strip()})"
        raise PreparationError(f"{label}: exited {result.returncode}{detail}")
    return result.stdout.strip() if capture else ""


def safe_remove_tree(path: Path, root: Path, label: str) -> None:
    if not os.path.lexists(path):
        return
    require(under(path.resolve(strict=False), root), f"{label}: path escaped source root")
    metadata = path.lstat()
    require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink is forbidden")
    require(stat.S_ISDIR(metadata.st_mode), f"{label}: cleanup target is not a directory")
    shutil.rmtree(path)


def install_pinned_node(tool: Path, environment: dict[str, str]) -> tuple[Path, Path, Path]:
    require(os.uname().sysname == "Darwin" and os.uname().machine == "arm64", "pinned Node archive requires macOS arm64")
    archive = tool / NODE_ARCHIVE_NAME
    run(
        [
            "/usr/bin/curl",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            NODE_ARCHIVE_URL,
            "--output",
            str(archive),
        ],
        cwd=tool,
        environment=environment,
        label="pinned Node.js download",
    )
    require(sha256_file(archive) == NODE_ARCHIVE_SHA256, "pinned Node.js archive SHA-256 mismatch")
    destination = tool / "node"
    private_directory(destination, "pinned Node.js extraction", create=True)
    try:
        opened = tarfile.open(archive, mode="r:gz")
    except (OSError, tarfile.TarError) as error:
        raise PreparationError(f"pinned Node.js archive cannot be opened ({error})") from error
    with opened:
        for member in opened.getmembers():
            safe_relative(member.name, "pinned Node.js archive member")
            require(
                member.isdir() or member.isfile() or member.issym() or member.islnk(),
                f"pinned Node.js archive contains a special member: {member.name}",
            )
            if member.issym() or member.islnk():
                link_parent = PurePosixPath(member.name).parent
                link_target = PurePosixPath(member.linkname)
                combined = link_target if link_target.is_absolute() else link_parent / link_target
                normalized = posixpath.normpath(combined.as_posix())
                require(
                    not combined.is_absolute()
                    and normalized not in ("", ".", "..")
                    and not normalized.startswith("../"),
                    f"pinned Node.js archive link escapes extraction: {member.name}",
                )
        opened.extractall(destination)
    root = destination / f"node-v{NODE_VERSION}-darwin-arm64"
    node = root / "bin/node"
    npm = root / "bin/npm"
    regular_file(node.resolve(strict=True), "pinned Node.js binary")
    regular_file(npm.resolve(strict=True), "pinned npm client")
    return node, npm, archive


def compare_archive(source_root: Path, archive: Path) -> set[str]:
    archive_files: set[str] = set()
    try:
        opened = tarfile.open(archive, mode="r:")
    except (OSError, tarfile.TarError) as error:
        raise PreparationError(f"source archive: cannot open ({error})") from error
    with opened:
        for member in opened.getmembers():
            relative = safe_relative(member.name, "source archive member")
            target = source_root / relative
            if member.isdir():
                require(target.is_dir(), f"source archive directory is missing: {member.name}")
                continue
            require(member.isfile(), f"source archive contains unsupported member: {member.name}")
            metadata = regular_file(target, f"source archive member {member.name}")
            require(metadata.st_size == member.size, f"source archive member size changed: {member.name}")
            require(
                bool(metadata.st_mode & stat.S_IXUSR) == bool(member.mode & stat.S_IXUSR),
                f"source archive executable mode changed: {member.name}",
            )
            source = opened.extractfile(member)
            require(source is not None, f"source archive member is unreadable: {member.name}")
            with source:
                expected = sha256_stream(source)
            require(sha256_file(target) == expected, f"source archive member changed: {member.name}")
            archive_files.add(relative.as_posix())

    actual_files: set[str] = set()
    for directory, names, files in os.walk(source_root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        directory_path = Path(directory)
        for name in [*names, *files]:
            path = directory_path / name
            metadata = path.lstat()
            relative = path.relative_to(source_root).as_posix()
            require(not stat.S_ISLNK(metadata.st_mode), f"source snapshot contains a symlink: {relative}")
            require(
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode),
                f"source snapshot contains a special file: {relative}",
            )
            if stat.S_ISREG(metadata.st_mode):
                actual_files.add(relative)
    return actual_files - archive_files


def tool_record(path: Path, version: str) -> dict[str, object]:
    resolved = path.resolve(strict=True)
    metadata = regular_file(resolved, f"tool {path.name}")
    return {
        "path": str(path),
        "resolved_path": str(resolved),
        "sha256": sha256_file(resolved),
        "size": metadata.st_size,
        "version": version,
    }


def install_pinned_nimbus(
    tool: Path,
    environment: dict[str, str],
    firefox_root: Path,
) -> dict[str, object]:
    lock_source = firefox_root.parent / NIMBUS_FML_LOCK_RELATIVE
    metadata = regular_file(lock_source, "Nimbus FML binary lock")
    require(metadata.st_size <= MAX_MANIFEST_SIZE, "Nimbus FML binary lock is too large")
    lock_bytes = lock_source.read_bytes()
    try:
        parsed = json.loads(
            lock_bytes.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PreparationError("Nimbus FML binary lock is malformed") from error
    except ValueError as error:
        raise PreparationError(f"Nimbus FML binary lock is malformed ({error})") from error
    require(
        lock_bytes == canonical_bytes(parsed),
        "Nimbus FML binary lock is not canonical",
    )
    require(
        isinstance(parsed, dict) and set(parsed) == NIMBUS_BINARY_KEYS,
        "Nimbus FML binary lock fields are not exact",
    )
    require(
        parsed.get("schema_version") == 1
        and not isinstance(parsed.get("schema_version"), bool),
        "Nimbus FML binary lock schema is unsupported",
    )
    version = parsed.get("version")
    url = parsed.get("url")
    checksum_url = parsed.get("checksum_url")
    archive_sha256 = parsed.get("archive_sha256")
    require(
        isinstance(version, str) and bool(version) and "/" not in version,
        "Nimbus FML binary lock version is malformed",
    )
    require(
        isinstance(url, str)
        and (url.startswith("https://") or url.startswith("file://")),
        "Nimbus FML binary lock URL is not HTTPS",
    )
    require(
        isinstance(checksum_url, str)
        and (checksum_url.startswith("https://") or checksum_url.startswith("file://")),
        "Nimbus FML binary lock checksum URL is not HTTPS",
    )
    require(
        isinstance(archive_sha256, str)
        and re.fullmatch(r"[0-9a-f]{64}", archive_sha256) is not None,
        "Nimbus FML binary lock archive digest is malformed",
    )
    executables = parsed.get("executables")
    require(
        isinstance(executables, dict) and set(executables) == set(NIMBUS_FML_ARCHES.values()),
        "Nimbus FML binary lock executable set is not exact",
    )
    for arch, digest in executables.items():
        require(
            isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"Nimbus FML binary lock executable digest is malformed: {arch}",
        )
    machine = os.uname().machine
    require(machine in NIMBUS_FML_ARCHES, f"unsupported architecture: {machine}")
    executable_arch = NIMBUS_FML_ARCHES[machine]
    executable_sha256 = executables[executable_arch]

    zip_path = tool / "nimbus-fml.zip"
    run(
        [
            "/usr/bin/curl",
            "--proto",
            "=https,file",
            "--proto-redir",
            "=https,file",
            "--tlsv1.2",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            url,
            "--output",
            str(zip_path),
        ],
        cwd=tool,
        environment=environment,
        label="pinned Nimbus FML download",
    )
    require(
        sha256_file(zip_path) == archive_sha256,
        "pinned Nimbus FML archive SHA-256 mismatch",
    )
    fml_dir = firefox_root / "build/nimbus" / version / "bin"
    fml_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    private_directory(fml_dir, "Nimbus FML cache", create=True)
    (fml_dir / "nimbus-fml.sha256").write_text(
        f"{archive_sha256}  nimbus-fml.zip\n",
        encoding="utf-8",
    )
    (fml_dir / "nimbus-fml.zip").write_bytes(zip_path.read_bytes())
    run(
        [
            "/usr/bin/unzip",
            "-o",
            "-j",
            str(fml_dir / "nimbus-fml.zip"),
            f"{executable_arch}/release/nimbus-fml",
            "-d",
            str(fml_dir),
        ],
        cwd=fml_dir,
        environment=environment,
        label="pinned Nimbus FML extraction",
    )
    binary = fml_dir / "nimbus-fml"
    metadata = regular_file(binary, "pinned Nimbus FML executable")
    require(
        sha256_file(binary) == executable_sha256,
        "pinned Nimbus FML executable SHA-256 mismatch",
    )
    if not bool(metadata.st_mode & stat.S_IXUSR):
        binary.chmod(metadata.st_mode | stat.S_IXUSR)
    return {
        "archive_sha256": archive_sha256,
        "executable_arch": executable_arch,
        "executable_sha256": executable_sha256,
        "url": url,
        "version": version,
    }


def publish(path: Path, payload: bytes) -> None:
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
    except FileExistsError as error:
        raise PreparationError("generated-source manifest already exists") from error
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def load_manifest(path: Path) -> tuple[dict[str, object], bytes]:
    metadata = regular_file(path, "generated-source manifest")
    require(metadata.st_size <= MAX_MANIFEST_SIZE, "generated-source manifest is too large")
    raw = path.read_bytes()
    try:
        payload = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PreparationError("generated-source manifest is malformed") from error
    require(isinstance(payload, dict), "generated-source manifest root must be an object")
    require(set(payload) == MANIFEST_KEYS, "generated-source manifest fields are not exact")
    require(raw == canonical_bytes(payload), "generated-source manifest is not canonical")
    return payload, raw


def validate_tools(payload: dict[str, object], source: Path) -> None:
    tools = payload.get("tools")
    require(isinstance(tools, dict), "generated-source manifest tools schema is malformed")
    require(set(tools) == TOOLS_KEYS, "generated-source manifest tools fields are not exact")
    requirement = tools.get("glean_parser_requirement")
    require(
        requirement == "20.0",
        "generated-source manifest Glean parser requirement is not exactly 20.0",
    )
    version = tools.get("glean_parser_version")
    require(
        version == "20.0.0",
        "generated-source manifest Glean parser version is not exactly 20.0.0",
    )
    nimbus_script = tools.get("nimbus_script_sha256")
    require(
        isinstance(nimbus_script, str)
        and re.fullmatch(r"[0-9a-f]{64}", nimbus_script) is not None,
        "generated-source manifest Nimbus script digest is malformed",
    )
    nimbus_path = source / "firefox-ios/bin/nimbus-fml.sh"
    require(
        sha256_file(nimbus_path) == nimbus_script,
        "generated-source manifest Nimbus script digest mismatch",
    )
    nimbus_binary = tools.get("nimbus_binary")
    require(
        isinstance(nimbus_binary, dict)
        and set(nimbus_binary) == NIMBUS_MANIFEST_KEYS,
        "generated-source manifest Nimbus binary fields are not exact",
    )
    require(
        isinstance(nimbus_binary.get("version"), str)
        and bool(nimbus_binary["version"])
        and "/" not in nimbus_binary["version"],
        "generated-source manifest Nimbus binary version is malformed",
    )
    require(
        isinstance(nimbus_binary.get("url"), str)
        and (
            nimbus_binary["url"].startswith("https://")
            or nimbus_binary["url"].startswith("file://")
        ),
        "generated-source manifest Nimbus binary URL is not HTTPS",
    )
    for key in ("archive_sha256", "executable_sha256"):
        digest = nimbus_binary.get(key)
        require(
            isinstance(digest, str)
            and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"generated-source manifest Nimbus binary {key} is malformed",
        )
    require(
        nimbus_binary.get("executable_arch") in NIMBUS_FML_ARCHES.values(),
        "generated-source manifest Nimbus binary architecture is malformed",
    )
    installed = tools.get("installed_packages")
    require(
        isinstance(installed, list)
        and bool(installed)
        and all(isinstance(item, str) and bool(item) for item in installed),
        "generated-source manifest package inventory is malformed",
    )
    node_archive = tools.get("node_archive")
    require(
        isinstance(node_archive, dict) and set(node_archive) == NODE_ARCHIVE_KEYS,
        "generated-source manifest Node archive fields are not exact",
    )
    for key, pattern in (
        ("name", r".+"),
        ("url", r".+"),
        ("sha256", r"[0-9a-f]{64}"),
    ):
        value = node_archive.get(key)
        require(
            isinstance(value, str) and re.fullmatch(pattern, value) is not None,
            f"generated-source manifest Node archive {key} is malformed",
        )
    for key in ("glean_python", "node", "npm"):
        record = tools.get(key)
        require(
            isinstance(record, dict) and set(record) == TOOL_RECORD_KEYS,
            f"generated-source manifest tool record {key} fields are not exact",
        )
        require(
            isinstance(record.get("version"), str) and bool(record["version"]),
            f"generated-source manifest tool record {key} version is malformed",
        )
        require(
            isinstance(record.get("path"), str) and bool(record["path"]),
            f"generated-source manifest tool record {key} path is malformed",
        )
        require(
            isinstance(record.get("resolved_path"), str) and bool(record["resolved_path"]),
            f"generated-source manifest tool record {key} resolved path is malformed",
        )
        require(
            isinstance(record.get("size"), int)
            and not isinstance(record.get("size"), bool)
            and record["size"] > 0,
            f"generated-source manifest tool record {key} size is malformed",
        )
        digest = record.get("sha256")
        require(
            isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"generated-source manifest tool record {key} digest is malformed",
        )


def verify(
    source_root: Path,
    manifest_path: Path,
    *,
    source_sha: str,
    source_archive: Path,
) -> dict[str, object]:
    require(source_root.is_absolute(), "generated-source root must be absolute")
    require(not source_root.is_symlink(), "generated-source root symlink is forbidden")
    require(manifest_path.is_absolute(), "generated-source manifest path must be absolute")
    require(SHA1.fullmatch(source_sha) is not None, "expected source SHA is malformed")
    source = source_root.resolve(strict=True)
    payload, _ = load_manifest(manifest_path)
    require(payload.get("schema_version") == 1, "generated-source manifest schema is unsupported")
    require(
        isinstance(payload.get("source_sha"), str)
        and SHA1.fullmatch(payload["source_sha"]) is not None,
        "generated-source manifest source SHA is malformed",
    )
    require(
        payload.get("source_sha") == source_sha,
        "generated-source manifest source SHA does not match the requested commit",
    )
    archive_sha256 = payload.get("source_archive_sha256")
    require(
        isinstance(archive_sha256, str)
        and re.fullmatch(r"[0-9a-f]{64}", archive_sha256) is not None,
        "generated-source manifest archive digest is malformed",
    )
    archive = source_archive.resolve(strict=True)
    require(
        sha256_file(archive) == archive_sha256,
        "generated-source manifest archive digest mismatch",
    )
    validate_tools(payload, source)
    files = payload.get("generated_files")
    require(isinstance(files, list) and bool(files), "generated-source file list is empty")
    observed: list[str] = []
    for index, entry in enumerate(files):
        require(isinstance(entry, dict), f"generated-source file {index} is malformed")
        require(
            set(entry) == {"executable", "path", "sha256", "size"},
            f"generated-source file {index} fields are not exact",
        )
        relative = safe_relative(entry.get("path"), f"generated-source file {index}")
        size = entry.get("size")
        executable = entry.get("executable")
        digest = entry.get("sha256")
        require(
            isinstance(size, int) and not isinstance(size, bool) and size > 0,
            f"generated-source file {index} size is malformed",
        )
        require(isinstance(executable, bool), f"generated-source file {index} executable flag is malformed")
        require(
            isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"generated-source file {index} digest is malformed",
        )
        path = source / relative
        metadata = regular_file(path, f"generated-source file {relative.as_posix()}")
        require(metadata.st_size == size, f"generated-source size mismatch: {relative}")
        require(
            bool(metadata.st_mode & stat.S_IXUSR) is executable,
            f"generated-source executable mode mismatch: {relative}",
        )
        require(sha256_file(path) == digest, f"generated-source digest mismatch: {relative}")
        observed.append(relative.as_posix())
    require(observed == sorted(observed), "generated-source files are not sorted")
    require(len(observed) == len(set(observed)), "generated-source files contain duplicates")
    require(set(observed) == set(GENERATED_PATHS), "generated-source manifest path set is not exact")
    return payload


def prepare(
    *,
    source_root: Path,
    source_archive: Path,
    source_sha: str,
    output_root: Path,
    tool_state: Path,
    output: Path,
) -> dict[str, object]:
    require(SHA1.fullmatch(source_sha) is not None, "source SHA is malformed")
    root = source_root.resolve(strict=True)
    archive = source_archive.resolve(strict=True)
    out_root = output_root.resolve(strict=True)
    require(under(root, out_root), "source snapshot must be inside the private output root")
    require(under(archive, out_root), "source archive must be inside the private output root")
    tool = tool_state.resolve(strict=False)
    destination = output.resolve(strict=False)
    require(under(tool, out_root) and not under(tool, root), "tool state must be outside the source snapshot")
    require(under(destination, out_root) and not under(destination, root), "manifest must be outside the source snapshot")
    require(not os.path.lexists(tool), "tool-state path must not pre-exist")
    require(not os.path.lexists(destination), "generated-source manifest must not pre-exist")
    private_directory(out_root, "output root", create=False)
    private_directory(tool, "tool state", create=True)
    for name in ("home", "tmp", "verify"):
        private_directory(tool / name, f"tool state {name}", create=True)

    nvmrc = root / ".nvmrc"
    regular_file(nvmrc, "Node.js version authority")
    require(nvmrc.read_text(encoding="utf-8").strip() == NODE_VERSION, "pinned Node.js version differs from .nvmrc")

    user = run(["/usr/bin/id", "-un"], cwd=root, environment={"PATH": SYSTEM_PATH}, label="user identity", capture=True)
    base_environment = {
        "HOME": str(tool / "home"),
        "LANG": "en_US.UTF-8",
        "LOGNAME": user,
        "PATH": SYSTEM_PATH,
        "TMPDIR": str(tool / "tmp"),
        "USER": user,
    }
    node, npm, node_archive = install_pinned_node(tool, base_environment)
    environment = {
        **base_environment,
        "CI": "true",
        "FLOORP_GLEAN_TOOL_ROOT": str(tool),
        "FLOORP_GLEAN_VENV": str(tool / "glean-venv"),
        "FLOORP_GLEAN_VERIFY_ROOT": str(tool / "verify"),
        "PATH": f"{node.parent}:{SYSTEM_PATH}",
    }
    bootstrap = root / "bootstrap.sh"
    regular_file(bootstrap, "bootstrap script")
    run(["/bin/bash", str(bootstrap), "firefox"], cwd=root, environment=environment, label="Floorp bootstrap")

    firefox_root = root / "firefox-ios"
    sdk_generator = firefox_root / "bin/sdk_generator.sh"
    sdk_generator_text = sdk_generator.read_text(encoding="utf-8")
    require(
        re.findall(r"(?m)^GLEAN_PARSER_VERSION=([^\s]+)$", sdk_generator_text)
        == ["20.0"],
        "Glean parser requirement is not exactly 20.0",
    )
    require(
        re.findall(
            r"(?m)^GLEAN_PARSER_DISTRIBUTION_VERSION=([^\s]+)$",
            sdk_generator_text,
        )
        == ["20.0.0"],
        "Glean parser distribution version is not exactly 20.0.0",
    )
    storage_output = firefox_root / "Storage/Generated"
    storage_metrics = firefox_root / "Storage/metrics.yaml"
    storage_environment = {
        **environment,
        "ACTION": "build",
        "FLOORP_GLEAN_VERIFY_ONLY": "NO",
        "PROJECT": "Client",
        "SOURCE_ROOT": str(firefox_root),
    }
    run(
        [
            "/bin/bash",
            str(sdk_generator),
            "-g",
            "Glean",
            "-o",
            str(storage_output),
            "-b",
            "0",
            str(storage_metrics),
        ],
        cwd=firefox_root,
        environment=storage_environment,
        label="Storage Glean generation",
    )

    nimbus = firefox_root / "bin/nimbus-fml.sh"
    regular_file(nimbus, "pinned Nimbus generator")
    nimbus_binary = install_pinned_nimbus(tool, environment, firefox_root)
    nimbus_environment = {
        **environment,
        "CONFIGURATION": "FloorpRelease",
        "PROJECT": "Client",
        "SOURCE_ROOT": str(firefox_root),
    }
    run(
        [
            "/bin/bash",
            str(nimbus),
            "--verbose",
            "-a",
            nimbus_binary["version"],
        ],
        cwd=firefox_root,
        environment=nimbus_environment,
        label="Nimbus generation",
    )
    binary_path = (
        firefox_root
        / "build/nimbus"
        / nimbus_binary["version"]
        / "bin/nimbus-fml"
    )
    require(
        sha256_file(binary_path) == nimbus_binary["executable_sha256"],
        "Nimbus FML executable changed during generation",
    )

    safe_remove_tree(root / "node_modules", root, "node_modules cleanup")
    safe_remove_tree(firefox_root / "build/nimbus", root, "Nimbus cache cleanup")
    require(not os.path.lexists(firefox_root / ".venv"), "source snapshot contains a forbidden .venv")

    extras = compare_archive(root, archive)
    expected = set(GENERATED_PATHS)
    require(extras == expected, f"generated-source path set mismatch: missing={sorted(expected - extras)!r} unexpected={sorted(extras - expected)!r}")

    generated_files: list[dict[str, object]] = []
    for relative in sorted(extras):
        path = root / safe_relative(relative, "generated-source path")
        metadata = regular_file(path, f"generated-source path {relative}")
        require(metadata.st_size > 0, f"generated-source path is empty: {relative}")
        generated_files.append(
            {
                "executable": bool(metadata.st_mode & stat.S_IXUSR),
                "path": relative,
                "sha256": sha256_file(path),
                "size": metadata.st_size,
            }
        )

    venv_python = tool / "glean-venv/bin/python"
    regular_file(venv_python.resolve(strict=True), "Glean virtual-environment Python")
    glean_version = run(
        [
            str(venv_python),
            "-I",
            "-c",
            "import importlib.metadata; print(importlib.metadata.version('glean_parser'))",
        ],
        cwd=root,
        environment=environment,
        label="Glean parser version",
        capture=True,
    )
    require(
        glean_version == "20.0.0",
        "Glean parser distribution version is not exactly 20.0.0",
    )
    inventory_text = run(
        [str(venv_python), "-I", "-m", "pip", "freeze", "--all"],
        cwd=root,
        environment=environment,
        label="Glean package inventory",
        capture=True,
    )
    inventory = sorted(line for line in inventory_text.splitlines() if line)
    require(bool(inventory), "Glean package inventory is empty")
    node_version = run([str(node), "--version"], cwd=root, environment=environment, label="Node.js version", capture=True)
    require(node_version == f"v{NODE_VERSION}", "Node.js version does not match .nvmrc authority")
    npm_version = run([str(npm), "--version"], cwd=root, environment=environment, label="npm version", capture=True)
    payload: dict[str, object] = {
        "generated_files": generated_files,
        "schema_version": 1,
        "source_archive_sha256": sha256_file(archive),
        "source_sha": source_sha,
        "tools": {
            "glean_parser_requirement": "20.0",
            "glean_parser_version": glean_version,
            "glean_python": tool_record(venv_python, run([str(venv_python), "--version"], cwd=root, environment=environment, label="Glean Python version", capture=True)),
            "installed_packages": inventory,
            "nimbus_binary": nimbus_binary,
            "nimbus_script_sha256": sha256_file(nimbus),
            "node_archive": {
                "name": NODE_ARCHIVE_NAME,
                "sha256": sha256_file(node_archive),
                "url": NODE_ARCHIVE_URL,
            },
            "node": tool_record(node, node_version),
            "npm": tool_record(npm, npm_version),
        },
    }
    raw = canonical_bytes(payload)
    publish(destination, raw)
    verify(root, destination, source_sha=source_sha, source_archive=archive)
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--source-root", required=True, type=Path)
    prepare_parser.add_argument("--source-archive", required=True, type=Path)
    prepare_parser.add_argument("--source-sha", required=True)
    prepare_parser.add_argument("--output-root", required=True, type=Path)
    prepare_parser.add_argument("--tool-state", required=True, type=Path)
    prepare_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--source-root", required=True, type=Path)
    verify_parser.add_argument("--manifest", required=True, type=Path)
    verify_parser.add_argument("--source-sha", required=True)
    verify_parser.add_argument("--source-archive", required=True, type=Path)
    arguments = parser.parse_args(argv)
    previous_umask = os.umask(0o077)
    try:
        if arguments.command == "prepare":
            prepare(
                source_root=arguments.source_root,
                source_archive=arguments.source_archive,
                source_sha=arguments.source_sha,
                output_root=arguments.output_root,
                tool_state=arguments.tool_state,
                output=arguments.output,
            )
            print(f"APPROVE: prepared generated source inputs at {arguments.output.resolve(strict=True)}")
        else:
            verify(
                arguments.source_root,
                arguments.manifest,
                source_sha=arguments.source_sha,
                source_archive=arguments.source_archive,
            )
            print("APPROVE: generated source inputs match their canonical manifest")
        return 0
    except PreparationError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError) as error:
        print(f"INPUT_ERROR: generated-source preparation failed ({error})", file=sys.stderr)
        return 2
    finally:
        os.umask(previous_umask)


if __name__ == "__main__":
    raise SystemExit(main())
