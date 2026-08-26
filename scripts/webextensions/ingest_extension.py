#!/usr/bin/env python3
"""Quarantine and normalize an untrusted WebExtension package.

This tool is deliberately a *build/review* boundary, not a client-side
installer.  ZIP, XPI, and CRX inputs are accepted only as untrusted source
material.  A successful run creates a deterministic, non-compressed FWEA1
artifact that the iOS client can verify against a signed catalog record.

The tool has two goals which must stay separate:

* preserve a reviewable provenance/inspection record for the upstream input;
* produce a normalized immutable artifact without exposing ZIP/CRX parsing to
  the shipping application.

It uses only Python's standard archive support plus an optional JSON patch
file.  Patches are intentionally narrow, recorded, and never mutate the
source input in place.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


MAX_ARCHIVE_BYTES = 25 * 1024 * 1024
MAX_EXPANDED_BYTES = 32 * 1024 * 1024
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_FILE_COUNT = 2048
MAX_COMPRESSION_RATIO = 100
FWEA1_MAGIC = b"FWEA1\n"

SAFE_RESOURCE_SUFFIXES = {
    ".css",
    ".html",
    ".htm",
    ".js",
    ".json",
    ".mjs",
    ".png",
    ".svg",
    ".txt",
    ".wasm",
    ".webp",
}
SAFE_MANIFEST_DROP_KEYS = {
    "author",
    "browser_specific_settings",
    "default_locale",
    "description",
    "homepage_url",
    "icons",
    "minimum_chrome_version",
    "short_name",
    "version_name",
}
FLOORP_MANIFEST_KEYS = {
    "action",
    "background",
    "content_scripts",
    "declarative_net_request",
    "floorp_cosmetic_filter_resources",
    "host_permissions",
    "manifest_version",
    "name",
    "optional_host_permissions",
    "optional_permissions",
    "options_ui",
    "permissions",
    "version",
}
FORBIDDEN_PERMISSIONS = {
    "debugger",
    "nativeMessaging",
    "webRequestBlocking",
}
REMOTE_EXECUTABLE_PATTERN = re.compile(
    r"https?://[^\s'\"`<>]+\.(?:js|mjs|wasm)(?:[?#][^\s'\"`<>]*)?",
    re.IGNORECASE,
)
NETWORK_ENDPOINT_PATTERN = re.compile(r"https?://[^\s'\"`<>]+", re.IGNORECASE)
DYNAMIC_CODE_PATTERN = re.compile(r"\b(?:eval|Function)\s*\(")


class IngestionError(RuntimeError):
    """A concrete quarantine reason for an untrusted source package."""


class DuplicateKeyError(ValueError):
    """Raised when JSON has duplicate object members."""


@dataclasses.dataclass(frozen=True)
class Finding:
    severity: str
    code: str
    detail: str
    path: str | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "severity": self.severity,
            "code": self.code,
            "detail": self.detail,
        }
        if self.path is not None:
            result["path"] = self.path
        return result


@dataclasses.dataclass(frozen=True)
class ArchiveEntry:
    path: str
    data: bytes


@dataclasses.dataclass(frozen=True)
class IngestionResult:
    source_digest: str
    normalized_digest: str
    manifest_digest: str
    inventory_digest: str
    artifact_digest: str
    artifact_bytes: int
    findings: tuple[Finding, ...]
    manifest: dict[str, Any]
    inventory: tuple[dict[str, Any], ...]
    patch_digest: str | None

    def report(self, *, extension_id: str, generation: str, source: str, license_id: str) -> dict[str, Any]:
        return {
            "schema": 1,
            "extension_id": extension_id,
            "generation": generation,
            "source": source,
            "license": license_id,
            "source_sha256": self.source_digest,
            "normalized_tree_sha256": self.normalized_digest,
            "artifact_sha256": self.artifact_digest,
            "artifact_bytes": self.artifact_bytes,
            "manifest_sha256": self.manifest_digest,
            "resource_inventory_sha256": self.inventory_digest,
            "patch_sha256": self.patch_digest,
            "manifest": self.manifest,
            "inventory": list(self.inventory),
            "findings": [finding.as_dict() for finding in self.findings],
            "status": "accepted",
        }


def canonical_json(value: Any) -> bytes:
    """Return the canonical JSON form shared by FWEA1 and catalog tooling.

    String field names in generated metadata are ASCII.  Keeping separators and
    key ordering fixed makes the same input map to one digest across hosts.
    """

    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_extension_id(value: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,127}", value):
        raise IngestionError("extension id must be a 3–128 character lowercase identifier")
    return value


def safe_generation(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", value):
        raise IngestionError("generation must be a 1–96 character identifier")
    return value


def strict_json_loads(data: bytes, *, label: str) -> Any:
    def object_pairs_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        object_value: dict[str, Any] = {}
        for key, value in pairs:
            if key in object_value:
                raise DuplicateKeyError(f"duplicate key {key!r}")
            object_value[key] = value
        return object_value

    def reject_constant(value: str) -> Any:
        raise ValueError(f"non-finite JSON number {value!r}")

    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=object_pairs_hook,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, DuplicateKeyError) as error:
        raise IngestionError(f"{label} is not strict UTF-8 JSON: {error}") from error


def validate_path(path: str, *, allow_directory: bool = False) -> str:
    if not path or "\\" in path or "\x00" in path:
        raise IngestionError(f"unsafe archive path {path!r}")
    if unicodedata.normalize("NFC", path) != path:
        raise IngestionError(f"non-NFC archive path {path!r}")
    if path.startswith("/") or re.match(r"^[A-Za-z]:", path):
        raise IngestionError(f"absolute archive path {path!r}")
    if path.endswith("/"):
        if not allow_directory:
            raise IngestionError(f"unexpected archive directory record {path!r}")
        path = path[:-1]
    parts = PurePosixPath(path).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise IngestionError(f"path traversal archive path {path!r}")
    try:
        path.encode("ascii")
    except UnicodeEncodeError as error:
        raise IngestionError(f"non-ASCII archive path {path!r}") from error
    if len(path.encode("utf-8")) > 1024:
        raise IngestionError(f"archive path is too long: {path!r}")
    return path


def validate_resource_name(path: str) -> None:
    validate_path(path)
    if path == "manifest.json":
        return
    suffix = Path(path).suffix.lower()
    if suffix not in SAFE_RESOURCE_SUFFIXES and not path.upper().startswith(("LICENSE", "NOTICE")):
        raise IngestionError(f"resource type is not accepted by the normalized artifact: {path!r}")


def _check_collision(path: str, paths: set[str], folded: set[str]) -> None:
    if path in paths or path.casefold() in folded:
        raise IngestionError(f"duplicate or case-colliding archive path {path!r}")
    paths.add(path)
    folded.add(path.casefold())


def decode_crx(data: bytes) -> bytes:
    """Strip CRX v2/v3 framing and return its embedded ZIP bytes."""

    if not data.startswith(b"Cr24"):
        return data
    if len(data) < 12:
        raise IngestionError("truncated CRX header")
    version, header_length = struct.unpack_from("<II", data, 4)
    if version == 2:
        if len(data) < 16:
            raise IngestionError("truncated CRX2 header")
        public_key_length, signature_length = struct.unpack_from("<II", data, 8)
        offset = 16 + public_key_length + signature_length
    elif version == 3:
        offset = 12 + header_length
    else:
        raise IngestionError(f"unsupported CRX version {version}")
    if offset >= len(data) or data[offset : offset + 4] != b"PK\x03\x04":
        raise IngestionError("CRX does not contain a ZIP payload")
    return data[offset:]


def read_zip(data: bytes) -> list[ArchiveEntry]:
    if len(data) > MAX_ARCHIVE_BYTES:
        raise IngestionError("archive byte size exceeds the configured limit")
    try:
        archive = zipfile.ZipFile(__import__("io").BytesIO(data), "r")
    except zipfile.BadZipFile as error:
        raise IngestionError(f"malformed ZIP/XPI/CRX payload: {error}") from error

    entries: list[ArchiveEntry] = []
    paths: set[str] = set()
    folded: set[str] = set()
    total_uncompressed = 0
    infos = archive.infolist()
    if len(infos) > MAX_FILE_COUNT:
        raise IngestionError("archive file count exceeds the configured limit")
    for info in infos:
        if info.is_dir():
            validate_path(info.filename, allow_directory=True)
            continue
        path = validate_path(info.filename)
        validate_resource_name(path)
        _check_collision(path, paths, folded)
        if info.flag_bits & 0x1:
            raise IngestionError(f"encrypted archive member is not supported: {path}")
        if info.flag_bits & 0x8:
            raise IngestionError(f"data-descriptor archive member is not deterministic: {path}")
        if info.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
            raise IngestionError(f"unsupported compression algorithm for {path}")
        unix_mode = info.external_attr >> 16
        if stat.S_IFMT(unix_mode) == stat.S_IFLNK:
            raise IngestionError(f"symlink archive member is not supported: {path}")
        if info.file_size < 0 or info.file_size > MAX_FILE_BYTES:
            raise IngestionError(f"archive member exceeds the per-file size limit: {path}")
        total_uncompressed += info.file_size
        if total_uncompressed > MAX_EXPANDED_BYTES:
            raise IngestionError("archive expanded size exceeds the configured limit")
        if info.compress_size > 0 and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO:
            raise IngestionError(f"archive compression ratio is excessive: {path}")
        try:
            member = archive.read(info)
        except (OSError, RuntimeError, zipfile.BadZipFile) as error:
            raise IngestionError(f"cannot extract archive member {path}: {error}") from error
        if len(member) != info.file_size:
            raise IngestionError(f"archive member size mismatch: {path}")
        entries.append(ArchiveEntry(path, member))
    archive.close()
    return sorted(entries, key=lambda entry: entry.path.encode("utf-8"))


def read_directory(path: Path) -> list[ArchiveEntry]:
    entries: list[ArchiveEntry] = []
    paths: set[str] = set()
    folded: set[str] = set()
    total_bytes = 0
    for current, directories, file_names in os.walk(path, followlinks=False):
        current_path = Path(current)
        for directory in directories:
            full = current_path / directory
            if full.is_symlink():
                raise IngestionError(f"source directory contains a symlink: {full}")
        for file_name in file_names:
            full = current_path / file_name
            if full.is_symlink() or not full.is_file():
                raise IngestionError(f"source directory contains a non-regular file: {full}")
            relative = full.relative_to(path).as_posix()
            relative = validate_path(relative)
            validate_resource_name(relative)
            _check_collision(relative, paths, folded)
            size = full.stat().st_size
            if size > MAX_FILE_BYTES:
                raise IngestionError(f"source file exceeds the per-file size limit: {relative}")
            total_bytes += size
            if total_bytes > MAX_EXPANDED_BYTES:
                raise IngestionError("source directory expanded size exceeds the configured limit")
            entries.append(ArchiveEntry(relative, full.read_bytes()))
    if len(entries) > MAX_FILE_COUNT:
        raise IngestionError("source directory file count exceeds the configured limit")
    return sorted(entries, key=lambda entry: entry.path.encode("utf-8"))


def source_entries(source: Path) -> tuple[list[ArchiveEntry], str]:
    if source.is_dir():
        entries = read_directory(source)
        source_fingerprint = canonical_json(
            [{"path": entry.path, "sha256": sha256(entry.data), "size": len(entry.data)} for entry in entries]
        )
        return entries, sha256(source_fingerprint)
    data = source.read_bytes()
    if len(data) > MAX_ARCHIVE_BYTES:
        raise IngestionError("source package byte size exceeds the configured limit")
    return read_zip(decode_crx(data)), sha256(data)


def load_patch(path: Path | None) -> tuple[dict[str, Any], str | None]:
    if path is None:
        return {}, None
    data = path.read_bytes()
    value = strict_json_loads(data, label="compatibility patch")
    if not isinstance(value, dict):
        raise IngestionError("compatibility patch must be a JSON object")
    allowed = {"drop_manifest_keys", "set_manifest", "remove_paths", "replace_text"}
    unknown = set(value) - allowed
    if unknown:
        raise IngestionError(f"compatibility patch contains unknown operations: {sorted(unknown)}")
    return value, sha256(canonical_json(value))


def apply_patch(entries: list[ArchiveEntry], patch: dict[str, Any]) -> list[ArchiveEntry]:
    contents = {entry.path: entry.data for entry in entries}
    manifest_data = contents.get("manifest.json")
    if manifest_data is None:
        raise IngestionError("package has no manifest.json")
    manifest = strict_json_loads(manifest_data, label="manifest.json")
    if not isinstance(manifest, dict):
        raise IngestionError("manifest.json must be a JSON object")

    drop_keys = patch.get("drop_manifest_keys", [])
    if not isinstance(drop_keys, list) or not all(isinstance(key, str) for key in drop_keys):
        raise IngestionError("patch drop_manifest_keys must be a string list")
    for key in drop_keys:
        manifest.pop(key, None)

    set_manifest = patch.get("set_manifest", {})
    if not isinstance(set_manifest, dict) or not all(isinstance(key, str) for key in set_manifest):
        raise IngestionError("patch set_manifest must be an object")
    for key, value in set_manifest.items():
        manifest[key] = value

    remove_paths = patch.get("remove_paths", [])
    if not isinstance(remove_paths, list) or not all(isinstance(value, str) for value in remove_paths):
        raise IngestionError("patch remove_paths must be a string list")
    for path in remove_paths:
        contents.pop(validate_path(path), None)

    replace_text = patch.get("replace_text", [])
    if not isinstance(replace_text, list):
        raise IngestionError("patch replace_text must be a list")
    for replacement in replace_text:
        if not isinstance(replacement, dict) or set(replacement) != {"path", "find", "replace"}:
            raise IngestionError("each text replacement needs path, find, and replace")
        path = validate_path(str(replacement["path"]))
        if path not in contents:
            raise IngestionError(f"patch replacement references absent resource {path}")
        find = replacement["find"]
        substitute = replacement["replace"]
        if not isinstance(find, str) or not isinstance(substitute, str) or not find:
            raise IngestionError("patch text replacement values must be non-empty/find strings")
        try:
            source = contents[path].decode("utf-8")
        except UnicodeDecodeError as error:
            raise IngestionError(f"patch replacement resource is not UTF-8: {path}") from error
        if find not in source:
            raise IngestionError(f"patch replacement text was not found in {path}")
        contents[path] = source.replace(find, substitute).encode("utf-8")

    contents["manifest.json"] = canonical_json(manifest)
    return [ArchiveEntry(path, data) for path, data in sorted(contents.items(), key=lambda item: item[0].encode("utf-8"))]


def normalize_manifest(entries: list[ArchiveEntry]) -> tuple[list[ArchiveEntry], dict[str, Any], list[Finding]]:
    contents = {entry.path: entry.data for entry in entries}
    raw_manifest = contents.get("manifest.json")
    if raw_manifest is None:
        raise IngestionError("package has no manifest.json")
    manifest = strict_json_loads(raw_manifest, label="manifest.json")
    if not isinstance(manifest, dict):
        raise IngestionError("manifest.json must be a JSON object")
    if manifest.get("manifest_version") != 3:
        raise IngestionError("only manifest_version 3 packages can be normalized")

    findings: list[Finding] = []
    for key in sorted(SAFE_MANIFEST_DROP_KEYS & set(manifest)):
        manifest.pop(key, None)
        findings.append(Finding("info", "manifest-field-normalized", f"Removed non-executable manifest field {key}.", "manifest.json"))

    unsupported = sorted(set(manifest) - FLOORP_MANIFEST_KEYS)
    if unsupported:
        raise IngestionError(
            "manifest contains executable or unreviewed fields requiring a compatibility patch: "
            + ", ".join(unsupported)
        )

    # The Floorp client rejects display-only HTML resources that are not
    # reachable from the normalized manifest.  Keep all executable resources,
    # licenses, notices, and assets to make the generation reviewable.
    contents["manifest.json"] = canonical_json(manifest)
    normalized = [
        ArchiveEntry(path, data)
        for path, data in sorted(contents.items(), key=lambda item: item[0].encode("utf-8"))
    ]
    return normalized, manifest, findings


def inspect(entries: Iterable[ArchiveEntry], manifest: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    permissions = manifest.get("permissions", [])
    if not isinstance(permissions, list) or not all(isinstance(item, str) for item in permissions):
        raise IngestionError("manifest permissions must be a string list")
    for permission in sorted(set(permissions) & FORBIDDEN_PERMISSIONS):
        findings.append(Finding("reject", "forbidden-permission", f"Permission {permission} is outside the curated runtime.", "manifest.json"))
    if "update_url" in manifest:
        findings.append(Finding("reject", "upstream-auto-update", "Upstream update_url would bypass immutable catalog generations.", "manifest.json"))
    if "externally_connectable" in manifest:
        findings.append(Finding("warning", "externally-connectable", "External connections require product review.", "manifest.json"))
    if "web_accessible_resources" in manifest:
        findings.append(Finding("warning", "web-accessible-resources", "Web-accessible resources require a reviewable exposure inventory.", "manifest.json"))
    if "content_security_policy" in manifest:
        findings.append(Finding("warning", "content-security-policy", "CSP was supplied by the upstream package and must be reviewed after normalization.", "manifest.json"))
    if manifest.get("background"):
        findings.append(Finding("info", "background", "Background runtime declared.", "manifest.json"))
    if manifest.get("content_scripts"):
        findings.append(Finding("info", "content-script", "Content script declared.", "manifest.json"))
    if manifest.get("declarative_net_request"):
        findings.append(Finding("info", "dnr", "Declarative network rules declared.", "manifest.json"))

    for entry in entries:
        suffix = Path(entry.path).suffix.lower()
        if suffix not in {".js", ".mjs", ".html", ".htm", ".json"}:
            continue
        try:
            text = entry.data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append(Finding("reject", "non-utf8-executable", "Executable or structured resource is not UTF-8.", entry.path))
            continue
        if DYNAMIC_CODE_PATTERN.search(text):
            findings.append(Finding("reject", "dynamic-code", "eval() or Function() is not allowed in a curated artifact.", entry.path))
        if REMOTE_EXECUTABLE_PATTERN.search(text):
            findings.append(Finding("reject", "remote-executable", "Remote JavaScript or WASM would bypass the signed artifact boundary.", entry.path))
        endpoints = sorted(set(NETWORK_ENDPOINT_PATTERN.findall(text)))
        if endpoints:
            findings.append(Finding("warning", "network-endpoint", ", ".join(endpoints[:5]), entry.path))
    return findings


def inventory(entries: Iterable[ArchiveEntry]) -> tuple[dict[str, Any], ...]:
    return tuple(
        {"path": entry.path, "sha256": sha256(entry.data), "size": len(entry.data)}
        for entry in sorted(entries, key=lambda value: value.path.encode("utf-8"))
    )


def encode_fwea1(entries: Iterable[ArchiveEntry]) -> tuple[bytes, tuple[dict[str, Any], ...]]:
    values = tuple(sorted(entries, key=lambda entry: entry.path.encode("utf-8")))
    if not values or len(values) > MAX_FILE_COUNT:
        raise IngestionError("normalized artifact has invalid resource count")
    file_inventory = inventory(values)
    header = canonical_json({"files": list(file_inventory)})
    if len(header) > 1024 * 1024:
        raise IngestionError("normalized artifact inventory is too large")
    artifact = FWEA1_MAGIC + struct.pack(">I", len(header)) + header + b"".join(entry.data for entry in values)
    if len(artifact) > MAX_EXPANDED_BYTES + 1024 * 1024:
        raise IngestionError("normalized artifact exceeds the package byte limit")
    return artifact, file_inventory


def normal_tree_digest(entries: Iterable[ArchiveEntry]) -> str:
    return sha256(canonical_json(list(inventory(entries))))


def ingest(
    source: Path,
    *,
    output_directory: Path,
    extension_id: str,
    generation: str,
    upstream: str,
    license_id: str,
    patch_path: Path | None,
) -> IngestionResult:
    safe_extension_id(extension_id)
    safe_generation(generation)
    if not re.fullmatch(r"[A-Za-z0-9.+-]{1,128}", license_id):
        raise IngestionError("license identifier must be a concise SPDX-style identifier")
    if not re.fullmatch(r"https://[^\s?#]+(?:[?#][^\s]*)?", upstream):
        raise IngestionError("upstream must be an HTTPS URL")

    raw_entries, source_digest = source_entries(source)
    patch, patch_digest = load_patch(patch_path)
    patched_entries = apply_patch(raw_entries, patch)
    normalized_entries, manifest, normalization_findings = normalize_manifest(patched_entries)
    findings = [*normalization_findings, *inspect(normalized_entries, manifest)]
    rejected = [finding for finding in findings if finding.severity == "reject"]
    if rejected:
        details = "; ".join(f"{finding.code}: {finding.detail}" for finding in rejected)
        raise IngestionError(f"static inspection quarantined the package: {details}")

    artifact, resource_inventory = encode_fwea1(normalized_entries)
    manifest_data = next(entry.data for entry in normalized_entries if entry.path == "manifest.json")
    result = IngestionResult(
        source_digest=source_digest,
        normalized_digest=normal_tree_digest(normalized_entries),
        manifest_digest=sha256(manifest_data),
        inventory_digest=sha256(canonical_json({"files": list(resource_inventory)})),
        artifact_digest=sha256(artifact),
        artifact_bytes=len(artifact),
        findings=tuple(findings),
        manifest=manifest,
        inventory=resource_inventory,
        patch_digest=patch_digest,
    )

    output_directory.mkdir(parents=True, exist_ok=True)
    normalized_directory = output_directory / "normalized"
    if normalized_directory.exists():
        shutil.rmtree(normalized_directory)
    for entry in normalized_entries:
        destination = normalized_directory / entry.path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(entry.data)
    (output_directory / "artifact.fwea1").write_bytes(artifact)
    (output_directory / "inventory.json").write_bytes(canonical_json({"files": list(resource_inventory)}))
    (output_directory / "inspection.json").write_bytes(
        canonical_json(result.report(
            extension_id=extension_id,
            generation=generation,
            source=upstream,
            license_id=license_id,
        ))
    )
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("source", type=Path, help="untrusted ZIP/XPI/CRX input or unpacked source directory")
    result.add_argument("--output", required=True, type=Path, help="output directory for normalized review material")
    result.add_argument("--extension-id", required=True)
    result.add_argument("--generation", required=True)
    result.add_argument("--upstream", required=True)
    result.add_argument("--license", dest="license_id", required=True)
    result.add_argument("--patch", type=Path, help="reviewed compatibility patch JSON")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        result = ingest(
            arguments.source,
            output_directory=arguments.output,
            extension_id=arguments.extension_id,
            generation=arguments.generation,
            upstream=arguments.upstream,
            license_id=arguments.license_id,
            patch_path=arguments.patch,
        )
    except (IngestionError, OSError) as error:
        print(f"quarantined: {error}", file=sys.stderr)
        return 2
    print(json.dumps({
        "artifact_sha256": result.artifact_digest,
        "artifact_bytes": result.artifact_bytes,
        "manifest_sha256": result.manifest_digest,
        "resource_inventory_sha256": result.inventory_digest,
        "status": "accepted",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
