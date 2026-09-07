#!/usr/bin/env bash
# Collects byte-verifiable evidence for one Floorp release candidate.
#
# Binds the full source SHA, marketing version/build number (from the archived
# app), signing identity, entitlements, archive and IPA digests, and the dSYM
# UUID inventory into one JSON document matching
# scripts/release/floorp-release-evidence.schema.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA_TEMP_DIR=""
APPLE_TEAM_REQUIREMENT='=anchor apple generic and certificate leaf[subject.OU] = "DV2U35YBHT"'
APPLE_DISTRIBUTION_REQUIREMENT="$APPLE_TEAM_REQUIREMENT and certificate leaf[field.1.2.840.113635.100.6.1.4] exists"

cleanup() {
    if [[ -n "$IPA_TEMP_DIR" && -d "$IPA_TEMP_DIR" ]]; then
        rm -rf -- "$IPA_TEMP_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  collect-floorp-release-evidence.sh \
    --archive PATH [--ipa PATH] --source-sha SHA \
    [--archive-only] [--ci-run-url URL] [--xcresult-path PATH] \
    [--app-store-connect-build-id ID] [--export-status STATUS] \
    --output PATH

  --archive-only   validate a signed archive without an exported IPA
  --output         absolute path for the evidence JSON
EOF
}

ARCHIVE=""
IPA=""
SOURCE_SHA=""
ARCHIVE_ONLY=0
CI_RUN_URL=""
XCRESULT_PATH=""
ASC_BUILD_ID=""
EXPORT_STATUS=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) ARCHIVE="$2"; shift 2 ;;
        --ipa) IPA="$2"; shift 2 ;;
        --source-sha) SOURCE_SHA="$2"; shift 2 ;;
        --archive-only) ARCHIVE_ONLY=1; shift ;;
        --ci-run-url) CI_RUN_URL="$2"; shift 2 ;;
        --xcresult-path) XCRESULT_PATH="$2"; shift 2 ;;
        --app-store-connect-build-id) ASC_BUILD_ID="$2"; shift 2 ;;
        --export-status) EXPORT_STATUS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$ARCHIVE" || -z "$SOURCE_SHA" || -z "$OUTPUT" ]]; then
    echo "Missing required arguments." >&2
    usage >&2
    exit 2
fi
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "source-sha must be a 40-character hex SHA." >&2
    exit 2
fi
if [[ "$ARCHIVE_ONLY" -eq 0 && -z "$IPA" ]]; then
    echo "IPA is required unless --archive-only is set." >&2
    exit 2
fi

canonical_existing_path() {
    python3 - "$1" "$2" <<'PYEOF'
import sys
from pathlib import Path

raw, kind = sys.argv[1:]
if any(ord(character) < 32 or character == "\x7f" for character in raw):
    raise SystemExit(f"artifact path contains control characters: {raw!r}")
path = Path(raw)
if path.is_symlink():
    raise SystemExit(f"artifact path must not be a symbolic link: {path}")
try:
    resolved = path.resolve(strict=True)
except (OSError, RuntimeError) as error:
    raise SystemExit(f"artifact path does not exist: {path} ({error})") from error
if kind == "directory" and not resolved.is_dir():
    raise SystemExit(f"artifact path is not a directory: {resolved}")
if kind == "file" and not resolved.is_file():
    raise SystemExit(f"artifact path is not a file: {resolved}")
print(resolved)
PYEOF
}

canonical_output_path() {
    python3 - "$1" <<'PYEOF'
import sys
from pathlib import Path

raw = sys.argv[1]
if any(ord(character) < 32 or character == "\x7f" for character in raw):
    raise SystemExit(f"output path contains control characters: {raw!r}")
path = Path(raw)
if not path.name:
    raise SystemExit(f"output path must name a file: {path}")
if path.is_symlink():
    raise SystemExit(f"output path must not be a symbolic link: {path}")
try:
    parent = path.parent.resolve(strict=True)
except (OSError, RuntimeError) as error:
    raise SystemExit(f"output directory does not exist: {path.parent} ({error})") from error
if not parent.is_dir():
    raise SystemExit(f"output parent is not a directory: {parent}")
print(parent / path.name)
PYEOF
}

if ! ARCHIVE="$(canonical_existing_path "$ARCHIVE" directory)"; then
    exit 2
fi
if [[ "$ARCHIVE_ONLY" -eq 0 ]]; then
    if ! IPA="$(canonical_existing_path "$IPA" file)"; then
        exit 2
    fi
fi
if ! OUTPUT="$(canonical_output_path "$OUTPUT")"; then
    exit 2
fi

