#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <iOS-Simulator-UDID>" >&2
    exit 64
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
simulator_udid="$1"
revision="$(git -C "${repository_root}" rev-parse --verify HEAD^{commit})"

if [[ ! "${revision}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Stage 3 performance measurement requires a 40-character Git HEAD." >&2
    exit 65
fi

assert_clean_revision() {
    local current_revision
    current_revision="$(git -C "${repository_root}" rev-parse --verify HEAD^{commit})"
    if [[ "${current_revision}" != "${revision}" ]]; then
        echo "Git HEAD changed during Stage 3 performance measurement." >&2
        return 66
    fi
    if [[ -n "$(git -C "${repository_root}" status --porcelain=v1 --untracked-files=all)" ]]; then
        echo "Stage 3 performance measurement requires a clean worktree, including no untracked files." >&2
        return 67
    fi
}

assert_clean_revision || exit $?

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_nonce="$(uuidgen | tr '[:upper:]' '[:lower:]')"
if [[ -n "${FLOORP_STAGE3_DERIVED_DATA_PATH:-}" ]]; then
    derived_data="${FLOORP_STAGE3_DERIVED_DATA_PATH}"
    if ! mkdir -m 700 "${derived_data}"; then
        echo "Stage 3 performance measurement requires a new, empty DerivedData path." >&2
        exit 68
    fi
else
    # A source revision alone is not enough: a previous dirty build may have
    # used the same HEAD.  Allocate a fresh, private directory for every run
    # so test-without-building cannot execute stale products.
    derived_data="$(mktemp -d "/private/tmp/floorp-stage3-performance-${revision:0:12}-${timestamp}.XXXXXX")"
fi
result_bundle="${FLOORP_STAGE3_RESULT_BUNDLE_PATH:-/private/tmp/floorp-stage3-performance-${revision:0:12}-${timestamp}-${run_nonce}.xcresult}"
attachment_directory="${result_bundle%.xcresult}-attachments"
selector="ClientTests/FloorpWebExtensionStage3SimulatorPerformanceTests/testRecordsDemandingFixtureSimulatorPerformanceScopes"

if [[ -e "${result_bundle}" || -e "${attachment_directory}" ]]; then
    echo "Refusing to overwrite an existing Stage 3 result or attachment path." >&2
    exit 68
fi

xcodebuild build-for-testing \
    -project "${repository_root}/firefox-ios/Client.xcodeproj" \
    -scheme Fennec \
    -configuration Fennec_Testing \
    -destination "platform=iOS Simulator,id=${simulator_udid}" \
    -testPlan FloorpCI \
    -only-testing:"${selector}" \
    -derivedDataPath "${derived_data}"

assert_clean_revision || exit $?

app_path="${derived_data}/Build/Products/Fennec_Testing-iphonesimulator/Client.app"
codesign --verify --deep --strict --verbose=4 "${app_path}"
codesign --verify --deep --strict --verbose=4 "${app_path}/PlugIns/ClientTests.xctest"

xcodebuild test-without-building \
    -project "${repository_root}/firefox-ios/Client.xcodeproj" \
    -scheme Fennec \
    -configuration Fennec_Testing \
    -destination "platform=iOS Simulator,id=${simulator_udid}" \
    -testPlan FloorpCI \
    -only-testing:"${selector}" \
    -derivedDataPath "${derived_data}" \
    -resultBundlePath "${result_bundle}" \
    FLOORP_STAGE3_SOURCE_REVISION="${revision}" \
    FLOORP_STAGE3_CLEAN_WORKTREE_ATTESTED_REVISION="${revision}" \
    FLOORP_STAGE3_WORKTREE_STATE="clean"

if assert_clean_revision; then
    :
else
    attestation_status=$?
    if [[ -e "${result_bundle}" ]]; then
        /usr/bin/find "${result_bundle}" -depth -delete
    fi
    exit "${attestation_status}"
fi

xcrun xcresulttool get test-results summary --path "${result_bundle}"
xcrun xcresulttool export attachments \
    --path "${result_bundle}" \
    --output-path "${attachment_directory}"

echo "FLOORP_STAGE3_SOURCE_REVISION=${revision}"
echo "FLOORP_STAGE3_RESULT_BUNDLE=${result_bundle}"
echo "FLOORP_STAGE3_ATTACHMENT_DIRECTORY=${attachment_directory}"
