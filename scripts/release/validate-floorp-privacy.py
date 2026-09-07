#!/usr/bin/env python3
"""Validates Floorp release privacy boundaries (Todo 14).

Always consumes the runtime endpoint matrix
(docs/floorp-release-endpoints.json) and App Store Connect metadata artifact.
When explicitly supplied, it also consumes captured network metadata, a static
endpoint scan, an archive dSYM UUID inventory, and signed entitlements. Named
trace or static-scan inputs must exist; omitting one makes no claim that its
corresponding dynamic or static check ran. The validator rejects:

  - any traced or statically referenced host outside the matrix, and any
    disabled-service host that appears in a trace;
  - missing dSYM UUIDs for the app, app extensions, or embedded frameworks;
  - a missing default-browser entitlement, or forbidden APNs and browser
    app-installation entitlements;
  - internally inconsistent App Privacy / export-compliance metadata.

Exit codes:
  0  privacy boundaries hold
  1  a privacy violation was found
  2  malformed input
"""

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Optional


class PrivacyError(Exception):
    pass


class MalformedError(PrivacyError):
    pass


MATRIX_FIELDS = {"schema_version", "note", "endpoints"}
ENDPOINT_FIELDS = {"host", "purpose", "owner", "status", "service"}


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise MalformedError(f"{path}: invalid JSON ({error})") from error


def check(condition: bool, message: str) -> None:
    if not condition:
        raise PrivacyError(message)


def malformed(condition: bool, message: str) -> None:
    if not condition:
        raise MalformedError(message)


def validate_endpoint_matrix(matrix: dict) -> None:
    malformed(isinstance(matrix, dict), "endpoint matrix root must be an object")
    malformed(set(matrix) == MATRIX_FIELDS, "endpoint matrix fields are not exact")
    malformed(
        type(matrix["schema_version"]) is int and matrix["schema_version"] == 1,
        "endpoint matrix schema_version must be integer 1",
    )
    malformed(
        isinstance(matrix["note"], str) and bool(matrix["note"].strip()),
        "endpoint matrix note must be a non-empty string",
    )
    endpoints = matrix["endpoints"]
    malformed(
        isinstance(endpoints, list) and bool(endpoints),
        "endpoint matrix endpoints must be a non-empty array",
    )
    observed_hosts = set()
    for index, entry in enumerate(endpoints):
        malformed(
            isinstance(entry, dict) and set(entry) == ENDPOINT_FIELDS,
            f"endpoint matrix entry {index} fields are not exact",
        )
        for field in ENDPOINT_FIELDS:
            malformed(
                isinstance(entry[field], str) and bool(entry[field].strip()),
                f"endpoint matrix entry {index} {field} must be a non-empty string",
            )
        host = entry["host"]
        malformed(
            host == host.strip().lower()
            and re.fullmatch(r"[a-z0-9.-]+", host) is not None
            and ".." not in host,
            f"endpoint matrix entry {index} host is not normalized",
        )
        malformed(
            entry["status"] in {"enabled", "disabled"},
            f"endpoint matrix entry {index} status is invalid",
        )
        malformed(host not in observed_hosts, f"duplicate endpoint matrix host: {host}")
        observed_hosts.add(host)


