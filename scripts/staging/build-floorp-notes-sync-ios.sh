#!/bin/bash -p
# Builds a source-bound Floorp Notes Sync artifact without changing the worktree.

set -euo pipefail

case "$-" in
    *p*) ;;
    *)
        echo "build-floorp-notes-sync-ios: invoke the executable directly or with /bin/bash -p" >&2
        exit 2
        ;;
esac

SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PYTHON_BIN="run_isolated_python"
GIT_BIN="/usr/bin/git"
TAR_BIN="/usr/bin/tar"
CHMOD_BIN="/bin/chmod"
XCODE_SELECT_BIN="/usr/bin/xcode-select"
CODESIGN_BIN="/usr/bin/codesign"
SECURITY_BIN="/usr/bin/security"
SPCTL_BIN="/usr/sbin/spctl"
TEE_BIN="/usr/bin/tee"
SHASUM_BIN="/usr/bin/shasum"
AWK_BIN="/usr/bin/awk"
FIND_BIN="/usr/bin/find"
SORT_BIN="/usr/bin/sort"

export PATH="$SYSTEM_PATH"
unset CDPATH DEVELOPER_DIR GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE SDKROOT TOOLCHAINS \
    XCODE_XCCONFIG_FILE GH_HOST HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR \
    REQUESTS_CA_BUNDLE CURL_CA_BUNDLE GIT_SSL_CAINFO GIT_SSL_CAPATH \
    GIT_SSL_NO_VERIFY GH_CONFIG_DIR GH_HTTP_UNIX_SOCKET GITHUB_API_URL \
    GITHUB_SERVER_URL NODE_EXTRA_CA_CERTS PYTHONHOME PYTHONPATH \
    PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE PYTHONWARNINGS \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR \
    GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_EXEC_PATH GIT_EXTERNAL_DIFF \
    GIT_OBJECT_DIRECTORY GIT_SSH GIT_SSH_COMMAND GIT_TEMPLATE_DIR
for variable in ${!GIT_CONFIG_@}; do
    unset "$variable"
done
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null

run_isolated_python() {
    /usr/bin/python3 -I -S "$@"
}

usage() {
    cat <<'EOF'
Usage:
  build-floorp-notes-sync-ios.sh \
    --mode production-qa|release-disabled|release-enabled \
    --source-sha SHA --output-dir PATH --manifest PATH \
    [--evidence PATH --validation-clock-manifest PATH] \
    [--schema PATH] [--endpoint-matrix PATH] \
    [--action build|archive] [--archive-path PATH] \
    [--destination DESTINATION] [--allow-signing]

Modes:
  production-qa   Requires validated G1-G4 evidence and a validation clock.
                  Uses production FxA/Sync, but refuses archive and signing.
  release-disabled
                  Builds ordinary FloorpRelease with no evidence and an
                  effective false gate. Signing is refused.
  release-enabled Requires validated G1-G5 evidence and a fresh validation
                  clock. Signing is allowed only for a generic iOS archive
                  and is verified with the Floorp release entitlements.

All generated build inputs and outputs must be outside the source worktree.
EOF
}

fail() {
    echo "build-floorp-notes-sync-ios: $*" >&2
    exit 2
}

MODE=""
SOURCE_SHA=""
OUTPUT_DIR=""
MANIFEST=""
EVIDENCE=""
VALIDATION_CLOCK=""
SCHEMA=""
ENDPOINT_MATRIX=""
ACTION="build"
ARCHIVE_PATH=""
DESTINATION=""
DESTINATION_SET=0
ALLOW_SIGNING=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --source-sha) SOURCE_SHA="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --evidence) EVIDENCE="$2"; shift 2 ;;
        --validation-clock-manifest) VALIDATION_CLOCK="$2"; shift 2 ;;
        --schema) SCHEMA="$2"; shift 2 ;;
        --endpoint-matrix) ENDPOINT_MATRIX="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        --archive-path) ARCHIVE_PATH="$2"; shift 2 ;;
        --destination) DESTINATION="$2"; DESTINATION_SET=1; shift 2 ;;
        --allow-signing) ALLOW_SIGNING=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

for required in MODE SOURCE_SHA OUTPUT_DIR MANIFEST; do
    [[ -n "${!required}" ]] || fail "missing required argument for ${required}"
done

case "$MODE" in
    production-qa|release-disabled|release-enabled) ;;
    *) fail "unsupported mode: $MODE" ;;
esac
case "$ACTION" in
    build|archive) ;;
    *) fail "unsupported action: $ACTION" ;;
esac
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "source-sha must be a lowercase 40-character Git SHA"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)"
VALIDATOR_SOURCE="$ROOT/scripts/ci/validate-floorp-notes-sync-release.py"
VALIDATOR="$VALIDATOR_SOURCE"
VALIDATOR_FIXTURE_SOURCE="$ROOT/sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
VALIDATOR_BUILD_CONFIGURATION_SOURCE="$ROOT/firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
SCHEMA="${SCHEMA:-$ROOT/docs/floorp-notes-sync-release-evidence.schema.json}"
ENDPOINT_MATRIX="${ENDPOINT_MATRIX:-$ROOT/docs/floorp-release-endpoints.json}"
PIN="$ROOT/MozillaRustComponents/FloorpApplicationServicesPin.json"
GENERATED_BINDING="$ROOT/MozillaRustComponents/Sources/MozillaRustComponentsWrapper/Generated/floorp_prefs_sync.swift"
ENTITLEMENTS_SOURCE="$ROOT/firefox-ios/Client/Entitlements/FloorpReleaseApplication.entitlements"
PROJECT="$ROOT/firefox-ios/Client.xcodeproj"

absolute_path() {
    "$PYTHON_BIN" - "$1" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
MANIFEST="$(absolute_path "$MANIFEST")"
[[ -z "$EVIDENCE" ]] || EVIDENCE="$(absolute_path "$EVIDENCE")"
[[ -z "$VALIDATION_CLOCK" ]] || VALIDATION_CLOCK="$(absolute_path "$VALIDATION_CLOCK")"
SCHEMA="$(absolute_path "$SCHEMA")"
ENDPOINT_MATRIX="$(absolute_path "$ENDPOINT_MATRIX")"

"$PYTHON_BIN" - "$ROOT" "$OUTPUT_DIR" "$MANIFEST" <<'PY' || exit $?
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
for label, raw in (("output-dir", sys.argv[2]), ("manifest", sys.argv[3])):
    path = pathlib.Path(raw).resolve()
    try:
        common = pathlib.Path(os.path.commonpath((root, path)))
    except ValueError:
        common = None
    if common == root:
        print(
            f"build-floorp-notes-sync-ios: {label} must be outside the source worktree",
            file=sys.stderr,
        )
        raise SystemExit(2)
PY

[[ ! -e "$MANIFEST" && ! -L "$MANIFEST" ]] \
    || fail "manifest already exists; build manifests are append-only: $MANIFEST"

if [[ "$MODE" == "production-qa" ]]; then
    [[ "$ACTION" == "build" ]] || fail "production-qa refuses archive actions"
    [[ "$ALLOW_SIGNING" -eq 0 ]] || fail "production-qa refuses signing"
fi
if [[ "$MODE" == "release-disabled" ]]; then
    [[ -z "$EVIDENCE" && -z "$VALIDATION_CLOCK" ]] \
        || fail "release-disabled refuses evidence and validation-clock inputs"
else
    [[ -n "$EVIDENCE" ]] || fail "$MODE requires --evidence"
    [[ -n "$VALIDATION_CLOCK" ]] || fail "$MODE requires --validation-clock-manifest"
fi
if [[ "$ACTION" == "build" && -n "$ARCHIVE_PATH" ]]; then
    fail "--archive-path is only valid with --action archive"
fi
if [[ "$ACTION" == "archive" ]]; then
    ARCHIVE_PATH="${ARCHIVE_PATH:-$OUTPUT_DIR/FloorpNotesSync.xcarchive}"
    ARCHIVE_PATH="$(absolute_path "$ARCHIVE_PATH")"
    "$PYTHON_BIN" - "$ROOT" "$ARCHIVE_PATH" <<'PY' || exit $?
import os
import pathlib
import sys
root, archive = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:])
if pathlib.Path(os.path.commonpath((root, archive))) == root:
    print("build-floorp-notes-sync-ios: archive must be outside the source worktree", file=sys.stderr)
    raise SystemExit(2)
PY
fi

DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"
if [[ "$ACTION" == "archive" && "$DESTINATION_SET" -eq 0 ]]; then
    DESTINATION="generic/platform=iOS"
fi
if [[ "$ALLOW_SIGNING" -eq 1 ]]; then
    [[ "$MODE" == "release-enabled" && "$ACTION" == "archive" ]] \
        || fail "--allow-signing requires a release-enabled archive"
    [[ "$DESTINATION" == "generic/platform=iOS" ]] \
        || fail "--allow-signing requires destination generic/platform=iOS"
fi

for path in "$ENDPOINT_MATRIX" "$PIN" "$GENERATED_BINDING" "$ENTITLEMENTS_SOURCE" "$PROJECT"; do
    [[ -e "$path" ]] || fail "required build-contract input is missing: $path"
done
if [[ "$MODE" != "release-disabled" ]]; then
    for path in "$VALIDATOR_SOURCE" "$VALIDATOR_FIXTURE_SOURCE" \
        "$VALIDATOR_BUILD_CONFIGURATION_SOURCE" "$SCHEMA"; do
        [[ -e "$path" ]] || fail "required build-contract input is missing: $path"
    done
fi
[[ -z "$EVIDENCE" || -f "$EVIDENCE" ]] || fail "evidence does not exist: $EVIDENCE"
[[ -z "$VALIDATION_CLOCK" || -f "$VALIDATION_CLOCK" ]] \
    || fail "validation clock does not exist: $VALIDATION_CLOCK"

ACTUAL_HEAD="$("$GIT_BIN" -C "$ROOT" rev-parse HEAD)"
ACTUAL_TREE="$("$GIT_BIN" -C "$ROOT" rev-parse 'HEAD^{tree}')"
[[ "$ACTUAL_HEAD" == "$SOURCE_SHA" ]] \
    || fail "source-sha $SOURCE_SHA does not match worktree HEAD $ACTUAL_HEAD"
SOURCE_STATUS_BEFORE="$("$GIT_BIN" -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
[[ -z "$SOURCE_STATUS_BEFORE" ]] || fail "source worktree must be clean before building"

"$PYTHON_BIN" - "$OUTPUT_DIR" "$MANIFEST" "$ACTION" "$ARCHIVE_PATH" <<'PY' || exit $?
import os
import stat
import sys
from pathlib import Path

output = Path(sys.argv[1])
manifest = Path(sys.argv[2])
action = sys.argv[3]
archive = Path(sys.argv[4]) if sys.argv[4] else None


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def private_parent(path, label):
    try:
        parent = path.parent.resolve(strict=True)
        metadata = parent.stat()
    except OSError as error:
        reject(f"{label} parent is unavailable ({error})")
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        reject(f"{label} parent must be an owned directory")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        reject(f"{label} parent must not be group/world writable")
    return parent


output_parent = private_parent(output, "output-dir")
if os.path.lexists(output):
    reject("output-dir must not already exist")
try:
    os.mkdir(output, 0o700)
except OSError as error:
    reject(f"output-dir could not be created exclusively ({error})")
metadata = output.lstat()
if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
    reject("output-dir was replaced during creation")
if stat.S_IMODE(metadata.st_mode) != 0o700:
    reject("output-dir permissions are not private")
descriptor = os.open(output_parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)

private_parent(manifest, "manifest")
if action == "archive" and archive is not None:
    private_parent(archive, "archive")
    if os.path.lexists(archive):
        reject("archive path must not already exist")
PY
CONTRACT_DIR="$OUTPUT_DIR/contract-inputs"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
TOOL_STATE="$OUTPUT_DIR/tool-state"
GLEAN_VENV="$TOOL_STATE/glean-venv"
GLEAN_VERIFY_ROOT="$TOOL_STATE/verify"
BUILD_LOG="$OUTPUT_DIR/xcodebuild.log"
SOURCE_ARCHIVE="$OUTPUT_DIR/source-$SOURCE_SHA.tar"
SOURCE_SNAPSHOT="$OUTPUT_DIR/source-$SOURCE_SHA"
SOURCE_SNAPSHOT_RECORD="$CONTRACT_DIR/source-snapshot.json"
GENERATED_SOURCE_RECORD="$CONTRACT_DIR/generated-source-inputs.json"
PREFLIGHT="$CONTRACT_DIR/preflight.json"
XC_CONFIG="$CONTRACT_DIR/FloorpNotesSyncBuild.xcconfig"
COMMAND_JSON="$CONTRACT_DIR/xcodebuild-command.json"
XCODE_VERSION_FILE="$CONTRACT_DIR/xcode-version.txt"
TOOLCHAIN_RECORD="$CONTRACT_DIR/xcode-toolchain.json"
EVIDENCE_RESOURCE=""
EVIDENCE_SNAPSHOT=""
VALIDATION_CLOCK_SNAPSHOT=""
SCHEMA_SNAPSHOT=""
VALIDATOR_SNAPSHOT=""
VALIDATOR_FIXTURE_SNAPSHOT=""
VALIDATOR_ENDPOINT_SNAPSHOT=""
VALIDATOR_BUILD_CONFIGURATION_SNAPSHOT=""
SNAPSHOT_RECORD=""
SNAPSHOT_RECORD_SHA256=""
LOCAL_SNAPSHOT_RECORD=""
LOCAL_SNAPSHOT_RECORD_SHA256=""
mkdir -p "$CONTRACT_DIR"

