#!/usr/bin/env python3
"""Fail-closed ZIP inventory checks shared by Floorp release tooling.

This module validates the complete central-directory inventory before any
member is extracted.  It deliberately does not choose which members a caller
may materialize; callers remain responsible for their artifact-specific root
and content contracts.
"""

from __future__ import annotations

import stat
import unicodedata
import zipfile
from collections.abc import Iterable


DEFAULT_MAX_MEMBERS = 200_000
DEFAULT_MAX_TOTAL_SIZE = 16 * 1024 * 1024 * 1024
DEFAULT_MAX_MEMBER_SIZE = 4 * 1024 * 1024 * 1024
DEFAULT_MAX_COMPRESSION_RATIO = 1_000


class SafeZipError(ValueError):
    """The ZIP cannot be represented as one unambiguous safe file tree."""


def _reject(condition: bool, message: str) -> None:
    if not condition:
        raise SafeZipError(message)


def _collision_key(parts: tuple[str, ...]) -> str:
    return "/".join(unicodedata.normalize("NFC", part).casefold() for part in parts)


def preflight_zip_members(
    entries: Iterable[zipfile.ZipInfo],
    *,
    max_members: int = DEFAULT_MAX_MEMBERS,
    max_total_size: int = DEFAULT_MAX_TOTAL_SIZE,
    max_member_size: int = DEFAULT_MAX_MEMBER_SIZE,
    max_compression_ratio: int = DEFAULT_MAX_COMPRESSION_RATIO,
) -> list[zipfile.ZipInfo]:
    """Return a stable member list after validating its complete file tree.

    Exact duplicates, case/Unicode aliases, file-vs-directory conflicts,
    traversal, non-regular types, encryption, and ZIP-bomb-sized inventories
    are rejected.  Explicit directory entries may follow an identical implicit
    parent directory created by an earlier child.
    """
    members = list(entries)
    _reject(bool(members), "artifact ZIP is empty")
    _reject(len(members) <= max_members, "artifact ZIP has too many members")

    seen_names: set[str] = set()
    # key -> (original path without a trailing slash, kind, explicit)
    nodes: dict[str, tuple[str, str, bool]] = {}
    total_size = 0

    for entry in members:
        name = entry.filename
        _reject(isinstance(name, str) and bool(name), "artifact ZIP member name is empty")
        _reject(name not in seen_names, f"artifact ZIP contains duplicate member: {name!r}")
        seen_names.add(name)
        _reject(
            "\\" not in name
            and all(ord(character) >= 32 and character != "\x7f" for character in name),
            f"artifact ZIP contains an unsafe member: {name!r}",
        )
        _reject(not name.startswith("/"), f"artifact ZIP member is absolute: {name!r}")
        raw_parts = name.split("/")
        if raw_parts[-1] == "":
            raw_parts = raw_parts[:-1]
        _reject(
            bool(raw_parts) and all(part not in {"", ".", ".."} for part in raw_parts),
            f"artifact ZIP member traverses or aliases a path: {name!r}",
        )
        parts = tuple(raw_parts)
        normalized_name = "/".join(parts)

        _reject(not (entry.flag_bits & 0x1), f"artifact ZIP member is encrypted: {name!r}")
        mode = entry.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        _reject(
            not stat.S_ISLNK(mode) and file_type in {0, stat.S_IFREG, stat.S_IFDIR},
            f"artifact ZIP contains an unsupported member type: {name!r}",
        )
        is_directory = entry.is_dir() or file_type == stat.S_IFDIR
        _reject(
            not entry.is_dir() or file_type in {0, stat.S_IFDIR},
            f"artifact ZIP directory has a conflicting type: {name!r}",
        )
        _reject(
            entry.is_dir() or file_type != stat.S_IFDIR,
            f"artifact ZIP member has an ambiguous directory type: {name!r}",
        )

        _reject(0 <= entry.file_size <= max_member_size,
                f"artifact ZIP member is too large: {name!r}")
        _reject(entry.compress_size >= 0, f"artifact ZIP member has an invalid size: {name!r}")
        if not is_directory and entry.file_size:
            _reject(
                entry.compress_size > 0
                and entry.file_size <= entry.compress_size * max_compression_ratio,
                f"artifact ZIP member has an excessive compression ratio: {name!r}",
            )
        total_size += entry.file_size
        _reject(total_size <= max_total_size, "artifact ZIP expands beyond the size limit")

        for depth in range(1, len(parts)):
            prefix_parts = parts[:depth]
            prefix_name = "/".join(prefix_parts)
            prefix_key = _collision_key(prefix_parts)
            previous = nodes.get(prefix_key)
            if previous is None:
                nodes[prefix_key] = (prefix_name, "directory", False)
            else:
                previous_name, previous_kind, _previous_explicit = previous
                _reject(
                    previous_name == prefix_name,
                    "artifact ZIP contains case-insensitive path aliases: "
                    f"{previous_name!r}, {prefix_name!r}",
                )
                _reject(
                    previous_kind == "directory",
                    f"artifact ZIP places a child below a regular file: {prefix_name!r}",
                )

        key = _collision_key(parts)
        kind = "directory" if is_directory else "file"
        previous = nodes.get(key)
        if previous is None:
            nodes[key] = (normalized_name, kind, True)
            continue

        previous_name, previous_kind, previous_explicit = previous
        _reject(
            previous_name == normalized_name,
            "artifact ZIP contains case-insensitive path aliases: "
            f"{previous_name!r}, {normalized_name!r}",
        )
        _reject(
            previous_kind == kind == "directory" and not previous_explicit,
            f"artifact ZIP contains a file/directory path conflict: {normalized_name!r}",
        )
        nodes[key] = (normalized_name, "directory", True)

    return members
