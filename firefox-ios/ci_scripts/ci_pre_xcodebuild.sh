#!/usr/bin/env bash

# Bind Floorp Xcode Cloud archives to the exact protected-tag source commit.

set -euo pipefail

readonly FLOORP_APP_STORE_CONNECT_TEAM_ID="74c6a531-19e2-4ed5-a34b-915003cc10f9"
readonly FLOORP_SIGNING_TEAM_ID="DV2U35YBHT"

if [[ "${CI_XCODE_SCHEME:-}" != "Floorp" || "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    echo "Skipping Floorp source binding for ${CI_XCODE_SCHEME:-unknown} ${CI_XCODEBUILD_ACTION:-unknown}."
    exit 0
fi

fail() {
    echo "Floorp source binding failed: $*" >&2
    exit 1
}

[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] \
    || fail "Floorp archives must be source-bound by Xcode Cloud"

readonly REPOSITORY_PATH="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
readonly SOURCE_SHA="${CI_COMMIT:?CI_COMMIT is required}"
readonly SOURCE_TAG="${CI_TAG:?CI_TAG is required for a Floorp archive}"
readonly SOURCE_REF="${CI_GIT_REF:?CI_GIT_REF is required for a Floorp archive}"

[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || fail "CI_COMMIT must be a lowercase 40-character Git SHA"
[[ "$SOURCE_TAG" == "floorp-catalog-${SOURCE_SHA}" ]] \
    || fail "CI_TAG must be floorp-catalog-CI_COMMIT"
[[ "$SOURCE_REF" == "refs/tags/${SOURCE_TAG}" ]] \
    || fail "CI_GIT_REF must be the canonical CI_TAG reference"
[[ "${CI_BUNDLE_ID:-}" == "app.floorp.Floorp" ]] \
    || fail "CI_BUNDLE_ID is not the Floorp release bundle"
[[ "${CI_TEAM_ID:-}" == "$FLOORP_APP_STORE_CONNECT_TEAM_ID" ]] \
    || fail "CI_TEAM_ID is not the Floorp App Store Connect team"

HEAD_SHA="$(/usr/bin/git -C "$REPOSITORY_PATH" rev-parse --verify 'HEAD^{commit}')" \
    || fail "could not resolve the checked-out Git commit"
readonly HEAD_SHA
[[ "$HEAD_SHA" == "$SOURCE_SHA" ]] \
    || fail "CI_COMMIT does not match the checked-out Git HEAD"

readonly RELEASE_CONFIGURATION="${REPOSITORY_PATH}/firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
/usr/bin/python3 - "$RELEASE_CONFIGURATION" "$SOURCE_SHA" "$FLOORP_SIGNING_TEAM_ID" <<'PYEOF'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


configuration = Path(sys.argv[1])
source_sha = sys.argv[2]
signing_team_id = sys.argv[3]
if (
    not configuration.is_file()
    or configuration.is_symlink()
    or not stat.S_ISREG(configuration.lstat().st_mode)
):
    raise SystemExit(f"release configuration is not a real regular file: {configuration}")

try:
    original = configuration.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"could not read release configuration: {error}") from error

signing_team_assignments = list(
    re.finditer(r"(?m)^FLOORP_DEVELOPMENT_TEAM[ \t]*=[ \t]*([^\r\n]*)$", original)
)
if (
    len(signing_team_assignments) != 1
    or signing_team_assignments[0].group(1).strip() != signing_team_id
):
    raise SystemExit(
        "FloorpRelease.xcconfig must contain exactly one "
        f"FLOORP_DEVELOPMENT_TEAM assignment for {signing_team_id}"
    )

assignments = list(
    re.finditer(r"(?m)^FLOORP_SOURCE_SHA[ \t]*=[ \t]*([^\r\n]*)$", original)
)
if len(assignments) != 1 or assignments[0].group(1) != "":
    raise SystemExit(
        "FloorpRelease.xcconfig must contain exactly one empty FLOORP_SOURCE_SHA assignment"
    )

match = assignments[0]
updated = original[: match.start()] + f"FLOORP_SOURCE_SHA = {source_sha}" + original[match.end() :]
descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{configuration.name}.", suffix=".tmp", dir=configuration.parent
)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary_name, stat.S_IMODE(configuration.stat().st_mode))
    os.replace(temporary_name, configuration)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PYEOF

echo "Bound Floorp archive metadata to source ${SOURCE_SHA}."
