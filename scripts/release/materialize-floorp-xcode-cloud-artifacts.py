#!/usr/bin/env python3
"""Materialize one source-bound Xcode Cloud archive and App Store export.

The downloader records the authenticated run -> archive action -> artifact
relationships.  This tool rechecks those records and the downloaded bytes,
preflights every ZIP member, and produces the exact ``.xcarchive`` and ``.ipa``
paths consumed by the Floorp release-evidence gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from floorp_archive_tree import ArchiveTreeError, archive_tree_sha256
from floorp_safe_zip import SafeZipError, preflight_zip_members


MAX_WRAPPER_EXPANDED_BYTES = 12 * 1024 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z0-9._-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")


class MaterializationError(ValueError):
    """Downloaded artifact metadata or bytes violate the release contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MaterializationError(message)


def require_object(value: Any, context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context} must be an object")
    return value


def require_identifier(value: Any, context: str) -> str:
    require(
        isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None,
        f"{context} is invalid",
    )
    return value


def canonical_file(path: Path, context: str) -> Path:
    require(path.is_absolute(), f"{context} path must be absolute")
    require(not path.is_symlink(), f"{context} must not be a symbolic link")
    try:
        resolved = path.resolve(strict=True)
        mode = path.lstat().st_mode
    except (OSError, RuntimeError) as error:
        raise MaterializationError(f"{context} does not exist: {path}") from error
    require(stat.S_ISREG(mode) and resolved.is_file(), f"{context} is not a real file")
    return resolved


def new_file_path(path: Path, context: str) -> Path:
    require(path.is_absolute(), f"{context} path must be absolute")
    require(not path.exists() and not path.is_symlink(), f"refusing to overwrite {context}")
    try:
        parent = path.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise MaterializationError(f"{context} parent does not exist") from error
    require(parent.is_dir(), f"{context} parent is not a directory")
    return parent / path.name


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as handle:
        opened = os.fstat(handle.fileno())
        require(stat.S_ISREG(opened.st_mode), f"artifact changed type while hashing: {path}")
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
        require(size == opened.st_size, f"artifact changed size while hashing: {path}")
    return digest.hexdigest(), size


def load_download_metadata(
    path: Path,
    download: Path,
    *,
    expected_run_id: str,
    expected_file_type: str,
) -> dict[str, Any]:
    metadata_path = canonical_file(path, f"{expected_file_type} metadata")
    try:
        value = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MaterializationError(
            f"could not read {expected_file_type} metadata: {error}"
        ) from error
    value = require_object(value, f"{expected_file_type} metadata")
    require(
        set(value) == {"schema_version", "run_id", "action", "artifact", "download_path"},
        f"{expected_file_type} metadata fields are invalid",
    )
    require(
        isinstance(value.get("schema_version"), int)
        and not isinstance(value.get("schema_version"), bool)
        and value["schema_version"] == 1,
        f"{expected_file_type} metadata schema is unsupported",
    )
    require(value.get("run_id") == expected_run_id, "artifact metadata run ID mismatch")

    action = require_object(value.get("action"), "artifact action")
    require(
        set(action)
        == {"id", "name", "action_type", "execution_progress", "completion_status"},
        "artifact action fields are invalid",
    )
    require_identifier(action.get("id"), "artifact action ID")
    require(isinstance(action.get("name"), str) and action["name"], "action name is missing")
    require(action.get("action_type") == "ARCHIVE", "artifact action is not ARCHIVE")
    require(
        action.get("execution_progress") == "COMPLETE"
        and action.get("completion_status") == "SUCCEEDED",
        "artifact action did not complete successfully",
    )

    artifact = require_object(value.get("artifact"), "artifact identity")
    require(
        set(artifact)
        == {
            "id",
            "file_type",
            "file_name",
            "file_size",
            "downloaded_size",
            "sha256",
        },
        "artifact identity fields are invalid",
    )
    require_identifier(artifact.get("id"), "artifact ID")
    require(
        artifact.get("file_type") == expected_file_type,
        f"expected {expected_file_type} artifact metadata",
    )
    file_name = artifact.get("file_name")
    require(
        isinstance(file_name, str)
        and file_name not in {"", ".", ".."}
        and "/" not in file_name
        and "\\" not in file_name
        and all(ord(character) >= 32 and ord(character) != 127 for character in file_name),
        "artifact file name is invalid",
    )
    size = artifact.get("file_size")
    downloaded_size = artifact.get("downloaded_size")
    require(
        isinstance(size, int)
        and not isinstance(size, bool)
        and size > 0
        and downloaded_size == size,
        "artifact byte counts are invalid",
    )
    digest = artifact.get("sha256")
    require(isinstance(digest, str) and SHA256.fullmatch(digest), "artifact digest is invalid")
    require(
        value.get("download_path") == str(download),
        "artifact metadata does not name the selected download",
    )
    actual_digest, actual_size = sha256_file(download)
    require(actual_size == size, "downloaded artifact size does not match metadata")
    require(actual_digest == digest, "downloaded artifact digest does not match metadata")
    return value


