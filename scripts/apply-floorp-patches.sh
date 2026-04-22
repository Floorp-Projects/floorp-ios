#!/bin/bash
# apply-floorp-patches.sh
# Applies Floorp patches to upstream Firefox iOS source files before build.
# This keeps Firefox files clean in git — patches are applied at build time.
#
# Usage:
#   ./scripts/apply-floorp-patches.sh          # Apply patches
#   ./scripts/apply-floorp-patches.sh --reverse # Reverse patches (restore upstream)
#
# This script is designed to be called from an Xcode "Run Script" build phase
# or manually before building.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_DIR="$PROJECT_ROOT/floorp/patches"

# Track applied patches via a marker file
MARKER_DIR="$PROJECT_ROOT/.floorp-patch-state"
APPLIED_MARKER="$MARKER_DIR/applied"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[Floorp Patches]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[Floorp Patches]${NC} $1"; }
log_error() { echo -e "${RED}[Floorp Patches]${NC} $1"; }

ensure_marker_dir() {
    mkdir -p "$MARKER_DIR"
}

is_patched() {
    [ -f "$APPLIED_MARKER" ]
}

apply_patches() {
    if is_patched; then
        log_info "Patches already applied, skipping."
        return 0
    fi

    if [ ! -d "$PATCHES_DIR" ]; then
        log_error "Patches directory not found: $PATCHES_DIR"
        exit 1
    fi

    local patch_count=0
    local fail_count=0

    for patch_file in "$PATCHES_DIR"/*.patch; do
        [ -f "$patch_file" ] || continue

        local patch_name="$(basename "$patch_file")"
        log_info "Applying: $patch_name"

        if git -C "$PROJECT_ROOT" apply --check "$patch_file" 2>/dev/null; then
            if ! git -C "$PROJECT_ROOT" apply "$patch_file" 2>/dev/null; then
                log_error "  ✗ CRITICAL: Patch check passed but apply failed: $patch_name"
                log_error "  This indicates a corrupted patch or unexpected file state."
                log_error "  Aborting build to prevent partial patch application."
                exit 1
            fi
            echo "$patch_name" >> "$APPLIED_MARKER"
            ((patch_count++))
            log_info "  ✓ Applied successfully"
        else
            log_error "  ✗ Failed to apply: $patch_name"
            log_error "  This may mean the patch conflicts with upstream changes."
            log_error "  Run './scripts/apply-floorp-patches.sh --status' to check current state."
            ((fail_count++))
        fi
    done

    if [ $fail_count -gt 0 ]; then
        log_error "$fail_count patch(es) failed to apply!"
        log_error "Build cannot continue with partial patches."
        log_error "Run './scripts/apply-floorp-patches.sh --reverse' to clean up."
        exit 1
    fi

    log_info "$patch_count patch(es) applied successfully."

    # Verify all patches are in the marker file
    local expected_count=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l | tr -d ' ')
    if [ "$patch_count" -ne "$expected_count" ]; then
        log_warn "Expected $expected_count patches but only applied $patch_count."
    fi

    return 0
}

reverse_patches() {
    if ! is_patched; then
        log_info "No patches to reverse."
        return 0
    fi

    # Reverse in reverse order
    local patches=()
    while IFS= read -r line; do
        patches+=("$PATCHES_DIR/$line")
    done < "$APPLIED_MARKER"

    local count=0
    for ((i=${#patches[@]}-1; i>=0; i--)); do
        local patch_file="${patches[$i]}"
        local patch_name="$(basename "$patch_file")"
        log_info "Reversing: $patch_name"

        if git -C "$PROJECT_ROOT" apply --reverse --check "$patch_file" 2>/dev/null; then
            if ! git -C "$PROJECT_ROOT" apply --reverse "$patch_file" 2>/dev/null; then
                log_error "  ✗ CRITICAL: Reverse check passed but apply --reverse failed: $patch_name"
                log_error "  Manual intervention required."
                exit 1
            fi
            ((count++))
            log_info "  ✓ Reversed successfully"
        else
            log_error "  ✗ Failed to reverse: $patch_name"
        fi
    done

    rm -f "$APPLIED_MARKER"
    log_info "$count patch(es) reversed."
    return 0
}

case "${1:-}" in
    --reverse|-r)
        ensure_marker_dir
        reverse_patches
        ;;
    --status|-s)
        if is_patched; then
            log_info "Patches are currently applied:"
            cat "$APPLIED_MARKER"
        else
            log_info "No patches applied."
        fi
        ;;
    --force|-f)
        rm -f "$APPLIED_MARKER"
        ensure_marker_dir
        apply_patches
        ;;
    *)
        ensure_marker_dir
        apply_patches
        ;;
esac
