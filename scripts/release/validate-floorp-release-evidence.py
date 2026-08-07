#!/usr/bin/env python3
"""Validates one Floorp release-evidence document (issue #25, Todo 12).

The evidence document is produced by collect-floorp-release-evidence.sh and
must conform to scripts/release/floorp-release-evidence.schema.json. Beyond
schema conformance this validator enforces the release contract:

  - the archive's captured version/build/team/bundle match the evidence and
    the Floorp release identity (DV2U35YBHT / app.floorp.Floorp);
  - the IPA's version/build match the archive (no mixed build IDs);
  - the signed entitlements match the approved Floorp capability set and
    omit the denied capabilities (APNs, web-browser, browser app-installation);
  - the dSYM inventory is non-empty with unique UUIDs;
  - the IPA SHA-256 is recomputed when the file is present.

Exit codes:
  0  evidence is valid
  1  evidence violates the release contract
  2  malformed input
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


class ValidationError(Exception):
    pass


class MalformedError(ValidationError):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise MalformedError(f"{path}: invalid JSON ({error})") from error


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate_shape(schema: dict, evidence: dict) -> None:
    if not isinstance(evidence, dict):
        raise ValidationError("evidence must be an object")
    if evidence.get("schema_version") != schema.get("properties", {}).get("schema_version", {}).get("const"):
        raise ValidationError("schema_version mismatch")
    required = schema.get("required", [])
    for name in required:
        if name not in evidence:
            raise ValidationError(f"missing required field: {name}")
    properties = schema.get("properties", {})
    for name, value in evidence.items():
        if name not in properties:
            raise ValidationError(f"unexpected field: {name}")
    for name, spec in properties.items():
        if name not in evidence:
            continue
        value = evidence[name]
        if "const" in spec:
            if value != spec["const"]:
                raise ValidationError(f"{name} must equal {spec['const']}")
            continue
        if "type" not in spec:
            continue
        expected_types = spec.get("type")
        allowed = expected_types if isinstance(expected_types, list) else [expected_types]
        if "null" in allowed and value is None:
            continue
        if "array" in allowed and isinstance(value, list):
            continue
        if "object" in allowed and isinstance(value, dict):
            continue
        if "string" in allowed and isinstance(value, str):
            if "pattern" in spec and not re.fullmatch(spec["pattern"], value):
                raise ValidationError(f"{name} fails pattern {spec['pattern']}")
            if spec.get("minLength") is not None and len(value) < spec["minLength"]:
                raise ValidationError(f"{name} is shorter than minLength")
            continue
        if "integer" in allowed and isinstance(value, int):
            continue
        raise ValidationError(f"{name} has unexpected type {type(value).__name__}")


def validate_entitlements(entitlements: dict) -> None:
    denied = [
        "aps-environment",
        "com.apple.developer.web-browser",
        "com.apple.developer.browser.app-installation",
    ]
    for name in denied:
        check(name not in entitlements, f"forbidden entitlement present: {name}")

    application_identifier = entitlements.get("application-identifier")
    check(
        isinstance(application_identifier, str) and "app.floorp.Floorp" in application_identifier,
        "application-identifier must contain app.floorp.Floorp",
    )
    keychain_groups = entitlements.get("keychain-access-groups", [])
    check(
        isinstance(keychain_groups, list)
        and any(isinstance(g, str) and g.endswith("app.floorp.Floorp") for g in keychain_groups),
        "keychain-access-groups must contain app.floorp.Floorp",
    )
    app_groups = entitlements.get("com.apple.security.application-groups", [])
    check(
        isinstance(app_groups, list) and "group.app.floorp.Floorp.DV2U35YBHT" in app_groups,
        "application-groups must contain group.app.floorp.Floorp.DV2U35YBHT",
    )


def main(argv=None) -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--evidence", required=True, type=Path)
    arguments.add_argument("--schema", required=True, type=Path)
    parsed = arguments.parse_args(argv)
    try:
        schema = load_json(parsed.schema)
        evidence = load_json(parsed.evidence)
        validate_shape(schema, evidence)

        archive_info = evidence["archive_info"]
        check(
            evidence["marketing_version"] == archive_info["marketing_version"],
            "marketing version differs from archive Info.plist",
        )
        check(
            evidence["build_number"] == archive_info["build_number"],
            "build number differs from archive Info.plist",
        )
        check(archive_info["bundle_id"] == "app.floorp.Floorp", "archive bundle id is not app.floorp.Floorp")
        check(archive_info["team_id"] == "DV2U35YBHT", "archive team id is not DV2U35YBHT")

        ipa_info = evidence.get("ipa_info")
        if ipa_info is not None:
            check(
                ipa_info["marketing_version"] == archive_info["marketing_version"],
                "mixed build IDs: IPA marketing version differs from archive",
            )
            check(
                ipa_info["build_number"] == archive_info["build_number"],
                "mixed build IDs: IPA build number differs from archive",
            )

        validate_entitlements(evidence["entitlements"])

        dsyms = evidence["dsym_inventory"]
        check(bool(dsyms), "dSYM inventory is empty")
        uuids = [entry["uuid"] for entry in dsyms]
        check(len(uuids) == len(set(uuids)), "duplicate dSYM UUID")

        ipa_path = evidence["ipa_path"]
        ipa_sha256 = evidence["ipa_sha256"]
        if ipa_path and Path(ipa_path).is_file() and ipa_sha256:
            actual = hashlib.sha256(Path(ipa_path).read_bytes()).hexdigest()
            check(actual == ipa_sha256, f"IPA SHA-256 mismatch: expected {ipa_sha256}, got {actual}")

        signing_identity = evidence.get("signing_identity")
        if signing_identity:
            check(
                "Apple Development" in signing_identity or "Apple Distribution" in signing_identity,
                f"unexpected signing identity: {signing_identity}",
            )
        return 0
    except ValidationError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 2 if isinstance(error, MalformedError) else 1


if __name__ == "__main__":
    raise SystemExit(main())