if ! OUTPUT_SCOPE="$(python3 - "$OUTPUT" "$ARCHIVE" <<'PYEOF'
import os
import sys
from pathlib import Path

output, archive = map(Path, sys.argv[1:])
try:
    if output == archive:
        print("inside")
        raise SystemExit(0)
    current = output.parent
    while True:
        if os.path.samefile(current, archive):
            print("inside")
            raise SystemExit(0)
        parent = current.parent
        if parent == current:
            break
        current = parent
except OSError as error:
    raise SystemExit(f"could not establish evidence output ancestry: {error}") from error
print("outside")
PYEOF
)"; then
    exit 2
fi
if [[ "$OUTPUT_SCOPE" == "inside" ]]; then
    echo "Evidence output must not be the archive or be stored inside it: $OUTPUT" >&2
    exit 2
fi
if [[ -n "$IPA" && "$OUTPUT" == "$IPA" ]]; then
    echo "Evidence output must not overwrite the IPA: $OUTPUT" >&2
    exit 2
fi
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo "Refusing to overwrite existing evidence output: $OUTPUT" >&2
    exit 2
fi

APP="$ARCHIVE/Products/Applications/Client.app"
for APP_DIRECTORY in \
    "$ARCHIVE/Products" \
    "$ARCHIVE/Products/Applications" \
    "$APP"; do
    if [[ ! -d "$APP_DIRECTORY" || -L "$APP_DIRECTORY" ]]; then
        echo "Archived app path contains a missing or symbolic-link directory: $APP_DIRECTORY" >&2
        exit 2
    fi
done

ARCHIVE_SHA256="$(python3 "$SCRIPT_DIR/floorp_archive_tree.py" "$ARCHIVE")"

PLIST="$APP/Info.plist"
if [[ ! -f "$PLIST" || -L "$PLIST" ]]; then
    echo "Archived app Info.plist is not a real file: $PLIST" >&2
    exit 2
fi
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
if ! ARCHIVE_SOURCE_SHA="$(
    /usr/libexec/PlistBuddy -c 'Print :MozFloorpSourceSHA' "$PLIST"
)"; then
    echo "Archived app does not contain MozFloorpSourceSHA: $PLIST" >&2
    exit 2
fi
if [[ "$ARCHIVE_SOURCE_SHA" != "$SOURCE_SHA" ]]; then
    echo "Archived app source SHA does not match --source-sha." >&2
    exit 2
fi
TEAM_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' "$ARCHIVE/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:TeamIdentifier' "$ARCHIVE/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' "$ARCHIVE/Info.plist" 2>/dev/null \
    || echo ""
)"

SIGNING_IDENTITY="$(
    /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:SigningIdentity' "$ARCHIVE/Info.plist" 2>/dev/null \
    || echo ""
)"
ARCHIVE_TEAM_ID="$TEAM_ID"

if [[ -z "$ARCHIVE_TEAM_ID" || -z "$SIGNING_IDENTITY" ]]; then
    echo "Archive signing team and identity are required." >&2
    exit 2
fi

if ! codesign --verify --strict -R "$APPLE_TEAM_REQUIREMENT" "$APP"; then
    echo "Archived app code signature is invalid: $APP" >&2
    exit 2
fi

if ENTITLEMENTS_JSON="$(
    codesign -d --entitlements :- "$APP" 2>/dev/null \
        | plutil -convert json -o - -- - 2>/dev/null
)" && [[ -n "$ENTITLEMENTS_JSON" ]]; then
    :
else
    echo "Could not read signed archive entitlements: $APP" >&2
    exit 2
fi

DSYM_ENTRIES="$(python3 - "$ARCHIVE/dSYMs" <<'PYEOF'
import json
import re
import stat
import subprocess
import sys
from pathlib import Path


dsym_root = Path(sys.argv[1])
if not dsym_root.is_dir() or dsym_root.is_symlink():
    raise SystemExit(f"dSYM directory does not exist: {dsym_root}")
dsym_root = dsym_root.resolve(strict=True)


def require_real_directory_chain(path, label):
    try:
        relative = path.relative_to(dsym_root)
    except ValueError as error:
        raise SystemExit(f"{label} is outside {dsym_root}: {path}") from error
    current = dsym_root
    for part in relative.parts:
        current = current / part
        if (
            not current.is_dir()
            or current.is_symlink()
            or not stat.S_ISDIR(current.lstat().st_mode)
        ):
            raise SystemExit(
                f"{label} contains a missing or symbolic-link directory: {current}"
            )
    try:
        path.resolve(strict=True).relative_to(dsym_root)
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"{label} resolves outside {dsym_root}: {path}") from error