mkdir -p "$SOURCE_SNAPSHOT"
"$GIT_BIN" -C "$ROOT" archive --format=tar --output="$SOURCE_ARCHIVE" "$SOURCE_SHA"
ARCHIVED_COMMIT="$("$GIT_BIN" get-tar-commit-id < "$SOURCE_ARCHIVE")"
[[ "$ARCHIVED_COMMIT" == "$SOURCE_SHA" ]] \
    || fail "source archive is not bound to the requested commit"
"$PYTHON_BIN" - "$SOURCE_ARCHIVE" <<'PY'
import os
import sys
import tarfile


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


archive_path = sys.argv[1]
try:
    opened = tarfile.open(archive_path, mode="r:")
except (OSError, tarfile.TarError) as error:
    reject(f"source archive cannot be audited ({error})")
observed: set[str] = set()
with opened:
    for member in opened:
        name = member.name
        if member.isdir() and name.endswith("/"):
            name = name[:-1]
        if not name or name == "." or name.endswith("/."):
            reject(f"source archive member has an unsafe name: {name!r}")
        if name.startswith("/") or name.startswith("\\") or "\\" in name:
            reject(f"source archive member has an absolute path: {name}")
        parts = name.split("/")
        if any(part in ("", ".", "..") for part in parts):
            reject(f"source archive member escapes the snapshot: {name}")
        if member.issym():
            reject(f"source archive contains a symlink member: {name}")
        if member.islnk():
            reject(f"source archive contains a hardlink member: {name}")
        if not (member.isreg() or member.isdir()):
            reject(f"source archive contains a special-file member: {name}")
        if name in observed:
            reject(f"source archive contains a duplicate member: {name}")
        observed.add(name)
PY
"$TAR_BIN" -xf "$SOURCE_ARCHIVE" -C "$SOURCE_SNAPSHOT"
GENERATED_SOURCE_PREPARER="$SOURCE_SNAPSHOT/scripts/staging/prepare-floorp-ios-source-snapshot.py"
[[ -f "$GENERATED_SOURCE_PREPARER" ]] \
    || fail "exact-commit generated-source preparer is missing"
"$PYTHON_BIN" "$GENERATED_SOURCE_PREPARER" prepare \
    --source-root "$SOURCE_SNAPSHOT" \
    --source-archive "$SOURCE_ARCHIVE" \
    --source-sha "$SOURCE_SHA" \
    --output-root "$OUTPUT_DIR" \
    --tool-state "$TOOL_STATE" \
    --output "$GENERATED_SOURCE_RECORD"
GENERATED_SOURCE_DIGEST="$("$SHASUM_BIN" -a 256 "$GENERATED_SOURCE_RECORD" | "$AWK_BIN" '{print $1}')"
"$CHMOD_BIN" -R a-w "$SOURCE_SNAPSHOT"

SOURCE_SNAPSHOT_DIGEST="$("$PYTHON_BIN" - "$SOURCE_SNAPSHOT" "$SOURCE_ARCHIVE" \
    "$SOURCE_SNAPSHOT_RECORD" "$SOURCE_SHA" "$ACTUAL_TREE" \
    "$GENERATED_SOURCE_RECORD" "$GENERATED_SOURCE_DIGEST" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
archive = Path(sys.argv[2]).resolve(strict=True)
record_path = Path(sys.argv[3]).resolve(strict=False)
source_sha, source_tree, generated_record, generated_digest = sys.argv[4:]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


tree_digest = hashlib.sha256()
file_count = 0
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    names.sort()
    files.sort()
    directory_path = Path(directory)
    for name in [*names, *files]:
        path = directory_path / name
        metadata = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(metadata.st_mode):
            reject(f"source snapshot contains a symlink: {relative}")
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            reject(f"source snapshot contains a special file: {relative}")
        if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            reject(f"source snapshot is writable: {relative}")
        if stat.S_ISREG(metadata.st_mode):
            executable = bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
            row = f"F\0{relative}\0{int(executable)}\0{metadata.st_size}\0{file_digest(path)}\n"
            tree_digest.update(row.encode("utf-8"))
            file_count += 1

archive_digest = file_digest(archive)
record = {
    "archive_path": str(archive),
    "archive_sha256": archive_digest,
    "commit": source_sha,
    "file_count": file_count,
    "generated_source_inputs": {
        "path": str(Path(generated_record).resolve(strict=True)),
        "sha256": generated_digest,
    },
    "read_only": True,
    "snapshot_path": str(root),
    "snapshot_tree_sha256": tree_digest.hexdigest(),
    "tree": source_tree,
}
payload = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
try:
    descriptor = os.open(
        record_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
except FileExistsError:
    reject("source snapshot record already exists")
try:
    os.write(descriptor, payload)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
print(tree_digest.hexdigest())
PY
)"

verify_source_snapshot() {
    "$PYTHON_BIN" - "$SOURCE_SNAPSHOT" "$SOURCE_ARCHIVE" "$SOURCE_SNAPSHOT_RECORD" \
        "$SOURCE_SNAPSHOT_DIGEST" "$GENERATED_SOURCE_RECORD" \
        "$GENERATED_SOURCE_DIGEST" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
archive = Path(sys.argv[2]).resolve(strict=True)
record_path = Path(sys.argv[3]).resolve(strict=True)
expected_tree_digest = sys.argv[4]
generated_record_path = Path(sys.argv[5]).resolve(strict=True)
expected_generated_digest = sys.argv[6]
record = json.loads(record_path.read_text())


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


if file_digest(archive) != record.get("archive_sha256"):
    reject("source archive changed after exact-commit extraction")
if file_digest(generated_record_path) != expected_generated_digest:
    reject("generated-source manifest changed after preparation")
if record.get("generated_source_inputs") != {
    "path": str(generated_record_path),
    "sha256": expected_generated_digest,
}:
    reject("source snapshot record does not bind generated-source inputs")
tree_digest = hashlib.sha256()
file_count = 0
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    names.sort()
    files.sort()
    directory_path = Path(directory)
    for name in [*names, *files]:
        path = directory_path / name
        metadata = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(metadata.st_mode):
            reject(f"source snapshot contains a symlink: {relative}")
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            reject(f"source snapshot contains a special file: {relative}")
        if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            reject(f"source snapshot became writable: {relative}")
        if stat.S_ISREG(metadata.st_mode):
            executable = bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
            row = f"F\0{relative}\0{int(executable)}\0{metadata.st_size}\0{file_digest(path)}\n"
            tree_digest.update(row.encode("utf-8"))
            file_count += 1
if tree_digest.hexdigest() != expected_tree_digest:
    reject("source snapshot content changed during the build")
if file_count != record.get("file_count"):
    reject("source snapshot file count changed during the build")
PY
    "$PYTHON_BIN" "$GENERATED_SOURCE_PREPARER" verify \
        --source-root "$SOURCE_SNAPSHOT" \
        --manifest "$GENERATED_SOURCE_RECORD" \
        --source-sha "$SOURCE_SHA" \
        --source-archive "$SOURCE_ARCHIVE"
}

DEFAULT_SCHEMA="$ROOT/docs/floorp-notes-sync-release-evidence.schema.json"
DEFAULT_ENDPOINT_MATRIX="$ROOT/docs/floorp-release-endpoints.json"
[[ "$SCHEMA" != "$DEFAULT_SCHEMA" ]] \
    || SCHEMA="$SOURCE_SNAPSHOT/docs/floorp-notes-sync-release-evidence.schema.json"
[[ "$ENDPOINT_MATRIX" != "$DEFAULT_ENDPOINT_MATRIX" ]] \
    || ENDPOINT_MATRIX="$SOURCE_SNAPSHOT/docs/floorp-release-endpoints.json"
VALIDATOR_SOURCE="$SOURCE_SNAPSHOT/scripts/ci/validate-floorp-notes-sync-release.py"
VALIDATOR_FIXTURE_SOURCE="$SOURCE_SNAPSHOT/sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
VALIDATOR_BUILD_CONFIGURATION_SOURCE="$SOURCE_SNAPSHOT/firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
CLOCK_CLIENT="$SOURCE_SNAPSHOT/scripts/ci/create-floorp-validation-clock.sh"
PIN="$SOURCE_SNAPSHOT/MozillaRustComponents/FloorpApplicationServicesPin.json"
GENERATED_BINDING="$SOURCE_SNAPSHOT/MozillaRustComponents/Sources/MozillaRustComponentsWrapper/Generated/floorp_prefs_sync.swift"
ENTITLEMENTS_SOURCE="$SOURCE_SNAPSHOT/firefox-ios/Client/Entitlements/FloorpReleaseApplication.entitlements"
PROJECT="$SOURCE_SNAPSHOT/firefox-ios/Client.xcodeproj"

for path in "$ENDPOINT_MATRIX" "$PIN" "$GENERATED_BINDING" "$ENTITLEMENTS_SOURCE" "$PROJECT"; do
    [[ -e "$path" ]] || fail "exact-commit build input is missing: $path"
done
if [[ "$MODE" != "release-disabled" ]]; then
    for path in "$VALIDATOR_SOURCE" "$VALIDATOR_FIXTURE_SOURCE" \
        "$VALIDATOR_BUILD_CONFIGURATION_SOURCE" "$SCHEMA" "$CLOCK_CLIENT"; do
        [[ -e "$path" ]] || fail "exact-commit release input is missing: $path"
    done
fi
verify_source_snapshot

local_artifact_snapshot() {
    "$PYTHON_BIN" - "$@" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

MAX_LOCAL_SOURCES = 80
MAX_LOCAL_FILE_SIZE = 32 * 1024 * 1024
MAX_XCRESULT_FILES = 200_000
MAX_XCRESULT_DIRECTORIES = 200_000
MAX_XCRESULT_BYTES = 4 * 1024 * 1024 * 1024
MAX_XCRESULT_DEPTH = 128
MAX_XCRESULT_RELATIVE_PATH_BYTES = 4096
SECRET_MARKERS = (
    b"authorization: bearer",
    b"access_token",
    b"refresh_token",
    b"raw_sync_key",
)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)
DIRECTORY = getattr(os, "O_DIRECTORY", 0)
NONBLOCK = getattr(os, "O_NONBLOCK", 0)


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def canonical_bytes(value):
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        return str(value).encode("ascii")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    if isinstance(value, list):
        return b"[" + b",".join(canonical_bytes(item) for item in value) + b"]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return b"{" + b",".join(
            canonical_bytes(key) + b":" + canonical_bytes(value[key]) for key in keys
        ) + b"}"
    reject(f"local artifact record contains unsupported {type(value).__name__}")


def digest(value):
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject(f"release evidence contains duplicate key {key}")
        result[key] = value
    return result


def relative_parts(value, label):
    if not isinstance(value, str) or not value or len(value) > 1024:
        reject(f"{label}: local artifact path is empty or too long")
    if value.startswith("/") or re.fullmatch(r"[A-Za-z0-9._/-]+", value) is None:
        reject(f"{label}: local artifact path is unsafe")
    parts = tuple(value.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        reject(f"{label}: local artifact path is unsafe")
    return parts


def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        offset += os.write(descriptor, payload[offset:])


def safe_destination_parent(root, parts):
    current = root
    for part in parts:
        current = current / part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        mode = current.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            reject(f"local artifact destination is not a safe directory: {current}")
    return current


def open_relative(base_descriptor, parts, *, directory, label):
    current = os.dup(base_descriptor)
    try:
        for part in parts[:-1]:
            next_descriptor = os.open(
                part,
                os.O_RDONLY | DIRECTORY | NOFOLLOW | CLOEXEC,
                dir_fd=current,
            )
            metadata = os.fstat(next_descriptor)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(next_descriptor)
                reject(f"{label}: local artifact parent is not a directory")
            os.close(current)
            current = next_descriptor
        flags = os.O_RDONLY | NOFOLLOW | CLOEXEC
        if directory:
            flags |= DIRECTORY
        else:
            flags |= NONBLOCK
        target = os.open(parts[-1], flags, dir_fd=current)
    except OSError as error:
        reject(f"{label}: local artifact cannot be opened safely ({error})")
    finally:
        os.close(current)
    metadata = os.fstat(target)
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(metadata.st_mode):
        os.close(target)
        reject(f"{label}: local artifact has the wrong filesystem type")
    return target


def copy_or_hash_file(
    source_descriptor,
    *,
    destination=None,
    maximum_size,
    scan_secrets=False,
    require_read_only=False,
    label,
):
    before = os.fstat(source_descriptor)
    if not stat.S_ISREG(before.st_mode):
        reject(f"{label}: local artifact is not a regular file")
    if before.st_size > maximum_size:
        reject(f"{label}: local artifact exceeds the bounded size")
    if require_read_only and before.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
        reject(f"{label}: local artifact snapshot became writable")
    destination_descriptor = None
    if destination is not None:
        try:
            destination_descriptor = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC,
                0o400,
            )
        except OSError as error:
            reject(f"{label}: local artifact snapshot target is unsafe ({error})")
    hasher = hashlib.sha256()
    secret_tail = b""
    maximum_marker_length = max(map(len, SECRET_MARKERS))
    size = 0
    try:
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > maximum_size:
                reject(f"{label}: local artifact exceeds the bounded size")
            hasher.update(chunk)
            if scan_secrets:
                scan_window = (secret_tail + chunk).lower()
                if any(marker in scan_window for marker in SECRET_MARKERS):
                    reject(f"{label}: .xcresult contains forbidden secret metadata")
                secret_tail = scan_window[-(maximum_marker_length - 1):]
            if destination_descriptor is not None:
                write_all(destination_descriptor, chunk)
        after = os.fstat(source_descriptor)
        if identity(before) != identity(after) or size != before.st_size:
            reject(f"{label}: local artifact changed while it was snapshotted")
        if destination_descriptor is not None:
            os.fsync(destination_descriptor)
            os.fchmod(destination_descriptor, 0o400)
    except BaseException:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
            try:
                Path(destination).unlink()
            except OSError:
                pass
            destination_descriptor = None
        raise
    finally:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
    return hasher.hexdigest(), size


