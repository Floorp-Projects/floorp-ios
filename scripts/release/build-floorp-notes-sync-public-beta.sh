#!/bin/bash
# Build and sign the explicit public-beta Notes Sync candidate.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  build-floorp-notes-sync-public-beta.sh \
    --evidence PATH --source-sha SHA --output-dir PATH --archive PATH

The evidence must be created by create-floorp-notes-sync-public-beta-evidence.py.
All generated inputs and outputs are kept outside the source worktree.
EOF
}

EVIDENCE=""
SOURCE_SHA=""
OUTPUT_DIR=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --evidence) EVIDENCE="$2"; shift 2 ;;
        --source-sha) SOURCE_SHA="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for value in EVIDENCE SOURCE_SHA OUTPUT_DIR ARCHIVE; do
    [[ -n "${!value}" ]] || { echo "missing --${value,,}" >&2; usage >&2; exit 2; }
done

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
EVIDENCE="$(/usr/bin/python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$EVIDENCE")"
OUTPUT_DIR="$(/usr/bin/python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$OUTPUT_DIR")"
ARCHIVE="$(/usr/bin/python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$ARCHIVE")"

[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "source SHA is invalid" >&2; exit 2; }
[[ -f "$EVIDENCE" ]] || { echo "evidence does not exist: $EVIDENCE" >&2; exit 2; }
[[ ! -e "$ARCHIVE" ]] || { echo "archive path already exists: $ARCHIVE" >&2; exit 2; }

actual_sha="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$actual_sha" == "$SOURCE_SHA" ]] || {
    echo "source SHA does not match worktree HEAD: $actual_sha" >&2
    exit 2
}
[[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "source worktree must be clean" >&2
    exit 2
}

evidence_values="$(/usr/bin/python3 - "$EVIDENCE" "$SOURCE_SHA" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
source_sha = sys.argv[2]
raw = path.read_bytes()
value = json.loads(raw.decode("utf-8"))
if value.get("build_contract_mode") != "public-beta":
    raise SystemExit("evidence mode is not public-beta")
ios = value.get("ios", {})
if ios.get("source_sha") != source_sha or ios.get("configuration") != "FloorpRelease":
    raise SystemExit("evidence iOS identity does not match the candidate")
build_number = ios.get("build_number")
if not isinstance(build_number, str) or re.fullmatch(r"[1-9][0-9]*", build_number) is None:
    raise SystemExit("evidence build number is invalid")
print(build_number)
print(hashlib.sha256(raw).hexdigest())
PY
)"
BUILD_NUMBER="$(printf '%s\n' "$evidence_values" | sed -n '1p')"
EVIDENCE_SHA256="$(printf '%s\n' "$evidence_values" | sed -n '2p')"

mkdir -p "$OUTPUT_DIR"
XC_CONFIG="$OUTPUT_DIR/public-beta.xcconfig"
BUILD_LOG="$OUTPUT_DIR/xcodebuild.log"
MANIFEST="$OUTPUT_DIR/public-beta-build.json"
SOURCE_PACKAGES="${SOURCE_PACKAGES:-$HOME/Library/Developer/Xcode/DerivedData/Client-cwejnsddrtpdgwbcmlapagtkoqsl/SourcePackages}"

cat > "$XC_CONFIG" <<EOF
// Generated outside the source worktree for one approved public-beta candidate.
FLOORP_BUILD_NUMBER = $BUILD_NUMBER
FLOORP_NOTES_SYNC_BUILD_MODE = public-beta
FLOORP_NOTES_SYNC_SOURCE_SHA = $SOURCE_SHA
FLOORP_NOTES_SYNC_REQUESTED = YES
FLOORP_NOTES_SYNC_EFFECTIVE = YES
FLOORP_NOTES_SYNC_FXA_SERVER = release
FLOORP_NOTES_SYNC_ENDPOINT_AUTHORITY = production
FLOORP_NOTES_SYNC_PROTOCOL = sync15
FLOORP_NOTES_SYNC_CUSTOM_FXA_OVERRIDE = NO
FLOORP_NOTES_SYNC_CUSTOM_TOKEN_SERVER_OVERRIDE = NO
FLOORP_NOTES_SYNC_ALLOWED_HOSTS = accounts.firefox.com,api.accounts.firefox.com,event-sync.services.mozilla.com,oauth.accounts.firefox.com,profile.accounts.firefox.com,static.accounts.firefox.com,sync.services.mozilla.com,token.services.mozilla.com
FLOORP_NOTES_SYNC_ENDPOINT_MATRIX_SHA256 = af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca
FLOORP_NOTES_SYNC_EVIDENCE_DIGEST = $EVIDENCE_SHA256
FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE = $EVIDENCE
FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE_SHA256 = $EVIDENCE_SHA256
DEVELOPMENT_TEAM = DV2U35YBHT
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Apple Distribution
PROVISIONING_PROFILE_SPECIFIER = Floorp App Store
EOF

set -o pipefail
xcodebuild archive \
    -project "$ROOT/firefox-ios/Client.xcodeproj" \
    -scheme Floorp \
    -configuration FloorpRelease \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -xcconfig "$XC_CONFIG" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipMacroValidation \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Apple Distribution' \
    DEVELOPMENT_TEAM=DV2U35YBHT \
    PROVISIONING_PROFILE_SPECIFIER='Floorp App Store' \
    | tee "$BUILD_LOG"

APP="$ARCHIVE/Products/Applications/Client.app"
[[ -d "$APP" ]] || { echo "archived Client.app is missing" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"

/usr/bin/python3 - "$APP" "$ARCHIVE" "$SOURCE_SHA" "$BUILD_NUMBER" "$EVIDENCE_SHA256" "$MANIFEST" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

app, archive, source_sha, build_number, evidence_sha, manifest = map(Path, sys.argv[1:])
with (app / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
expected = {
    "CFBundleIdentifier": "app.floorp.Floorp",
    "CFBundleShortVersionString": "0.2.0",
    "CFBundleVersion": build_number,
    "MozFloorpNotesSyncBuildMode": "public-beta",
    "MozFloorpNotesSyncSourceSHA": source_sha,
    "MozAllowFloorpNotesSync": "YES",
    "MozFloorpNotesSyncRegistrationAllowed": "YES",
    "MozFloorpNotesSyncEngineRequestsAllowed": "YES",
    "MozFloorpNotesSyncUIExposureAllowed": "YES",
    "MozFloorpNotesSyncEvidenceDigest": evidence_sha,
    "MozFloorpNotesSyncEvidenceResourceSHA256": evidence_sha,
}
for key, value in expected.items():
    if str(info.get(key, "")) != value:
        raise SystemExit(f"archived Info.plist mismatch for {key}: {info.get(key)!r}")
Path(manifest).write_text(json.dumps({
    "archive": str(archive),
    "bundle_id": info["CFBundleIdentifier"],
    "build_number": str(info["CFBundleVersion"]),
    "evidence_sha256": evidence_sha,
    "marketing_version": str(info["CFBundleShortVersionString"]),
    "source_sha": source_sha,
    "sync_enabled": True,
}, indent=2, sort_keys=True) + "\n")
PY

echo "public-beta archive created: $ARCHIVE"
