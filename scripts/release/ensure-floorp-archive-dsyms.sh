#!/usr/bin/env bash
# Ensures that the Floorp archive contains a UUID-matched dSYM for the
# prebuilt Glean framework. glean-swift 69.0.0 does not ship a dSYM in its
# binary artifact, so Xcode cannot add one to the archive on its own.

set -euo pipefail

log_prefix="Floorp Glean archive dSYM"

skip() {
    echo "${log_prefix}: skipping ($1)"
    exit 0
}

fail() {
    echo "error: ${log_prefix}: $1" >&2
    exit 1
}

configuration="${CONFIGURATION:-}"
action="${ACTION:-}"
platform_name="${PLATFORM_NAME:-}"

[[ "${configuration}" == "FloorpRelease" ]] \
    || skip "configuration is ${configuration:-unset}, not FloorpRelease"
case "${action}" in
    archive|install) ;;
    *) skip "action is ${action:-unset}, not archive/install" ;;
esac
[[ "${platform_name}" == "iphoneos" ]] \
    || skip "platform is ${platform_name:-unset}, not iphoneos"

[[ "${DEPLOYMENT_LOCATION:-}" == "YES" ]] \
    || fail "FloorpRelease archive/install must use DEPLOYMENT_LOCATION=YES"
[[ "${TARGET_NAME:-}" == "Client" ]] \
    || fail "unexpected target ${TARGET_NAME:-unset}; expected Client"

[[ -n "${CODESIGNING_FOLDER_PATH:-}" ]] \
    || fail "CODESIGNING_FOLDER_PATH is unset"
[[ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]] \
    || fail "DWARF_DSYM_FOLDER_PATH is unset"
glean_binary="${CODESIGNING_FOLDER_PATH}/Frameworks/Glean.framework/Glean"
dsym_path="${DWARF_DSYM_FOLDER_PATH}/Glean.framework.dSYM"
xcrun_path="/usr/bin/xcrun"

# Production builds pass no arguments. Tool substitution exists only so the
# fail-closed mismatch path can be exercised by this script's unit tests.
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" == "--test-xcrun" ]] \
        || fail "unexpected arguments"
    xcrun_path="$2"
fi

[[ -n "${glean_binary}" ]] || fail "Glean binary path is unset"
[[ -f "${glean_binary}" ]] \
    || fail "embedded Glean binary is missing at ${glean_binary}"
[[ -n "${dsym_path}" ]] || fail "dSYM output path is unset"
[[ "$(basename "${dsym_path}")" == "Glean.framework.dSYM" ]] \
    || fail "refusing unexpected dSYM output path ${dsym_path}"
[[ -x "${xcrun_path}" ]] || fail "xcrun is unavailable at ${xcrun_path}"

normalize_uuids() {
    awk '
        $1 == "UUID:" {
            gsub(/-/, "", $2)
            print toupper($2)
        }
    ' | LC_ALL=C sort -u
}

validate_uuid_list() {
    local description="$1"
    local values="$2"
    local value

    [[ -n "${values}" ]] || fail "${description} contains no Mach-O UUID"
    while IFS= read -r value; do
        [[ "${value}" =~ ^[0-9A-F]{32}$ ]] \
            || fail "${description} returned an invalid UUID: ${value}"
    done <<< "${values}"
}

binary_uuid_output="$("${xcrun_path}" dwarfdump --uuid "${glean_binary}" 2>&1)" \
    || fail "dwarfdump failed for embedded Glean binary: ${binary_uuid_output}"
binary_uuids="$(printf '%s\n' "${binary_uuid_output}" | normalize_uuids)"
validate_uuid_list "embedded Glean binary" "${binary_uuids}"

dsym_parent="$(dirname "${dsym_path}")"
mkdir -p "${dsym_parent}"
work_dir="$(mktemp -d "${dsym_parent}/.floorp-glean-dsym.XXXXXX")" \
    || fail "could not create a temporary dSYM directory"

cleanup() {
    if [[ -n "${work_dir:-}" && -d "${work_dir}" ]]; then
        find "${work_dir}" -depth -delete
    fi
}
trap cleanup EXIT

candidate="${work_dir}/Glean.framework.dSYM"
if ! dsymutil_output="$("${xcrun_path}" dsymutil "${glean_binary}" -o "${candidate}" 2>&1)"; then
    fail "dsymutil failed: ${dsymutil_output}"
fi
if [[ -n "${dsymutil_output}" ]]; then
    printf '%s\n' "${dsymutil_output}"
fi

candidate_dwarf="${candidate}/Contents/Resources/DWARF/Glean"
[[ -s "${candidate_dwarf}" ]] \
    || fail "dsymutil did not produce a non-empty Glean DWARF companion"

dsym_uuid_output="$("${xcrun_path}" dwarfdump --uuid "${candidate_dwarf}" 2>&1)" \
    || fail "dwarfdump failed for generated Glean dSYM: ${dsym_uuid_output}"
dsym_uuids="$(printf '%s\n' "${dsym_uuid_output}" | normalize_uuids)"
validate_uuid_list "generated Glean dSYM" "${dsym_uuids}"

if [[ "${binary_uuids}" != "${dsym_uuids}" ]]; then
    fail "UUID mismatch; binary=[${binary_uuids//$'\n'/,}] dSYM=[${dsym_uuids//$'\n'/,}]"
fi

debug_info_path="${work_dir}/debug-info.txt"
if ! "${xcrun_path}" dwarfdump --debug-info "${candidate_dwarf}" \
    > "${debug_info_path}" 2>&1; then
    fail "could not inspect generated Glean debug information: $(<"${debug_info_path}")"
fi
if ! grep -q 'DW_TAG_compile_unit' "${debug_info_path}"; then
    echo "warning: ${log_prefix}: glean-swift provides no source-level DWARF; " \
        "the generated dSYM supplies the required UUID companion and only the symbols retained upstream" >&2
fi

if [[ -e "${dsym_path}" || -L "${dsym_path}" ]]; then
    find "${dsym_path}" -depth -delete
fi
mv "${candidate}" "${dsym_path}"

final_dwarf="${dsym_path}/Contents/Resources/DWARF/Glean"
final_uuid_output="$("${xcrun_path}" dwarfdump --uuid "${final_dwarf}" 2>&1)" \
    || fail "dwarfdump failed for installed Glean dSYM: ${final_uuid_output}"
final_uuids="$(printf '%s\n' "${final_uuid_output}" | normalize_uuids)"
[[ "${final_uuids}" == "${binary_uuids}" ]] \
    || fail "installed Glean dSYM changed after validation"

echo "${log_prefix}: generated ${dsym_path} for UUID(s) ${binary_uuids//$'\n'/,}"
