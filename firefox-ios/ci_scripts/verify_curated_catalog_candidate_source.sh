#!/usr/bin/env bash

# Reject a curated-catalog candidate unless the exact source that Xcode Cloud
# checked out is the immutable, current-main commit named by its release tag.
#
# This script is deliberately a separate, source-controlled pre-archive gate:
# GitHub Actions can validate the tag before it creates a build run, but only
# Xcode Cloud can attest to the commit it actually cloned.  It is a no-op for
# ordinary branch and non-candidate tag builds.

set -euo pipefail

readonly REPOSITORY_PATH="${1:?repository path is required}"
readonly CANDIDATE_TAG_PATTERN='^floorp-catalog-([0-9a-f]{40})$'

# Xcode Cloud has used both CI_GIT_REF and CI_TAG to expose tag builds across
# integrations.  Seeing the candidate tag in either variable must enter the
# strict path; a missing or differently formatted CI_GIT_REF then rejects the
# build instead of accidentally treating it as an ordinary branch build.
if [[ "${CI_GIT_REF:-}" == refs/tags/floorp-catalog-* || \
      "${CI_TAG:-}" == floorp-catalog-* ]]; then
    readonly CANDIDATE_TAG="${CI_TAG:-}"
    readonly CANDIDATE_COMMIT="${CI_COMMIT:-}"

    if [[ ! "${CANDIDATE_TAG}" =~ ${CANDIDATE_TAG_PATTERN} ]]; then
        echo "Curated catalog candidate has an invalid Xcode Cloud tag." >&2
        exit 1
    fi
    if [[ "${CI_GIT_REF}" != "refs/tags/${CANDIDATE_TAG}" ]]; then
        echo "Curated catalog candidate Git ref does not match CI_TAG." >&2
        exit 1
    fi
    if [[ ! "${CANDIDATE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || \
        [[ "${CANDIDATE_TAG}" != "floorp-catalog-${CANDIDATE_COMMIT}" ]]; then
        echo "Curated catalog candidate tag does not bind the checked-out commit." >&2
        exit 1
    fi
    if [[ "${CI_WORKFLOW:-}" != "Floorp TestFlight Manual" ]]; then
        echo "Curated catalog candidate was started by an unapproved Xcode Cloud workflow." >&2
        exit 1
    fi
    if [[ "${CI_START_CONDITION:-}" != "manual" && \
        "${CI_START_CONDITION:-}" != "manual_rebuild" ]]; then
        echo "Curated catalog candidate must be a manual Xcode Cloud tag build." >&2
        exit 1
    fi
    if [[ "${CI_BUNDLE_ID:-}" != "app.floorp.Floorp" ]]; then
        echo "Curated catalog candidate has an unexpected bundle identifier." >&2
        exit 1
    fi

    readonly CHECKOUT_COMMIT="$(git -C "${REPOSITORY_PATH}" rev-parse HEAD)"
    if [[ "${CHECKOUT_COMMIT}" != "${CANDIDATE_COMMIT}" ]]; then
        echo "Curated catalog candidate checkout does not match CI_COMMIT." >&2
        exit 1
    fi

    # Recheck main from the actual Xcode Cloud checkout.  A tag whose suffix
    # names an older commit, or a tag moved between the GitHub Actions preflight
    # and the Cloud clone, cannot reach xcodebuild.
    git -C "${REPOSITORY_PATH}" fetch --no-tags origin \
        '+refs/heads/main:refs/remotes/origin/main'
    readonly CURRENT_MAIN_COMMIT="$(git -C "${REPOSITORY_PATH}" rev-parse refs/remotes/origin/main)"
    if [[ "${CURRENT_MAIN_COMMIT}" != "${CANDIDATE_COMMIT}" ]]; then
        echo "Curated catalog candidate is not the current main commit." >&2
        exit 1
    fi
fi
