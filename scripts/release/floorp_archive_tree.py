#!/usr/bin/env python3
"""Compute the canonical SHA-256 of a Floorp ``.xcarchive`` tree.

The digest intentionally excludes mutable filesystem metadata such as mtimes,
owners, and permissions.  It binds every relative path, entry type, regular
file byte stream, and symbolic-link target without following symbolic links.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from pathlib import Path


FORMAT_MARKER = b"floorp-xcarchive-tree-v1\0"


class ArchiveTreeError(ValueError):
    """The archive cannot be represented by the canonical tree format."""


def _encoded(value: str) -> bytes:
    return value.encode("utf-8", errors="surrogateescape")


def _field(digest, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def archive_tree_sha256(root: Path) -> str:
    """Return a deterministic digest for directories, files, and symlinks."""
    root = Path(root)
    try:
        root_stat = root.lstat()
    except OSError as error:
        raise ArchiveTreeError(f"archive does not exist: {root} ({error})") from error
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        raise ArchiveTreeError(f"archive must be a real directory: {root}")
    try:
        root_resolved = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ArchiveTreeError(f"archive cannot be resolved: {root} ({error})") from error

    digest = hashlib.sha256(FORMAT_MARKER)

    def visit(directory: Path, relative_directory: Path) -> None:
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: _encoded(entry.name))
        except OSError as error:
            raise ArchiveTreeError(
                f"could not enumerate archive directory {directory}: {error}"
            ) from error

        for entry in entries:
            relative = relative_directory / entry.name
            relative_bytes = _encoded(relative.as_posix())
            path = Path(entry.path)
            try:
                entry_stat = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise ArchiveTreeError(
                    f"could not stat archive entry {path}: {error}"
                ) from error

            mode = entry_stat.st_mode
            if stat.S_ISLNK(mode):
                try:
                    target_text = os.readlink(path)
                    target_path = Path(target_text)
                    if not target_path.is_absolute():
                        target_path = path.parent / target_path
                    target_path.resolve(strict=True).relative_to(root_resolved)
                    target = _encoded(target_text)
                except (OSError, RuntimeError, ValueError) as error:
                    raise ArchiveTreeError(
                        f"archive symlink is broken or resolves outside the archive: "
                        f"{path} ({error})"
                    ) from error
                digest.update(b"L")
                _field(digest, relative_bytes)
                _field(digest, target)
            elif stat.S_ISDIR(mode):
                digest.update(b"D")
                _field(digest, relative_bytes)
                visit(path, relative)
            elif stat.S_ISREG(mode):
                digest.update(b"F")
                _field(digest, relative_bytes)
                digest.update(entry_stat.st_size.to_bytes(8, "big"))
                flags = os.O_RDONLY
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    descriptor = os.open(path, flags)
                    with os.fdopen(descriptor, "rb") as handle:
                        opened_stat = os.fstat(handle.fileno())
                        if not stat.S_ISREG(opened_stat.st_mode):
                            raise ArchiveTreeError(
                                f"archive entry changed type while hashing: {path}"
                            )
                        if opened_stat.st_size != entry_stat.st_size:
                            raise ArchiveTreeError(
                                f"archive entry changed size while hashing: {path}"
                            )
                        while chunk := handle.read(1024 * 1024):
                            digest.update(chunk)
                except ArchiveTreeError:
                    raise
                except OSError as error:
                    raise ArchiveTreeError(
                        f"could not hash archive file {path}: {error}"
                    ) from error
            else:
                raise ArchiveTreeError(f"unsupported archive entry type: {path}")

    visit(root, Path())
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args(argv)
    try:
        print(archive_tree_sha256(arguments.archive))
        return 0
    except ArchiveTreeError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
