#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SWIFTLINT_BIN="${1:?Pass the SwiftLint executable as the first argument}"
readonly REQUESTED_BASE_SHA="${2:-}"
readonly HEAD_SHA="${3:-HEAD}"
readonly BATCH_SIZE=100

cd "${PROJECT_ROOT}"

base_sha="${REQUESTED_BASE_SHA}"
if [[ -z "${base_sha}" || "${base_sha}" =~ ^0+$ ]] || ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    base_sha="$(git rev-parse "${HEAD_SHA}^")"
fi

declare -a swift_files=()
while IFS= read -r -d '' file; do
    if [[ "${file}" == focus-ios/* ]]; then
        continue
    fi
    swift_files+=("${file}")
done < <(git diff --diff-filter=ACMR --name-only -z "${base_sha}" "${HEAD_SHA}" -- '*.swift')

if [[ "${#swift_files[@]}" -eq 0 ]]; then
    echo "No added or modified Swift files to lint."
    exit 0
fi

printf 'Linting %d changed Swift file(s).\n' "${#swift_files[@]}"
for ((start = 0; start < ${#swift_files[@]}; start += BATCH_SIZE)); do
    batch=("${swift_files[@]:start:BATCH_SIZE}")
    "${SWIFTLINT_BIN}" lint --strict --quiet --config "${PROJECT_ROOT}/.swiftlint.yml" "${batch[@]}"
done
