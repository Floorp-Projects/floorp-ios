#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/floorp-rebrand-dry-run.XXXXXX")"
readonly SCRIPT_DIR PROJECT_ROOT FIXTURE_ROOT

cleanup() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FIXTURE_ROOT}/scripts"
mkdir -p "${FIXTURE_ROOT}/firefox-ios/Client/Telemetry"
cp "${PROJECT_ROOT}/scripts/rebrand-to-floorp.sh" "${FIXTURE_ROOT}/scripts/rebrand-to-floorp.sh"

cat > "${FIXTURE_ROOT}/firefox-ios/Client/Telemetry/TelemetryWrapper.swift" <<'EOF'
final class TelemetryWrapper {
    func initGlean() {
        configureGlean()
    }
}
EOF
cp "${FIXTURE_ROOT}/firefox-ios/Client/Telemetry/TelemetryWrapper.swift" \
    "${FIXTURE_ROOT}/TelemetryWrapper.expected.swift"

"${FIXTURE_ROOT}/scripts/rebrand-to-floorp.sh" --dry-run >/dev/null

if [[ -e "${FIXTURE_ROOT}/firefox-ios/Floorp" ]]; then
    echo "dry-run created the Floorp source directory" >&2
    exit 1
fi

if ! cmp -s \
    "${FIXTURE_ROOT}/TelemetryWrapper.expected.swift" \
    "${FIXTURE_ROOT}/firefox-ios/Client/Telemetry/TelemetryWrapper.swift"; then
    echo "dry-run modified TelemetryWrapper.swift" >&2
    exit 1
fi

echo "Floorp rebrand dry-run is non-mutating."
