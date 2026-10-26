#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Vendored from mozilla/application-services at f515906ebb956a1a1cd6ad51d0f8877a6a8675f3.
# Pristine SHA-256: 443a72235811e6367914f80b2eacc900d55913442cb9d594930170e0e2cc5da4.
# Floorp cache changes and installation integrity are documented in README.md.

# Nimbus Feature Manifest Language Generator
#
# For more information, check out https://experimenter.info/fml-spec
#
# This script generates Swift definitions for all the experimentable features supported by Nimbus.
# It generates Swift code to be included in the final build.
#
# To use it in a Swift project, follow these steps:
# 1. Import the `nimbus-fml.sh` script into your project.
# 2. Edit the `nimbus-fml-configuration.sh` file to suit your project.
# 3. Add a `<NAME>.fml.yaml` feature manifest file. Check out https://experimenter.info/fml-spec for the spec.
# 4. Test the new file by running this file from SOURCE_ROOT.
# 5. Add a new "Run Script" build step and set the command to `bash $PWD/nimbus-fml.sh`.
# 6. Run the build.
# 7. Add the "FML.swift" file in the `Generated` folder to your project.
# 8. Add the same "FML.swift" from the `Generated` folder as Output Files of the newly created "Run Script" step.
# 9. Start using the generated feature code.
set -euo pipefail

DIRNAME=$(dirname "$0")

# CMDNAME is used in the usage text below.
# shellcheck disable=SC2034
CMDNAME=$(basename "$0")
USAGE=$(cat <<HEREDOC
${CMDNAME}

Nimbus Feature Manifest Language generator initializer.

This script generates the code needed to interact with Nimbus, exposing features which are experimentable.

For more information, check out https://experimenter.info/fml-spec

The script structure was adopted from the similar script "sdk_generator.sh" written by the Glean team.

This script should be executed as a "Run Build Script" phase from Xcode, but you can run it from the command line
if you define "PROJECT", "CONFIGURATION" and "SOURCE_ROOT" environment variables.

Application-specific configuration options for this script has moved to ./nimbus-fml-configuration.sh alongside this file.

Local developer specific configuration should go in ./nimbus-fml-configuration.local.sh and not checked into to source control.

USAGE:
    ${CMDNAME} [OPTIONS] [FILE]

OPTIONS:
    -a, --use-fml-version <REF>      Version or reference of nimbus-fml to use. If missing, derives from the project.pbxproj file.
    -F, --fresh                      Re-download the nimbus-fml binary.
    -h, --help                       display this help message.
HEREDOC
)

helptext() {
    echo "$USAGE"
}

# fail_trap is executed if an error occurs.
fail_trap() {
  local result=$1
  local line_number=$2
  echo "Error calling nimbus-fml.sh at line ${line_number}"
  exit "$result"
}

#Stop execution on any error
trap 'fail_trap $? $LINENO' ERR

if [ -z "${SOURCE_ROOT:-}" ] ; then
    echo "Warning: No \$SOURCE_ROOT defined."
    echo "  Execute this script as a build step in Xcode."
    echo "  Guessing it as CWD"
    SOURCE_ROOT="$(pwd)"
fi