def scan_xcresult(source_descriptor, *, destination, label, require_read_only):
    files = []
    directories = 0
    total_size = 0
    seen_directories = set()

    def walk(directory_descriptor, relative_parts_value, destination_directory, depth):
        nonlocal directories, total_size
        if depth > MAX_XCRESULT_DEPTH:
            reject(f"{label}: .xcresult exceeds the bounded directory depth")
        before = os.fstat(directory_descriptor)
        if not stat.S_ISDIR(before.st_mode):
            reject(f"{label}: .xcresult contains a non-directory")
        directory_identity = (before.st_dev, before.st_ino)
        if directory_identity in seen_directories:
            reject(f"{label}: .xcresult contains a directory cycle")
        seen_directories.add(directory_identity)
        directories += 1
        if directories > MAX_XCRESULT_DIRECTORIES:
            reject(f"{label}: .xcresult has too many directories")
        if require_read_only and before.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            reject(f"{label}: .xcresult snapshot became writable")
        try:
            entries = sorted(list(os.scandir(directory_descriptor)), key=lambda entry: entry.name)
            for entry in entries:
                child_parts = (*relative_parts_value, entry.name)
                relative = "/".join(child_parts)
                if len(relative.encode("utf-8")) > MAX_XCRESULT_RELATIVE_PATH_BYTES:
                    reject(f"{label}: .xcresult relative path is too long")
                lowered_parts = {part.lower() for part in child_parts}
                if lowered_parts.intersection({"attachments", "screenshots"}):
                    reject(f"{label}: .xcresult contains content-bearing attachments")
                listed = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(listed.st_mode):
                    reject(f"{label}: .xcresult contains a symlink")
                if stat.S_ISDIR(listed.st_mode):
                    try:
                        child_descriptor = os.open(
                            entry.name,
                            os.O_RDONLY | DIRECTORY | NOFOLLOW | CLOEXEC,
                            dir_fd=directory_descriptor,
                        )
                    except OSError as error:
                        reject(f"{label}: .xcresult directory changed while opening ({error})")
                    opened = os.fstat(child_descriptor)
                    if (listed.st_dev, listed.st_ino) != (opened.st_dev, opened.st_ino):
                        os.close(child_descriptor)
                        reject(f"{label}: .xcresult directory changed while opening")
                    child_destination = None
                    if destination_directory is not None:
                        child_destination = destination_directory / entry.name
                        try:
                            child_destination.mkdir(mode=0o700)
                        except OSError as error:
                            os.close(child_descriptor)
                            reject(f"{label}: .xcresult destination is unsafe ({error})")
                    try:
                        walk(child_descriptor, child_parts, child_destination, depth + 1)
                    finally:
                        os.close(child_descriptor)
                    if child_destination is not None:
                        os.chmod(child_destination, 0o500)
                elif stat.S_ISREG(listed.st_mode):
                    if len(files) >= MAX_XCRESULT_FILES:
                        reject(f"{label}: .xcresult has too many files")
                    try:
                        child_descriptor = os.open(
                            entry.name,
                            os.O_RDONLY | NOFOLLOW | CLOEXEC | NONBLOCK,
                            dir_fd=directory_descriptor,
                        )
                    except OSError as error:
                        reject(f"{label}: .xcresult file changed while opening ({error})")
                    opened = os.fstat(child_descriptor)
                    if (listed.st_dev, listed.st_ino) != (opened.st_dev, opened.st_ino):
                        os.close(child_descriptor)
                        reject(f"{label}: .xcresult file changed while opening")
                    child_destination = (
                        destination_directory / entry.name
                        if destination_directory is not None
                        else None
                    )
                    try:
                        file_sha256, size = copy_or_hash_file(
                            child_descriptor,
                            destination=child_destination,
                            maximum_size=MAX_XCRESULT_BYTES - total_size,
                            scan_secrets=True,
                            require_read_only=require_read_only,
                            label=f"{label}:{relative}",
                        )
                    finally:
                        os.close(child_descriptor)
                    total_size += size
                    if total_size > MAX_XCRESULT_BYTES:
                        reject(f"{label}: .xcresult exceeds the bounded total size")
                    files.append({"path": relative, "sha256": file_sha256, "size": size})
                else:
                    reject(f"{label}: .xcresult contains a special file")
            after = os.fstat(directory_descriptor)
            if identity(before) != identity(after):
                reject(f"{label}: .xcresult changed while it was snapshotted")
        finally:
            seen_directories.remove(directory_identity)

    walk(source_descriptor, (), destination, 0)
    files.sort(key=lambda item: item["path"])
    paths = {item["path"] for item in files}
    if "Info.plist" not in paths or not any(path.startswith("Data/") for path in paths):
        reject(f"{label}: .xcresult is missing Info.plist or Data contents")
    if not files:
        reject(f"{label}: .xcresult contains no files")
    return digest({"files": files}), len(files), directories, total_size


def local_descriptors(evidence_path):
    try:
        evidence = json.loads(
            evidence_path.read_text(),
            object_pairs_hook=unique_object,
            parse_constant=lambda value: reject(f"release evidence contains {value}"),
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        reject(f"release evidence cannot be parsed for local artifact snapshotting ({error})")
    gates = evidence.get("gates") if isinstance(evidence, dict) else None
    if not isinstance(gates, dict):
        reject("release evidence gates are unavailable for local artifact snapshotting")
    descriptors = []
    for gate_name, gate in gates.items():
        if not isinstance(gate, dict):
            continue
        artifact = gate.get("artifact")
        if not isinstance(artifact, dict):
            continue
        sources = artifact.get("sources", [])
        if not isinstance(sources, list) or len(sources) > 16:
            reject(f"{gate_name}: artifact sources are malformed")
        for index, source in enumerate(sources):
            if not isinstance(source, dict) or source.get("kind") not in (
                "local-file",
                "local-directory",
            ):
                continue
            label = f"{gate_name}.artifact.sources[{index}]"
            path = source.get("path")
            parts = relative_parts(path, label)
            sha256 = source.get("sha256")
            if not isinstance(sha256, str) or re.fullmatch(r"[0-9a-f]{64}", sha256) is None:
                reject(f"{label}: local artifact SHA-256 is malformed")
            if source["kind"] == "local-directory":
                if source.get("content_policy") != "test-result-bundle" or not path.endswith(
                    ".xcresult"
                ):
                    reject(f"{label}: local directory must be a test-result .xcresult")
            descriptors.append(
                {
                    "kind": source["kind"],
                    "label": label,
                    "parts": parts,
                    "path": path,
                    "sha256": sha256,
                }
            )
    if len(descriptors) > MAX_LOCAL_SOURCES:
        reject("release evidence references too many local artifacts")
    paths = [descriptor["path"] for descriptor in descriptors]
    if len(paths) != len(set(paths)):
        reject("release evidence contains duplicate local artifact paths")
    return sorted(descriptors, key=lambda item: item["path"])


LIMITS = {
    "local_file_bytes": MAX_LOCAL_FILE_SIZE,
    "local_sources": MAX_LOCAL_SOURCES,
    "xcresult_bytes": MAX_XCRESULT_BYTES,
    "xcresult_depth": MAX_XCRESULT_DEPTH,
    "xcresult_directories": MAX_XCRESULT_DIRECTORIES,
    "xcresult_files": MAX_XCRESULT_FILES,
    "xcresult_relative_path_bytes": MAX_XCRESULT_RELATIVE_PATH_BYTES,
}


operation = sys.argv[1]
if operation == "create":
    descriptor_evidence = Path(sys.argv[2]).resolve(strict=True)
    source_base = Path(sys.argv[3]).resolve(strict=True)
    snapshot_root = Path(sys.argv[4]).resolve(strict=True)
    record_path = Path(sys.argv[5]).resolve(strict=False)
    try:
        record_path.relative_to(snapshot_root)
    except ValueError:
        reject("local artifact snapshot record escaped the snapshot root")
    source_base_descriptor = os.open(source_base, os.O_RDONLY | DIRECTORY | NOFOLLOW | CLOEXEC)
    items = []
    try:
        for descriptor in local_descriptors(descriptor_evidence):
            label = descriptor["label"]
            parts = descriptor["parts"]
            safe_destination_parent(snapshot_root, parts[:-1])
            destination = snapshot_root.joinpath(*parts)
            if descriptor["kind"] == "local-file":
                source_descriptor = open_relative(
                    source_base_descriptor,
                    parts,
                    directory=False,
                    label=label,
                )
                try:
                    sha256, size = copy_or_hash_file(
                        source_descriptor,
                        destination=destination,
                        maximum_size=MAX_LOCAL_FILE_SIZE,
                        label=label,
                    )
                finally:
                    os.close(source_descriptor)
                if sha256 != descriptor["sha256"]:
                    reject(f"{label}: local artifact bytes do not match evidence SHA-256")
                item = {
                    "kind": descriptor["kind"],
                    "path": descriptor["path"],
                    "sha256": sha256,
                    "size": size,
                    "snapshot_path": str(destination),
                    "source_path": str(source_base.joinpath(*parts)),
                }
            else:
                source_descriptor = open_relative(
                    source_base_descriptor,
                    parts,
                    directory=True,
                    label=label,
                )
                try:
                    destination.mkdir(mode=0o700)
                except OSError as error:
                    os.close(source_descriptor)
                    reject(f"{label}: local directory snapshot target is unsafe ({error})")
                try:
                    sha256, file_count, directory_count, total_size = scan_xcresult(
                        source_descriptor,
                        destination=destination,
                        label=label,
                        require_read_only=False,
                    )
                finally:
                    os.close(source_descriptor)
                os.chmod(destination, 0o500)
                if sha256 != descriptor["sha256"]:
                    reject(f"{label}: local directory tree does not match evidence SHA-256")
                item = {
                    "directory_count": directory_count,
                    "file_count": file_count,
                    "kind": descriptor["kind"],
                    "path": descriptor["path"],
                    "sha256": sha256,
                    "snapshot_path": str(destination),
                    "source_path": str(source_base.joinpath(*parts)),
                    "total_size": total_size,
                }
            items.append(item)
    finally:
        os.close(source_base_descriptor)
    record = {
        "descriptor_evidence_path": str(descriptor_evidence),
        "items": items,
        "limits": LIMITS,
        "schema_version": 1,
        "snapshot_root": str(snapshot_root),
        "source_evidence_directory": str(source_base),
    }
    payload = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    try:
        descriptor = os.open(
            record_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC,
            0o400,
        )
    except OSError as error:
        reject(f"local artifact snapshot record target is unsafe ({error})")
    try:
        write_all(descriptor, payload)
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o400)
    finally:
        os.close(descriptor)
    root_descriptor = os.open(snapshot_root, os.O_RDONLY | DIRECTORY | NOFOLLOW | CLOEXEC)
    try:
        os.fsync(root_descriptor)
    finally:
        os.close(root_descriptor)
    print(hashlib.sha256(payload).hexdigest())
elif operation == "verify":
    snapshot_root = Path(sys.argv[2]).resolve(strict=True)
    record_path = Path(sys.argv[3]).resolve(strict=True)
    expected_record_digest = sys.argv[4]
    record_bytes = record_path.read_bytes()
    if hashlib.sha256(record_bytes).hexdigest() != expected_record_digest:
        reject("local artifact snapshot record changed")
    try:
        record = json.loads(record_bytes, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        reject(f"local artifact snapshot record is malformed ({error})")
    if record.get("limits") != LIMITS or record.get("snapshot_root") != str(snapshot_root):
        reject("local artifact snapshot record contract changed")
    items = record.get("items")
    if not isinstance(items, list) or len(items) > MAX_LOCAL_SOURCES:
        reject("local artifact snapshot record item set is malformed")
    root_descriptor = os.open(snapshot_root, os.O_RDONLY | DIRECTORY | NOFOLLOW | CLOEXEC)
    try:
        observed_paths = set()
        for item in items:
            if not isinstance(item, dict):
                reject("local artifact snapshot record item is malformed")
            kind = item.get("kind")
            path = item.get("path")
            parts = relative_parts(path, "local artifact snapshot record")
            if path in observed_paths:
                reject("local artifact snapshot record has duplicate paths")
            observed_paths.add(path)
            expected_path = snapshot_root.joinpath(*parts)
            if item.get("snapshot_path") != str(expected_path):
                reject("local artifact snapshot path changed")
            if kind == "local-file":
                source_descriptor = open_relative(
                    root_descriptor,
                    parts,
                    directory=False,
                    label=path,
                )
                try:
                    sha256, size = copy_or_hash_file(
                        source_descriptor,
                        maximum_size=MAX_LOCAL_FILE_SIZE,
                        require_read_only=True,
                        label=path,
                    )
                finally:
                    os.close(source_descriptor)
                if sha256 != item.get("sha256") or size != item.get("size"):
                    reject(f"{path}: local artifact snapshot changed")
            elif kind == "local-directory":
                source_descriptor = open_relative(
                    root_descriptor,
                    parts,
                    directory=True,
                    label=path,
                )
                try:
                    sha256, file_count, directory_count, total_size = scan_xcresult(
                        source_descriptor,
                        destination=None,
                        label=path,
                        require_read_only=True,
                    )
                finally:
                    os.close(source_descriptor)
                if (
                    sha256 != item.get("sha256")
                    or file_count != item.get("file_count")
                    or directory_count != item.get("directory_count")
                    or total_size != item.get("total_size")
                ):
                    reject(f"{path}: local directory snapshot changed")
            else:
                reject("local artifact snapshot record has an unexpected kind")
    finally:
        os.close(root_descriptor)
else:
    reject("local artifact snapshot operation is unsupported")
PY
}