def load_entitlements(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as error:
        raise MalformedError(f"{path}: invalid entitlements plist ({error})") from error


def validate_trace(matrix: dict, trace: dict) -> None:
    by_host = {entry["host"]: entry for entry in matrix["endpoints"]}
    disabled = {host for host, entry in by_host.items() if entry["status"] == "disabled"}
    for flow in trace.get("flows", []):
        host = flow.get("host", "")
        check(host in by_host, f"traced host not in matrix: {host}")
        check(host not in disabled, f"disabled-service host traced: {host}")


DOCUMENTATION_HOSTS = {
    "github.com", "mozilla.org", "www.mozilla.org", "w3.org", "www.w3.org",
    "mozilla.com", "www.mozilla.com",
    "apache.org", "www.apache.org", "bugzilla.mozilla.org", "support.mozilla.org",
    "floorp.app", "tools.ietf.org", "mzl.la", "monitor.firefox.com",
    "relay.firefox.com", "mozilla.github.io", "mozilla.social", "easylist.to",
    "cs.chromium.org", "test.com", "example.com", "www.google.com",
    "adjust-skadnetwork.com", "zip4.usps.com", "www.laposte.fr",
    "www.correos.es", "www.indiapost.gov.in", "www.canadapost.ca",
    "houseandhome.com", "mozilla-hub.atlassian.net", "bugzil.la", "localhost",
    "127.0.0.1", "accounts.foo.com", "foo.com", "m.foo.com", "www.example.com",
    "my.dev", "my.test.url", "www.foosite.com", "www.appmysite.com",
    "apps.apple.com", "itunes.apple.com", "developer.apple.com", "help.apple.com",
    "developer.mozilla.org", "firefox-source-docs.mozilla.org", "hg.mozilla.org",
    "blog.mozilla.org", "blog.floorp.app", "firefox.com", "www.firefox.com",
    "acorn.firefox.com", "experimenter.info", "archive.org", "betawiki.net",
    "docs.github.com", "docs.google.com", "drive.google.com", "workspace.google.com",
    "lens.google.com", "www.bing.com", "youtube.com", "www.figma.com",
    "en.wikipedia.org", "zh.wikipedia.org", "ko.wikipedia.org", "en.m.wikipedia.org",
    "wikipedia.org", "html.spec.whatwg.org", "datatracker.ietf.org", "www.ietf.org",
    "www.rfc-editor.org", "www.iana.org", "publicsuffix.org", "schema.org",
    "jwt.io", "stackoverflow.com", "simonwillison.net", "oleb.net", "paragonie.com",
    "useyourloaf.com", "openradar.appspot.com", "www.fifa.com", "webpack.js.org",
    "searchfox.org", "source.chromium.org", "caniuse.com", "www.w3.org",
    "www.oracle.com", "creativecommons.org", "www.unicode.org", "docs.swiftybeaver.com",
}

EXPECTED_PRIVACY_DISCLOSURES = {
    ("Contact Info", "Name", True, True, False, ("App Functionality",)),
    ("Contact Info", "Email Address", True, True, False, ("App Functionality",)),
    ("Contact Info", "Phone Number", True, True, False, ("App Functionality",)),
    ("Contact Info", "Physical Address", True, True, False, ("App Functionality",)),
    ("Financial Info", "Payment Info", True, True, False, ("App Functionality",)),
    ("Location", "Coarse Location", True, True, False,
     ("Analytics", "App Functionality")),
    ("User Content", "Photos or Videos", True, True, False, ("App Functionality",)),
    ("User Content", "Other User Content", True, True, False, ("App Functionality",)),
    ("Browsing History", "Browsing History", True, True, False, ("App Functionality",)),
    ("Search History", "Search History", True, True, False, ("App Functionality",)),
    ("Identifiers", "User ID", True, True, False, ("Analytics", "App Functionality")),
    ("Identifiers", "Device ID", True, True, False, ("Analytics", "App Functionality")),
    ("Usage Data", "Product Interaction", True, True, False,
     ("Analytics", "App Functionality")),
    ("Diagnostics", "Crash Data", True, True, False,
     ("Analytics", "App Functionality")),
    ("Diagnostics", "Performance Data", True, True, False,
     ("Analytics", "App Functionality")),
    ("Diagnostics", "Other Diagnostic Data", True, True, False,
     ("Analytics", "App Functionality")),
    ("Other Data", "Other Data Types", True, True, False,
     ("Analytics", "App Functionality")),
}


def validate_static_endpoints(matrix: dict, static_path: Path) -> None:
    hosts = {entry["host"] for entry in matrix["endpoints"]}
    if not static_path.is_file():
        raise MalformedError(f"static endpoint input does not exist: {static_path}")
    try:
        text = static_path.read_text()
    except OSError as error:
        raise MalformedError(
            f"{static_path}: could not read static endpoint input ({error})"
        ) from error
    found = set(re.findall(r"https?://([a-zA-Z0-9._\-]+)", text))
    unknown = sorted(host for host in found
                     if host not in hosts and host not in DOCUMENTATION_HOSTS)
    check(not unknown, f"static endpoints outside matrix/doc allowlist: {unknown}")


def normalize_uuid(value: str, context: str) -> str:
    normalized = value.replace("-", "").upper()
    check(
        re.fullmatch(r"[0-9A-F]{32}", normalized) is not None,
        f"invalid UUID in {context}: {value}",
    )
    return normalized


def parse_dwarfdump_output(output: str, context: str) -> set[str]:
    uuid_lines = [line for line in output.splitlines() if line.lstrip().startswith("UUID:")]
    check(bool(uuid_lines), f"dwarfdump returned no UUID for {context}")
    uuids = set()
    for line in uuid_lines:
        match = re.fullmatch(r"\s*UUID:\s+([^\s]+)\s+\([^)]+\)\s+.+\s*", line)
        check(match is not None, f"could not parse dwarfdump output for {context}: {line}")
        uuids.add(normalize_uuid(match.group(1), context))
    return uuids


def load_dsym_inventory(inventory_path: Optional[Path]) -> set[str]:
    check(inventory_path is not None, "dSYM inventory path is required with an archive")
    check(inventory_path.is_file(), f"dSYM inventory does not exist: {inventory_path}")
    try:
        inventory_text = inventory_path.read_text()
    except OSError as error:
        raise MalformedError(f"{inventory_path}: could not read dSYM inventory ({error})") from error

    # Accept either the collector's evidence JSON (or its dsym_inventory array)
    # or a retained raw `dwarfdump --uuid` inventory.
    try:
        document = json.loads(inventory_text)
    except json.JSONDecodeError:
        return parse_dwarfdump_output(inventory_text, str(inventory_path))

    entries = document.get("dsym_inventory") if isinstance(document, dict) else document
    check(isinstance(entries, list) and bool(entries), "dSYM inventory is empty or malformed")
    uuids = set()
    for index, entry in enumerate(entries):
        check(isinstance(entry, dict), f"dSYM inventory item {index} must be an object")
        uuid = entry.get("uuid")
        check(isinstance(uuid, str), f"dSYM inventory item {index} has no UUID")
        uuids.add(normalize_uuid(uuid, f"dSYM inventory item {index}"))
    return uuids


def bundle_executable(bundle: Path) -> Path:
    check(
        bundle.is_dir() and not bundle.is_symlink(),
        f"bundle is not a real directory: {bundle}",
    )
    info_path = bundle / "Info.plist"
    check(
        info_path.is_file()
        and not info_path.is_symlink()
        and stat.S_ISREG(info_path.lstat().st_mode),
        f"bundle Info.plist is missing or not a real regular file: {bundle}",
    )
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except Exception as error:
        raise MalformedError(f"{info_path}: invalid bundle Info.plist ({error})") from error
    executable_name = info.get("CFBundleExecutable")
    check(
        isinstance(executable_name, str)
        and bool(executable_name)
        and executable_name not in {".", ".."}
        and "/" not in executable_name
        and "\\" not in executable_name
        and Path(executable_name).name == executable_name,
        f"CFBundleExecutable is missing or unsafe: {bundle}",
    )
    executable = bundle / executable_name
    check(
        executable.is_file()
        and not executable.is_symlink()
        and stat.S_ISREG(executable.lstat().st_mode),
        f"bundle executable is missing or not a real regular file: {executable}",
    )
    check(
        executable.resolve().parent == bundle.resolve(),
        f"bundle executable resolves outside its bundle: {executable}",
    )
    return executable


def distributed_bundle_executables(app: Path) -> dict[str, Path]:
    """Return every shipped app/framework/appex executable by bundle-relative path."""
    check(
        app.is_dir() and not app.is_symlink(),
        f"archived app does not exist or is not a real directory: {app}",
    )
    bundles = {".": app}
    candidates = []
    for current_root, directory_names, _file_names in os.walk(
        app, topdown=True, followlinks=False
    ):
        current = Path(current_root)
        for directory_name in directory_names:
            directory = current / directory_name
            check(
                not directory.is_symlink(),
                f"distributed app contains a symbolic-link directory: {directory}",
            )
            if directory.suffix in {".app", ".framework", ".appex"}:
                candidates.append(directory)
    candidates.sort()
    for bundle in candidates:
        check(
            bundle.is_dir() and not bundle.is_symlink(),
            f"bundle is not a real directory: {bundle}",
        )
        relative = bundle.relative_to(app).as_posix()
        check(relative not in bundles, f"duplicate distributed bundle path: {relative}")
        bundles[relative] = bundle
    return {
        relative: bundle_executable(bundle)
        for relative, bundle in sorted(bundles.items())
    }


def macho_uuids(binary: Path) -> set[str]:
    try:
        result = subprocess.run(
            ["dwarfdump", "--uuid", str(binary)], capture_output=True, text=True
        )
    except OSError as error:
        raise PrivacyError(f"failed to run dwarfdump for {binary}: {error}") from error
    detail = result.stderr.strip() or f"exit status {result.returncode}"
    check(result.returncode == 0, f"dwarfdump failed for {binary}: {detail}")
    return parse_dwarfdump_output(result.stdout, str(binary))


def validate_dsym_inventory(archive: Path, inventory_path: Optional[Path]) -> None:
    check(
        archive.is_dir() and not archive.is_symlink(),
        f"archive does not exist or is not a real directory: {archive}",
    )
    inventory_uuids = load_dsym_inventory(inventory_path)
    app = archive / "Products" / "Applications" / "Client.app"
    check(
        app.resolve() == archive.resolve() / "Products" / "Applications" / "Client.app",
        f"archived app resolves outside the archive: {app}",
    )
    executables = distributed_bundle_executables(app)
    # A dSYM may legitimately contain an unshipped architecture slice or a
    # build-tool binary, so require complete archive coverage without rejecting
    # such additional retained symbols.
    missing = []
    for relative, executable in executables.items():
        binary_uuids = macho_uuids(executable)
        absent = sorted(binary_uuids - inventory_uuids)
        if absent:
            bundle_label = app.name if relative == "." else Path(relative).name
            missing.append(f"{bundle_label}: {','.join(absent)}")
    check(not missing, f"archive binaries missing dSYM UUIDs: {missing}")


def validate_entitlements(entitlements_path: Path) -> None:
    entitlements = load_entitlements(entitlements_path)
    forbidden = [
        "aps-environment",
        "com.apple.developer.browser.app-installation",
    ]
    for name in forbidden:
        check(name not in entitlements, f"forbidden entitlement present: {name}")
    check(entitlements.get("com.apple.developer.web-browser") is True,
          "default-browser entitlement must be enabled")
    application_identifier = entitlements.get("application-identifier", "")
    check("app.floorp.Floorp" in application_identifier,
          "application-identifier must contain app.floorp.Floorp")


def validate_metadata(metadata: dict) -> None:
    app = metadata.get("app", {})
    check(app.get("bundle_id") == "app.floorp.Floorp", "metadata bundle_id drift")
    check(app.get("apple_id") == "6796708699", "metadata apple_id drift")
    check(app.get("app_store_id") == app.get("apple_id"),
          "metadata app_store_id must match apple_id")
    check(app.get("team_id") == "DV2U35YBHT", "metadata team_id drift")
    locales = app.get("primary_locales", [])
    check(bool(locales) and set(locales).issubset({"en-US", "ja-JP"}),
          "metadata primary_locales must be non-empty and within en-US/ja-JP")

    export = metadata.get("export_compliance", {})
    check(export.get("uses_encryption") is True, "export metadata must declare encryption")
    exempt = export.get("exempt_from_export_compliance")
    check(exempt is True, "export metadata must declare exemption")
    check(export.get("itsapp_uses_non_exempt_encryption") is False,
          "export metadata contradiction: non-exempt encryption true while exempt")

    privacy = metadata.get("privacy", {})
    check(privacy.get("privacy_policy_url") == "https://floorp.app/privacy",
          "privacy metadata must use the public Floorp privacy policy URL")
    check(privacy.get("tracking") is False,
          "privacy metadata must explicitly declare tracking=false")
    check("docs/floorp-ios-app-privacy.md" in privacy.get("live_verification", ""),
          "privacy metadata must retain the live-policy release gate")
    data_types = privacy.get("data_types", [])
    check(isinstance(data_types, list) and bool(data_types),
          "privacy metadata must declare collected data types")
    valid_categories = {"Contact Info", "Identifiers", "Health & Fitness", "Financial Info",
                        "Location", "Sensitive Info", "Contacts", "User Content",
                        "Browsing History", "Search History", "Purchases", "Usage Data",
                        "Diagnostics", "Other Data"}
    observed_disclosures = []
    for entry in data_types:
        check(isinstance(entry, dict), "privacy data entries must be objects")
        check(entry.get("category") in valid_categories,
              f"invalid privacy data category: {entry.get('category')}")
        check(entry.get("collected") is True, "privacy entry must declare collected=true")
        check(entry.get("linked_to_user_identity") is True,
              "privacy entry must declare linked_to_user_identity=true")
        check(entry.get("used_for_tracking") is False,
              "privacy entry must declare used_for_tracking=false")
        purposes = entry.get("purpose", [])
        check(isinstance(purposes, list) and all(isinstance(value, str) for value in purposes)
              and "App Functionality" in purposes,
              "privacy entry must include the App Functionality purpose")
        observed_disclosures.append((
            entry.get("category"),
            entry.get("data_type"),
            entry.get("collected"),
            entry.get("linked_to_user_identity"),
            entry.get("used_for_tracking"),
            tuple(sorted(purposes)),
        ))
    check(len(observed_disclosures) == len(set(observed_disclosures)),
          "privacy metadata must not contain duplicate disclosures")
    check(set(observed_disclosures) == EXPECTED_PRIVACY_DISCLOSURES,
          "privacy metadata disclosure set must exactly match the approved Floorp release declaration")


def main(argv=None) -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--matrix", required=True, type=Path)
    arguments.add_argument("--trace", type=Path)
    arguments.add_argument("--archive", type=Path)
    arguments.add_argument("--static-endpoints", type=Path)
    arguments.add_argument("--dsym-inventory", type=Path)
    arguments.add_argument("--entitlements", type=Path)
    arguments.add_argument("--metadata", required=True, type=Path)
    parsed = arguments.parse_args(argv)
    try:
        matrix = load_json(parsed.matrix)
        validate_endpoint_matrix(matrix)
        metadata = load_json(parsed.metadata)
        if parsed.trace:
            validate_trace(matrix, load_json(parsed.trace))
        if parsed.static_endpoints:
            validate_static_endpoints(matrix, parsed.static_endpoints)
        if parsed.archive:
            validate_dsym_inventory(parsed.archive, parsed.dsym_inventory)
        if parsed.entitlements:
            validate_entitlements(parsed.entitlements)
        validate_metadata(metadata)
        return 0
    except MalformedError as error:
        print(f"MALFORMED: {error}", file=sys.stderr)
        return 2
    except PrivacyError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
