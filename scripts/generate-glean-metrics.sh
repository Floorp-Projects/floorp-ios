#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR PROJECT_ROOT
readonly FIREFOX_ROOT="${PROJECT_ROOT}/firefox-ios"
readonly GLEAN_FILE_LIST="${FIREFOX_ROOT}/Client/Glean/gleanProbes.xcfilelist"
readonly GENERATOR="${FIREFOX_ROOT}/bin/sdk_generator.sh"
readonly OUTPUT_DIR="${FIREFOX_ROOT}/Client/Generated/Metrics"

if [[ "${ACTION:-build}" == "indexbuild" ]]; then
    echo "Skipping Glean code generation for indexbuild."
    exit 0
fi

definitions=(
    "${FIREFOX_ROOT}/Client/Glean/pings.yaml"
    "${FIREFOX_ROOT}/Client/Glean/tags.yaml"
)
while IFS= read -r line; do
    [[ "${line}" == '$(PROJECT_DIR)/Client/Glean/probes/'* ]] || continue
    relative_path="${line#\$\(PROJECT_DIR\)/}"
    definition="${FIREFOX_ROOT}/${relative_path}"
    if [[ ! -f "${definition}" ]]; then
        echo "Missing Glean definition: ${definition}" >&2
        exit 1
    fi
    definitions+=("${definition}")
done < "${GLEAN_FILE_LIST}"

if [[ "${#definitions[@]}" -le 2 ]]; then
    echo "No Glean probes found in ${GLEAN_FILE_LIST}" >&2
    exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/floorp-glean.XXXXXX")"
cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT

ACTION=build SOURCE_ROOT="${FIREFOX_ROOT}" PROJECT=Client \
    bash "${GENERATOR}" -g Glean -o "${temporary_dir}" "${definitions[@]}"

generated_file="${temporary_dir}/Metrics.swift"
if [[ ! -s "${generated_file}" ]]; then
    echo "Glean generator did not produce Metrics.swift" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
staged_file="$(mktemp "${OUTPUT_DIR}/.Metrics.swift.XXXXXX")"
install -m 0644 "${generated_file}" "${staged_file}"
mv -f "${staged_file}" "${OUTPUT_DIR}/Metrics.swift"