if [[ "$MODE" != "release-disabled" ]]; then
    VALIDATOR_REPOSITORY="$CONTRACT_DIR/validator-repository"
    EVIDENCE_SNAPSHOT="$CONTRACT_DIR/FloorpNotesSyncReleaseEvidence.json"
    VALIDATION_CLOCK_SNAPSHOT="$CONTRACT_DIR/validation-clock.json"
    SCHEMA_SNAPSHOT="$VALIDATOR_REPOSITORY/docs/floorp-notes-sync-release-evidence.schema.json"
    VALIDATOR_SNAPSHOT="$VALIDATOR_REPOSITORY/scripts/ci/validate-floorp-notes-sync-release.py"
    VALIDATOR_FIXTURE_SNAPSHOT="$VALIDATOR_REPOSITORY/sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
    VALIDATOR_ENDPOINT_SNAPSHOT="$VALIDATOR_REPOSITORY/docs/floorp-release-endpoints.json"
    VALIDATOR_BUILD_CONFIGURATION_SNAPSHOT="$VALIDATOR_REPOSITORY/firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
    SNAPSHOT_RECORD="$CONTRACT_DIR/input-snapshots.json"
    SNAPSHOT_RECORD_SHA256="$("$PYTHON_BIN" - "$CONTRACT_DIR" "$SNAPSHOT_RECORD" \
        evidence "$EVIDENCE" "$EVIDENCE_SNAPSHOT" \
        validation_clock "$VALIDATION_CLOCK" "$VALIDATION_CLOCK_SNAPSHOT" \
        schema "$SCHEMA" "$SCHEMA_SNAPSHOT" \
        validator "$VALIDATOR_SOURCE" "$VALIDATOR_SNAPSHOT" \
        merge_fixture "$VALIDATOR_FIXTURE_SOURCE" "$VALIDATOR_FIXTURE_SNAPSHOT" \
        floorp_release_configuration "$VALIDATOR_BUILD_CONFIGURATION_SOURCE" \
            "$VALIDATOR_BUILD_CONFIGURATION_SNAPSHOT" \
        endpoint_policy "$ENDPOINT_MATRIX" "$VALIDATOR_ENDPOINT_SNAPSHOT" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

contract_dir = Path(sys.argv[1]).resolve()
record_path = Path(sys.argv[2]).resolve()
triples = [sys.argv[index:index + 3] for index in range(3, len(sys.argv), 3)]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def snapshot(source_raw, target_raw, label):
    source = Path(source_raw).resolve(strict=True)
    target = Path(target_raw).resolve(strict=False)
    try:
        target.relative_to(contract_dir)
    except ValueError:
        reject(f"{label} snapshot escaped contract-inputs")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            reject(f"{label} input is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    payload = b"".join(chunks)
    if identity_before != identity_after or len(payload) != before.st_size:
        reject(f"{label} input changed while it was being snapshotted")
    try:
        with target.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError:
        reject(f"{label} snapshot already exists")
    return {
        "source_path": str(source),
        "snapshot_path": str(target),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
    }


records = {}
for label, source, target in triples:
    records[label] = snapshot(source, target, label)
record_bytes = (json.dumps(records, indent=2, sort_keys=True) + "\n").encode()
with record_path.open("xb") as handle:
    handle.write(record_bytes)
    handle.flush()
    os.fsync(handle.fileno())
print(hashlib.sha256(record_bytes).hexdigest())
PY
)"
    EVIDENCE_SOURCE_DIRECTORY="$("$PYTHON_BIN" -c \
        'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True).parent)' \
        "$EVIDENCE")"
    LOCAL_SNAPSHOT_RECORD="$CONTRACT_DIR/local-artifact-snapshots.json"
    LOCAL_SNAPSHOT_RECORD_SHA256="$(local_artifact_snapshot create \
        "$EVIDENCE_SNAPSHOT" "$EVIDENCE_SOURCE_DIRECTORY" "$CONTRACT_DIR" \
        "$LOCAL_SNAPSHOT_RECORD")"
    VALIDATOR="$VALIDATOR_SNAPSHOT"
fi

verify_snapshot_record() {
    "$PYTHON_BIN" - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

contract_dir = Path(sys.argv[1]).resolve()
record_path = Path(sys.argv[2]).resolve()
expected_record_digest = sys.argv[3]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


record_bytes = record_path.read_bytes()
if hashlib.sha256(record_bytes).hexdigest() != expected_record_digest:
    reject("contract snapshot record changed")
try:
    records = json.loads(record_bytes)
except json.JSONDecodeError as error:
    reject(f"contract snapshot record is invalid: {error}")
if set(records) != {
    "endpoint_policy",
    "evidence",
    "floorp_release_configuration",
    "merge_fixture",
    "schema",
    "validation_clock",
    "validator",
}:
    reject("contract snapshot record has an unexpected input set")
for label, record in records.items():
    snapshot = Path(record.get("snapshot_path", ""))
    if snapshot.is_symlink():
        reject(f"{label} snapshot escaped contract-inputs")
    try:
        snapshot.resolve(strict=True).relative_to(contract_dir)
    except ValueError:
        reject(f"{label} snapshot escaped contract-inputs")
    metadata = snapshot.stat()
    if not stat.S_ISREG(metadata.st_mode):
        reject(f"{label} snapshot is not a regular file")
    payload = snapshot.read_bytes()
    if len(payload) != record.get("size"):
        reject(f"{label} snapshot size changed")
    if hashlib.sha256(payload).hexdigest() != record.get("sha256"):
        reject(f"{label} snapshot digest changed")
PY
}

verify_contract_snapshots() {
    [[ -n "$SNAPSHOT_RECORD" ]] || return 0
    verify_snapshot_record "$CONTRACT_DIR" "$SNAPSHOT_RECORD" "$SNAPSHOT_RECORD_SHA256"
    local_artifact_snapshot verify \
        "$CONTRACT_DIR" "$LOCAL_SNAPSHOT_RECORD" "$LOCAL_SNAPSHOT_RECORD_SHA256"
}

verify_contract_snapshots

"$PYTHON_BIN" - "$MODE" "$SOURCE_SHA" "$EVIDENCE_SNAPSHOT" "$VALIDATION_CLOCK_SNAPSHOT" "$ENDPOINT_MATRIX" \
    "$PIN" "$GENERATED_BINDING" "$PREFLIGHT" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    mode,
    source_sha,
    evidence_path,
    clock_path,
    endpoint_path,
    pin_path,
    generated_binding,
    output_path,
) = sys.argv[1:]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def load(path, label):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        reject(f"invalid {label}: {error}")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


expected_hosts = {
    "accounts.firefox.com": "fxa",
    "api.accounts.firefox.com": "fxa",
    "event-sync.services.mozilla.com": "sync",
    "oauth.accounts.firefox.com": "fxa",
    "profile.accounts.firefox.com": "fxa",
    "static.accounts.firefox.com": "fxa",
    "sync.services.mozilla.com": "sync",
    "token.services.mozilla.com": "sync",
}
matrix = load(endpoint_path, "endpoint matrix")
rows = {row.get("host"): row for row in matrix.get("endpoints", []) if isinstance(row, dict)}
for host, service in expected_hosts.items():
    row = rows.get(host)
    if not row:
        reject(f"production endpoint is missing: {host}")
    if row.get("status") != "enabled" or row.get("service") != service:
        reject(f"production endpoint is not enabled for {service}: {host}")
    if "Mozilla" not in str(row.get("owner", "")):
        reject(f"production endpoint lacks Mozilla ownership: {host}")

pin = load(pin_path, "Application Services pin")
release = pin.get("release", {})
assets = pin.get("assets", {})
expected_pin_identity = {
    "repository": "Floorp-Projects/application-services",
    "release_tag": "floorp-ios-155.20260731050244.4",
    "release_revision": 4,
    "source_commit": "b6d29804c391a573ecc0db6c1c4491b3e07a6693",
    "source_tree": "8bfa4a27d5b807b613d577ee49198617aab0e117",
}
observed_pin_identity = {
    "repository": pin.get("repository"),
    "release_tag": release.get("tag"),
    "release_revision": release.get("revision"),
    "source_commit": release.get("sourceCommit"),
    "source_tree": release.get("sourceTree"),
}
if observed_pin_identity != expected_pin_identity or release.get("immutable") is not True:
    reject("Application Services pin is not the immutable Todo 17 revision .4 artifact")