dsym_bundles = sorted(dsym_root.glob("*.dSYM"))
if not dsym_bundles:
    raise SystemExit(f"dSYM inventory is empty: {dsym_root}")

entries = []
for bundle in dsym_bundles:
    require_real_directory_chain(bundle, "dSYM bundle")
    dwarf_dir = bundle / "Contents" / "Resources" / "DWARF"
    require_real_directory_chain(dwarf_dir, "dSYM DWARF directory")
    dwarf_entries = sorted(dwarf_dir.iterdir())
    binaries = [
        path
        for path in dwarf_entries
        if path.is_file()
        and not path.is_symlink()
        and stat.S_ISREG(path.lstat().st_mode)
    ]
    if len(binaries) != len(dwarf_entries) or not binaries:
        raise SystemExit(
            f"dSYM DWARF directory contains a missing or unsupported binary: {bundle}"
        )

    for binary in binaries:
        try:
            binary.resolve(strict=True).relative_to(dsym_root)
        except (OSError, RuntimeError, ValueError) as error:
            raise SystemExit(
                f"dSYM DWARF binary resolves outside {dsym_root}: {binary}"
            ) from error
        try:
            result = subprocess.run(
                ["dwarfdump", "--uuid", str(binary)],
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise SystemExit(f"failed to run dwarfdump for {binary}: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit status {result.returncode}"
            raise SystemExit(f"dwarfdump failed for {binary}: {detail}")

        uuid_lines = [
            line for line in result.stdout.splitlines()
            if line.lstrip().startswith("UUID:")
        ]
        if not uuid_lines:
            raise SystemExit(f"dwarfdump returned no UUID for {binary}")

        for line in uuid_lines:
            match = re.fullmatch(
                r"\s*UUID:\s+([^\s]+)\s+\([^)]+\)\s+.+\s*",
                line,
            )
            if match is None:
                raise SystemExit(f"could not parse dwarfdump output for {binary}: {line}")
            uuid = match.group(1).replace("-", "").upper()
            if re.fullmatch(r"[0-9A-F]{32}", uuid) is None:
                raise SystemExit(f"invalid UUID from dwarfdump for {binary}: {match.group(1)}")
            entries.append({"uuid": uuid, "path": str(binary.resolve())})

if not entries:
    raise SystemExit(f"dSYM inventory is empty: {dsym_root}")

print(json.dumps(entries, separators=(",", ":")))
PYEOF
)"

IPA_SHA256=""
IPA_MARKETING_VERSION=""
IPA_BUILD_NUMBER=""
if [[ "$ARCHIVE_ONLY" -eq 0 ]]; then
    IPA_SHA256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
    IPA_TEMP_DIR="$(mktemp -d)"
    IPA_EXTRACTION_ROOT="$IPA_TEMP_DIR/Extracted"
    IPA_APP_BUNDLE="$IPA_EXTRACTION_ROOT/Exported.app"
    IPA_INFO_PLIST="$IPA_APP_BUNDLE/Info.plist"
    if ! python3 - \
        "$SCRIPT_DIR/validate-floorp-release-evidence.py" \
        "$IPA" \
        "$IPA_EXTRACTION_ROOT" <<'PYEOF'
import importlib.util
import sys
from pathlib import Path

validator_path, ipa_path, extraction_root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("floorp_release_evidence", validator_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"could not load IPA verifier: {validator_path}")
module = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(module)
except (ImportError, OSError, RuntimeError, SyntaxError) as error:
    raise SystemExit(f"could not load IPA verifier: {error}") from error
try:
    _metadata, extracted_app = module.extract_ipa_app(ipa_path, extraction_root)
except (OSError, RuntimeError, module.ValidationError) as error:
    raise SystemExit(f"could not read IPA artifact: {error}") from error
if extracted_app != extraction_root / "Exported.app":
    raise SystemExit(f"IPA verifier returned an unexpected app path: {extracted_app}")
PYEOF
    then
        echo "Failed to inspect IPA: $IPA" >&2
        exit 2
    fi
    if ! codesign --verify --strict -R "$APPLE_DISTRIBUTION_REQUIREMENT" "$IPA_APP_BUNDLE"; then
        echo "IPA main app code signature is invalid: $IPA" >&2
        exit 2
    fi
    IPA_MARKETING_VERSION="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$IPA_INFO_PLIST"
    )"
    IPA_BUILD_NUMBER="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IPA_INFO_PLIST"
    )"
    if ! IPA_SOURCE_SHA="$(
        /usr/libexec/PlistBuddy -c 'Print :MozFloorpSourceSHA' "$IPA_INFO_PLIST"
    )"; then
        echo "IPA app does not contain MozFloorpSourceSHA: $IPA" >&2
        exit 2
    fi
    if [[ "$IPA_SOURCE_SHA" != "$SOURCE_SHA" ]]; then
        echo "IPA app source SHA does not match --source-sha." >&2
        exit 2
    fi
    TEAM_ID="$(
        codesign -dv "$IPA_APP_BUNDLE" 2>&1 \
            | sed -n 's/^TeamIdentifier=//p' \
            | head -1
    )"
    SIGNING_IDENTITY="$(
        codesign -dvv "$IPA_APP_BUNDLE" 2>&1 \
            | sed -n 's/^Authority=//p' \
            | head -1
    )"
    if [[ -z "$TEAM_ID" || -z "$SIGNING_IDENTITY" ]]; then
        echo "Could not read IPA signing team or identity: $IPA" >&2
        exit 2
    fi
    if ENTITLEMENTS_JSON="$(
        codesign -d --entitlements :- "$IPA_APP_BUNDLE" 2>/dev/null \
            | plutil -convert json -o - -- - 2>/dev/null
    )" && [[ -n "$ENTITLEMENTS_JSON" ]]; then
        :
    else
        echo "Could not read signed IPA entitlements: $IPA" >&2
        exit 2
    fi
