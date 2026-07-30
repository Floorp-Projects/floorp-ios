#!/usr/bin/env bash

#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#
# Pass either 'firefox' (default) or 'focus' to specify which product
# Use the --force option to force a re-build locales.

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PRODUCT="${1:-firefox}"
readonly FORCE_BOOTSTRAP="${2:-}"

# Keep this revision aligned with Mozilla Application Services updates.
# The checksum prevents executing a mutable or corrupted bootstrap payload.
readonly NIMBUS_SCRIPT_REVISION="f515906ebb956a1a1cd6ad51d0f8877a6a8675f3"
readonly NIMBUS_SCRIPT_SHA256="443a72235811e6367914f80b2eacc900d55913442cb9d594930170e0e2cc5da4"
readonly NIMBUS_SCRIPT_URL="https://raw.githubusercontent.com/mozilla/application-services/${NIMBUS_SCRIPT_REVISION}/components/nimbus/ios/scripts/nimbus-fml.sh"

install_nimbus_script() {
    local destination="${PROJECT_ROOT}/firefox-ios/bin/nimbus-fml.sh"
    local current_checksum=""
    local temporary_file

    if [[ -f "${destination}" ]]; then
        current_checksum="$(shasum -a 256 "${destination}" | awk '{print $1}')"
    fi

    if [[ "${current_checksum}" == "${NIMBUS_SCRIPT_SHA256}" ]]; then
        echo "Nimbus FML script is already up to date."
        return
    fi

    temporary_file="$(mktemp "${TMPDIR:-/tmp}/floorp-nimbus-fml.XXXXXX")"

    curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
        --location "${NIMBUS_SCRIPT_URL}" --output "${temporary_file}"
    if ! printf '%s  %s\n' "${NIMBUS_SCRIPT_SHA256}" "${temporary_file}" | shasum -a 256 --check; then
        rm -f "${temporary_file}"
        return 1
    fi
    install -m 0755 "${temporary_file}" "${destination}"
    rm -f "${temporary_file}"
}

install_git_hooks() {
    case "${CI:-false}" in
        true|TRUE|1) return ;;
    esac

    cp -R "${PROJECT_ROOT}/.githooks/." "${PROJECT_ROOT}/.git/hooks/"
    chmod +x "${PROJECT_ROOT}/.git/hooks/"*
}

cd "${PROJECT_ROOT}"

if [[ "${PRODUCT}" == "firefox" ]]; then
    echo "Running Floorp bootstrap..."

    if [[ "${FORCE_BOOTSTRAP}" == "--force" ]]; then
        rm -rf "${PROJECT_ROOT}/build" \
            "${PROJECT_ROOT}/firefox-ios/build/nimbus" \
            "${PROJECT_ROOT}/firefox-ios/.venv"
    elif [[ -n "${FORCE_BOOTSTRAP}" ]]; then
        echo "Unknown option: ${FORCE_BOOTSTRAP}" >&2
        echo "Usage: $0 [firefox|focus] [--force]" >&2
        exit 1
    fi

    command -v npm >/dev/null 2>&1 || {
        echo "npm is required. Install the Node.js version declared in .nvmrc." >&2
        exit 1
    }

    install_nimbus_script
    install_git_hooks

    # package-lock.json is authoritative in local builds and CI.
    npm ci
    npm run build

elif [[ "${PRODUCT}" == "focus" ]]; then
    echo "Running Focus script..."

    set -x
    cd focus-ios

    # Version 107.0 hash
    SHAVAR_COMMIT_HASH="91cf7dd142fc69aabe334a1a6e0091a1db228203"

    # Download the nimbus-fml.sh script from application-services.
    NIMBUS_FML_FILE=./nimbus.fml.yaml
    curl --proto '=https' --tlsv1.2 -sSf  https://raw.githubusercontent.com/mozilla/application-services/main/components/nimbus/ios/scripts/bootstrap.sh | bash -s -- $NIMBUS_FML_FILE

    # Clone shavar prod list
    cd .. # Make sure we are at the root of the repo
    rm -rf shavar-prod-lists && git clone https://github.com/mozilla-services/shavar-prod-lists.git && git -C shavar-prod-lists checkout $SHAVAR_COMMIT_HASH

    cd BrowserKit
    swift run || true
    swift run

else
    echo "Unknown product: $PRODUCT"
    echo "Usage: $0 [firefox|focus] [--force]"
    exit 1
fi