artifact_projection = {
    "focus_xcframework_sha256": "FocusRustComponents.xcframework.zip",
    "mozilla_xcframework_sha256": "MozillaRustComponents.xcframework.zip",
    "release_manifest_sha256": "release-manifest.json",
    "sha256sums_sha256": "SHA256SUMS",
    "swift_components_sha256": "swift-components.tar.xz",
}
application_services_artifacts = {}
for evidence_name, pin_name in artifact_projection.items():
    asset = assets.get(pin_name)
    if not isinstance(asset, dict):
        reject(f"Application Services pin is missing {pin_name}")
    digest = asset.get("sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        reject(f"Application Services pin has an invalid digest for {pin_name}")
    if pin_name.endswith(".xcframework.zip") and asset.get("swiftPMChecksum") != digest:
        reject(f"Application Services pin checksum differs from sha256 for {pin_name}")
    application_services_artifacts[evidence_name] = digest

expected_application_services_input = {
    "repository": observed_pin_identity["repository"],
    "release_tag": observed_pin_identity["release_tag"],
    "source_sha": observed_pin_identity["source_commit"],
    "tree_sha": observed_pin_identity["source_tree"],
    "artifacts": application_services_artifacts,
}
if not Path(generated_binding).is_file():
    reject("generated floorp_prefs_sync.swift binding is missing")

digest = None
clock_run_id = None
clock_manifest_path = None
clock_manifest_sha256 = None
ios_release_input = None
if mode != "release-disabled":
    evidence = load(evidence_path, "release evidence")
    if evidence.get("build_contract_mode") != mode:
        reject(f"evidence build_contract_mode must be {mode}")
    release_inputs = evidence.get("release_inputs", {})
    ios = release_inputs.get("ios", {})
    expected_ios_keys = {"build_number", "configuration", "repository", "source_sha"}
    if not isinstance(ios, dict) or set(ios) != expected_ios_keys:
        reject("evidence iOS release inputs do not have the exact contract fields")
    if ios.get("repository") != "Floorp-Projects/floorp-ios":
        reject("evidence iOS repository does not match the release contract")
    if ios.get("source_sha") != source_sha:
        reject("evidence iOS source SHA does not match --source-sha")
    if ios.get("configuration") != "FloorpRelease":
        reject("evidence iOS configuration is not FloorpRelease")
    if not isinstance(ios.get("build_number"), str) or not ios["build_number"]:
        reject("evidence iOS build number must be a nonempty string")
    ios_release_input = ios
    evidence_application_services = release_inputs.get("application_services")
    if evidence_application_services != expected_application_services_input:
        reject(
            "evidence Application Services release inputs do not exactly match "
            "the checked-in pin"
        )
    endpoint = release_inputs.get("environment", {})
    expected_endpoint = {
        "fxa_configuration": "FxAConfig.Server.release",
        "fxa_hosts": sorted(
            host for host, service in expected_hosts.items() if service == "fxa"
        ),
        "sync_hosts": sorted(
            host for host, service in expected_hosts.items() if service == "sync"
        ),
        "wire_protocol": "sync15",
    }
    if endpoint != expected_endpoint:
        reject("evidence endpoint authority is not the exact production FxA/Sync contract")
    required = ["g1", "g2", "g3", "g4"]
    digest_name = "g1_g4_digest_sha256"
    if mode == "release-enabled":
        required.append("g5")
        digest_name = "g1_g5_digest_sha256"
    gates = evidence.get("gates", {})
    if not isinstance(gates, dict) or set(gates) != set(required):
        expected = ", ".join(name.upper() for name in required)
        reject(f"{mode} requires the exact gate set {expected}; embedded G6 is forbidden")
    for gate in required:
        if not isinstance(gates.get(gate), dict) or gates[gate].get("status") != "passed":
            reject(f"{mode} requires {gate} status passed")
    digest = evidence.get(digest_name)
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        reject(f"{mode} requires a lowercase {digest_name}")

    clock = load(clock_path, "validation clock")
    if clock.get("repository") != "Floorp-Projects/floorp-ios":
        reject("validation clock repository does not match the release contract")
    if clock.get("expected_head_sha") != source_sha:
        reject("validation clock expected head does not match the release contract")
    workflow = clock.get("workflow", {})
    if workflow.get("path") != ".github/workflows/floorp-notes-sync-validation-clock.yml":
        reject("validation clock workflow path does not match the release contract")
    run = clock.get("run", {})
    expected_run = {
        "repository": "Floorp-Projects/floorp-ios",
        "workflow_path": ".github/workflows/floorp-notes-sync-validation-clock.yml",
        "head_sha": source_sha,
        "status": "completed",
        "conclusion": "success",
    }
    for name, expected in expected_run.items():
        if run.get(name) != expected:
            reject(f"validation clock run {name} does not match the release contract")
    if run.get("workflow_id") != workflow.get("id"):
        reject("validation clock run workflow ID does not match the release contract")
    clock_run_id = run.get("id")
    if not isinstance(clock_run_id, int) or isinstance(clock_run_id, bool) or clock_run_id <= 0:
        reject("validation clock run_id must be a positive integer")
    clock_manifest_path = str(Path(clock_path).resolve())
    clock_manifest_sha256 = sha256(clock_path)

preflight = {
    "application_services": {
        **observed_pin_identity,
        "artifacts": application_services_artifacts,
        "xcframework_sha256": application_services_artifacts[
            "mozilla_xcframework_sha256"
        ],
        "pin_path": str(Path(pin_path).resolve()),
        "pin_sha256": sha256(pin_path),
        "generated_binding_path": str(Path(generated_binding).resolve()),
        "generated_binding_sha256": sha256(generated_binding),
    },
    "release_inputs": {
        "application_services": expected_application_services_input
        if mode != "release-disabled"
        else None,
        "ios": ios_release_input,
    },
    "endpoint_authority": {
        "environment": "production",
        "fxa_server": "FxAConfig.Server.release",
        "wire_protocol": "sync15",
        "custom_fxa_override": False,
        "custom_token_server_override": False,
        "hosts": sorted(expected_hosts),
        "matrix_path": str(Path(endpoint_path).resolve()),
        "matrix_sha256": sha256(endpoint_path),
    },
    "evidence_digest_sha256": digest,
    "clock_run_id": clock_run_id,
    "clock_manifest_path": clock_manifest_path,
    "clock_manifest_sha256": clock_manifest_sha256,
}
Path(output_path).write_text(json.dumps(preflight, indent=2, sort_keys=True) + "\n")
PY

if [[ "$MODE" != "release-disabled" ]]; then
    verify_contract_snapshots
    if ! "$PYTHON_BIN" "$VALIDATOR" \
        --schema "$SCHEMA_SNAPSHOT" \
        --evidence "$EVIDENCE_SNAPSHOT" \
        --validation-clock-manifest "$VALIDATION_CLOCK_SNAPSHOT" \
        --canonicalization rfc8785-jcs; then
        echo "build-floorp-notes-sync-ios: release validator rejected $MODE evidence" >&2
        exit 1
    fi
    verify_contract_snapshots
    EVIDENCE_RESOURCE="$EVIDENCE_SNAPSHOT"
fi

EVIDENCE_DIGEST="$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["evidence_digest_sha256"] or "")' "$PREFLIGHT")"
EVIDENCE_RESOURCE_SHA256=""
if [[ -n "$EVIDENCE_RESOURCE" ]]; then
    EVIDENCE_RESOURCE_SHA256="$("$SHASUM_BIN" -a 256 "$EVIDENCE_RESOURCE" | "$AWK_BIN" '{print $1}')"
fi
ENDPOINT_MATRIX_DIGEST="$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["endpoint_authority"]["matrix_sha256"])' "$PREFLIGHT")"
if [[ "$MODE" == "release-disabled" ]]; then
    REQUESTED="NO"
    EFFECTIVE="NO"
else
    REQUESTED="YES"
    EFFECTIVE="YES"
fi

xcconfig_value() {
    "$PYTHON_BIN" - "$1" <<'PY'
import sys
value = sys.argv[1]
if "\n" in value or "\r" in value:
    raise SystemExit("xcconfig values cannot contain newlines")
if any(character in value for character in '#$"\''):
    raise SystemExit("xcconfig values contain unsupported metacharacters")
print(value.replace("\\", "\\\\").replace(" ", "\\ "))
PY
}

BUILD_NUMBER_SETTING=""
if [[ "$MODE" != "release-disabled" ]]; then
    IOS_BUILD_NUMBER="$(
        "$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_inputs"]["ios"]["build_number"])' \
            "$PREFLIGHT"
    )"
    [[ "$IOS_BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] \
        || fail "evidence iOS build number is not a valid CFBundleVersion"
    BUILD_NUMBER_SETTING="FLOORP_BUILD_NUMBER = $(xcconfig_value "$IOS_BUILD_NUMBER")"
fi

cat > "$XC_CONFIG" <<EOF
// Generated outside the source worktree by build-floorp-notes-sync-ios.sh.
$BUILD_NUMBER_SETTING
FLOORP_NOTES_SYNC_BUILD_MODE = $(xcconfig_value "$MODE")
FLOORP_NOTES_SYNC_SOURCE_SHA = $SOURCE_SHA
FLOORP_NOTES_SYNC_REQUESTED = $REQUESTED
FLOORP_NOTES_SYNC_EFFECTIVE = $EFFECTIVE
FLOORP_NOTES_SYNC_FXA_SERVER = release
FLOORP_NOTES_SYNC_ENDPOINT_AUTHORITY = production
FLOORP_NOTES_SYNC_PROTOCOL = sync15
FLOORP_NOTES_SYNC_CUSTOM_FXA_OVERRIDE = NO
FLOORP_NOTES_SYNC_CUSTOM_TOKEN_SERVER_OVERRIDE = NO
FLOORP_NOTES_SYNC_ALLOWED_HOSTS = accounts.firefox.com,api.accounts.firefox.com,event-sync.services.mozilla.com,oauth.accounts.firefox.com,profile.accounts.firefox.com,static.accounts.firefox.com,sync.services.mozilla.com,token.services.mozilla.com
FLOORP_NOTES_SYNC_ENDPOINT_MATRIX_SHA256 = $ENDPOINT_MATRIX_DIGEST
FLOORP_NOTES_SYNC_EVIDENCE_DIGEST = $EVIDENCE_DIGEST
FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE = $(xcconfig_value "$EVIDENCE_RESOURCE")
FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE_SHA256 = $EVIDENCE_RESOURCE_SHA256
EOF

SELECTED_DEVELOPER_RAW="$("$XCODE_SELECT_BIN" -p)"
SELECTED_DEVELOPER="$("$PYTHON_BIN" - "$SELECTED_DEVELOPER_RAW" <<'PY'
import sys
from pathlib import Path

raw = Path(sys.argv[1])
if not raw.is_absolute():
    raise SystemExit("build-floorp-notes-sync-ios: xcode-select returned a non-absolute path")
resolved = raw.resolve(strict=True)
if raw != resolved:
    raise SystemExit("build-floorp-notes-sync-ios: xcode-select returned a symlinked path")
if resolved.name != "Developer" or resolved.parent.name != "Contents" or resolved.parent.parent.suffix != ".app":
    raise SystemExit("build-floorp-notes-sync-ios: xcode-select did not select an Xcode app")
print(resolved)
PY
)"
XCODE_APP="${SELECTED_DEVELOPER%/Contents/Developer}"
XCODEBUILD_BIN="$SELECTED_DEVELOPER/usr/bin/xcodebuild"
[[ -x "$XCODEBUILD_BIN" && ! -L "$XCODEBUILD_BIN" ]] \
    || fail "selected Xcode has no authenticated xcodebuild executable"

XCODE_APP_SIGNATURE="$CONTRACT_DIR/xcode-app-signature.txt"
XCODEBUILD_SIGNATURE="$CONTRACT_DIR/xcodebuild-signature.txt"
SPCTL_RESULT="$CONTRACT_DIR/xcode-spctl.txt"
"$CODESIGN_BIN" --verify --strict "$XCODE_APP" \
    || fail "selected Xcode app failed code-signature verification"
"$CODESIGN_BIN" --verify --strict "$XCODEBUILD_BIN" \
    || fail "selected xcodebuild failed code-signature verification"
"$CODESIGN_BIN" -d --verbose=4 "$XCODE_APP" > /dev/null 2> "$XCODE_APP_SIGNATURE" \
    || fail "selected Xcode app signature metadata is unavailable"
"$CODESIGN_BIN" -d --verbose=4 "$XCODEBUILD_BIN" > /dev/null 2> "$XCODEBUILD_SIGNATURE" \
    || fail "selected xcodebuild signature metadata is unavailable"
"$SPCTL_BIN" --assess --type execute --verbose=4 "$XCODE_APP" > "$SPCTL_RESULT" 2>&1 \
    || fail "selected Xcode app failed Gatekeeper assessment"

"$PYTHON_BIN" - "$XCODE_APP" "$SELECTED_DEVELOPER" "$XCODEBUILD_BIN" \
    "$XCODE_APP_SIGNATURE" "$XCODEBUILD_SIGNATURE" "$SPCTL_RESULT" \
    "$TOOLCHAIN_RECORD" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

(
    app_raw,
    developer_raw,
    xcodebuild_raw,
    app_signature_raw,
    binary_signature_raw,
    assessment_raw,
    record_raw,
) = sys.argv[1:]
app = Path(app_raw).resolve(strict=True)
developer = Path(developer_raw).resolve(strict=True)
xcodebuild = Path(xcodebuild_raw).resolve(strict=True)
record_path = Path(record_raw).resolve(strict=False)


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse_signature(path):
    fields = {}
    authorities = []
    for line in Path(path).read_text().splitlines():
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name == "Authority":
            authorities.append(value)
        else:
            fields[name] = value
    return fields, authorities


app_fields, app_authorities = parse_signature(app_signature_raw)
binary_fields, binary_authorities = parse_signature(binary_signature_raw)
apple_mac_os_application_signing = [
    "Apple Mac OS Application Signing",
    "Apple Worldwide Developer Relations Certification Authority",
    "Apple Root CA",
]
apple_software_signing = [
    "Software Signing",
    "Apple Code Signing Certification Authority",
    "Apple Root CA",
]
allowed_binary_authorities = [
    apple_software_signing,
    apple_mac_os_application_signing,
]
allowed_app_authorities = [
    apple_mac_os_application_signing,
    apple_software_signing,
]
if app_fields.get("Identifier") != "com.apple.dt.Xcode":
    reject("selected Xcode app has an unexpected signing identifier")
if app_fields.get("TeamIdentifier") != "59GAB85EFG":
    reject("selected Xcode app is not signed by Apple's Xcode team")
if app_fields.get("Signature") == "adhoc" or app_authorities not in allowed_app_authorities:
    reject("selected Xcode app does not have the approved Apple authority chain")
if binary_fields.get("Identifier") != "com.apple.dt.xcodebuild":
    reject("selected xcodebuild has an unexpected signing identifier")
if binary_fields.get("TeamIdentifier") != "59GAB85EFG":
    reject("selected xcodebuild is not signed by Apple's Xcode team")
if binary_fields.get("Signature") == "adhoc" or binary_authorities not in allowed_binary_authorities:
    reject("selected xcodebuild does not have an approved Apple authority chain")
assessment = Path(assessment_raw).read_text().strip()
if "accepted" not in assessment:
    reject("selected Xcode app was not accepted by Gatekeeper")

digest = hashlib.sha256(xcodebuild.read_bytes()).hexdigest()
record = {
    "developer_dir": str(developer),
    "xcode_app": {
        "authorities": app_authorities,
        "identifier": app_fields["Identifier"],
        "path": str(app),
        "team_identifier": app_fields["TeamIdentifier"],
    },
    "xcodebuild": {
        "authorities": binary_authorities,
        "cdhash": binary_fields.get("CDHash"),
        "identifier": binary_fields["Identifier"],
        "path": str(xcodebuild),
        "sha256": digest,
        "team_identifier": binary_fields["TeamIdentifier"],
    },
    "gatekeeper_assessment": assessment.splitlines(),
}
payload = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
try:
    descriptor = os.open(
        record_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
except FileExistsError:
    reject("Xcode toolchain record already exists")
try:
    os.write(descriptor, payload)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY

DEVELOPER_DIR="$SELECTED_DEVELOPER" "$XCODEBUILD_BIN" -version > "$XCODE_VERSION_FILE"
verify_contract_snapshots
verify_source_snapshot

XCODE_PRIVATE_HOME="$OUTPUT_DIR/xcode-home"
XCODE_PRIVATE_TMP="$OUTPUT_DIR/xcode-tmp"
XCODE_PACKAGE_CLONES="$OUTPUT_DIR/swiftpm-packages"
"$PYTHON_BIN" - "$XCODE_PRIVATE_HOME" "$XCODE_PRIVATE_TMP" "$XCODE_PACKAGE_CLONES" <<'PY'
import os
import stat
import sys
from pathlib import Path

for raw in sys.argv[1:]:
    path = Path(raw)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        metadata = None
    if metadata is not None:
        print(f"build-floorp-notes-sync-ios: private Xcode path already exists: {path}", file=sys.stderr)
        raise SystemExit(2)
    os.mkdir(path, 0o700)
PY

XCODE_ARGS=(
    "$ACTION"
    -project "$PROJECT"
    -scheme Floorp
    -configuration FloorpRelease
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA"
    -disableAutomaticPackageResolution
    -onlyUsePackageVersionsFromResolvedFile
    -clonedSourcePackagesDirPath "$XCODE_PACKAGE_CLONES"
    -skipMacroValidation
    -xcconfig "$XC_CONFIG"
    COMPILER_INDEX_STORE_ENABLE=NO
    "FLOORP_GENERATED_SOURCE_MANIFEST=$GENERATED_SOURCE_RECORD"
    "FLOORP_GENERATED_SOURCE_SHA=$SOURCE_SHA"
    "FLOORP_SOURCE_ARCHIVE=$SOURCE_ARCHIVE"
    FLOORP_GENERATED_SOURCES_PREPARED=YES
    "FLOORP_GLEAN_TOOL_ROOT=$TOOL_STATE"
    "FLOORP_GLEAN_VENV=$GLEAN_VENV"
    "FLOORP_GLEAN_VERIFY_ROOT=$GLEAN_VERIFY_ROOT"
    FLOORP_GLEAN_VERIFY_ONLY=YES
)
if [[ "$ACTION" == "archive" ]]; then
    XCODE_ARGS+=( -archivePath "$ARCHIVE_PATH" )
fi
if [[ "$ALLOW_SIGNING" -eq 0 ]]; then
    XCODE_ARGS+=( CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO )
fi
"$PYTHON_BIN" - "$COMMAND_JSON" "${XCODE_ARGS[@]}" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:], indent=2) + "\n")
PY

