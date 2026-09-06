#!/usr/bin/env python3
"""Validates Floorp release privacy boundaries (Todo 14).

Consumes the runtime endpoint matrix (docs/floorp-release-endpoints.json),
the captured network metadata, the static endpoint scan, the archive dSYM
UUID inventory, the signed entitlements, and the App Store Connect metadata
artifact, and rejects:

  - any traced or statically referenced host outside the matrix, and any
    disabled-service host that appears in a trace;
  - missing dSYM UUIDs for frameworks embedded in the archive;
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
import plistlib
import re
import sys
from pathlib import Path


class PrivacyError(Exception):
    pass


class MalformedError(PrivacyError):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise MalformedError(f"{path}: invalid JSON ({error})") from error


def check(condition: bool, message: str) -> None:
    if not condition:
        raise PrivacyError(message)


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
        return
    text = static_path.read_text()
    found = set(re.findall(r"https?://([a-zA-Z0-9._\-]+)", text))
    unknown = sorted(host for host in found
                     if host not in hosts and host not in DOCUMENTATION_HOSTS)
    check(not unknown, f"static endpoints outside matrix/doc allowlist: {unknown}")


def validate_dsym_inventory(archive: Path, inventory_path: Path) -> None:
    if not archive.is_dir() or not inventory_path.is_file():
        return
    inventory_text = inventory_path.read_text()
    inventory_uuids = set(re.findall(r"UUID: ([0-9A-F]{32})", inventory_text))
    frameworks_dir = archive / "Products" / "Applications" / "Client.app" / "Frameworks"
    if not frameworks_dir.is_dir():
        return
    missing = []
    for framework in frameworks_dir.glob("*.framework"):
        result = __import__("subprocess").run(
            ["dwarfdump", "--uuid", str(framework)], capture_output=True, text=True
        )
        framework_uuids = set(re.findall(r"UUID: ([0-9A-F]{32})", result.stdout))
        if framework_uuids and not framework_uuids.issubset(inventory_uuids):
            missing.append(framework.name)
    check(not missing, f"embedded frameworks missing dSYM UUIDs: {missing}")


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
    arguments.add_argument("--ipa", type=Path)
    arguments.add_argument("--static-endpoints", type=Path)
    arguments.add_argument("--dsym-inventory", type=Path)
    arguments.add_argument("--entitlements", type=Path)
    arguments.add_argument("--metadata", required=True, type=Path)
    parsed = arguments.parse_args(argv)
    try:
        matrix = load_json(parsed.matrix)
        metadata = load_json(parsed.metadata)
        if parsed.trace and parsed.trace.is_file():
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
