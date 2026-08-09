#!/usr/bin/env bash
# Collects byte-verifiable evidence for one Floorp release candidate.
#
# Binds the full source SHA, marketing version/build number (from the archived
# app), signing identity, entitlements, archive and IPA digests, and the dSYM
# UUID inventory into one JSON document matching
# scripts/release/floorp-release-evidence.schema.json.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  collect-floorp-release-evidence.sh \
    --archive PATH [--ipa PATH] --source-sha SHA \
    [--archive-only] [--ci-run-url URL] [--xcresult-path PATH] \
    [--app-store-connect-build-id ID] [--export-status STATUS] \
    --output PATH

  --archive-only   skip IPA presence/digest requirements (cloud validation)
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
if [[ ! -d "$ARCHIVE" ]]; then
    echo "Archive does not exist: $ARCHIVE" >&2
    exit 2
fi
if [[ "$ARCHIVE_ONLY" -eq 0 && ( -z "$IPA" || ! -f "$IPA" ) ]]; then
    echo "IPA is required unless --archive-only is set." >&2
    exit 2
fi

APP="$ARCHIVE/Products/Applications/Client.app"
if [[ ! -d "$APP" ]]; then
    echo "Archived app not found at $APP" >&2
    exit 2
fi

PLIST="$APP/Info.plist"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
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

ENTITLEMENTS_JSON="{}"
if ENTITLEMENTS_JSON="$(codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -convert json -o - -- - 2>/dev/null)" && [[ -n "$ENTITLEMENTS_JSON" ]]; then
    :
else
    ENTITLEMENTS_JSON="{}"
fi

DSYM_ENTRIES="[]"
if [[ -d "$ARCHIVE/dSYMs" ]]; then
    DSYM_ENTRIES="$(dwarfdump --uuid "$ARCHIVE"/dSYMs/*.dSYM 2>/dev/null | \
        awk '/^UUID:/ { uuid=$2; path=$3; sub(/^\(/, "", path); sub(/\)$/, "", path); printf "%s%s", (NR>1 ? "," : ""), "{\"uuid\":\"" uuid "\",\"path\":\"" path "\"}" }' \
        | sed 's/^/[/; s/$/]/' || echo "[]")"
fi

IPA_SHA256=""
IPA_INFO="null"
if [[ "$ARCHIVE_ONLY" -eq 0 ]]; then
    IPA_SHA256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
    IPA_APP="$(mktemp -d)/Payload/Client.app"
    mkdir -p "$(dirname "$IPA_APP")"
    unzip -q -o "$IPA" 'Payload/Client.app/Info.plist' -d "$(dirname "$(dirname "$IPA_APP")")" 2>/dev/null || true
    if [[ -f "$IPA_APP/Info.plist" ]]; then
        IPA_INFO="$(python3 -c "
import json, plistlib, sys
with open('$IPA_APP/Info.plist', 'rb') as handle:
    info = plistlib.load(handle)
print(json.dumps({
    'marketing_version': info.get('CFBundleShortVersionString', ''),
    'build_number': info.get('CFBundleVersion', ''),
}))
")"
    fi
    rm -rf "$(dirname "$(dirname "$IPA_APP")")"
fi

if [[ -z "$TEAM_ID" && "$ARCHIVE_ONLY" -eq 0 && -n "$IPA" ]]; then
    # Xcode Cloud archive-only runs produce unsigned archives (no team in the
    # Info.plist); the exported IPA carries the signing team.
    IPA_APP_TEAM="$(mktemp -d)/Payload/Client.app"
    mkdir -p "$(dirname "$IPA_APP_TEAM")"
    unzip -q -o "$IPA" 'Payload/Client.app/*' -d "$(dirname "$(dirname "$IPA_APP_TEAM")")" 2>/dev/null || true
    if [[ -d "$IPA_APP_TEAM" ]]; then
        TEAM_ID="$(codesign -dv "$IPA_APP_TEAM" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            SIGNING_IDENTITY="$(codesign -dvv "$IPA_APP_TEAM" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
        fi
    fi
    rm -rf "$(dirname "$(dirname "$IPA_APP_TEAM")")"
fi

ARCHIVE_INFO="$(python3 -c "
import json, sys
print(json.dumps({
    'marketing_version': '$MARKETING_VERSION',
    'build_number': '$BUILD_NUMBER',
    'bundle_id': '$BUNDLE_ID',
    'team_id': '$TEAM_ID',
}))
")"

python3 - "$OUTPUT" "$SOURCE_SHA" "$MARKETING_VERSION" "$BUILD_NUMBER" "$BUNDLE_ID" "$TEAM_ID" "$ARCHIVE" "$IPA" "$IPA_SHA256" "$SIGNING_IDENTITY" "$ENTITLEMENTS_JSON" "$DSYM_ENTRIES" "$ASC_BUILD_ID" "$CI_RUN_URL" "$XCRESULT_PATH" "$EXPORT_STATUS" "$ARCHIVE_ONLY" "$ARCHIVE_INFO" "$IPA_INFO" <<'PYEOF'
import json
import sys

(
    output, source_sha, marketing_version, build_number, bundle_id, team_id,
    archive, ipa, ipa_sha256, signing_identity, entitlements_json,
    dsym_entries, asc_build_id, ci_run_url, xcresult_path, export_status,
    archive_only, archive_info, ipa_info,
) = sys.argv[1:]

evidence = {
    "schema_version": 1,
    "archive_only": archive_only == "1",
    "source_sha256": source_sha,
    "marketing_version": marketing_version,
    "build_number": build_number,
    "bundle_id": bundle_id,
    "team_id": team_id,
    "archive_path": archive,
    "ipa_path": ipa,
    "ipa_sha256": ipa_sha256,
    "signing_identity": signing_identity or None,
    "archive_info": json.loads(archive_info),
    "ipa_info": json.loads(ipa_info),
    "entitlements": json.loads(entitlements_json or "{}"),
    "dsym_inventory": json.loads(dsym_entries or "[]"),
    "app_store_connect_build_id": asc_build_id or None,
    "ci_run_url": ci_run_url or None,
    "xcresult_path": xcresult_path or None,
    "export_status": export_status or None,
}
with open(output, "w") as handle:
    json.dump(evidence, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(output)
PYEOF

echo "Collected release evidence for ${MARKETING_VERSION} (${BUILD_NUMBER}) at ${OUTPUT}"