def extract_wrapper(wrapper: Path, destination: Path) -> None:
    try:
        with zipfile.ZipFile(wrapper) as archive:
            members = preflight_zip_members(
                archive.infolist(), max_total_size=MAX_WRAPPER_EXPANDED_BYTES
            )
            for member in members:
                raw_parts = member.filename.split("/")
                if raw_parts[-1] == "":
                    raw_parts = raw_parts[:-1]
                target = destination.joinpath(*raw_parts)
                mode = member.external_attr >> 16
                is_directory = member.is_dir() or stat.S_ISDIR(mode)
                if is_directory:
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                written = 0
                with archive.open(member, "r") as source, target.open("xb") as output:
                    while chunk := source.read(1024 * 1024):
                        output.write(chunk)
                        written += len(chunk)
                    output.flush()
                    os.fsync(output.fileno())
                require(written == member.file_size, f"ZIP member size changed: {member.filename}")
                permissions = stat.S_IMODE(mode) if mode else 0o600
                target.chmod(permissions & 0o777)
    except (OSError, RuntimeError, zipfile.BadZipFile, SafeZipError) as error:
        raise MaterializationError(f"could not safely extract {wrapper.name}: {error}") from error


def safe_zip_inventory(path: Path) -> list[zipfile.ZipInfo]:
    """Read and preflight a complete ZIP without trusting its display name."""
    try:
        with zipfile.ZipFile(path) as archive:
            return preflight_zip_members(
                archive.infolist(), max_total_size=MAX_WRAPPER_EXPANDED_BYTES
            )
    except (OSError, RuntimeError, zipfile.BadZipFile, SafeZipError) as error:
        raise MaterializationError(f"artifact is not a safe ZIP: {path.name} ({error})") from error


def direct_children_with_suffix(root: Path, suffix: str, *, directory: bool) -> list[Path]:
    result = []
    for child in root.iterdir():
        if child.name.casefold().endswith(suffix.casefold()) and not child.is_symlink():
            if (directory and child.is_dir()) or (not directory and child.is_file()):
                result.append(child)
    return sorted(result)


def recursive_files_with_suffix(root: Path, suffix: str) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*")
        if path.name.casefold().endswith(suffix.casefold())
        and path.is_file()
        and not path.is_symlink()
    )