fi

FINAL_ARCHIVE_SHA256="$(python3 "$SCRIPT_DIR/floorp_archive_tree.py" "$ARCHIVE")"
if [[ "$FINAL_ARCHIVE_SHA256" != "$ARCHIVE_SHA256" ]]; then
    echo "Archive changed while release evidence was being collected." >&2
    exit 2
fi
if [[ "$ARCHIVE_ONLY" -eq 0 ]]; then
    FINAL_IPA_SHA256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
    if [[ "$FINAL_IPA_SHA256" != "$IPA_SHA256" ]]; then
        echo "IPA changed while release evidence was being collected." >&2
        exit 2
    fi
fi

python3 - \
    "$OUTPUT" \
    "$SOURCE_SHA" \
    "$MARKETING_VERSION" \
    "$BUILD_NUMBER" \
    "$BUNDLE_ID" \
    "$TEAM_ID" \
    "$ARCHIVE_TEAM_ID" \
    "$ARCHIVE" \
    "$ARCHIVE_SHA256" \
    "$IPA" \
    "$IPA_SHA256" \
    "$SIGNING_IDENTITY" \
    "$ENTITLEMENTS_JSON" \
    "$DSYM_ENTRIES" \
    "$ASC_BUILD_ID" \
    "$CI_RUN_URL" \
    "$XCRESULT_PATH" \
    "$EXPORT_STATUS" \
    "$ARCHIVE_ONLY" \
    "$IPA_MARKETING_VERSION" \
    "$IPA_BUILD_NUMBER" <<'PYEOF'
import json
import os
import sys
import tempfile
from pathlib import Path

(
    output, source_sha, marketing_version, build_number, bundle_id, team_id,
    archive_team_id, archive, archive_sha256, ipa, ipa_sha256, signing_identity,
    entitlements_json, dsym_entries, asc_build_id, ci_run_url, xcresult_path,
    export_status, archive_only, ipa_marketing_version, ipa_build_number,
) = sys.argv[1:]

is_archive_only = archive_only == "1"

evidence = {
    "schema_version": 1,
    "archive_only": is_archive_only,
    "source_sha256": source_sha,
    "marketing_version": marketing_version,
    "build_number": build_number,
    "bundle_id": bundle_id,
    "team_id": team_id,
    "archive_path": archive,
    "archive_sha256": archive_sha256,
    "ipa_path": ipa,
    "ipa_sha256": ipa_sha256,
    "signing_identity": signing_identity or None,
    "archive_info": {
        "marketing_version": marketing_version,
        "build_number": build_number,
        "bundle_id": bundle_id,
        "team_id": archive_team_id,
    },
    "ipa_info": None if is_archive_only else {
        "marketing_version": ipa_marketing_version,
        "build_number": ipa_build_number,
    },
    "entitlements": json.loads(entitlements_json or "{}"),
    "dsym_inventory": json.loads(dsym_entries or "[]"),
    "app_store_connect_build_id": asc_build_id or None,
    "ci_run_url": ci_run_url or None,
    "xcresult_path": xcresult_path or None,
    "export_status": export_status or None,
}
output_path = Path(output)
descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{output_path.name}.",
    suffix=".tmp",
    dir=output_path.parent,
)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.link(temporary_name, output_path)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
print(output)
PYEOF

echo "Collected release evidence for ${MARKETING_VERSION} (${BUILD_NUMBER}) at ${OUTPUT}"
