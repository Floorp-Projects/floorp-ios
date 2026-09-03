#!/usr/bin/env python3

"""Fail closed when Floorp's bundled WKWebExtension assets drift."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile


DEFAULT_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]

EXPECTED = (
    {
        "display_name": "Dark Reader",
        "archive": "darkreader-chrome-mv3-4.9.129.zip",
        "license_file": "darkreader-chrome-mv3-4.9.129.LICENSE",
        "license_marker": "MIT License",
        "review_license_marker": "MIT",
        "provenance_file": "darkreader-chrome-mv3-4.9.129.provenance.json",
        "provenance": {
            "asset": "darkreader-chrome-mv3.zip",
            "downloadURL": "https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip",
            "license": "MIT",
            "release": "v4.9.129",
            "sha256": "20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64",
            "sourceCommit": "c2a707302a39b8047543712e9c582bac07835d34",
        },
        "manifest": {
            "manifest_version": 3,
            "name": "Dark Reader",
            "version": "4.9.129",
        },
    },
    {
        "display_name": "uBlock Origin Lite",
        "archive": "uBOLite_2026.825.1619.safari.zip",
        "license_file": "uBOLite_2026.825.1619.LICENSE",
        "license_marker": "GNU GENERAL PUBLIC LICENSE",
        "review_license_marker": "GNU GPL v3.0 or later",
        "provenance_file": "uBOLite_2026.825.1619.provenance.json",
        "provenance": {
            "asset": "uBOLite_2026.825.1619.safari.zip",
            "downloadURL": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.825.1619/uBOLite_2026.825.1619.safari.zip",
            "license": "GPL-3.0-or-later",
            "release": "2026.825.1619",
            "sha256": "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94",
            "sourceCommit": "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b",
            "strictMinimumSafariVersion": "18.6",
            "unmodifiedUpstreamAsset": True,
        },
        "manifest": {
            "manifest_version": 3,
            "name": "__MSG_extName__",
            "version": "2026.825.1619",
        },
    },
)


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_json(path: Path, repository_root: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read valid JSON from {path.relative_to(repository_root)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(repository_root)} must contain a JSON object")
    return value


def verify_archive(
    entry: dict[str, object],
    bundle_root: Path,
    repository_root: Path,
) -> None:
    archive = bundle_root / str(entry["archive"])
    provenance_path = bundle_root / str(entry["provenance_file"])
    license_path = bundle_root / str(entry["license_file"])
    expected_provenance = entry["provenance"]
    expected_manifest = entry["manifest"]
    assert isinstance(expected_provenance, dict)
    assert isinstance(expected_manifest, dict)

    if not archive.is_file():
        fail(f"missing bundled archive: {archive.relative_to(repository_root)}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != expected_provenance["sha256"]:
        fail(f"unexpected SHA-256 for {archive.name}: {digest}")

    provenance = load_json(provenance_path, repository_root)
    if provenance != expected_provenance:
        fail(f"provenance changed for {archive.name}")

    try:
        license_text = license_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read license for {archive.name}: {error}")
    if str(entry["license_marker"]) not in license_text:
        fail(f"license text does not match {expected_provenance['license']} for {archive.name}")

    try:
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
            for name in names:
                path = PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts or "\\" in name:
                    fail(f"unsafe ZIP entry in {archive.name}: {name}")
            if names.count("manifest.json") != 1:
                fail(f"{archive.name} must contain exactly one root manifest.json")
            manifest = json.loads(package.read("manifest.json"))
            bad_member = package.testzip()
            if bad_member is not None:
                fail(f"CRC failure in {archive.name}: {bad_member}")
    except (OSError, zipfile.BadZipFile, KeyError, json.JSONDecodeError) as error:
        fail(f"invalid bundled extension archive {archive.name}: {error}")

    if not isinstance(manifest, dict):
        fail(f"manifest.json in {archive.name} must contain an object")
    for key, expected_value in expected_manifest.items():
        if manifest.get(key) != expected_value:
            fail(f"unexpected manifest {key} in {archive.name}: {manifest.get(key)!r}")


def verify_review_notes(repository_root: Path) -> None:
    path = repository_root / "docs/app-review-notes-native-webextensions.md"
    try:
        document = path.read_text(encoding="utf-8")
        blocks = document.split("```text\n")
        notes = blocks[1].split("\n```", 1)[0]
        what_to_test = blocks[2].split("\n```", 1)[0]
    except (OSError, IndexError) as error:
        fail(f"cannot read the App Review notes template: {error}")
    if len(notes.encode("utf-8")) > 4_000:
        fail("App Review notes exceed App Store Connect's 4,000-byte limit")
    if len(what_to_test.encode("utf-8")) > 4_000:
        fail("TestFlight What to Test text exceeds App Store Connect's 4,000-byte limit")
    if "Dark Reader" not in what_to_test or "uBlock Origin Lite" not in what_to_test:
        fail("TestFlight What to Test text must cover both bundled extensions")

    required_values = {
        "WKWebExtension",
        "does not download WebExtension code",
        "[RELEASE_TAG_OR_FULL_COMMIT]",
    }
    for entry in EXPECTED:
        provenance = entry["provenance"]
        manifest = entry["manifest"]
        assert isinstance(provenance, dict)
        assert isinstance(manifest, dict)
        required_values.update(
            {
                f'{entry["display_name"]} {manifest["version"]}',
                str(provenance["sha256"]),
                str(provenance["sourceCommit"]),
                str(entry["review_license_marker"]),
            }
        )
    missing = sorted(value for value in required_values if value not in notes)
    if missing:
        fail(f"App Review notes omit required disclosure values: {missing}")


def verify_testflight_metadata(repository_root: Path) -> None:
    metadata = {
        "en-US": repository_root / "firefox-ios/TestFlight/WhatToTest.en-US.txt",
        "ja-JP": repository_root / "firefox-ios/TestFlight/WhatToTest.ja-JP.txt",
    }
    required_values = {"Dark Reader", "uBlock Origin Lite", "WKWebExtension"}
    for entry in EXPECTED:
        manifest = entry["manifest"]
        assert isinstance(manifest, dict)
        required_values.add(f'{entry["display_name"]} {manifest["version"]}')
    forbidden_values = {
        "en-US": {
            "one signed, app-bundled extension",
            "exactly one catalog package",
        },
        "ja-JP": {
            "拡張機能は Dark Reader 1件",
            "catalog package は1件だけ",
        },
    }
    documents = {}
    for locale, path in metadata.items():
        try:
            document = path.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read TestFlight metadata for {locale}: {error}")
        if len(document.encode("utf-8")) > 4_000:
            fail(f"TestFlight metadata for {locale} exceeds the 4,000-byte limit")
        normalized_document = " ".join(document.split())
        missing = sorted(value for value in required_values if value not in normalized_document)
        if missing:
            fail(f"TestFlight metadata for {locale} omits required values: {missing}")
        forbidden = sorted(
            value for value in forbidden_values[locale] if value in normalized_document
        )
        if forbidden:
            fail(f"TestFlight metadata for {locale} retains legacy claims: {forbidden}")
        documents[locale] = document.strip()

    try:
        review_document = (
            repository_root / "docs/app-review-notes-native-webextensions.md"
        ).read_text(encoding="utf-8")
        expected_english = review_document.split("```text\n")[2].split("\n```", 1)[0].strip()
    except (OSError, IndexError) as error:
        fail(f"cannot compare TestFlight metadata with App Review notes: {error}")
    if documents["en-US"] != expected_english:
        fail("English TestFlight metadata differs from the reviewed What to Test template")


def verify_repository(repository_root: Path) -> None:
    repository_root = repository_root.resolve()
    bundle_root = repository_root / "firefox-ios/Floorp/NativeWebExtensions/Bundled"
    legacy_paths = (
        repository_root / "firefox-ios/Floorp/WebExtensions",
        repository_root / "scripts/webextensions",
    )
    for path in legacy_paths:
        if path.exists():
            fail(f"legacy WebExtension implementation remains: {path.relative_to(repository_root)}")

    if not bundle_root.is_dir():
        fail(f"missing bundled extension directory: {bundle_root.relative_to(repository_root)}")

    expected_files = {
        str(value[key])
        for value in EXPECTED
        for key in ("archive", "license_file", "provenance_file")
    }
    actual_files = {path.name for path in bundle_root.iterdir() if path.is_file()}
    if actual_files != expected_files:
        fail(
            "bundled extension file set changed; "
            f"expected {sorted(expected_files)}, found {sorted(actual_files)}"
        )

    for entry in EXPECTED:
        verify_archive(entry, bundle_root, repository_root)
    verify_review_notes(repository_root)
    verify_testflight_metadata(repository_root)


def main() -> int:
    repository_root = Path(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_REPOSITORY_ROOT
    if len(sys.argv) > 2:
        fail("usage: verify_bundled_extensions.py [repository-root]")
    verify_repository(repository_root)
    print("Verified bundled native WebExtensions, provenance, licenses, and release metadata.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
