#!/usr/bin/env bash

# Prepare generated Floorp sources in Xcode Cloud's clean checkout.

set -euo pipefail

# Xcode Cloud has no interactive "Trust & Enable" prompt for Swift macro
# packages; skip macro fingerprint validation so packages such as
# ModifiedCopyMacro can be used without a one-time local approval.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

readonly REPOSITORY_PATH="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
readonly CI_SCRIPTS_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# A curated-catalog candidate is tag-bound twice: GitHub Actions checks it
# before requesting a build, and this gate checks the commit Xcode Cloud
# actually cloned before any generated source or archive is produced.
bash "${CI_SCRIPTS_PATH}/verify_curated_catalog_candidate_source.sh" "${REPOSITORY_PATH}"

readonly NODE_VERSION="$(<"${REPOSITORY_PATH}/.nvmrc")"

case "$(uname -m)" in
    arm64)
        readonly NODE_ARCH="arm64"
        readonly NODE_SHA256="eb02f7fab96d3d67de40c5ec8566096fcb4c2026728787683ae5a97eb612b941"
        ;;
    x86_64)
        readonly NODE_ARCH="x64"
        readonly NODE_SHA256="6fb20fceacbb157c2f95825b80df4a454a0f6d81cdcd7bb81eeae9147e0e76ec"
        ;;
    *)
        echo "Unsupported Xcode Cloud architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

if [[ "${NODE_VERSION}" != "24.18.1" ]]; then
    echo "Update ci_post_clone.sh checksums for Node.js ${NODE_VERSION}." >&2
    exit 1
fi

readonly NODE_DIRECTORY="${TMPDIR:-/tmp}/floorp-node-${NODE_VERSION}"
readonly NODE_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/floorp-node.XXXXXX.tar.gz")"
readonly NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
trap 'rm -f "${NODE_ARCHIVE}"' EXIT

curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "${NODE_URL}" --output "${NODE_ARCHIVE}"
printf '%s  %s\n' "${NODE_SHA256}" "${NODE_ARCHIVE}" | shasum -a 256 --check

mkdir -p "${NODE_DIRECTORY}"
tar -xzf "${NODE_ARCHIVE}" --strip-components=1 -C "${NODE_DIRECTORY}"
export PATH="${NODE_DIRECTORY}/bin:${PATH}"

node --version
CI=true "${REPOSITORY_PATH}/bootstrap.sh" firefox
