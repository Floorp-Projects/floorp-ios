#!/usr/bin/env python3
"""Validates one Floorp release-evidence document (issue #25, Todo 12).

The evidence document is produced by collect-floorp-release-evidence.sh and
must conform to scripts/release/floorp-release-evidence.schema.json. Beyond
schema conformance this validator enforces the release contract:

  - caller-supplied source/version/build/release identity match the evidence;
  - the archive exists and its canonical full-tree SHA-256 still matches;
  - the IPA exists for local exports and its SHA-256 still matches;
  - the archive and IPA metadata agree (no mixed build IDs);
  - the signed entitlements include the approved default-browser capability
    and omit denied capabilities (APNs and browser app-installation);
  - retained dSYMs are real and cover every app/framework/appex Mach-O UUID;
  - publication evidence matches caller-supplied CI/App Store Connect identity
    and a fully revalidated Xcode Cloud receipt.

Exit codes:
  0  evidence is valid
  1  evidence violates the release contract
  2  malformed input
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from types import ModuleType


class ValidationError(Exception):
    pass


class MalformedError(ValidationError):
    pass


SCRIPT_DIR = Path(__file__).resolve().parent
SOURCE_SHA = re.compile(r"[0-9a-f]{40}")
BUILD_NUMBER = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}")
CI_RUN_URL = re.compile(
    r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*"
)
IDENTIFIER = re.compile(r"[A-Za-z0-9._-]+")
READY_FOR_UPLOAD = "ready-for-upload"
UPLOADED_AND_PROCESSED = "uploaded-and-processed"
FLOORP_APP_ID = "6796708699"
FLOORP_BUNDLE_ID = "app.floorp.Floorp"
FLOORP_TEAM_ID = "DV2U35YBHT"
FLOORP_PLATFORM = "IOS"
FLOORP_MIN_OS_VERSION = "18.4"
APPLE_TEAM_REQUIREMENT = (
    '=anchor apple generic and certificate leaf[subject.OU] = "DV2U35YBHT"'
)
APPLE_DISTRIBUTION_REQUIREMENT = (
    APPLE_TEAM_REQUIREMENT
    + " and certificate leaf[field.1.2.840.113635.100.6.1.4] exists"
)
APPLE_ROOT_KEYCHAIN = Path(
    "/System/Library/Keychains/SystemRootCertificates.keychain"
)
APPLE_ROOT_CERTIFICATE_SHA256 = {
    # Apple Root CA, Apple Root CA - G2, and Apple Root CA - G3.  Fail closed
    # when Apple introduces a new provisioning-profile trust anchor until that
    # root is reviewed and explicitly added here.
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
}
PROFILE_SIGNER_SUBJECT = (
    "subject= C=US,O=Apple Inc.,CN=Apple iPhone OS Provisioning Profile Signing"
)
PROFILE_SIGNER_OID = "1.2.840.113635.100.6.58"
PEM_CERTIFICATE = re.compile(
    br"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)"
    br"-----END CERTIFICATE-----\s*"
)


def load_json(path: Path):
    def reject_duplicates(pairs):
        value = {}
        for name, item in pairs:
            if name in value:
                raise MalformedError(f"{path}: duplicate JSON field {name}")
            value[name] = item
        return value

    def reject_constant(value):
        raise MalformedError(f"{path}: non-finite JSON number {value}")

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except MalformedError:
        raise
    except (json.JSONDecodeError, OSError, UnicodeError) as error:
        raise MalformedError(f"{path}: invalid JSON ({error})") from error


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate_schema_value(value, spec: dict, path: str) -> None:
    if "const" in spec:
        check(value == spec["const"], f"{path} must equal {spec['const']}")

    expected_types = spec.get("type")
    if expected_types is not None:
        allowed = expected_types if isinstance(expected_types, list) else [expected_types]
        type_matches = (
            ("null" in allowed and value is None)
            or ("array" in allowed and isinstance(value, list))
            or ("object" in allowed and isinstance(value, dict))
            or ("string" in allowed and isinstance(value, str))
            or ("boolean" in allowed and isinstance(value, bool))
            or (
                "integer" in allowed
                and isinstance(value, int)
                and not isinstance(value, bool)
            )
            or (
                "number" in allowed
                and isinstance(value, (int, float))
                and not isinstance(value, bool)
            )
        )
        check(type_matches, f"{path} has unexpected type {type(value).__name__}")

    if isinstance(value, str):
        if "pattern" in spec:
            check(
                re.fullmatch(spec["pattern"], value) is not None,
                f"{path} fails pattern {spec['pattern']}",
            )
        if spec.get("minLength") is not None:
            check(len(value) >= spec["minLength"], f"{path} is shorter than minLength")

    if isinstance(value, list) and "items" in spec:
        for index, item in enumerate(value):
            validate_schema_value(item, spec["items"], f"{path}[{index}]")

    if isinstance(value, dict):
        properties = spec.get("properties", {})
        for name in spec.get("required", []):
            check(name in value, f"missing required field: {path}.{name}")
        additional = spec.get("additionalProperties", True)
        for name, item in value.items():
            child_path = f"{path}.{name}"
            if name in properties:
                validate_schema_value(item, properties[name], child_path)
            elif additional is False:
                raise ValidationError(f"unexpected field: {child_path}")
            elif isinstance(additional, dict):
                validate_schema_value(item, additional, child_path)


def validate_shape(schema: dict, evidence: dict) -> None:
    validate_schema_value(evidence, schema, "evidence")


def validate_entitlements(entitlements: dict) -> None:
    denied = [
        "aps-environment",
        "com.apple.developer.browser.app-installation",
    ]
    for name in denied:
        check(name not in entitlements, f"forbidden entitlement present: {name}")
    check(entitlements.get("com.apple.developer.web-browser") is True,
          "default-browser entitlement must be enabled")

    application_identifier = entitlements.get("application-identifier")
    if application_identifier is not None:
        check(
            isinstance(application_identifier, str)
            and "app.floorp.Floorp" in application_identifier,
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


def load_sibling_module(module_name: str, filename: str) -> ModuleType:
    path = SCRIPT_DIR / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise MalformedError(f"could not load release helper: {path}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except (ImportError, OSError, SyntaxError) as error:
        raise MalformedError(f"could not load release helper {path}: {error}") from error
    return module


def required_string(value, name: str) -> str:
    check(isinstance(value, str) and bool(value), f"{name} is required")
    return value


def canonical_existing_path(value: str, label: str, *, kind: str) -> Path:
    check(isinstance(value, str) and bool(value), f"{label} path is required")
    check(
        all(ord(character) >= 32 and character != "\x7f" for character in value),
        f"{label} path contains control characters",
    )
    path = Path(value)
    check(path.is_absolute(), f"{label} path must be absolute")
    check(not path.is_symlink(), f"{label} path must not be a symbolic link: {path}")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValidationError(f"{label} does not exist: {path} ({error})") from error
    check(
        path == resolved,
        f"{label} path must be canonical: expected {resolved}, got {path}",
    )
    if kind == "directory":
        check(path.is_dir(), f"{label} is not a directory: {path}")
    elif kind == "file":
        check(path.is_file(), f"{label} is not a file: {path}")
    else:
        raise MalformedError(f"unsupported canonical path kind: {kind}")
    return path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_real_directory_chain(path: Path, root: Path, label: str) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise ValidationError(f"{label} is outside {root}: {path}") from error
    current = root
    check(
        current.is_dir() and not current.is_symlink(),
        f"{label} root is not a real directory: {current}",
    )
    for part in relative.parts:
        current = current / part
        check(
            current.is_dir()
            and not current.is_symlink()
            and stat.S_ISDIR(current.lstat().st_mode),
            f"{label} contains a missing or symbolic-link directory: {current}",
        )
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, RuntimeError, ValueError) as error:
        raise ValidationError(f"{label} resolves outside {root}: {path}") from error


def load_plist(path: Path, label: str) -> dict:
    check(
        path.is_file() and not path.is_symlink(),
        f"{label} does not exist: {path}",
    )
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValidationError(f"{label} is not a valid plist: {path} ({error})") from error
    check(isinstance(value, dict), f"{label} must contain a dictionary")
    return value


def validate_archive_metadata(
    archive: Path,
    evidence: dict,
    expected_source_sha: str,
) -> tuple[Path, str, str]:
    check(
        archive.is_dir() and not archive.is_symlink(),
        f"archive does not exist: {archive}",
    )
    app = archive / "Products" / "Applications" / "Client.app"
    require_real_directory_chain(app, archive, "archived app")
    check(
        app.is_dir() and not app.is_symlink(),
        f"archived app does not exist: {app}",
    )
    info = load_plist(app / "Info.plist", "archived app Info.plist")
    expected = evidence["archive_info"]
    fields = {
        "marketing_version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
        "bundle_id": info.get("CFBundleIdentifier"),
    }
    mismatches = [
        name for name, actual in fields.items() if actual != expected[name]
    ]
    check(
        not mismatches,
        "release evidence does not match archived app Info.plist: "
        + ", ".join(mismatches),
    )
    check(
        info.get("MozFloorpSourceSHA") == expected_source_sha,
        "archived app source SHA does not match its external expected value",
    )

    archive_info = load_plist(archive / "Info.plist", "archive Info.plist")
    properties = archive_info.get("ApplicationProperties")
    check(
        isinstance(properties, dict),
        "archive Info.plist has no ApplicationProperties dictionary",
    )
    team_id = (
        properties.get("Team")
        or properties.get("TeamIdentifier")
        or archive_info.get("TeamIdentifier")
        or ""
    )
    signing_identity = properties.get("SigningIdentity") or ""
    check(isinstance(team_id, str), "archive signing team must be a string")
    check(
        isinstance(signing_identity, str),
        "archive signing identity must be a string",
    )
    check(
        team_id == expected["team_id"],
        "release evidence does not match archive signing team",
    )
    check(team_id == FLOORP_TEAM_ID, f"archive signing team is not {FLOORP_TEAM_ID}")
    check(
        "Apple Development" in signing_identity
        or "Apple Distribution" in signing_identity,
        f"unexpected archive signing identity: {signing_identity}",
    )
    return app, team_id, signing_identity


def extract_ipa_app(ipa_path: Path, extraction_root: Path) -> tuple[dict, Path]:
    """Safely extract the one direct Payload app for signature verification."""
    info_pattern = re.compile(r"Payload/([^/]+\.app)/Info\.plist")
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            entries = archive.infolist()
            safe_zip = load_sibling_module("floorp_safe_zip", "floorp_safe_zip.py")
            try:
                safe_zip.preflight_zip_members(entries)
            except safe_zip.SafeZipError as error:
                raise ValidationError(str(error)) from error
            matches = [
                info
                for info in entries
                if info_pattern.fullmatch(info.filename) is not None
            ]
            check(
                len(matches) == 1,
                "IPA must contain exactly one direct Payload/*.app/Info.plist; "
                f"found {len(matches)}",
            )
            check(
                not matches[0].is_dir()
                and not stat.S_ISLNK(matches[0].external_attr >> 16)
                and 0 < matches[0].file_size <= 4 * 1024 * 1024,
                "IPA app Info.plist is not a regular bounded file",
            )
            value = plistlib.loads(archive.read(matches[0]))
            check(isinstance(value, dict), "IPA app Info.plist must contain a dictionary")
            executable_name = value.get("CFBundleExecutable")
            check(
                isinstance(executable_name, str)
                and re.fullmatch(r"[^/\\]+", executable_name) is not None
                and executable_name not in {".", ".."},
                "IPA app CFBundleExecutable is missing or unsafe",
            )
            app_name = info_pattern.fullmatch(matches[0].filename).group(1)
            check(
                "\\" not in app_name
                and all(ord(character) >= 32 and character != "\x7f" for character in app_name),
                "IPA direct app bundle name is unsafe",
            )
            executable_member = f"Payload/{app_name}/{executable_name}"
            executables = [info for info in entries if info.filename == executable_member]
            check(
                len(executables) == 1,
                "IPA must contain exactly one declared main executable; "
                f"found {len(executables)}",
            )
            executable = executables[0]
            mode = executable.external_attr >> 16
            check(
                not executable.is_dir() and not stat.S_ISLNK(mode),
                "IPA main executable must be a regular file",
            )
            check(
                0 < executable.file_size <= 1024 * 1024 * 1024,
                "IPA main executable size is invalid",
            )

            prefix = f"Payload/{app_name}"
            app_entries = [
                entry
                for entry in entries
                if entry.filename == prefix
                or entry.filename == f"{prefix}/"
                or entry.filename.startswith(f"{prefix}/")
            ]
            check(bool(app_entries), "IPA main app bundle is empty")
            check(len(app_entries) <= 100_000, "IPA main app has too many entries")
            total_size = sum(entry.file_size for entry in app_entries)
            check(total_size <= 4 * 1024 * 1024 * 1024, "IPA main app is too large")

            app_output = extraction_root / "Exported.app"
            app_output.mkdir(parents=True)
            for entry in app_entries:
                name = entry.filename
                check(
                    "\\" not in name
                    and all(ord(character) >= 32 and character != "\x7f" for character in name),
                    f"IPA contains an unsafe ZIP member: {name!r}",
                )
                relative_text = name[len(prefix):].lstrip("/")
                if not relative_text:
                    continue
                relative = PurePosixPath(relative_text)
                check(
                    not relative.is_absolute()
                    and all(part not in {"", ".", ".."} for part in relative.parts),
                    f"IPA contains an unsafe ZIP member: {name!r}",
                )
                mode = entry.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                check(
                    not stat.S_ISLNK(mode)
                    and file_type in {0, stat.S_IFREG, stat.S_IFDIR},
                    f"IPA contains an unsupported ZIP member: {name!r}",
                )
                destination = app_output.joinpath(*relative.parts)
                if entry.is_dir() or file_type == stat.S_IFDIR:
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, destination.open("xb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                permissions = stat.S_IMODE(mode)
                if permissions:
                    os.chmod(destination, permissions)

            extracted_executable = app_output / executable_name
            check(
                extracted_executable.is_file()
                and not extracted_executable.is_symlink(),
                "extracted IPA main executable is missing",
            )
    except (OSError, zipfile.BadZipFile, RuntimeError, plistlib.InvalidFileException) as error:
        raise ValidationError(f"IPA metadata cannot be read: {ipa_path} ({error})") from error
    return (
        {
            "marketing_version": value.get("CFBundleShortVersionString"),
            "build_number": value.get("CFBundleVersion"),
            "bundle_id": value.get("CFBundleIdentifier"),
            "source_sha": value.get("MozFloorpSourceSHA"),
        },
        app_output,
    )


def inspect_code_signature(target: Path, *, require_distribution: bool = False) -> dict:
    try:
        result = subprocess.run(
            ["/usr/bin/codesign", "-dvv", "--entitlements", ":-", str(target)],
            capture_output=True,
        )
    except OSError as error:
        raise ValidationError(f"failed to run codesign for {target}: {error}") from error
    stderr = result.stderr.decode("utf-8", errors="replace")
    detail = stderr.strip() or f"exit status {result.returncode}"
    check(result.returncode == 0, f"codesign inspection failed for {target}: {detail}")
    try:
        entitlements = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException as error:
        raise ValidationError(
            f"codesign returned invalid entitlements for {target}: {error}"
        ) from error
    check(isinstance(entitlements, dict), "signed entitlements must be a dictionary")

    def unique_detail(prefix: str, label: str) -> str:
        values = [line[len(prefix):] for line in stderr.splitlines() if line.startswith(prefix)]
        check(len(values) == 1 and bool(values[0]), f"codesign {label} is missing or ambiguous")
        return values[0]

    identifier = unique_detail("Identifier=", "identifier")
    team_id = unique_detail("TeamIdentifier=", "team identifier")
    authorities = [
        line[len("Authority="):]
        for line in stderr.splitlines()
        if line.startswith("Authority=")
    ]
    check(bool(authorities) and bool(authorities[0]), "codesign authority is missing")

    try:
        requirement = (
            APPLE_DISTRIBUTION_REQUIREMENT
            if require_distribution
            else APPLE_TEAM_REQUIREMENT
        )
        verification = subprocess.run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "-R",
                requirement,
                str(target),
            ],
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ValidationError(f"failed to verify code signature for {target}: {error}") from error
    verification_detail = verification.stderr.strip() or (
        f"exit status {verification.returncode}"
    )
    check(
        verification.returncode == 0,
        f"code signature verification failed for {target}: {verification_detail}",
    )
    leaf_certificate = None
    if require_distribution:
        with tempfile.TemporaryDirectory(prefix="floorp-signing-certificate-") as temporary:
            prefix = Path(temporary) / "certificate"
            try:
                extraction = subprocess.run(
                    [
                        "/usr/bin/codesign",
                        "-d",
                        f"--extract-certificates={prefix}",
                        str(target),
                    ],
                    capture_output=True,
                )
            except OSError as error:
                raise ValidationError(
                    f"failed to extract the signing certificate for {target}: {error}"
                ) from error
            extraction_detail = extraction.stderr.decode(
                "utf-8", errors="replace"
            ).strip()
            check(
                extraction.returncode == 0,
                "could not extract the distribution signing certificate: "
                + (extraction_detail or f"exit status {extraction.returncode}"),
            )
            leaf_path = Path(f"{prefix}0")
            check(
                leaf_path.is_file()
                and not leaf_path.is_symlink()
                and stat.S_ISREG(leaf_path.lstat().st_mode),
                "codesign did not return one real leaf signing certificate",
            )
            leaf_certificate = leaf_path.read_bytes()
            check(bool(leaf_certificate), "distribution signing certificate is empty")
    return {
        "entitlements": entitlements,
        "identifier": identifier,
        "team_id": team_id,
        "signing_identity": authorities[0],
        "leaf_certificate": leaf_certificate,
    }


def verified_apple_mobileprovision(profile_path: Path) -> dict:
    """Verify CMS bytes, Apple-only trust, and Apple's profile-signer role."""
    try:
        roots = subprocess.run(
            [
                "/usr/bin/security",
                "find-certificate",
                "-a",
                "-c",
                "Apple Root CA",
                "-p",
                str(APPLE_ROOT_KEYCHAIN),
            ],
            capture_output=True,
        )
    except OSError as error:
        raise ValidationError(f"failed to load Apple trust roots: {error}") from error
    roots_detail = roots.stderr.decode("utf-8", errors="replace").strip()
    check(
        roots.returncode == 0,
        "could not load Apple trust roots: "
        + (roots_detail or f"exit status {roots.returncode}"),
    )
    root_matches = list(PEM_CERTIFICATE.finditer(roots.stdout))
    check(bool(root_matches), "Apple trust-root keychain returned no certificates")
    residue = PEM_CERTIFICATE.sub(b"", roots.stdout)
    check(not residue.strip(), "Apple trust-root keychain returned malformed PEM data")
    fingerprints = set()
    try:
        for match in root_matches:
            encoded = re.sub(br"\s+", b"", match.group(1))
            fingerprints.add(
                hashlib.sha256(base64.b64decode(encoded, validate=True)).hexdigest()
            )
    except (binascii.Error, ValueError) as error:
        raise ValidationError(f"Apple trust-root PEM is invalid: {error}") from error
    check(
        fingerprints == APPLE_ROOT_CERTIFICATE_SHA256,
        "system Apple trust-root set differs from the reviewed release roots",
    )

    with tempfile.TemporaryDirectory(prefix="floorp-mobileprovision-") as temporary:
        temporary_root = Path(temporary)
        roots_path = temporary_root / "apple-roots.pem"
        verified_path = temporary_root / "verified.plist"
        signer_path = temporary_root / "signer.pem"
        roots_path.write_bytes(roots.stdout)
        try:
            verification = subprocess.run(
                [
                    "/usr/bin/openssl",
                    "smime",
                    "-verify",
                    "-binary",
                    "-inform",
                    "der",
                    "-in",
                    str(profile_path),
                    "-CAfile",
                    str(roots_path),
                    "-out",
                    str(verified_path),
                    "-signer",
                    str(signer_path),
                ],
                capture_output=True,
            )
        except OSError as error:
            raise ValidationError(
                f"failed to verify provisioning profile CMS signature: {error}"
            ) from error
        verification_detail = verification.stderr.decode(
            "utf-8", errors="replace"
        ).strip()
        check(
            verification.returncode == 0,
            "embedded provisioning profile CMS or Apple trust verification failed: "
            + (verification_detail or f"exit status {verification.returncode}"),
        )
        check(
            verified_path.is_file()
            and not verified_path.is_symlink()
            and stat.S_ISREG(verified_path.lstat().st_mode),
            "CMS verification did not return provisioning profile content",
        )
        check(
            signer_path.is_file()
            and not signer_path.is_symlink()
            and stat.S_ISREG(signer_path.lstat().st_mode),
            "CMS verification did not return its signer certificate",
        )
        signer_pem = signer_path.read_bytes()
        check(
            len(list(PEM_CERTIFICATE.finditer(signer_pem))) == 1
            and not PEM_CERTIFICATE.sub(b"", signer_pem).strip(),
            "provisioning profile must have exactly one CMS signer certificate",
        )
        try:
            signer = subprocess.run(
                [
                    "/usr/bin/openssl",
                    "x509",
                    "-in",
                    str(signer_path),
                    "-noout",
                    "-subject",
                    "-text",
                    "-nameopt",
                    "RFC2253",
                ],
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise ValidationError(
                f"failed to inspect provisioning profile CMS signer: {error}"
            ) from error
        signer_detail = signer.stderr.strip() or f"exit status {signer.returncode}"
        check(
            signer.returncode == 0,
            f"could not inspect provisioning profile CMS signer: {signer_detail}",
        )
        signer_lines = signer.stdout.splitlines()
        check(
            signer_lines.count(PROFILE_SIGNER_SUBJECT) == 1,
            "provisioning profile CMS signer has an unexpected subject",
        )
        signer_oid = re.compile(rf"^\s*{re.escape(PROFILE_SIGNER_OID)}:\s*$")
        check(
            sum(signer_oid.fullmatch(line) is not None for line in signer_lines) == 1,
            "provisioning profile CMS signer lacks Apple's profile-signing extension",
        )
        try:
            profile = plistlib.loads(verified_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise ValidationError(
                f"verified provisioning profile is not a valid plist: {error}"
            ) from error
    check(isinstance(profile, dict), "embedded provisioning profile must be a dictionary")
    return profile


def validate_distribution_provisioning(app: Path, signature: dict) -> None:
    """Bind an App Store distribution signature to its Apple profile."""
    profile_path = app / "embedded.mobileprovision"
    check(
        profile_path.is_file()
        and not profile_path.is_symlink()
        and stat.S_ISREG(profile_path.lstat().st_mode),
        f"distribution app has no real embedded provisioning profile: {profile_path}",
    )
    profile = verified_apple_mobileprovision(profile_path)

    team_identifiers = profile.get("TeamIdentifier")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    profile_entitlements = profile.get("Entitlements")
    developer_certificates = profile.get("DeveloperCertificates")
    check(
        isinstance(team_identifiers, list)
        and team_identifiers == [FLOORP_TEAM_ID],
        "embedded provisioning profile team does not match Floorp",
    )
    check(
        isinstance(prefixes, list) and FLOORP_TEAM_ID in prefixes,
        "embedded provisioning profile application prefix does not match Floorp",
    )
    check(
        isinstance(profile_entitlements, dict),
        "embedded provisioning profile has no entitlements dictionary",
    )
    check(
        isinstance(developer_certificates, list)
        and signature.get("leaf_certificate") in developer_certificates,
        "embedded provisioning profile does not authorize the signing certificate",
    )
    signed_entitlements = signature["entitlements"]
    signed_application_id = signed_entitlements.get("application-identifier")
    check(
        signed_application_id == f"{FLOORP_TEAM_ID}.{FLOORP_BUNDLE_ID}",
        "distribution signature has an unexpected application identifier",
    )
    check(
        profile_entitlements.get("application-identifier") == signed_application_id,
        "embedded provisioning profile application identifier differs from the signature",
    )
    check(
        profile_entitlements.get("com.apple.developer.team-identifier")
        == FLOORP_TEAM_ID,
        "embedded provisioning profile entitlement team differs from the signature",
    )
    check(
        profile_entitlements.get("get-task-allow") is False,
        "distribution provisioning profile must disable get-task-allow",
    )
    check(
        "ProvisionedDevices" not in profile
        and profile.get("ProvisionsAllDevices") in {None, False},
        "embedded provisioning profile is not an App Store distribution profile",
    )


def validate_expected_identity(
    *,
    expected_source_sha: str,
    expected_marketing_version: str,
    expected_build_number: str,
    expected_bundle_id: str,
) -> None:
    check(
        SOURCE_SHA.fullmatch(expected_source_sha) is not None,
        "expected source SHA must be 40 lowercase hexadecimal characters",
    )
    required_string(expected_marketing_version, "expected marketing version")
    check(
        BUILD_NUMBER.fullmatch(expected_build_number) is not None,
        "expected build number must be canonical numeric notation",
    )
    required_string(expected_bundle_id, "expected bundle ID")
    check(
        expected_bundle_id == FLOORP_BUNDLE_ID,
        f"expected bundle ID must be {FLOORP_BUNDLE_ID}",
    )


def validate_retained_dsyms(archive: Path, evidence: dict, privacy_module) -> None:
    """Require the evidence inventory to describe the archive's real dSYMs."""
    dsym_root = archive / "dSYMs"
    check(
        dsym_root.is_dir() and not dsym_root.is_symlink(),
        f"dSYM directory does not exist: {dsym_root}",
    )

    actual = set()
    bundles = sorted(dsym_root.glob("*.dSYM"))
    check(bool(bundles), f"dSYM inventory is empty: {dsym_root}")
    for bundle in bundles:
        require_real_directory_chain(bundle, dsym_root, "dSYM bundle")
        dwarf_dir = bundle / "Contents" / "Resources" / "DWARF"
        require_real_directory_chain(dwarf_dir, dsym_root, "dSYM DWARF directory")
        entries = sorted(dwarf_dir.iterdir())
        binaries = [
            path
            for path in entries
            if path.is_file()
            and not path.is_symlink()
            and stat.S_ISREG(path.lstat().st_mode)
        ]
        check(
            len(binaries) == len(entries) and bool(binaries),
            f"dSYM DWARF directory contains a missing or unsupported binary: {bundle}",
        )
        for binary in binaries:
            try:
                binary.resolve(strict=True).relative_to(dsym_root.resolve(strict=True))
            except (OSError, RuntimeError, ValueError) as error:
                raise ValidationError(
                    f"dSYM DWARF binary resolves outside {dsym_root}: {binary}"
                ) from error
            for uuid in privacy_module.macho_uuids(binary):
                actual.add((uuid, str(binary.resolve())))

    retained = {
        (entry["uuid"], entry["path"]) for entry in evidence["dsym_inventory"]
    }
    missing = actual - retained
    unexpected = retained - actual
    check(
        not missing and not unexpected,
        "dSYM inventory does not match retained archive symbols "
        f"(missing={len(missing)}, unexpected={len(unexpected)})",
    )


def validate_archive_integrity(
    archive: Path,
    expected_digest: str,
    evidence: dict,
    privacy_module,
) -> None:
    check(archive.is_dir() and not archive.is_symlink(), f"archive does not exist: {archive}")
    tree_module = load_sibling_module("floorp_archive_tree", "floorp_archive_tree.py")
    try:
        actual_digest = tree_module.archive_tree_sha256(archive)
    except tree_module.ArchiveTreeError as error:
        raise ValidationError(str(error)) from error
    check(
        actual_digest == expected_digest,
        f"archive SHA-256 mismatch: expected {expected_digest}, got {actual_digest}",
    )

    try:
        validate_retained_dsyms(archive, evidence, privacy_module)
    except privacy_module.MalformedError as error:
        raise MalformedError(str(error)) from error
    except privacy_module.PrivacyError as error:
        raise ValidationError(str(error)) from error


def archive_tree_sha256(archive: Path) -> str:
    tree_module = load_sibling_module("floorp_archive_tree", "floorp_archive_tree.py")
    try:
        return tree_module.archive_tree_sha256(archive)
    except tree_module.ArchiveTreeError as error:
        raise ValidationError(str(error)) from error


def validate_closing_artifact_digests(
    evidence: dict,
    *,
    archive: Path,
    artifact_kind: str,
) -> None:
    """Detect path or byte replacement after the initial artifact reads."""
    closing_archive = canonical_existing_path(
        evidence["archive_path"], "archive", kind="directory"
    )
    check(closing_archive == archive, "archive path changed during validation")
    closing_archive_digest = archive_tree_sha256(closing_archive)
    check(
        closing_archive_digest == evidence["archive_sha256"],
        "archive changed while release evidence was being validated",
    )
    if artifact_kind == "local-export":
        closing_ipa = canonical_existing_path(
            required_string(evidence["ipa_path"], "IPA path"),
            "IPA",
            kind="file",
        )
        closing_ipa_digest = sha256_file(closing_ipa)
        check(
            closing_ipa_digest == evidence["ipa_sha256"],
            "IPA changed while release evidence was being validated",
        )


def bundle_uuid_map(app: Path, privacy_module) -> dict[str, set[str]]:
    try:
        executables = privacy_module.distributed_bundle_executables(app)
        return {
            relative: privacy_module.macho_uuids(executable)
            for relative, executable in executables.items()
        }
    except privacy_module.MalformedError as error:
        raise MalformedError(str(error)) from error
    except privacy_module.PrivacyError as error:
        raise ValidationError(str(error)) from error


def validate_bundle_uuid_coverage(
    bundle_uuids: dict[str, set[str]],
    retained_dsym_uuids: set[str],
    artifact_label: str,
) -> None:
    missing = []
    for relative, executable_uuids in sorted(bundle_uuids.items()):
        absent = sorted(executable_uuids - retained_dsym_uuids)
        if absent:
            missing.append(f"{relative}: {','.join(absent)}")
    check(
        not missing,
        f"{artifact_label} binaries missing dSYM UUIDs: {missing}",
    )


def validate_artifact_kind(
    evidence: dict,
    artifact_kind: str,
    *,
    archive_bundle_uuids: dict[str, set[str]],
    retained_dsym_uuids: set[str],
    privacy_module,
    expected_source_sha: str,
) -> dict | None:
    archive_only = evidence["archive_only"]
    if artifact_kind == "archive-only":
        check(archive_only is True, "evidence is not archive-only")
        check(evidence["ipa_path"] == "", "archive-only evidence must not name an IPA")
        check(evidence["ipa_sha256"] == "", "archive-only evidence must not contain an IPA digest")
        check(evidence["ipa_info"] is None, "archive-only evidence must not contain IPA metadata")
        return None
    else:
        check(archive_only is False, "local-export evidence must not be archive-only")
        ipa_path = canonical_existing_path(
            required_string(evidence["ipa_path"], "IPA path"),
            "IPA",
            kind="file",
        )
        ipa_info = evidence["ipa_info"]
        check(isinstance(ipa_info, dict), "local-export evidence must contain IPA metadata")
        actual = sha256_file(ipa_path)
        check(
            actual == evidence["ipa_sha256"],
            f"IPA SHA-256 mismatch: expected {evidence['ipa_sha256']}, got {actual}",
        )
        with tempfile.TemporaryDirectory(prefix="floorp-ipa-signature-") as temporary:
            actual_ipa_info, extracted_app = extract_ipa_app(
                ipa_path,
                Path(temporary),
            )
            check(
                actual_ipa_info["marketing_version"]
                == ipa_info["marketing_version"],
                "release evidence marketing version does not match IPA Info.plist",
            )
            check(
                actual_ipa_info["build_number"] == ipa_info["build_number"],
                "release evidence build number does not match IPA Info.plist",
            )
            check(
                actual_ipa_info["bundle_id"] == evidence["bundle_id"],
                "release evidence bundle ID does not match IPA Info.plist",
            )
            check(
                actual_ipa_info["source_sha"] == expected_source_sha,
                "IPA source SHA does not match its external expected value",
            )
            ipa_bundle_uuids = bundle_uuid_map(extracted_app, privacy_module)
            check(
                ipa_bundle_uuids.keys() == archive_bundle_uuids.keys(),
                "IPA distributed bundle paths differ from the archive "
                f"(archive={sorted(archive_bundle_uuids)}, "
                f"IPA={sorted(ipa_bundle_uuids)})",
            )
            mismatches = [
                relative
                for relative in sorted(archive_bundle_uuids)
                if ipa_bundle_uuids[relative] != archive_bundle_uuids[relative]
            ]
            check(
                not mismatches,
                "IPA executable UUIDs differ from the archived build: "
                + ", ".join(mismatches),
            )
            validate_bundle_uuid_coverage(
                ipa_bundle_uuids,
                retained_dsym_uuids,
                "IPA",
            )
            signature = inspect_code_signature(
                extracted_app,
                require_distribution=True,
            )
            validate_distribution_provisioning(extracted_app, signature)
            return signature


def match_optional(actual, expected, label: str) -> None:
    if expected is None:
        check(actual is None, f"{label} must be absent when no expected value is supplied")
    else:
        check(actual == expected, f"{label} does not match its external expected value")


def validate_phase_binding(
    evidence: dict,
    *,
    phase: str,
    artifact_kind: str,
    expected_ci_run_url: str | None,
    expected_xcresult_path: str | None,
    expected_export_status: str | None,
    expected_app_store_connect_build_id: str | None,
) -> None:
    if expected_ci_run_url is not None:
        check(
            CI_RUN_URL.fullmatch(expected_ci_run_url) is not None,
            "expected CI run URL is not a canonical GitHub Actions run URL",
        )
    match_optional(evidence["ci_run_url"], expected_ci_run_url, "CI run URL")
    match_optional(evidence["xcresult_path"], expected_xcresult_path, "xcresult path")

    if phase == "pre-upload":
        check(
            expected_app_store_connect_build_id is None,
            "pre-upload validation cannot accept an App Store Connect build ID",
        )
        check(
            evidence["app_store_connect_build_id"] is None,
            "pre-upload evidence must not contain an App Store Connect build ID",
        )
        if artifact_kind == "archive-only":
            check(
                expected_export_status is None,
                "archive-only pre-upload validation cannot accept an export status",
            )
            check(
                evidence["export_status"] is None,
                "archive-only pre-upload evidence must not contain an export status",
            )
        else:
            check(
                expected_export_status == READY_FOR_UPLOAD,
                f"local-export pre-upload status must be {READY_FOR_UPLOAD}",
            )
            check(
                evidence["export_status"] == READY_FOR_UPLOAD,
                f"local-export evidence status must be {READY_FOR_UPLOAD}",
            )
        return

    build_id = required_string(
        expected_app_store_connect_build_id,
        "expected App Store Connect build ID",
    )
    check(
        IDENTIFIER.fullmatch(build_id) is not None,
        "expected App Store Connect build ID contains unsafe characters",
    )
    required_string(expected_ci_run_url, "expected CI run URL")
    check(
        expected_export_status == UPLOADED_AND_PROCESSED,
        f"publication export status must be {UPLOADED_AND_PROCESSED}",
    )
    check(
        evidence["app_store_connect_build_id"] == build_id,
        "App Store Connect build ID does not match its external expected value",
    )
    check(
        evidence["export_status"] == UPLOADED_AND_PROCESSED,
        f"publication evidence status must be {UPLOADED_AND_PROCESSED}",
    )


def validate_receipt_binding(
    evidence: dict,
    receipt_path: Path | None,
    *,
    expected_run_id: str | None,
    expected_workflow_id: str | None,
    expected_source_sha: str,
    expected_build_id: str | None,
    expected_build_number: str,
    expected_app_id: str | None,
    expected_bundle_id: str,
    expected_marketing_version: str,
    expected_platform: str | None,
    expected_min_os_version: str | None,
) -> None:
    check(receipt_path is not None, "Xcode Cloud build receipt is required for publication")
    check(
        receipt_path.is_file() and not receipt_path.is_symlink(),
        f"Xcode Cloud build receipt does not exist: {receipt_path}",
    )
    run_id = required_string(expected_run_id, "expected Xcode Cloud run ID")
    workflow_id = required_string(
        expected_workflow_id, "expected Xcode Cloud workflow ID"
    )
    build_id = required_string(expected_build_id, "expected App Store Connect build ID")
    app_id = required_string(expected_app_id, "expected App Store Connect app ID")
    platform = required_string(expected_platform, "expected platform")
    min_os = required_string(expected_min_os_version, "expected minimum OS version")
    check(app_id == FLOORP_APP_ID, f"expected App Store Connect app ID must be {FLOORP_APP_ID}")
    check(platform == FLOORP_PLATFORM, f"expected platform must be {FLOORP_PLATFORM}")
    check(
        min_os == FLOORP_MIN_OS_VERSION,
        f"expected minimum OS version must be {FLOORP_MIN_OS_VERSION}",
    )

    receipt_module = load_sibling_module(
        "floorp_xcode_cloud_build_receipt", "floorp_xcode_cloud_build_receipt.py"
    )
    receipt = load_json(receipt_path)
    try:
        receipt_build = receipt_module.validate_receipt(
            receipt,
            expected_run_id=run_id,
            expected_workflow_id=workflow_id,
            expected_source_sha=expected_source_sha,
            expected_build_id=build_id,
            expected_build_number=expected_build_number,
            expected_app_id=app_id,
            expected_bundle_id=expected_bundle_id,
            expected_marketing_version=expected_marketing_version,
            expected_platform=platform,
            expected_min_os_version=min_os,
        )
    except receipt_module.ReceiptError as error:
        raise ValidationError(f"Xcode Cloud build receipt rejected: {error}") from error

    expected_receipt_build = {
        "id": evidence["app_store_connect_build_id"],
        "number": evidence["build_number"],
        "bundle_id": evidence["bundle_id"],
        "marketing_version": evidence["marketing_version"],
    }
    mismatches = [
        name
        for name, expected in expected_receipt_build.items()
        if receipt_build.get(name) != expected
    ]
    check(
        not mismatches,
        "release evidence does not match Xcode Cloud receipt: " + ", ".join(mismatches),
    )


def validate_artifact_manifest_binding(
    evidence: dict,
    manifest_path: Path | None,
    *,
    expected_run_id: str | None,
) -> None:
    """Bind evidence bytes to authenticated Xcode Cloud artifact identities."""
    check(manifest_path is not None, "Xcode Cloud artifact manifest is required for publication")
    manifest_file = canonical_existing_path(
        str(manifest_path), "Xcode Cloud artifact manifest", kind="file"
    )
    manifest = load_json(manifest_file)
    check(isinstance(manifest, dict), "Xcode Cloud artifact manifest must be an object")
    check(
        set(manifest)
        == {"schema_version", "run_id", "action", "artifacts", "downloads", "materialized"},
        "Xcode Cloud artifact manifest fields are invalid",
    )
    check(
        isinstance(manifest["schema_version"], int)
        and not isinstance(manifest["schema_version"], bool)
        and manifest["schema_version"] == 1,
        "Xcode Cloud artifact manifest schema is unsupported",
    )
    run_id = required_string(expected_run_id, "expected Xcode Cloud run ID")
    check(manifest["run_id"] == run_id, "artifact manifest run ID mismatch")

    action = manifest["action"]
    check(isinstance(action, dict), "artifact manifest action must be an object")
    check(
        set(action)
        == {"id", "name", "action_type", "execution_progress", "completion_status"},
        "artifact manifest action fields are invalid",
    )
    check(
        isinstance(action["id"], str) and IDENTIFIER.fullmatch(action["id"]) is not None,
        "artifact manifest action ID is invalid",
    )
    check(isinstance(action["name"], str) and bool(action["name"]),
          "artifact manifest action name is missing")
    check(action["action_type"] == "ARCHIVE", "artifact manifest action is not ARCHIVE")
    check(
        action["execution_progress"] == "COMPLETE"
        and action["completion_status"] == "SUCCEEDED",
        "artifact manifest action did not succeed",
    )

    artifacts = manifest["artifacts"]
    downloads = manifest["downloads"]
    materialized = manifest["materialized"]
    check(isinstance(artifacts, dict) and set(artifacts) == {"archive", "archive_export"},
          "artifact manifest artifact fields are invalid")
    check(isinstance(downloads, dict) and set(downloads) == {"archive", "archive_export"},
          "artifact manifest download fields are invalid")
    check(
        isinstance(materialized, dict)
        and set(materialized)
        == {"archive_path", "archive_tree_sha256", "ipa_path", "ipa_sha256", "ipa_size"},
        "artifact manifest materialized fields are invalid",
    )

    artifact_ids = set()
    download_paths = []
    for name, expected_type in (("archive", "ARCHIVE"), ("archive_export", "ARCHIVE_EXPORT")):
        artifact = artifacts[name]
        check(isinstance(artifact, dict), f"{name} artifact identity must be an object")
        check(
            set(artifact)
            == {"id", "file_type", "file_name", "file_size", "downloaded_size", "sha256"},
            f"{name} artifact identity fields are invalid",
        )
        artifact_id = artifact["id"]
        check(
            isinstance(artifact_id, str) and IDENTIFIER.fullmatch(artifact_id) is not None,
            f"{name} artifact ID is invalid",
        )
        artifact_ids.add(artifact_id)
        check(artifact["file_type"] == expected_type,
              f"{name} artifact has the wrong file type")
        check(
            isinstance(artifact["file_name"], str)
            and bool(artifact["file_name"])
            and artifact["file_name"] not in {".", ".."}
            and "/" not in artifact["file_name"]
            and "\\" not in artifact["file_name"]
            and all(
                ord(character) >= 32 and character != "\x7f"
                for character in artifact["file_name"]
            ),
            f"{name} artifact file name is invalid",
        )
        size = artifact["file_size"]
        check(
            isinstance(size, int)
            and not isinstance(size, bool)
            and size > 0
            and isinstance(artifact["downloaded_size"], int)
            and not isinstance(artifact["downloaded_size"], bool)
            and artifact["downloaded_size"] == size,
            f"{name} artifact byte counts are invalid",
        )
        check(
            isinstance(artifact["sha256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]) is not None,
            f"{name} artifact digest is invalid",
        )
        download = canonical_existing_path(
            required_string(downloads[name], f"{name} download path"),
            f"Xcode Cloud {name} download",
            kind="file",
        )
        download_paths.append(download)
        check(download.stat().st_size == size, f"{name} download size mismatch")
        check(sha256_file(download) == artifact["sha256"], f"{name} download digest mismatch")
    check(len(artifact_ids) == 2, "Xcode Cloud artifact IDs must be distinct")
    check(
        not download_paths[0].samefile(download_paths[1]),
        "Xcode Cloud artifact downloads must be distinct files",
    )

    check(
        materialized["archive_path"] == evidence["archive_path"]
        and materialized["archive_tree_sha256"] == evidence["archive_sha256"],
        "artifact manifest archive does not match release evidence",
    )
    check(
        materialized["ipa_path"] == evidence["ipa_path"]
        and materialized["ipa_sha256"] == evidence["ipa_sha256"],
        "artifact manifest IPA does not match release evidence",
    )
    check(
        isinstance(materialized["ipa_size"], int)
        and not isinstance(materialized["ipa_size"], bool)
        and materialized["ipa_size"] == Path(evidence["ipa_path"]).stat().st_size,
        "artifact manifest IPA size does not match release evidence",
    )


def validate_release_evidence(
    schema: dict,
    evidence: dict,
    *,
    phase: str,
    artifact_kind: str,
    expected_source_sha: str,
    expected_marketing_version: str,
    expected_build_number: str,
    expected_bundle_id: str,
    expected_ci_run_url: str | None = None,
    expected_xcresult_path: str | None = None,
    expected_export_status: str | None = None,
    expected_app_store_connect_build_id: str | None = None,
    xcode_cloud_build_receipt: Path | None = None,
    xcode_cloud_artifact_manifest: Path | None = None,
    expected_xcode_cloud_run_id: str | None = None,
    expected_xcode_cloud_workflow_id: str | None = None,
    expected_app_id: str | None = None,
    expected_platform: str | None = None,
    expected_min_os_version: str | None = None,
) -> None:
    check(isinstance(schema, dict), "schema must be an object")
    check(isinstance(evidence, dict), "evidence must be an object")
    check(phase in {"pre-upload", "publication"}, f"unsupported phase: {phase}")
    check(
        artifact_kind in {"archive-only", "local-export"},
        f"unsupported artifact kind: {artifact_kind}",
    )
    check(
        phase != "publication" or artifact_kind == "local-export",
        "publication validation requires a local-export artifact; "
        "archive-only publication is not byte-bound to App Store Connect",
    )
    validate_shape(schema, evidence)
    validate_expected_identity(
        expected_source_sha=expected_source_sha,
        expected_marketing_version=expected_marketing_version,
        expected_build_number=expected_build_number,
        expected_bundle_id=expected_bundle_id,
    )

    check(
        evidence["source_sha256"] == expected_source_sha,
        "source SHA does not match its external expected value",
    )
    check(
        evidence["marketing_version"] == expected_marketing_version,
        "marketing version does not match its external expected value",
    )
    check(
        evidence["build_number"] == expected_build_number,
        "build number does not match its external expected value",
    )
    check(
        evidence["bundle_id"] == expected_bundle_id,
        "bundle ID does not match its external expected value",
    )

    archive_info = evidence["archive_info"]
    check(
        evidence["marketing_version"] == archive_info["marketing_version"],
        "marketing version differs from archive Info.plist",
    )
    check(
        evidence["build_number"] == archive_info["build_number"],
        "build number differs from archive Info.plist",
    )
    check(
        evidence["bundle_id"] == archive_info["bundle_id"],
        "bundle ID differs from archive Info.plist",
    )
    check(
        evidence["team_id"] == archive_info["team_id"],
        "team ID differs from archive Info.plist",
    )

    archive = canonical_existing_path(
        evidence["archive_path"], "archive", kind="directory"
    )
    archived_app, archive_team_id, archive_signing_identity = (
        validate_archive_metadata(archive, evidence, expected_source_sha)
    )

    if artifact_kind == "local-export":
        check(
            evidence["team_id"] == FLOORP_TEAM_ID,
            f"release team ID is not {FLOORP_TEAM_ID}",
        )
    elif evidence["team_id"]:
        check(
            evidence["team_id"] == FLOORP_TEAM_ID,
            f"archive team ID is not {FLOORP_TEAM_ID}",
        )

    ipa_info = evidence["ipa_info"]
    if isinstance(ipa_info, dict):
        check(
            ipa_info["marketing_version"] == archive_info["marketing_version"],
            "mixed build IDs: IPA marketing version differs from archive",
        )
        check(
            ipa_info["build_number"] == archive_info["build_number"],
            "mixed build IDs: IPA build number differs from archive",
        )

    dsyms = evidence["dsym_inventory"]
    check(bool(dsyms), "dSYM inventory is empty")
    uuids = [entry["uuid"] for entry in dsyms]
    check(len(uuids) == len(set(uuids)), "duplicate dSYM UUID")
    retained_dsym_uuids = set(uuids)

    privacy_module = load_sibling_module(
        "floorp_release_privacy", "validate-floorp-privacy.py"
    )

    validate_archive_integrity(
        archive,
        evidence["archive_sha256"],
        evidence,
        privacy_module,
    )
    archive_bundle_uuids = bundle_uuid_map(archived_app, privacy_module)
    validate_bundle_uuid_coverage(
        archive_bundle_uuids,
        retained_dsym_uuids,
        "archive",
    )
    archive_signature = inspect_code_signature(archived_app)
    check(
        archive_signature["identifier"] == FLOORP_BUNDLE_ID,
        "archive code-signing identifier is not the Floorp bundle ID",
    )
    check(
        archive_signature["team_id"] == archive_team_id,
        "archive code-signing team differs from archive Info.plist",
    )
    check(
        archive_signature["signing_identity"] == archive_signing_identity,
        "archive code-signing authority differs from archive Info.plist",
    )
    validate_entitlements(archive_signature["entitlements"])

    exported_signature = validate_artifact_kind(
        evidence,
        artifact_kind,
        archive_bundle_uuids=archive_bundle_uuids,
        retained_dsym_uuids=retained_dsym_uuids,
        privacy_module=privacy_module,
        expected_source_sha=expected_source_sha,
    )

    selected_signature = (
        archive_signature if artifact_kind == "archive-only" else exported_signature
    )
    check(selected_signature is not None, "signed release artifact is missing")
    check(
        selected_signature["identifier"] == FLOORP_BUNDLE_ID,
        "release artifact code-signing identifier is not the Floorp bundle ID",
    )
    check(
        selected_signature["team_id"] == evidence["team_id"],
        "release artifact signing team does not match evidence",
    )
    check(
        selected_signature["signing_identity"] == evidence["signing_identity"],
        "release artifact signing identity does not match evidence",
    )
    check(
        selected_signature["entitlements"] == evidence["entitlements"],
        "release artifact entitlements do not match evidence",
    )
    validate_entitlements(selected_signature["entitlements"])
    if artifact_kind == "local-export":
        check(
            "Apple Distribution" in selected_signature["signing_identity"],
            "local-export IPA must use an Apple Distribution identity",
        )

    validate_phase_binding(
        evidence,
        phase=phase,
        artifact_kind=artifact_kind,
        expected_ci_run_url=expected_ci_run_url,
        expected_xcresult_path=expected_xcresult_path,
        expected_export_status=expected_export_status,
        expected_app_store_connect_build_id=expected_app_store_connect_build_id,
    )
    if phase == "publication":
        validate_artifact_manifest_binding(
            evidence,
            xcode_cloud_artifact_manifest,
            expected_run_id=expected_xcode_cloud_run_id,
        )
        validate_receipt_binding(
            evidence,
            xcode_cloud_build_receipt,
            expected_run_id=expected_xcode_cloud_run_id,
            expected_workflow_id=expected_xcode_cloud_workflow_id,
            expected_source_sha=expected_source_sha,
            expected_build_id=expected_app_store_connect_build_id,
            expected_build_number=expected_build_number,
            expected_app_id=expected_app_id,
            expected_bundle_id=expected_bundle_id,
            expected_marketing_version=expected_marketing_version,
            expected_platform=expected_platform,
            expected_min_os_version=expected_min_os_version,
        )
    else:
        check(
            xcode_cloud_build_receipt is None
            and xcode_cloud_artifact_manifest is None
            and expected_xcode_cloud_run_id is None
            and expected_xcode_cloud_workflow_id is None
            and expected_app_id is None
            and expected_platform is None
            and expected_min_os_version is None,
            "publication-only receipt expectations are not allowed before upload",
        )

    validate_closing_artifact_digests(
        evidence,
        archive=archive,
        artifact_kind=artifact_kind,
    )


def main(argv=None) -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--evidence", required=True, type=Path)
    arguments.add_argument("--schema", required=True, type=Path)
    arguments.add_argument("--phase", required=True, choices=("pre-upload", "publication"))
    arguments.add_argument(
        "--artifact-kind", required=True, choices=("archive-only", "local-export")
    )
    arguments.add_argument("--expected-source-sha", required=True)
    arguments.add_argument("--expected-marketing-version", required=True)
    arguments.add_argument("--expected-build-number", required=True)
    arguments.add_argument("--expected-bundle-id", required=True)
    arguments.add_argument("--expected-ci-run-url")
    arguments.add_argument("--expected-xcresult-path")
    arguments.add_argument(
        "--expected-export-status",
        choices=(READY_FOR_UPLOAD, UPLOADED_AND_PROCESSED),
    )
    arguments.add_argument("--expected-app-store-connect-build-id")
    arguments.add_argument("--xcode-cloud-build-receipt", type=Path)
    arguments.add_argument("--xcode-cloud-artifact-manifest", type=Path)
    arguments.add_argument("--expected-xcode-cloud-run-id")
    arguments.add_argument("--expected-xcode-cloud-workflow-id")
    arguments.add_argument("--expected-app-id")
    arguments.add_argument("--expected-platform")
    arguments.add_argument("--expected-min-os-version")
    parsed = arguments.parse_args(argv)
    try:
        schema = load_json(parsed.schema)
        evidence = load_json(parsed.evidence)
        validate_release_evidence(
            schema,
            evidence,
            phase=parsed.phase,
            artifact_kind=parsed.artifact_kind,
            expected_source_sha=parsed.expected_source_sha,
            expected_marketing_version=parsed.expected_marketing_version,
            expected_build_number=parsed.expected_build_number,
            expected_bundle_id=parsed.expected_bundle_id,
            expected_ci_run_url=parsed.expected_ci_run_url,
            expected_xcresult_path=parsed.expected_xcresult_path,
            expected_export_status=parsed.expected_export_status,
            expected_app_store_connect_build_id=(
                parsed.expected_app_store_connect_build_id
            ),
            xcode_cloud_build_receipt=parsed.xcode_cloud_build_receipt,
            xcode_cloud_artifact_manifest=parsed.xcode_cloud_artifact_manifest,
            expected_xcode_cloud_run_id=parsed.expected_xcode_cloud_run_id,
            expected_xcode_cloud_workflow_id=(
                parsed.expected_xcode_cloud_workflow_id
            ),
            expected_app_id=parsed.expected_app_id,
            expected_platform=parsed.expected_platform,
            expected_min_os_version=parsed.expected_min_os_version,
        )
        return 0
    except MalformedError as error:
        print(f"MALFORMED: {error}", file=sys.stderr)
        return 2
    except (KeyError, TypeError) as error:
        print(f"MALFORMED: incomplete evidence ({error})", file=sys.stderr)
        return 2
    except (OSError, ValidationError) as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
