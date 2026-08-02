#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly PACKAGE_FILE="${PROJECT_ROOT}/MozillaRustComponents/Package.swift"
readonly PIN_FILE="${PROJECT_ROOT}/MozillaRustComponents/FloorpApplicationServicesPin.json"
readonly EXPECTED_REPOSITORY="Floorp-Projects/application-services"

verify_remote=false
case "${1:-}" in
    "") ;;
    --verify-remote) verify_remote=true ;;
    *)
        echo "Usage: $0 [--verify-remote]" >&2
        exit 2
        ;;
esac

for command_name in jq sed grep; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[FAIL] ${command_name} is required." >&2
        exit 2
    fi
done

if [[ ! -f "${PACKAGE_FILE}" || ! -f "${PIN_FILE}" ]]; then
    echo "[FAIL] Application Services package or pin metadata is missing." >&2
    exit 1
fi

if ! jq -e --arg repository "${EXPECTED_REPOSITORY}" '
    .schemaVersion == 1
    and .repository == $repository
    and (.artifactVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]{14}$"))
    and (.release.tag | test("^floorp-ios-[0-9]+\\.[0-9]{14}\\.[1-9][0-9]*$"))
    and .release.immutable == true
    and .release.prerelease == true
    and (.release.id | type == "number")
    and (.release.revision | type == "number")
    and (.release.sourceCommit | test("^[0-9a-f]{40}$"))
    and (.release.sourceTree | test("^[0-9a-f]{40}$"))
    and .upstream.repository == "mozilla/application-services"
    and (.upstream.commit | test("^[0-9a-f]{40}$"))
    and ((.assets | keys | sort) == [
        "FocusRustComponents.xcframework.zip",
        "MozillaRustComponents.xcframework.zip",
        "SHA256SUMS",
        "release-manifest.json",
        "swift-components.tar.xz"
    ])
    and ([.assets[] | .sha256] | all(test("^[0-9a-f]{64}$")))
    and ([.assets[] | .size] | all(type == "number" and . > 0))
    and (.assets["FocusRustComponents.xcframework.zip"].swiftPMChecksum
        == .assets["FocusRustComponents.xcframework.zip"].sha256)
    and (.assets["MozillaRustComponents.xcframework.zip"].swiftPMChecksum
        == .assets["MozillaRustComponents.xcframework.zip"].sha256)
' "${PIN_FILE}" >/dev/null; then
    echo "[FAIL] Floorp Application Services pin metadata is invalid." >&2
    exit 1
fi

repository="$(jq -er '.repository' "${PIN_FILE}")"
artifact_version="$(jq -er '.artifactVersion' "${PIN_FILE}")"
release_tag="$(jq -er '.release.tag' "${PIN_FILE}")"
release_url="$(jq -er '.release.url' "${PIN_FILE}")"
release_revision="$(jq -er '.release.revision' "${PIN_FILE}")"
release_base="https://github.com/${repository}/releases/download/${release_tag}"
mozilla_asset="MozillaRustComponents.xcframework.zip"
focus_asset="FocusRustComponents.xcframework.zip"
mozilla_url="${release_base}/${mozilla_asset}"
focus_url="${release_base}/${focus_asset}"
mozilla_checksum="$(jq -er --arg asset "${mozilla_asset}" '.assets[$asset].swiftPMChecksum' "${PIN_FILE}")"
focus_checksum="$(jq -er --arg asset "${focus_asset}" '.assets[$asset].swiftPMChecksum' "${PIN_FILE}")"

extract_swift_value() {
    local variable_name="$1"
    local value

    value="$(sed -nE "s/^let ${variable_name} = \"([^\"]+)\"$/\\1/p" "${PACKAGE_FILE}")"
    if [[ -z "${value}" || "${value}" == *$'\n'* ]]; then
        echo "[FAIL] Expected exactly one literal for ${variable_name} in Package.swift." >&2
        exit 1
    fi
    printf '%s' "${value}"
}