def write_new_json(path: Path, value: dict[str, Any]) -> None:
    destination = new_file_path(path, "artifact manifest")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary_name, destination)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def materialize(arguments: argparse.Namespace) -> dict[str, Any]:
    expected_run_id = require_identifier(arguments.expected_run_id, "expected run ID")
    archive_download = canonical_file(arguments.archive_download, "ARCHIVE download")
    export_download = canonical_file(arguments.export_download, "ARCHIVE_EXPORT download")
    require(not archive_download.samefile(export_download), "archive downloads must be distinct")
    archive_metadata = load_download_metadata(
        arguments.archive_metadata,
        archive_download,
        expected_run_id=expected_run_id,
        expected_file_type="ARCHIVE",
    )
    export_metadata = load_download_metadata(
        arguments.export_metadata,
        export_download,
        expected_run_id=expected_run_id,
        expected_file_type="ARCHIVE_EXPORT",
    )
    require(
        archive_metadata["action"] == export_metadata["action"],
        "archive artifacts came from different Xcode Cloud actions",
    )
    require(
        archive_metadata["artifact"]["id"] != export_metadata["artifact"]["id"],
        "archive artifacts have the same resource ID",
    )

    output_root = arguments.output_root
    require(output_root.is_absolute(), "materialization root path must be absolute")
    require(
        not output_root.exists() and not output_root.is_symlink(),
        "refusing to overwrite the materialization root",
    )
    try:
        output_parent = output_root.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise MaterializationError("materialization parent does not exist") from error
    require(output_parent.is_dir(), "materialization parent is not a directory")
    output_root = output_parent / output_root.name
    output_root.mkdir(mode=0o700)
    completed = False
    try:
        archive_root = output_root / "archive"
        export_root = output_root / "export"
        archive_root.mkdir(mode=0o700)
        export_root.mkdir(mode=0o700)

        # Apple documents fileName as an arbitrary string. Detect packaging
        # from the safely preflighted bytes instead of relying on a suffix.
        safe_zip_inventory(archive_download)
        extract_wrapper(archive_download, archive_root)
        archives = direct_children_with_suffix(archive_root, ".xcarchive", directory=True)
        require(
            len(archives) == 1,
            f"ARCHIVE wrapper must contain one root .xcarchive; found {len(archives)}",
        )
        archive = archives[0]

        export_members = safe_zip_inventory(export_download)
        direct_payload_plists = [
            member
            for member in export_members
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", member.filename)
            is not None
            and not member.is_dir()
        ]
        nested_ipa_members = [
            member
            for member in export_members
            if member.filename.casefold().endswith(".ipa") and not member.is_dir()
        ]
        if len(direct_payload_plists) == 1 and not nested_ipa_members:
            ipa = export_download
        else:
            require(
                not direct_payload_plists and len(nested_ipa_members) == 1,
                "ARCHIVE_EXPORT must be one direct IPA or contain exactly one nested IPA",
            )
            extract_wrapper(export_download, export_root)
            ipas = recursive_files_with_suffix(export_root, ".ipa")
            require(
                len(ipas) == 1,
                f"ARCHIVE_EXPORT wrapper must contain one IPA; found {len(ipas)}",
            )
            ipa = ipas[0]
            safe_zip_inventory(ipa)

        archive_digest = archive_tree_sha256(archive)
        ipa_digest, ipa_size = sha256_file(ipa)
        # Detect replacement of either retained download during materialization.
        for metadata, download in (
            (archive_metadata, archive_download),
            (export_metadata, export_download),
        ):
            final_digest, final_size = sha256_file(download)
            require(
                final_digest == metadata["artifact"]["sha256"]
                and final_size == metadata["artifact"]["file_size"],
                "downloaded Xcode Cloud artifact changed during materialization",
            )

        manifest = {
            "schema_version": 1,
            "run_id": expected_run_id,
            "action": archive_metadata["action"],
            "artifacts": {
                "archive": archive_metadata["artifact"],
                "archive_export": export_metadata["artifact"],
            },
            "downloads": {
                "archive": str(archive_download),
                "archive_export": str(export_download),
            },
            "materialized": {
                "archive_path": str(archive),
                "archive_tree_sha256": archive_digest,
                "ipa_path": str(ipa),
                "ipa_sha256": ipa_digest,
                "ipa_size": ipa_size,
            },
        }
        completed = True
        return manifest
    finally:
        if not completed:
            shutil.rmtree(output_root, ignore_errors=True)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-run-id", required=True)
    parser.add_argument("--archive-download", type=Path, required=True)
    parser.add_argument("--archive-metadata", type=Path, required=True)
    parser.add_argument("--export-download", type=Path, required=True)
    parser.add_argument("--export-metadata", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--manifest-output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        manifest_path = new_file_path(arguments.manifest_output, "artifact manifest")
        manifest = materialize(arguments)
        write_new_json(manifest_path, manifest)
        print(manifest_path)
        return 0
    except (ArchiveTreeError, MaterializationError, OSError) as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
