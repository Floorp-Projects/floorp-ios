#!/usr/bin/env bash

set -euo pipefail

readonly upstream_sha256="20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64"
readonly normalized_timestamp="202607150218.00"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_root="$(cd "${script_dir}/.." && pwd)"
readonly compatibility_patch="${repository_root}/firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch"

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <upstream-darkreader-chrome-mv3.zip> <output.zip>" >&2
    exit 64
fi

readonly upstream_archive="$1"
readonly requested_output_archive="$2"

if [[ ! -f "${upstream_archive}" ]]; then
    echo "upstream archive does not exist: ${upstream_archive}" >&2
    exit 66
fi

actual_sha256="$(shasum -a 256 "${upstream_archive}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${upstream_sha256}" ]]; then
    echo "upstream SHA-256 mismatch: expected ${upstream_sha256}, got ${actual_sha256}" >&2
    exit 65
fi

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/floorp-darkreader-package.XXXXXX")"
trap 'rm -rf "${staging_directory}"' EXIT

unzip -q "${upstream_archive}" -d "${staging_directory}"
# Dark Reader ships generated JavaScript bundles with CRLF line endings.
# Normalize the files touched by the reviewable compatibility patch so the
# patch itself remains portable and free of embedded CR bytes.
perl -pi -e 's/\r\n/\n/g' \
    "${staging_directory}/background/index.js" \
    "${staging_directory}/ui/devtools/index.js" \
    "${staging_directory}/ui/options/index.js" \
    "${staging_directory}/ui/stylesheet-editor/index.js" \
    "${staging_directory}/ui/popup/index.js"
patch -s -F 0 -V none -d "${staging_directory}" -p1 < "${compatibility_patch}"
if find "${staging_directory}" -type f \( -name '*.orig' -o -name '*.rej' \) -print -quit \
    | grep -q .; then
    echo "patch created an unexpected backup or reject file" >&2
    exit 65
fi

# Normalize metadata and ordering so the reviewed package digest is reproducible.
find "${staging_directory}" -type f -exec env TZ=UTC touch -t "${normalized_timestamp}" {} +
mkdir -p "$(dirname "${requested_output_archive}")"
readonly output_archive="$(cd "$(dirname "${requested_output_archive}")" && pwd)/$(basename "${requested_output_archive}")"
rm -f "${output_archive}"
(
    cd "${staging_directory}"
    find . -type f -print | LC_ALL=C sort | TZ=UTC zip -q -X "${output_archive}" -@
)

unzip -tqq "${output_archive}"
shasum -a 256 "${output_archive}"