set -o pipefail
XCODE_USER="${USER:-$(/usr/bin/id -un)}"
XCODE_LANG="${LANG:-en_US.UTF-8}"
if ! /usr/bin/env -i \
    PATH="$SYSTEM_PATH" \
    HOME="$XCODE_PRIVATE_HOME" \
    USER="$XCODE_USER" \
    LOGNAME="$XCODE_USER" \
    TMPDIR="$XCODE_PRIVATE_TMP" \
    LANG="$XCODE_LANG" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=core.fsmonitor \
    GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=core.hooksPath \
    GIT_CONFIG_VALUE_1=/dev/null \
    DEVELOPER_DIR="$SELECTED_DEVELOPER" \
    "$XCODEBUILD_BIN" "${XCODE_ARGS[@]}" 2>&1 | "$TEE_BIN" "$BUILD_LOG"; then
    echo "build-floorp-notes-sync-ios: xcodebuild failed" >&2
    exit 1
fi

verify_contract_snapshots
verify_source_snapshot

if [[ "$ACTION" == "archive" ]]; then
    APP="$ARCHIVE_PATH/Products/Applications/Client.app"
else
    APP=""
    while IFS= read -r candidate; do
        [[ -z "$APP" ]] || fail "multiple Client.app products found under DerivedData"
        APP="$candidate"
    done < <("$FIND_BIN" "$DERIVED_DATA/Build/Products" -type d -name Client.app -print 2>/dev/null | "$SORT_BIN")
fi
[[ -n "$APP" && -d "$APP" ]] || fail "built Client.app was not found"
APP="$(absolute_path "$APP")"

SOURCE_STATUS_AFTER="$("$GIT_BIN" -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
[[ "$SOURCE_STATUS_AFTER" == "$SOURCE_STATUS_BEFORE" && -z "$SOURCE_STATUS_AFTER" ]] \
    || fail "source worktree changed during the build"

FINAL_PREFLIGHT="$PREFLIGHT"
FINAL_EVIDENCE_RESOURCE="$EVIDENCE_RESOURCE"
FINAL_VALIDATOR="$VALIDATOR"
FINAL_SCHEMA="$SCHEMA_SNAPSHOT"
FINAL_CLOCK="$VALIDATION_CLOCK_SNAPSHOT"
FINAL_SNAPSHOT_RECORD="$SNAPSHOT_RECORD"
FINAL_SNAPSHOT_RECORD_SHA256="$SNAPSHOT_RECORD_SHA256"
FINAL_LOCAL_SNAPSHOT_RECORD="$LOCAL_SNAPSHOT_RECORD"
FINAL_LOCAL_SNAPSHOT_RECORD_SHA256="$LOCAL_SNAPSHOT_RECORD_SHA256"
PUBLICATION_DIR=""

if [[ "$MODE" != "release-disabled" ]]; then
    [[ -x "$CLOCK_CLIENT" ]] || fail "exact-commit validation-clock client is not executable"
    FRESH_CLOCK_CAPTURE="$CONTRACT_DIR/post-build-validation-clock-capture.json"
    "$CLOCK_CLIENT" \
        --repository Floorp-Projects/floorp-ios \
        --workflow floorp-notes-sync-validation-clock.yml \
        --expected-head "$SOURCE_SHA" \
        --max-age-seconds 300 \
        --output "$FRESH_CLOCK_CAPTURE"
    [[ -f "$FRESH_CLOCK_CAPTURE" && ! -L "$FRESH_CLOCK_CAPTURE" ]] \
        || fail "post-build validation clock was not captured safely"

    PUBLICATION_DIR="$CONTRACT_DIR/publication-inputs"
    PUBLICATION_VALIDATOR_REPOSITORY="$PUBLICATION_DIR/validator-repository"
    FINAL_EVIDENCE_RESOURCE="$PUBLICATION_DIR/FloorpNotesSyncReleaseEvidence.json"
    FINAL_CLOCK="$PUBLICATION_DIR/validation-clock.json"
    FINAL_SCHEMA="$PUBLICATION_VALIDATOR_REPOSITORY/docs/floorp-notes-sync-release-evidence.schema.json"
    FINAL_VALIDATOR="$PUBLICATION_VALIDATOR_REPOSITORY/scripts/ci/validate-floorp-notes-sync-release.py"
    FINAL_VALIDATOR_FIXTURE="$PUBLICATION_VALIDATOR_REPOSITORY/sync-fixtures/floorp-notes/floorp-notes-merge-v1.json"
    FINAL_VALIDATOR_ENDPOINT="$PUBLICATION_VALIDATOR_REPOSITORY/docs/floorp-release-endpoints.json"
    FINAL_VALIDATOR_BUILD_CONFIGURATION="$PUBLICATION_VALIDATOR_REPOSITORY/firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
    FINAL_SNAPSHOT_RECORD="$PUBLICATION_DIR/input-snapshots.json"
    FINAL_SNAPSHOT_RECORD_SHA256="$("$PYTHON_BIN" - "$PUBLICATION_DIR" \
        "$FINAL_SNAPSHOT_RECORD" \
        evidence "$EVIDENCE_SNAPSHOT" "$FINAL_EVIDENCE_RESOURCE" \
        validation_clock "$FRESH_CLOCK_CAPTURE" "$FINAL_CLOCK" \
        schema "$SCHEMA_SNAPSHOT" "$FINAL_SCHEMA" \
        validator "$VALIDATOR_SNAPSHOT" "$FINAL_VALIDATOR" \
        merge_fixture "$VALIDATOR_FIXTURE_SNAPSHOT" "$FINAL_VALIDATOR_FIXTURE" \
        floorp_release_configuration "$VALIDATOR_BUILD_CONFIGURATION_SNAPSHOT" \
            "$FINAL_VALIDATOR_BUILD_CONFIGURATION" \
        endpoint_policy "$VALIDATOR_ENDPOINT_SNAPSHOT" "$FINAL_VALIDATOR_ENDPOINT" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

snapshot_root = Path(sys.argv[1]).resolve()
record_path = Path(sys.argv[2]).resolve()
triples = [sys.argv[index:index + 3] for index in range(3, len(sys.argv), 3)]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def snapshot(source_raw, target_raw, label):
    source = Path(source_raw).resolve(strict=True)
    target = Path(target_raw).resolve(strict=False)
    try:
        target.relative_to(snapshot_root)
    except ValueError:
        reject(f"{label} publication snapshot escaped publication-inputs")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            reject(f"{label} publication input is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    payload = b"".join(chunks)
    if identity_before != identity_after or len(payload) != before.st_size:
        reject(f"{label} publication input changed while it was being snapshotted")
    try:
        with target.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError:
        reject(f"{label} publication snapshot already exists")
    return {
        "source_path": str(source),
        "snapshot_path": str(target),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
    }


records = {}
for label, source, target in triples:
    records[label] = snapshot(source, target, label)
record_bytes = (json.dumps(records, indent=2, sort_keys=True) + "\n").encode()
with record_path.open("xb") as handle:
    handle.write(record_bytes)
    handle.flush()
    os.fsync(handle.fileno())
directory_descriptor = os.open(snapshot_root, os.O_RDONLY)
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
print(hashlib.sha256(record_bytes).hexdigest())
PY
)"
    FINAL_LOCAL_SNAPSHOT_RECORD="$PUBLICATION_DIR/local-artifact-snapshots.json"
    FINAL_LOCAL_SNAPSHOT_RECORD_SHA256="$(local_artifact_snapshot create \
        "$FINAL_EVIDENCE_RESOURCE" "$CONTRACT_DIR" "$PUBLICATION_DIR" \
        "$FINAL_LOCAL_SNAPSHOT_RECORD")"
    verify_snapshot_record \
        "$PUBLICATION_DIR" "$FINAL_SNAPSHOT_RECORD" "$FINAL_SNAPSHOT_RECORD_SHA256"
    local_artifact_snapshot verify \
        "$PUBLICATION_DIR" "$FINAL_LOCAL_SNAPSHOT_RECORD" \
        "$FINAL_LOCAL_SNAPSHOT_RECORD_SHA256"

    FINAL_PREFLIGHT="$PUBLICATION_DIR/preflight.json"
    "$PYTHON_BIN" - "$PREFLIGHT" "$FINAL_CLOCK" "$FINAL_PREFLIGHT" "$SOURCE_SHA" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

preflight_path, clock_path, output_path = map(Path, sys.argv[1:4])
source_sha = sys.argv[4]
preflight = json.loads(preflight_path.read_text())
clock = json.loads(clock_path.read_text())


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


if clock.get("repository") != "Floorp-Projects/floorp-ios":
    reject("post-build validation clock repository does not match")
if clock.get("expected_head_sha") != source_sha:
    reject("post-build validation clock expected head does not match")
workflow = clock.get("workflow", {})
run = clock.get("run", {})
if workflow.get("path") != ".github/workflows/floorp-notes-sync-validation-clock.yml":
    reject("post-build validation clock workflow does not match")
expected_run = {
    "repository": "Floorp-Projects/floorp-ios",
    "workflow_path": ".github/workflows/floorp-notes-sync-validation-clock.yml",
    "head_sha": source_sha,
    "status": "completed",
    "conclusion": "success",
}
if any(run.get(name) != value for name, value in expected_run.items()):
    reject("post-build validation clock run does not match the release contract")
if run.get("workflow_id") != workflow.get("id"):
    reject("post-build validation clock workflow ID does not match")
run_id = run.get("id")
if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id <= 0:
    reject("post-build validation clock run ID is invalid")
clock_bytes = clock_path.read_bytes()
preflight["clock_run_id"] = run_id
preflight["clock_manifest_path"] = str(clock_path.resolve())
preflight["clock_manifest_sha256"] = hashlib.sha256(clock_bytes).hexdigest()
payload = (json.dumps(preflight, indent=2, sort_keys=True) + "\n").encode()
try:
    descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
except FileExistsError:
    reject("publication preflight already exists")
try:
    os.write(descriptor, payload)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
fi

MANIFEST_TMP="$MANIFEST.tmp.$$"
"$PYTHON_BIN" - "$APP" "$ARCHIVE_PATH" "$MANIFEST_TMP" "$MODE" "$SOURCE_SHA" "$ACTUAL_TREE" \
    "$ACTION" "$DESTINATION" "$ALLOW_SIGNING" "$OUTPUT_DIR" "$BUILD_LOG" "$XC_CONFIG" \
    "$FINAL_EVIDENCE_RESOURCE" "$EVIDENCE_DIGEST" "$FINAL_VALIDATOR" "$FINAL_SCHEMA" "$FINAL_PREFLIGHT" \
    "$XCODE_VERSION_FILE" "$COMMAND_JSON" "$ENTITLEMENTS_SOURCE" "$SNAPSHOT_RECORD" \
    "$SNAPSHOT_RECORD_SHA256" "$FINAL_SNAPSHOT_RECORD" "$FINAL_SNAPSHOT_RECORD_SHA256" \
    "$LOCAL_SNAPSHOT_RECORD" "$LOCAL_SNAPSHOT_RECORD_SHA256" \
    "$FINAL_LOCAL_SNAPSHOT_RECORD" "$FINAL_LOCAL_SNAPSHOT_RECORD_SHA256" \
    "$SOURCE_SNAPSHOT_RECORD" "$TOOLCHAIN_RECORD" "$CODESIGN_BIN" "$SECURITY_BIN" \
    "$FINAL_CLOCK" <<'PY'
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from datetime import timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