if [ -z "${PROJECT:-}" ]; then
    echo "Warning: No \$PROJECT defined."
    echo "  Execute this script as a build step in Xcode."
    xcodeproj=$(ls -d "${SOURCE_ROOT}"/*.xcodeproj || exit 2 | head -n 1 )
    PROJECT=$(basename -s .xcodeproj "$xcodeproj")
    echo "  Detected it as $PROJECT"
fi

if [ -z "${CONFIGURATION:-}" ] ; then
    echo "Warning: No \$CONFIGURATION defined."
    echo "  Execute this script as a build step in Xcode."
    echo "  Guessing it as Debug"
    CONFIGURATION=Debug
fi

# Note: This will be deprecated soon in favor of local SPM in firefox-ios!
# Find the application-services version when using rust-components-swift
find_as_version_remote() {
    # We can derive the version we need by looking at the project file.
    number_string=$(grep -A 3 $'https://github.com/mozilla/rust-components-swift' "$SOURCE_ROOT/$PROJECT.xcodeproj/project.pbxproj" | grep -E -o "\d+\.\d+\.\d+")
    if [ -z "$number_string" ]; then
        # If there is no rust-components then perhaps we're building with a local versions of rust_components, using rust_components_local.sh .
        # We try to resolve that, and find the version from the Package.swift file in that local directory.
        # https://github.com/mozilla-mobile/firefox-ios/issues/12243
        rust_components_path=$(grep -A 3 $'XCRemoteSwiftPackageReference "rust-components-swift"' "$SOURCE_ROOT/$PROJECT.xcodeproj/project.pbxproj" | grep 'repositoryURL = "file://' | grep -o -E '/\w[^"]+')
        if [ -n "$rust_components_path" ]; then
            number_string=$(grep 'let version =' "$rust_components_path/Package.swift" | grep -E -o "\d+\.\d+\.\d+")
        fi
    fi
    
    # Return the number_string (could be empty)
    echo "$number_string"
}

# Find the version number via the Package.swift of the local swift package in firefox-ios
find_as_version_local() {
    # Look for local Package.swift in the firefox-ios repository
    local package_swift_path="$SOURCE_ROOT/../MozillaRustComponents/Package.swift"

    if [ -f "$package_swift_path" ]; then
        number_string=$(grep 'let version =' "$package_swift_path" | grep -E -o "\d+\.\d+\.\d+")
        echo "$number_string"
    else
        echo ""
    fi
}

process_version_string() {
    local number_string="$1"
    
    if [ -z "$number_string" ]; then
        echo "Error: No application-services version was detected."
        echo "The package must be added as a project dependency or available locally."
        exit 2
    fi

    ## We try and differentiate between two version types.
    ## Nightlies: 121.0.20231027173509 --> 121.20231027173509
    ## Releases:  120.0.0 --> 120.0
    ##            120.0.1 --> 120.0.1
    ##            120.1.0 --> 120.1.0
    # Get the last component, i.e. the patch number…
    local patch=${number_string##*.}
    # … and check if it's more that 2 digits in length
    if [[ ${#patch} -gt 2 ]] ; then
        # If so, then it's likely a date stamp, so a nightly.
        # We have a middle 0 which we need to get rid of,
        # because taskcluster's versions are MAJOR.DATETIME
        AS_VERSION=${number_string//\.0\./\.}
    else
        # Otherwise, it's a release!
        # These versions have rules about zero
        # minor number and patch numbers, so we
        # rationalize that.
        AS_VERSION=${number_string/\.0\.0/.0}
    fi
}

find_as_version() {
    local version_string
    
    # Try remote first
    version_string=$(find_as_version_remote)
    
    # If remote didn't work, try local
    if [ -z "$version_string" ]; then
        version_string=$(find_as_version_local)
    fi
    
    # Process the version string (handles error cases too)
    process_version_string "$version_string"
}
FRESHEN_FML=
AS_VERSION=
MOZ_APPSERVICES_LOCAL=
REPO_FILES=
NIMBUS_DIR="$SOURCE_ROOT/build/nimbus"

export CACHE_DIR="$NIMBUS_DIR/fml-cache"
export APP_FML_FILE="$PROJECT/nimbus.fml.yaml"
export GENERATED_SRC_DIR=
export MOZ_APPSERVICES_MODULE=MozillaAppServices
export MODULES=$PROJECT

echo "Using $DIRNAME/nimbus-fml-configuration.sh as config"
# shellcheck disable=SC1091
source "$DIRNAME/nimbus-fml-configuration.sh"

local_config="$DIRNAME/nimbus-fml-configuration.local.sh"
if [ -f "$local_config" ] ; then
    echo "Modifying with $local_config"
    # shellcheck disable=SC1090
    source "$local_config"
fi

while (( "$#" )); do
    case "$1" in
        -o|--output)
            GENERATED_SRC_DIR=$2
            shift 2
            ;;
        -h|--help)
            helptext
            exit 0
            ;;
        -a|--use-fml-version)
            AS_VERSION=$2
            shift 2
            ;;
        -F|--fresh)
            FRESHEN_FML="true"
            shift 1
            ;;
        --verbose)
            set -x
            shift 1
            ;;
        --) # end argument parsing
            shift
            break
            ;;
        --*=|-*) # unsupported flags
            echo "Error: Unsupported flag $1" >&2
            exit 1
            ;;
        *) # preserve positional arguments
            APP_FML_FILE=$1
            shift
            ;;
    esac
done

if [ -z "$APP_FML_FILE" ]; then
    if [ -z "$SCRIPT_INPUT_FILE_COUNT" ] || [ "$SCRIPT_INPUT_FILE_COUNT" -eq 0 ]; then
        echo "Error: No input files provided for the Nimbus Feature Manifest."
        exit 2
    fi
    APP_FML_FILE=$SCRIPT_INPUT_FILE_0
fi

if [ -n "$MOZ_APPSERVICES_LOCAL" ] ; then
    # If we've specified where app-services lives, perhaps we can run from a local copy.
    LOCAL_FML_DIR="$MOZ_APPSERVICES_LOCAL/components/support/nimbus-fml"
    export BINARY_PATH="$HOME/.cargo/bin/cargo run --manifest-path $LOCAL_FML_DIR/Cargo.toml --"
else
    if [ -z "$AS_VERSION" ] ; then
        find_as_version
    fi

    # Otherwise, we should download a pre-built copy
    AS_DOWNLOAD_URL="https://archive.mozilla.org/pub/app-services/releases/$AS_VERSION"
    CHECKSUM_URL="$AS_DOWNLOAD_URL/nimbus-fml.sha256"
    FML_URL="$AS_DOWNLOAD_URL/nimbus-fml.zip"
    FML_DIR="$NIMBUS_DIR/$AS_VERSION/bin"
    CACHED_BINARY_PATH="$FML_DIR/nimbus-fml"
    mkdir -p "$FML_DIR"
    FML_DOWNLOAD_DIR=$(mktemp -d "$FML_DIR/.download.XXXXXX")
    trap 'rm -rf "$FML_DOWNLOAD_DIR"' EXIT
    CACHED_ZIP_DIRECTORY="$FML_DOWNLOAD_DIR/cache"
    mkdir "$CACHED_ZIP_DIRECTORY"
    if [[ -f "$FML_DIR/nimbus-fml.zip" ]]; then
        cp "$FML_DIR/nimbus-fml.zip" "$CACHED_ZIP_DIRECTORY/nimbus-fml.zip"
    fi

    checksum_from_file() {
        local checksum pattern
        [[ -f "$1" ]] || return 1
        checksum=$(cat "$1")
        pattern='^([[:xdigit:]]{64})[[:space:]]+[*]?nimbus-fml[.]zip$'
        [[ "$checksum" =~ $pattern ]] || return 1
        printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
    }

    verified_zip() {
        local actual
        [[ -f "$1/nimbus-fml.zip" ]] || return 1
        actual=$(shasum -a 256 "$1/nimbus-fml.zip" | awk '{print $1}') || return 1
        [[ "$actual" == "$2" ]]
    }

    fetch_checksum() {
        local status
        status=$(curl --fail -L --silent --show-error --write-out '%{http_code}' \
            --output "$FML_DOWNLOAD_DIR/nimbus-fml.sha256" "$CHECKSUM_URL") || return 1
        [[ "$status" == "200" ]]
    }

    CHECKSUM_AVAILABLE=false
    if fetch_checksum; then
        CHECKSUM_AVAILABLE=true
    else
        AS_DOWNLOAD_URL="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/project.application-services.v2.nimbus-fml.$AS_VERSION/artifacts/public%2Fbuild%2F"
        CHECKSUM_URL="${AS_DOWNLOAD_URL}nimbus-fml.sha256"
        FML_URL="${AS_DOWNLOAD_URL}nimbus-fml.zip"
        if fetch_checksum; then
            CHECKSUM_AVAILABLE=true
        fi
    fi

    ZIP_DIRECTORY="$CACHED_ZIP_DIRECTORY"
    REPLACE_CACHE=false
    if [[ "$CHECKSUM_AVAILABLE" == true ]]; then
        if ! NEW_CHECKSUM=$(checksum_from_file "$FML_DOWNLOAD_DIR/nimbus-fml.sha256"); then
            echo "Error: The downloaded Nimbus FML checksum is invalid." >&2
            exit 1
        fi
        OLD_CHECKSUM=$(checksum_from_file "$FML_DIR/nimbus-fml.sha256") || OLD_CHECKSUM=
        if [[ -n "$FRESHEN_FML" || "$OLD_CHECKSUM" != "$NEW_CHECKSUM" ]] \
            || ! verified_zip "$CACHED_ZIP_DIRECTORY" "$NEW_CHECKSUM"; then
            echo "Downloading to $FML_DIR"
            curl --fail -L --silent --show-error "$FML_URL" --output "$FML_DOWNLOAD_DIR/nimbus-fml.zip"
            if ! verified_zip "$FML_DOWNLOAD_DIR" "$NEW_CHECKSUM"; then
                echo "Error: The downloaded Nimbus FML ZIP does not match its checksum." >&2
                exit 1
            fi
            ZIP_DIRECTORY="$FML_DOWNLOAD_DIR"
            REPLACE_CACHE=true
        fi
    else
        if [[ -n "$FRESHEN_FML" ]]; then
            echo "Error: Cannot refresh Nimbus FML while the remote checksum is unavailable." >&2
            exit 1
        fi
        if ! OLD_CHECKSUM=$(checksum_from_file "$FML_DIR/nimbus-fml.sha256") \
            || ! verified_zip "$CACHED_ZIP_DIRECTORY" "$OLD_CHECKSUM"; then
            echo "Error: Remote Nimbus FML checksum unavailable and no verified cache exists for $AS_VERSION." >&2
            exit 1
        fi
        echo "Warning: Remote Nimbus FML checksum unavailable; using verified cache for $AS_VERSION." >&2
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" == 'x86_64' ]]; then
        EXE_ARCH=x86_64-apple-darwin
    elif [[ "$ARCH" == 'arm64' ]]; then
        EXE_ARCH=aarch64-apple-darwin
    else
        echo "Error: Unsupported architecture. This script can only run on Mac devices running x86_64 or arm64"
        exit 2
    fi
    if ! unzip -p "$ZIP_DIRECTORY/nimbus-fml.zip" "$EXE_ARCH/release/nimbus-fml" \
        > "$FML_DOWNLOAD_DIR/nimbus-fml" || [[ ! -s "$FML_DOWNLOAD_DIR/nimbus-fml" ]]; then
        echo "Error: The verified Nimbus FML ZIP does not contain the required binary." >&2
        exit 1
    fi
    chmod 755 "$FML_DOWNLOAD_DIR/nimbus-fml"
    if [[ "$REPLACE_CACHE" == true ]]; then
        mv "$FML_DOWNLOAD_DIR/nimbus-fml.zip" "$FML_DIR/nimbus-fml.zip"
        mv "$FML_DOWNLOAD_DIR/nimbus-fml.sha256" "$FML_DIR/nimbus-fml.sha256"
    fi
    if ! cmp -s "$FML_DOWNLOAD_DIR/nimbus-fml" "$CACHED_BINARY_PATH"; then
        cp "$FML_DOWNLOAD_DIR/nimbus-fml" "$FML_DOWNLOAD_DIR/nimbus-fml.cached"
        mv "$FML_DOWNLOAD_DIR/nimbus-fml.cached" "$CACHED_BINARY_PATH"
    else
        chmod 755 "$CACHED_BINARY_PATH"
    fi
    export BINARY_PATH="$FML_DOWNLOAD_DIR/nimbus-fml"
fi

echo_eval() {
    local CMD="$*"
    # Truncating the absolute paths into something easier to read.
    local display=${CMD//"$SOURCE_ROOT"/\$SOURCE_ROOT}
    echo "$display"
    eval "$CMD"
}

echo "SOURCE_ROOT=$SOURCE_ROOT"
pushd "${SOURCE_ROOT}" > /dev/null || true
# We're going to assemble the repo args from the repo files that
repo_args=
for repo_file in $REPO_FILES ; do
    repo_args="$repo_args --repo-file $repo_file"
done

# Now validate the FML file. This will load the YAML and print warnings or errors for each channel.
echo_eval "$BINARY_PATH validate $repo_args --cache-dir $CACHE_DIR $APP_FML_FILE"

# We'll generate the command, and output some nice copy/pastable version of the command to the Build console…
for module in $MODULES ; do
    output_dir=""
    input_pattern="$module"
    output_dir=${GENERATED_SRC_DIR:-"${module}/Generated"}
    # If $module is a file, then set the output directory to $PROJECT/Generated
    # otherwise,
    if [ -f "$module" ] ; then
        output_dir="$PROJECT/Generated"
    fi

    mkdir -p "$output_dir"
    echo_eval "$BINARY_PATH generate $repo_args --channel $CHANNEL --language swift --cache-dir $CACHE_DIR $input_pattern $output_dir"
done
popd > /dev/null || exit 0