assert_equal() {
    local description="$1"
    local actual="$2"
    local expected="$3"

    if [[ "${actual}" != "${expected}" ]]; then
        printf '[FAIL] %s\n  expected: %s\n  actual:   %s\n' \
            "${description}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

assert_equal "artifact version" "$(extract_swift_value version)" "${artifact_version}"
assert_equal \
    "release tag" \
    "${release_tag}" \
    "floorp-ios-${artifact_version%%.*}.${artifact_version##*.}.${release_revision}"
assert_equal \
    "release URL" \
    "${release_url}" \
    "https://github.com/${repository}/releases/tag/${release_tag}"
assert_equal "Mozilla binary URL" "$(extract_swift_value url)" "${mozilla_url}"
assert_equal "Mozilla SwiftPM checksum" "$(extract_swift_value checksum)" "${mozilla_checksum}"
assert_equal "Focus binary URL" "$(extract_swift_value focusUrl)" "${focus_url}"
assert_equal "Focus SwiftPM checksum" "$(extract_swift_value focusChecksum)" "${focus_checksum}"

if grep -Fq 'firefox-ci-tc.services.mozilla.com' "${PACKAGE_FILE}"; then
    echo "[FAIL] Package.swift must not use the mutable Mozilla Taskcluster index." >&2
    exit 1
fi

printf '[PASS] Package.swift uses Floorp release %s with pinned SwiftPM checksums.\n' \
    "${release_tag}"

if [[ "${verify_remote}" != true ]]; then
    exit 0
fi

for command_name in curl diff; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[FAIL] ${command_name} is required for remote verification." >&2
        exit 2
    fi
done

remote_temp="$(mktemp -d "${TMPDIR:-/tmp}/floorp-as-pin.XXXXXX")"
cleanup() {
    find "${remote_temp}" -depth -delete
}
trap cleanup EXIT

api_curl_args=(
    --proto '=https'
    --proto-redir '=https'
    --tlsv1.2
    --fail
    --silent
    --show-error
    --location
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    api_curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

download_curl_args=(
    --proto '=https'
    --proto-redir '=https'
    --tlsv1.2
    --fail
    --silent
    --show-error
    --location
)

release_api="https://api.github.com/repos/${repository}/releases/tags/${release_tag}"
ref_api="https://api.github.com/repos/${repository}/git/ref/tags/${release_tag}"
curl "${api_curl_args[@]}" "${release_api}" --output "${remote_temp}/release.json"
curl "${api_curl_args[@]}" "${ref_api}" --output "${remote_temp}/ref.json"

if ! jq -e --slurpfile pin "${PIN_FILE}" '
    $pin[0] as $pin
    | .id == $pin.release.id
    and .tag_name == $pin.release.tag
    and .html_url == $pin.release.url
    and .draft == false
    and .prerelease == $pin.release.prerelease
    and .immutable == $pin.release.immutable
' "${remote_temp}/release.json" >/dev/null; then
    echo "[FAIL] Published release metadata no longer matches the immutable pin." >&2
    exit 1
fi

if ! jq -e --slurpfile pin "${PIN_FILE}" '
    $pin[0] as $pin
    | .ref == ("refs/tags/" + $pin.release.tag)
    and .object.type == "commit"
    and .object.sha == $pin.release.sourceCommit
' "${remote_temp}/ref.json" >/dev/null; then
    echo "[FAIL] Published release tag does not resolve to the pinned source commit." >&2
    exit 1
fi

if ! diff -u \
    <(jq -r '.assets | keys[]' "${PIN_FILE}" | LC_ALL=C sort) \
    <(jq -r '.assets[].name' "${remote_temp}/release.json" | LC_ALL=C sort); then
    echo "[FAIL] Published release asset names do not match the pin." >&2
    exit 1
fi

while IFS= read -r asset; do
    expected_digest="sha256:$(jq -er --arg asset "${asset}" '.assets[$asset].sha256' "${PIN_FILE}")"
    expected_size="$(jq -er --arg asset "${asset}" '.assets[$asset].size' "${PIN_FILE}")"
    expected_url="${release_base}/${asset}"
    if ! jq -e \
        --arg asset "${asset}" \
        --arg digest "${expected_digest}" \
        --arg url "${expected_url}" \
        --argjson size "${expected_size}" '
        [.assets[] | select(
            .name == $asset
            and .digest == $digest
            and .browser_download_url == $url
            and .size == $size
        )] | length == 1
    ' "${remote_temp}/release.json" >/dev/null; then
        echo "[FAIL] Published metadata does not match ${asset}." >&2
        exit 1
    fi
done < <(jq -r '.assets | keys[]' "${PIN_FILE}")

curl "${download_curl_args[@]}" "${release_base}/SHA256SUMS" \
    --output "${remote_temp}/SHA256SUMS"
curl "${download_curl_args[@]}" "${release_base}/release-manifest.json" \
    --output "${remote_temp}/release-manifest.json"

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

assert_equal \
    "SHA256SUMS digest" \
    "$(sha256_file "${remote_temp}/SHA256SUMS")" \
    "$(jq -er '.assets.SHA256SUMS.sha256' "${PIN_FILE}")"
assert_equal \
    "release manifest digest" \
    "$(sha256_file "${remote_temp}/release-manifest.json")" \
    "$(jq -er '.assets["release-manifest.json"].sha256' "${PIN_FILE}")"

if ! diff -u \
    <(jq -r '
        .assets
        | to_entries[]
        | select(.key != "SHA256SUMS")
        | "\(.value.sha256)  \(.key)"
    ' "${PIN_FILE}" | LC_ALL=C sort) \
    <(LC_ALL=C sort "${remote_temp}/SHA256SUMS"); then
    echo "[FAIL] Published SHA256SUMS does not match the release pin." >&2
    exit 1
fi

if ! jq -e --slurpfile pin "${PIN_FILE}" '
    $pin[0] as $pin
    | .schema_version == 1
    and .repository == $pin.repository
    and .release_tag == $pin.release.tag
    and .release_revision == $pin.release.revision
    and .immutable_release_required == true
    and .source.commit == $pin.release.sourceCommit
    and .source.tree == $pin.release.sourceTree
    and .upstream.repository == $pin.upstream.repository
    and .upstream.commit == $pin.upstream.commit
    and .upstream.artifact_version == $pin.artifactVersion
    and .artifacts["FocusRustComponents.xcframework.zip"].sha256
        == $pin.assets["FocusRustComponents.xcframework.zip"].sha256
    and .artifacts["FocusRustComponents.xcframework.zip"].swiftpm_checksum
        == $pin.assets["FocusRustComponents.xcframework.zip"].swiftPMChecksum
    and .artifacts["MozillaRustComponents.xcframework.zip"].sha256
        == $pin.assets["MozillaRustComponents.xcframework.zip"].sha256
    and .artifacts["MozillaRustComponents.xcframework.zip"].swiftpm_checksum
        == $pin.assets["MozillaRustComponents.xcframework.zip"].swiftPMChecksum
    and .artifacts["swift-components.tar.xz"].sha256
        == $pin.assets["swift-components.tar.xz"].sha256
' "${remote_temp}/release-manifest.json" >/dev/null; then
    echo "[FAIL] Published release manifest does not match the release pin." >&2
    exit 1
fi

for binary_url in "${mozilla_url}" "${focus_url}"; do
    http_code="$(curl \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --fail \
        --silent \
        --show-error \
        --head \
        --location \
        --output /dev/null \
        --write-out '%{http_code}' \
        "${binary_url}")"
    assert_equal "binary asset availability" "${http_code}" "200"
done

printf '[PASS] GitHub release %s is published, immutable, complete, and source-pinned.\n' \
    "${release_url}"