(
    app_raw,
    archive_raw,
    manifest_raw,
    mode,
    source_sha,
    source_tree,
    action,
    destination,
    allow_signing_raw,
    output_raw,
    build_log_raw,
    xcconfig_raw,
    evidence_resource_raw,
    evidence_digest,
    validator_raw,
    schema_raw,
    preflight_raw,
    xcode_version_raw,
    command_json_raw,
    entitlements_raw,
    initial_snapshot_record_raw,
    initial_snapshot_record_sha256,
    final_snapshot_record_raw,
    final_snapshot_record_sha256,
    initial_local_snapshot_record_raw,
    initial_local_snapshot_record_sha256,
    final_local_snapshot_record_raw,
    final_local_snapshot_record_sha256,
    source_snapshot_record_raw,
    toolchain_record_raw,
    codesign_bin_raw,
    security_bin_raw,
    final_clock_raw,
) = sys.argv[1:]

app = Path(app_raw).resolve()
manifest_path = Path(manifest_raw).resolve()
archive = Path(archive_raw).resolve() if archive_raw else None
output = Path(output_raw).resolve()
build_log = Path(build_log_raw).resolve()
xcconfig = Path(xcconfig_raw).resolve()
evidence_resource = Path(evidence_resource_raw).resolve() if evidence_resource_raw else None
validator = Path(validator_raw).resolve()
schema = Path(schema_raw).resolve()
preflight_path = Path(preflight_raw).resolve()
xcode_version_path = Path(xcode_version_raw).resolve()
command_json_path = Path(command_json_raw).resolve()
entitlements_path = Path(entitlements_raw).resolve()
initial_snapshot_record_path = (
    Path(initial_snapshot_record_raw).resolve() if initial_snapshot_record_raw else None
)
final_snapshot_record_path = (
    Path(final_snapshot_record_raw).resolve() if final_snapshot_record_raw else None
)
initial_local_snapshot_record_path = (
    Path(initial_local_snapshot_record_raw).resolve()
    if initial_local_snapshot_record_raw
    else None
)
final_local_snapshot_record_path = (
    Path(final_local_snapshot_record_raw).resolve()
    if final_local_snapshot_record_raw
    else None
)
source_snapshot_record_path = Path(source_snapshot_record_raw).resolve(strict=True)
toolchain_record_path = Path(toolchain_record_raw).resolve(strict=True)
codesign_bin = Path(codesign_bin_raw).resolve(strict=True)
security_bin = Path(security_bin_raw).resolve(strict=True)
final_clock_path = Path(final_clock_raw).resolve(strict=True) if final_clock_raw else None
allow_signing = allow_signing_raw == "1"


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, *, base=None):
    path = Path(path).resolve()
    record = {
        "path": str(path),
        "sha256": sha256(path),
        "size": path.stat().st_size,
    }
    if base is not None:
        record["relative_path"] = path.relative_to(base).as_posix()
    return record


def gate_value(value, name):
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.upper() in {"YES", "TRUE", "1"}:
        return True
    if isinstance(value, str) and value.upper() in {"NO", "FALSE", "0"}:
        return False
    reject(f"Info.plist {name} is not a build-time boolean")


def merkle_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            row = f"L\0{relative}\0{os.readlink(path)}\n"
        elif path.is_file():
            row = f"F\0{relative}\0{path.stat().st_size}\0{sha256(path)}\n"
        else:
            continue
        digest.update(row.encode("utf-8"))
    return digest.hexdigest()


info_path = app / "Info.plist"
if not info_path.is_file():
    reject("built app is missing Info.plist")
with info_path.open("rb") as handle:
    info = plistlib.load(handle)

for key in info:
    normalized_key = str(key).lower().replace("-", "")
    if "floorpnotessync" in normalized_key and any(
        marker in normalized_key
        for marker in ("g6", "approval", "signer", "revocation")
    ):
        reject(f"built app contains forbidden Notes Sync authorization key {key}")
for resource in app.rglob("*"):
    relative_resource = resource.relative_to(app).as_posix().lower()
    if any(
        marker in relative_resource
        for marker in (
            "g6approval",
            "allowed-signers",
            "signer-registry",
            "revocations.json",
        )
    ):
        reject("built app contains forbidden G6 trust material")

expected_effective = mode != "release-disabled"
gate_keys = {
    "MozFloorpNotesSyncRequested": expected_effective,
    "MozAllowFloorpNotesSync": expected_effective,
    "MozFloorpNotesSyncRegistrationAllowed": expected_effective,
    "MozFloorpNotesSyncEngineRequestsAllowed": expected_effective,
    "MozFloorpNotesSyncUIExposureAllowed": expected_effective,
}
for key, expected in gate_keys.items():
    if key not in info or gate_value(info[key], key) != expected:
        reject(f"post-build gate contract mismatch for {key}")
if info.get("MozFloorpNotesSyncBuildMode") != mode:
    reject("post-build Notes Sync build mode does not match the requested mode")
if info.get("MozFloorpNotesSyncSourceSHA") != source_sha:
    reject("post-build Notes Sync source SHA does not match the requested source")
if info.get("MozFloorpNotesSyncEndpointAuthority") != "production":
    reject("post-build endpoint authority is not production")
if info.get("MozFloorpNotesSyncProtocol") != "sync15":
    reject("post-build Notes Sync protocol is not sync15")
if info.get("CFBundleIdentifier") != "app.floorp.Floorp":
    reject("post-build bundle identifier is not the Floorp release identifier")
preflight = json.loads(preflight_path.read_text())
ios_release_input = preflight["release_inputs"]["ios"]
if expected_effective:
    expected_ios_identity = {
        "repository": "Floorp-Projects/floorp-ios",
        "source_sha": source_sha,
        "configuration": "FloorpRelease",
    }
    if not isinstance(ios_release_input, dict):
        reject("validated evidence has no bound iOS release inputs")
    for field, expected in expected_ios_identity.items():
        if ios_release_input.get(field) != expected:
            reject(f"post-build iOS {field} is not bound to the release contract")
    built_build_number = info.get("CFBundleVersion")
    if not isinstance(built_build_number, str) or not built_build_number:
        reject("built CFBundleVersion is not a nonempty string")
    if ios_release_input.get("build_number") != built_build_number:
        reject("post-build iOS build number does not match CFBundleVersion")
elif ios_release_input is not None:
    reject("release-disabled preflight unexpectedly contains iOS release inputs")
if info.get("MozFloorpNotesSyncEndpointMatrixSHA256") != preflight["endpoint_authority"]["matrix_sha256"]:
    reject("post-build endpoint matrix digest does not match the approved authority")
embedded_digest = info.get("MozFloorpNotesSyncEvidenceDigest", "")
if embedded_digest != evidence_digest:
    reject("post-build evidence digest does not match validated evidence")

embedded_resource = app / "FloorpNotesSyncReleaseEvidence.json"
if expected_effective:
    if evidence_resource is None or not evidence_resource.is_file():
        reject("validated evidence resource was not generated")
    if not embedded_resource.is_file() or sha256(embedded_resource) != sha256(evidence_resource):
        reject("validated evidence resource was not embedded byte-for-byte")
    if info.get("MozFloorpNotesSyncEvidenceResourceSHA256") != sha256(evidence_resource):
        reject("post-build evidence resource digest does not match the embedded bytes")
elif embedded_resource.exists():
    reject("release-disabled app must not contain a Notes Sync evidence resource")
elif info.get("MozFloorpNotesSyncEvidenceResourceSHA256", "") != "":
    reject("release-disabled app must not bind a Notes Sync evidence resource digest")

executable_name = info.get("CFBundleExecutable")
executable = app / str(executable_name or "")
if not executable_name or not executable.is_file():
    reject("built app executable is missing")

frameworks = []
for framework in sorted(app.rglob("*.framework")):
    binary = framework / framework.stem
    if binary.is_file():
        frameworks.append(file_record(binary, base=app))
if not any("MozillaRustComponents.framework" in row["relative_path"] for row in frameworks):
    reject("built app has no MozillaRustComponents framework evidence")

with entitlements_path.open("rb") as handle:
    configured_entitlements = plistlib.load(handle)
expected_configured_entitlements = {
    "com.apple.developer.networking.multipath": True,
    "com.apple.security.application-groups": [
        "$(FLOORP_APP_GROUP_IDENTIFIER)"
    ],
    "keychain-access-groups": ["$(AppIdentifierPrefix)app.floorp.Floorp"],
}
if configured_entitlements != expected_configured_entitlements:
    reject("configured signing entitlements are not the exact Floorp release allowlist")

signed_entitlements = None
signing_verified = False
signing_identity = None
provisioning_profile_record = None

try:
    result = subprocess.run(
        [str(codesign_bin), "-d", "--entitlements", ":-", str(app)],
        capture_output=True,
        check=False,
    )
    payload = result.stdout
    if result.returncode == 0 and payload:
        signed_entitlements = plistlib.loads(payload)
except (OSError, plistlib.InvalidFileException):
    signed_entitlements = None

if allow_signing:
    if mode != "release-enabled" or action != "archive":
        reject("signed output is not a release-enabled archive")
    if destination != "generic/platform=iOS":
        reject("signed archive destination is not generic/platform=iOS")
    verification = subprocess.run(
        [str(codesign_bin), "--verify", "--deep", "--strict", str(app)],
        capture_output=True,
        check=False,
        text=True,
    )
    if verification.returncode != 0:
        detail = (verification.stderr or verification.stdout).strip()
        reject(f"codesign verification failed: {detail or 'no diagnostic'}")
    if not isinstance(signed_entitlements, dict) or not signed_entitlements:
        reject("signed archive has no readable signed entitlements")
    expected_team = "DV2U35YBHT"
    expected_bundle = "app.floorp.Floorp"
    expected_signed_entitlements = {
        "application-identifier": f"{expected_team}.{expected_bundle}",
        "com.apple.developer.networking.multipath": True,
        "com.apple.developer.team-identifier": expected_team,
        "com.apple.security.application-groups": [
            "group.app.floorp.Floorp.DV2U35YBHT"
        ],
        "keychain-access-groups": [f"{expected_team}.{expected_bundle}"],
    }
    if signed_entitlements != expected_signed_entitlements:
        reject(
            "signed entitlements are not the exact Floorp release allowlist; "
            "get-task-allow and unexpected entitlements are forbidden"
        )

    details = subprocess.run(
        [str(codesign_bin), "-d", "--verbose=4", str(app)],
        capture_output=True,
        check=False,
        text=True,
    )
    if details.returncode != 0:
        reject("signed archive has no readable signing identity")
    fields = {}
    authorities = []
    for line in details.stderr.splitlines():
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name == "Authority":
            authorities.append(value)
        else:
            fields[name] = value
    approved_distribution_prefixes = (
        "Apple Distribution: ",
        "iPhone Distribution: ",
    )
    approved_tail = [
        "Apple Worldwide Developer Relations Certification Authority",
        "Apple Root CA",
    ]
    if fields.get("Signature") == "adhoc" or not authorities:
        reject("signed archive uses an ad-hoc signature")
    if (
        len(authorities) != 3
        or not authorities[0].startswith(approved_distribution_prefixes)
        or f"({expected_team})" not in authorities[0]
        or authorities[1:] != approved_tail
    ):
        reject("signed archive does not have the approved Apple distribution authority chain")
    if fields.get("Identifier") != expected_bundle:
        reject("signed archive identity has the wrong bundle identifier")
    if fields.get("TeamIdentifier") != expected_team:
        reject("signed archive identity has the wrong TeamIdentifier")

    profile_path = app / "embedded.mobileprovision"
    if not profile_path.is_file() or profile_path.is_symlink():
        reject("signed archive is missing embedded.mobileprovision")
    decoded_profile = subprocess.run(
        [str(security_bin), "cms", "-D", "-i", str(profile_path)],
        capture_output=True,
        check=False,
    )
    if decoded_profile.returncode != 0 or not decoded_profile.stdout:
        reject("embedded.mobileprovision failed Apple CMS decoding")
    try:
        profile = plistlib.loads(decoded_profile.stdout)
    except plistlib.InvalidFileException as error:
        reject(f"embedded.mobileprovision is not a valid plist: {error}")
    if not isinstance(profile, dict):
        reject("embedded.mobileprovision root is not a dictionary")
    if final_clock_path is None:
        reject("signed archive verification requires a fresh validation clock")
    clock = json.loads(final_clock_path.read_text())
    try:
        trusted_now = parsedate_to_datetime(clock["github_http_date"]).astimezone(timezone.utc)
    except (KeyError, TypeError, ValueError) as error:
        reject(f"fresh validation clock has an invalid HTTP Date: {error}")

    def utc_datetime(value, label):
        if not hasattr(value, "tzinfo"):
            reject(f"embedded.mobileprovision {label} is not a date")
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    creation = utc_datetime(profile.get("CreationDate"), "CreationDate")
    expiration = utc_datetime(profile.get("ExpirationDate"), "ExpirationDate")
    if not creation <= trusted_now < expiration:
        reject("embedded.mobileprovision is not valid at the trusted GitHub time")
    if profile.get("TeamIdentifier") != [expected_team]:
        reject("embedded.mobileprovision TeamIdentifier does not match Floorp")
    if profile.get("ApplicationIdentifierPrefix") != [expected_team]:
        reject("embedded.mobileprovision application prefix does not match Floorp")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        reject("embedded.mobileprovision has no entitlement dictionary")
    if profile_entitlements.get("get-task-allow") is not False:
        reject("embedded.mobileprovision must explicitly disable get-task-allow")
    for key in (
        "application-identifier",
        "com.apple.developer.networking.multipath",
        "com.apple.developer.team-identifier",
    ):
        if profile_entitlements.get(key) != expected_signed_entitlements[key]:
            reject(f"embedded.mobileprovision entitlement {key} does not match Floorp")
    profile_app_groups = profile_entitlements.get("com.apple.security.application-groups")
    if not isinstance(profile_app_groups, list) or not set(
        expected_signed_entitlements["com.apple.security.application-groups"]
    ).issubset(profile_app_groups):
        reject("embedded.mobileprovision does not authorize the Floorp app group")
    profile_keychain_groups = profile_entitlements.get("keychain-access-groups")
    if not isinstance(profile_keychain_groups, list):
        reject("embedded.mobileprovision has no keychain-access-groups")
    for signed_group in expected_signed_entitlements["keychain-access-groups"]:
        if signed_group not in profile_keychain_groups and f"{expected_team}.*" not in profile_keychain_groups:
            reject("embedded.mobileprovision does not authorize the Floorp keychain group")
    profile_uuid = profile.get("UUID")
    profile_name = profile.get("Name")
    if not isinstance(profile_uuid, str) or not profile_uuid:
        reject("embedded.mobileprovision UUID is missing")
    if not isinstance(profile_name, str) or not profile_name:
        reject("embedded.mobileprovision Name is missing")
    developer_certificates = profile.get("DeveloperCertificates")
    if not (
        isinstance(developer_certificates, list)
        and developer_certificates
        and all(isinstance(value, bytes) and value for value in developer_certificates)
    ):
        reject("embedded.mobileprovision has no developer certificates")

    with tempfile.TemporaryDirectory() as temporary:
        extraction = subprocess.run(
            [str(codesign_bin), "-d", "--extract-certificates", str(app)],
            cwd=temporary,
            capture_output=True,
            check=False,
        )
        certificate_paths = sorted(Path(temporary).glob("codesign[0-9]*"))
        if extraction.returncode != 0 or not certificate_paths:
            reject("signed archive certificate chain could not be extracted")
        leaf_certificate = certificate_paths[0].read_bytes()
        if leaf_certificate not in developer_certificates:
            reject("signing certificate is not authorized by embedded.mobileprovision")
        verify_arguments = [str(security_bin), "verify-cert"]
        for certificate_path in certificate_paths:
            verify_arguments += ["-c", str(certificate_path)]
        verify_arguments += [
            "-p",
            "codeSign",
            "-d",
            trusted_now.strftime("%Y-%m-%d-%H:%M:%S"),
            "-q",
        ]
        certificate_verification = subprocess.run(
            verify_arguments,
            capture_output=True,
            check=False,
            text=True,
        )
        if certificate_verification.returncode != 0:
            reject("Apple signing certificate trust verification failed")
        leaf_certificate_sha256 = hashlib.sha256(leaf_certificate).hexdigest()

    signing_identity = {
        "authorities": authorities,
        "identifier": fields["Identifier"],
        "team_identifier": fields["TeamIdentifier"],
    }
    provisioning_profile_record = {
        "application_identifier_prefix": profile["ApplicationIdentifierPrefix"],
        "creation_date": creation.isoformat().replace("+00:00", "Z"),
        "expiration_date": expiration.isoformat().replace("+00:00", "Z"),
        "leaf_certificate_sha256": leaf_certificate_sha256,
        "name": profile_name,
        "path": str(profile_path),
        "sha256": sha256(profile_path),
        "team_identifier": profile["TeamIdentifier"],
        "uuid": profile_uuid,
    }
    signing_verified = True

