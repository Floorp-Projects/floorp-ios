#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly CHECK_SCRIPT="${SCRIPT_DIR}/check-application-services-pin.sh"
readonly SOURCE_CONFIGURATION_FILTER="${SCRIPT_DIR}/application-services-source-configuration.jq"
readonly PACKAGE_FILE="${PROJECT_ROOT}/MozillaRustComponents/Package.swift"
readonly PIN_FILE="${PROJECT_ROOT}/MozillaRustComponents/FloorpApplicationServicesPin.json"
readonly FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/floorp-as-sync.XXXXXX")"

cleanup() {
    find "${FIXTURE_ROOT}" -depth -delete
}
trap cleanup EXIT

for command_name in awk cmp cp find git grep jq mkdir mktemp mv; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[FAIL] ${command_name} is required for the Application Services sync test." >&2
        exit 2
    fi
done

write_common_base() {
    local source_file="$1"
    local destination_file="$2"

    awk '
        /^let checksum = / {
            print "let checksum = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
            next
        }
        /^let version = / {
            print "let version = \"154.0.20260730000000\""
            next
        }
        /^let url = / {
            print "let url = \"https://firefox-ci-tc.services.mozilla.com/old/MozillaRustComponents.xcframework.zip\""
            next
        }
        /^let focusChecksum = / {
            print "let focusChecksum = \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\""
            next
        }
        /^let focusUrl = / {
            print "let focusUrl = \"https://firefox-ci-tc.services.mozilla.com/old/FocusRustComponents.xcframework.zip\""
            next
        }
        { print }
    ' "${source_file}" > "${destination_file}"
}

write_upstream_bump() {
    local source_file="$1"
    local destination_file="$2"

    awk '
        /^import PackageDescription$/ {
            print
            print "// Upstream package change must survive Floorp pin restoration."
            next
        }
        /^let checksum = / {
            print "let checksum = \"1111111111111111111111111111111111111111111111111111111111111111\""
            next
        }
        /^let version = / {
            print "let version = \"156.0.20260803010101\""
            next
        }
        /^let url = / {
            print "let url = \"https://firefox-ci-tc.services.mozilla.com/new/MozillaRustComponents.xcframework.zip\""
            next
        }
        /^let focusChecksum = / {
            print "let focusChecksum = \"2222222222222222222222222222222222222222222222222222222222222222\""
            next
        }
        /^let focusUrl = / {
            print "let focusUrl = \"https://firefox-ci-tc.services.mozilla.com/new/FocusRustComponents.xcframework.zip\""
            next
        }
        /\.package\(url: "https:\/\/github.com\/mozilla\/glean-swift", from: "69\.0\.0"\)/ {
            sub(/69\.0\.0/, "70.0.0")
        }
        { print }
    ' "${source_file}" > "${destination_file}"
}

strip_managed_literals() {
    awk '
        /^let checksum = / { next }
        /^let version = / { next }
        /^let url = / { next }
        /^let focusChecksum = / { next }
        /^let focusUrl = / { next }
        { print }
    ' "$1"
}

run_pin_check() {
    local package_file="$1"
    local operation="${2:-}"

    if [[ -n "${operation}" ]]; then
        FLOORP_APPLICATION_SERVICES_PACKAGE_FILE="${package_file}" \
        FLOORP_APPLICATION_SERVICES_PIN_FILE="${PIN_FILE}" \
            "${CHECK_SCRIPT}" "${operation}" >/dev/null
    else
        FLOORP_APPLICATION_SERVICES_PACKAGE_FILE="${package_file}" \
        FLOORP_APPLICATION_SERVICES_PIN_FILE="${PIN_FILE}" \
            "${CHECK_SCRIPT}" >/dev/null
    fi
}

assert_unmanaged_content_preserved() {
    local upstream_file="$1"
    local resolved_file="$2"
    local expected_file="${FIXTURE_ROOT}/expected-unmanaged"
    local actual_file="${FIXTURE_ROOT}/actual-unmanaged"

    strip_managed_literals "${upstream_file}" > "${expected_file}"
    strip_managed_literals "${resolved_file}" > "${actual_file}"
    if ! cmp -s "${expected_file}" "${actual_file}"; then
        echo "[FAIL] Floorp pin restoration changed unmanaged Package.swift content." >&2
        exit 1
    fi
    grep -Fq '// Upstream package change must survive Floorp pin restoration.' \
        "${resolved_file}"
    grep -Fq 'from: "70.0.0"' "${resolved_file}"
}

clean_fixture="${FIXTURE_ROOT}/clean"
mkdir -p "${clean_fixture}"
write_upstream_bump "${PACKAGE_FILE}" "${clean_fixture}/Package.upstream.swift"
cp "${clean_fixture}/Package.upstream.swift" "${clean_fixture}/Package.swift"
run_pin_check "${clean_fixture}/Package.swift" --apply
run_pin_check "${clean_fixture}/Package.swift"
assert_unmanaged_content_preserved \
    "${clean_fixture}/Package.upstream.swift" \
    "${clean_fixture}/Package.swift"

source_configuration_fixture="${FIXTURE_ROOT}/source-configuration.json"
jq -n --slurpfile pin "${PIN_FILE}" '
    $pin[0] as $pin
    | {
        schema_version: 1,
        distribution_repository: $pin.repository,
        release_tag_pattern: "^floorp-ios-[0-9]+\\.[0-9]{14}\\.[1-9][0-9]*$",
        release_tag_example: "floorp-ios-155.20260731050244.1",
        upstream: {
            repository: $pin.upstream.repository,
            commit: $pin.upstream.commit,
            source_version: $pin.upstream.sourceVersion,
            artifact_version: $pin.artifactVersion
        },
        immutable_releases_required: true,
        artifacts: [
            "FocusRustComponents.xcframework.zip",
            "MozillaRustComponents.xcframework.zip",
            "swift-components.tar.xz"
        ]
    }
