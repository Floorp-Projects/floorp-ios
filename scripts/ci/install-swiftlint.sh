#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

set -euo pipefail

readonly SWIFTLINT_VERSION="0.62.2"
readonly SWIFTLINT_SHA256="79625bece2716395d955d34a5993e6c948ef57d0256abe5538aaab82f2ad6b68"
readonly SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
readonly INSTALL_DIRECTORY="${1:?Pass an installation directory as the first argument}"

archive_path="$(mktemp "${TMPDIR:-/tmp}/floorp-swiftlint.XXXXXX.zip")"
trap 'rm -f "${archive_path}"' EXIT

curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
    --location "${SWIFTLINT_URL}" --output "${archive_path}"
printf '%s  %s\n' "${SWIFTLINT_SHA256}" "${archive_path}" | shasum -a 256 --check

mkdir -p "${INSTALL_DIRECTORY}"
ditto -x -k "${archive_path}" "${INSTALL_DIRECTORY}"
"${INSTALL_DIRECTORY}/swiftlint" version