manifest = {
    "schema_version": 1,
    "mode": mode,
    "source": {
        "commit": source_sha,
        "tree": source_tree,
        "dirty": False,
        "status_porcelain_sha256": hashlib.sha256(b"").hexdigest(),
        "snapshot": json.loads(source_snapshot_record_path.read_text()),
    },
    "build": {
        "action": action,
        "scheme": "Floorp",
        "configuration": "FloorpRelease",
        "destination": destination,
        "marketing_version": str(info.get("CFBundleShortVersionString", "")),
        "build_number": str(info.get("CFBundleVersion", "")),
        "bundle_id": str(info.get("CFBundleIdentifier", "")),
        "signing_allowed": allow_signing,
        "signing_verified": signing_verified,
        "signing_identity": signing_identity,
        "provisioning_profile": provisioning_profile_record,
        "xcode_version": xcode_version_path.read_text().splitlines(),
        "toolchain": json.loads(toolchain_record_path.read_text()),
        "xcodebuild_arguments": json.loads(command_json_path.read_text()),
    },
    "paths": {
        "output": str(output),
        "app": str(app),
        "archive": str(archive) if archive else None,
        "build_log": str(build_log),
    },
    "contract_inputs": {
        "xcconfig_path": str(xcconfig),
        "xcconfig_sha256": sha256(xcconfig),
        "evidence_resource_path": str(evidence_resource) if evidence_resource else None,
        "evidence_resource_sha256": sha256(evidence_resource) if evidence_resource else None,
        "validator_path": str(validator) if validator.is_file() else None,
        "validator_sha256": sha256(validator) if validator.is_file() else None,
        "schema_path": str(schema) if schema.is_file() else None,
        "schema_sha256": sha256(schema) if schema.is_file() else None,
        "source_snapshot": json.loads(source_snapshot_record_path.read_text()),
        "initial_snapshot_record_path": str(initial_snapshot_record_path)
        if initial_snapshot_record_path
        else None,
        "initial_snapshot_record_sha256": initial_snapshot_record_sha256 or None,
        "initial_local_artifact_snapshot_record_path": str(
            initial_local_snapshot_record_path
        )
        if initial_local_snapshot_record_path
        else None,
        "initial_local_artifact_snapshot_record_sha256": (
            initial_local_snapshot_record_sha256 or None
        ),
        "snapshot_record_path": str(final_snapshot_record_path)
        if final_snapshot_record_path
        else None,
        "snapshot_record_sha256": final_snapshot_record_sha256 or None,
        "snapshots": json.loads(final_snapshot_record_path.read_text())
        if final_snapshot_record_path
        else None,
        "local_artifact_snapshot_record_path": str(final_local_snapshot_record_path)
        if final_local_snapshot_record_path
        else None,
        "local_artifact_snapshot_record_sha256": final_local_snapshot_record_sha256
        or None,
        "local_artifact_snapshots": json.loads(final_local_snapshot_record_path.read_text())
        if final_local_snapshot_record_path
        else None,
    },
    "release_inputs": preflight["release_inputs"],
    "endpoint_authority": preflight["endpoint_authority"],
    "evidence": {
        "embedded_digest_sha256": evidence_digest or None,
        "embedded_resource": file_record(embedded_resource, base=app) if embedded_resource.is_file() else None,
        "clock_run_id": preflight["clock_run_id"],
        "clock_manifest_path": preflight["clock_manifest_path"],
        "clock_manifest_sha256": preflight["clock_manifest_sha256"],
    },
    "gate": {
        "requested": expected_effective,
        "effective": expected_effective,
    },
    "runtime_contract": {
        "engine_registration_allowed": expected_effective,
        "engine_requests_allowed": expected_effective,
        "ui_exposure_allowed": expected_effective,
    },
    "artifacts": {
        "app_merkle_sha256": merkle_digest(app),
        "executable": file_record(executable, base=app),
        "info_plist": file_record(info_path, base=app),
        "entitlements": {
            "source": file_record(entitlements_path),
            "configured": configured_entitlements,
            "signed": signed_entitlements,
        },
        "application_services": {
            **preflight["application_services"],
            "frameworks": frameworks,
        },
    },
}
manifest_payload = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
try:
    manifest_descriptor = os.open(
        manifest_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
except FileExistsError:
    reject("temporary manifest already exists")
try:
    os.write(manifest_descriptor, manifest_payload)
    os.fsync(manifest_descriptor)
finally:
    os.close(manifest_descriptor)
PY
"$CHMOD_BIN" a-w "$MANIFEST_TMP"
MANIFEST_TMP_SHA256="$("$SHASUM_BIN" -a 256 "$MANIFEST_TMP" | "$AWK_BIN" '{print $1}')"
verify_contract_snapshots
verify_source_snapshot
if [[ -n "$PUBLICATION_DIR" ]]; then
    verify_snapshot_record \
        "$PUBLICATION_DIR" "$FINAL_SNAPSHOT_RECORD" "$FINAL_SNAPSHOT_RECORD_SHA256"
    local_artifact_snapshot verify \
        "$PUBLICATION_DIR" "$FINAL_LOCAL_SNAPSHOT_RECORD" \
        "$FINAL_LOCAL_SNAPSHOT_RECORD_SHA256"
fi

SOURCE_STATUS_FINAL="$("$GIT_BIN" -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
[[ "$SOURCE_STATUS_FINAL" == "$SOURCE_STATUS_BEFORE" && -z "$SOURCE_STATUS_FINAL" ]] \
    || fail "source worktree changed while writing the manifest"

if [[ "$MODE" != "release-disabled" ]]; then
    if ! "$PYTHON_BIN" "$FINAL_VALIDATOR" \
        --schema "$FINAL_SCHEMA" \
        --evidence "$FINAL_EVIDENCE_RESOURCE" \
        --validation-clock-manifest "$FINAL_CLOCK" \
        --canonicalization rfc8785-jcs; then
        echo "build-floorp-notes-sync-ios: final release validator rejected $MODE evidence" >&2
        exit 1
    fi
fi

verify_contract_snapshots
verify_source_snapshot
if [[ -n "$PUBLICATION_DIR" ]]; then
    verify_snapshot_record \
        "$PUBLICATION_DIR" "$FINAL_SNAPSHOT_RECORD" "$FINAL_SNAPSHOT_RECORD_SHA256"
    local_artifact_snapshot verify \
        "$PUBLICATION_DIR" "$FINAL_LOCAL_SNAPSHOT_RECORD" \
        "$FINAL_LOCAL_SNAPSHOT_RECORD_SHA256"
fi
SOURCE_STATUS_FINAL="$("$GIT_BIN" -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
[[ "$SOURCE_STATUS_FINAL" == "$SOURCE_STATUS_BEFORE" && -z "$SOURCE_STATUS_FINAL" ]] \
    || fail "source worktree changed immediately before manifest publication"

"$PYTHON_BIN" - "$MANIFEST_TMP" "$MANIFEST" "$MANIFEST_TMP_SHA256" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1]).resolve(strict=True)
target = Path(sys.argv[2]).resolve(strict=False)
expected_sha256 = sys.argv[3]


def reject(message):
    print(f"build-floorp-notes-sync-ios: {message}", file=sys.stderr)
    raise SystemExit(2)


if source.is_symlink() or not stat.S_ISREG(source.stat().st_mode):
    reject("temporary manifest is not a regular file")
payload = source.read_bytes()
if hashlib.sha256(payload).hexdigest() != expected_sha256:
    reject("temporary manifest changed before append-only publication")
try:
    manifest = json.loads(payload)
    app = Path(manifest["paths"]["app"]).resolve(strict=True)
    expected_app_digest = manifest["artifacts"]["app_merkle_sha256"]
except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
    reject(f"temporary manifest artifact binding is invalid ({error})")
if not app.is_dir() or app.is_symlink():
    reject("built app is unavailable immediately before publication")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def merkle_digest(root):
    digest = hashlib.sha256()
    for path in sorted(
        root.rglob("*"),
        key=lambda item: item.relative_to(root).as_posix(),
    ):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            row = f"L\0{relative}\0{os.readlink(path)}\n"
        elif path.is_file():
            row = f"F\0{relative}\0{path.stat().st_size}\0{sha256(path)}\n"
        else:
            continue
        digest.update(row.encode("utf-8"))
    return digest.hexdigest()


if merkle_digest(app) != expected_app_digest:
    reject("built app changed after release validation")
parent = target.parent.resolve(strict=True)
parent_flags = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
parent_descriptor = os.open(parent, parent_flags)
parent_before = os.fstat(parent_descriptor)
flags = (
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
try:
    descriptor = os.open(target.name, flags, 0o600, dir_fd=parent_descriptor)
except FileExistsError:
    os.close(parent_descriptor)
    reject("manifest already exists; refusing append-only replacement")
try:
    offset = 0
    while offset < len(payload):
        offset += os.write(descriptor, payload[offset:])
    os.fsync(descriptor)
except BaseException:
    os.close(descriptor)
    try:
        os.unlink(target.name, dir_fd=parent_descriptor)
    except OSError:
        pass
    os.close(parent_descriptor)
    raise
else:
    published = os.fstat(descriptor)
    os.close(descriptor)
entry = os.stat(target.name, dir_fd=parent_descriptor, follow_symlinks=False)
if (published.st_dev, published.st_ino) != (entry.st_dev, entry.st_ino):
    os.unlink(target.name, dir_fd=parent_descriptor)
    os.close(parent_descriptor)
    reject("published manifest entry changed during creation")
source.unlink()
os.fsync(parent_descriptor)
parent_after = os.stat(parent, follow_symlinks=False)
if (parent_before.st_dev, parent_before.st_ino) != (
    parent_after.st_dev,
    parent_after.st_ino,
):
    os.unlink(target.name, dir_fd=parent_descriptor)
    os.close(parent_descriptor)
    reject("manifest parent changed during publication")
os.close(parent_descriptor)
PY

echo "$MANIFEST"