' > "${source_configuration_fixture}"
jq -e \
    --slurpfile pin "${PIN_FILE}" \
    -f "${SOURCE_CONFIGURATION_FILTER}" \
    "${source_configuration_fixture}" >/dev/null

invalid_source_configuration="${FIXTURE_ROOT}/source-configuration-invalid.json"
jq '.release_tag_example = "mutable-tag"' \
    "${source_configuration_fixture}" > "${invalid_source_configuration}"
if jq -e \
    --slurpfile pin "${PIN_FILE}" \
    -f "${SOURCE_CONFIGURATION_FILTER}" \
    "${invalid_source_configuration}" >/dev/null; then
    echo "[FAIL] Source configuration accepted an example outside its release pattern." >&2
    exit 1
fi

shape_fixture="${FIXTURE_ROOT}/shape-drift"
mkdir -p "${shape_fixture}"
awk '
    /^let focusUrl = / {
        sub(/^let focusUrl = /, "let renamedFocusUrl = ")
    }
    { print }
' "${PACKAGE_FILE}" > "${shape_fixture}/Package.swift"
cp "${shape_fixture}/Package.swift" "${shape_fixture}/Package.expected.swift"
if FLOORP_APPLICATION_SERVICES_PACKAGE_FILE="${shape_fixture}/Package.swift" \
    FLOORP_APPLICATION_SERVICES_PIN_FILE="${PIN_FILE}" \
    "${CHECK_SCRIPT}" --apply >/dev/null 2>&1; then
    echo "[FAIL] Pin restoration accepted a changed managed declaration shape." >&2
    exit 1
fi
if ! cmp -s "${shape_fixture}/Package.expected.swift" "${shape_fixture}/Package.swift"; then
    echo "[FAIL] Failed pin restoration partially rewrote Package.swift." >&2
    exit 1
fi

conflict_repo="${FIXTURE_ROOT}/conflict-repository"
mkdir -p "${conflict_repo}/MozillaRustComponents"
write_common_base "${PACKAGE_FILE}" \
    "${conflict_repo}/MozillaRustComponents/Package.swift"
cp "${PIN_FILE}" \
    "${conflict_repo}/MozillaRustComponents/FloorpApplicationServicesPin.json"

git -C "${conflict_repo}" init --quiet
git -C "${conflict_repo}" config user.name "Floorp Application Services Test"
git -C "${conflict_repo}" config user.email "floorp-as-test@example.invalid"
git -C "${conflict_repo}" config commit.gpgSign false
git -C "${conflict_repo}" add .
git -C "${conflict_repo}" commit --quiet -m base
base_commit="$(git -C "${conflict_repo}" rev-parse HEAD)"

git -C "${conflict_repo}" checkout --quiet -b floorp
FLOORP_APPLICATION_SERVICES_PACKAGE_FILE="${conflict_repo}/MozillaRustComponents/Package.swift" \
FLOORP_APPLICATION_SERVICES_PIN_FILE="${conflict_repo}/MozillaRustComponents/FloorpApplicationServicesPin.json" \
    "${CHECK_SCRIPT}" --apply >/dev/null
git -C "${conflict_repo}" add MozillaRustComponents/Package.swift
git -C "${conflict_repo}" commit --quiet -m floorp-pin

git -C "${conflict_repo}" checkout --quiet -b upstream "${base_commit}"
write_upstream_bump \
    "${conflict_repo}/MozillaRustComponents/Package.swift" \
    "${conflict_repo}/MozillaRustComponents/Package.upstream.swift"
mv "${conflict_repo}/MozillaRustComponents/Package.upstream.swift" \
    "${conflict_repo}/MozillaRustComponents/Package.swift"
git -C "${conflict_repo}" add MozillaRustComponents/Package.swift
git -C "${conflict_repo}" commit --quiet -m upstream-bump

git -C "${conflict_repo}" checkout --quiet floorp
if git -C "${conflict_repo}" merge --no-commit --no-ff upstream >/dev/null 2>&1; then
    echo "[FAIL] Expected the simulated upstream Application Services bump to conflict." >&2
    exit 1
fi
if [[ -z "$(git -C "${conflict_repo}" ls-files -u -- MozillaRustComponents/Package.swift)" ]]; then
    echo "[FAIL] Simulated merge did not produce the expected Package.swift conflict." >&2
    exit 1
fi

git -C "${conflict_repo}" show \
    upstream:MozillaRustComponents/Package.swift > "${conflict_repo}/Package.upstream.expected.swift"
git -C "${conflict_repo}" checkout --theirs -- MozillaRustComponents/Package.swift
FLOORP_APPLICATION_SERVICES_PACKAGE_FILE="${conflict_repo}/MozillaRustComponents/Package.swift" \
FLOORP_APPLICATION_SERVICES_PIN_FILE="${conflict_repo}/MozillaRustComponents/FloorpApplicationServicesPin.json" \
    "${CHECK_SCRIPT}" --apply >/dev/null
git -C "${conflict_repo}" add MozillaRustComponents/Package.swift

if [[ -n "$(git -C "${conflict_repo}" ls-files -u)" ]]; then
    echo "[FAIL] Application Services conflict resolution left unmerged entries." >&2
    exit 1
fi
run_pin_check "${conflict_repo}/MozillaRustComponents/Package.swift"
assert_unmanaged_content_preserved \
    "${conflict_repo}/Package.upstream.expected.swift" \
    "${conflict_repo}/MozillaRustComponents/Package.swift"
git -C "${conflict_repo}" diff --cached --check

echo "Floorp Application Services pin survives clean and conflicting upstream bumps."
