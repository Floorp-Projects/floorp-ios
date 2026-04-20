#!/bin/bash
# ============================================================================
# rebrand-to-floorp.sh
# Floorp iOS branding script — applies all Firefox → Floorp renames
#
# Usage:
#   ./scripts/rebrand-to-floorp.sh          # Apply branding
#   ./scripts/rebrand-to-floorp.sh --dry-run # Preview changes only
#
# This script is designed to be re-applied after merging from upstream
# (Mozilla firefox-ios). After an upstream merge, run this script to
# re-apply the Floorp branding changes.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE — no changes will be made ==="
    echo ""
fi

# Helper functions
run_cmd() {
    if $DRY_RUN; then
        echo "  [DRY] $*"
    else
        "$@"
    fi
}

echo "============================================="
echo " Floorp iOS Rebranding Script"
echo " Project root: $PROJECT_ROOT"
echo "============================================="
echo ""

# ============================================================================
# 1. Swift Identifier Constant Replacements
# ============================================================================
echo ">>> Step 1: Swift identifier constants..."

# StandardImageIdentifiers.swift
FILE="$PROJECT_ROOT/BrowserKit/Sources/Common/Constants/StandardImageIdentifiers.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/logoFirefox = "logoFirefoxLarge"/logoFloorp = "logoFloorpLarge"/g' "$FILE"
    run_cmd sed -i '' 's/logoFirefox/logoFloorp/g' "$FILE"
    echo "  ✓ StandardImageIdentifiers.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# ImageIdentifiers.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Application/ImageIdentifiers.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/firefoxFavicon = "faviconFox"/floorpFavicon = "floorpFavicon"/g' "$FILE"
    echo "  ✓ ImageIdentifiers.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# OnboardingImageIdentifiers.swift
FILE="$PROJECT_ROOT/BrowserKit/Sources/OnboardingKit/Views/Shared/OnboardingImageIdentifiers.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/firefoxLoader/floorpLoader/g' "$FILE"
    echo "  ✓ OnboardingImageIdentifiers.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# ============================================================================
# 2. Swift Source References
# ============================================================================
echo ">>> Step 2: Swift source references..."

# LaunchScreenView.swift
FILE="$PROJECT_ROOT/BrowserKit/Sources/OnboardingKit/Views/LaunchScreen/LaunchScreenView.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/OnboardingImageIdentifiers\.firefoxLoader/OnboardingImageIdentifiers.floorpLoader/g' "$FILE"
    echo "  ✓ LaunchScreenView.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# FloorpURLBuilding.swift (or FirefoxURLBuilding.swift if not yet renamed)
for NAME in FloorpURLBuilding FirefoxURLBuilding; do
    FILE="$PROJECT_ROOT/BrowserKit/Sources/ActionExtensionKit/${NAME}.swift"
    if [[ -f "$FILE" ]]; then
        run_cmd sed -i '' \
            -e 's/FirefoxURLBuilding/FloorpURLBuilding/g' \
            -e 's/FirefoxURLBuilder/FloorpURLBuilder/g' \
            -e 's/buildFirefoxURL/buildFloorpURL/g' \
            -e 's/openWithFirefox/openWithFloorp/g' \
            -e 's/fallbackScheme = "firefox"/fallbackScheme = "floorp"/g' \
            "$FILE"
        echo "  ✓ ActionExtensionKit/${NAME}.swift"
        break
    fi
done

# FloorpURLBuilderTests.swift (or FirefoxURLBuilderTests.swift)
for NAME in FloorpURLBuilderTests FirefoxURLBuilderTests; do
    FILE="$PROJECT_ROOT/BrowserKit/Tests/ActionExtensionKitTests/${NAME}.swift"
    if [[ -f "$FILE" ]]; then
        run_cmd sed -i '' \
            -e 's/FirefoxURLBuilderTests/FloorpURLBuilderTests/g' \
            -e 's/FirefoxURLBuilder/FloorpURLBuilder/g' \
            -e 's/buildFirefoxURL/buildFloorpURL/g' \
            -e 's/testBuildFirefoxURL/testBuildFloorpURL/g' \
            -e 's/openWithFirefox/openWithFloorp/g' \
            "$FILE"
        echo "  ✓ ActionExtensionKitTests/${NAME}.swift"
        break
    fi
done

# ActionViewController.swift
FILE="$PROJECT_ROOT/firefox-ios/Extensions/ActionExtension/ActionViewController.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' \
        -e 's/FirefoxURLBuilding/FloorpURLBuilding/g' \
        -e 's/FirefoxURLBuilder/FloorpURLBuilder/g' \
        -e 's/buildFirefoxURL/buildFloorpURL/g' \
        -e 's/openWithFirefox/openWithFloorp/g' \
        -e 's/openFirefox/openFloorp/g' \
        -e 's/firefoxURLBuilder/floorpURLBuilder/g' \
        -e 's/firefoxURL/floorpURL/g' \
        -e 's/isOpeningWithFirefoxExtension/isOpeningWithFloorpExtension/g' \
        "$FILE"
    echo "  ✓ ActionViewController.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# ConnectSetting.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Frontend/Settings/Main/Account/ConnectSetting.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/StandardImageIdentifiers\.Large\.logoFirefox/StandardImageIdentifiers.Large.logoFloorp/g' "$FILE"
    echo "  ✓ ConnectSetting.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# ShareViewController.swift
FILE="$PROJECT_ROOT/firefox-ios/Extensions/ShareTo/ShareViewController.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/StandardImageIdentifiers\.Large\.logoFirefox/StandardImageIdentifiers.Large.logoFloorp/g' "$FILE"
    echo "  ✓ ShareViewController.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# HeadersViewViewController.swift
FILE="$PROJECT_ROOT/SampleComponentLibraryApp/SampleComponentLibraryApp/Headers/HeadersViewViewController.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/StandardImageIdentifiers\.Large\.logoFirefox/StandardImageIdentifiers.Large.logoFloorp/g' "$FILE"
    echo "  ✓ HeadersViewViewController.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# BackForwardTableViewCell.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Frontend/Browser/BackForwardTableViewCell.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/ImageIdentifiers\.firefoxFavicon/ImageIdentifiers.floorpFavicon/g' "$FILE"
    echo "  ✓ BackForwardTableViewCell.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# TopTabCell.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Frontend/Browser/TopTabCell.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/ImageIdentifiers\.firefoxFavicon/ImageIdentifiers.floorpFavicon/g' "$FILE"
    echo "  ✓ TopTabCell.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# TabCell.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Frontend/Browser/Tabs/Views/TabCell.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/firefoxFavicon/floorpFavicon/g' "$FILE"
    echo "  ✓ TabCell.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# TabTitleSupplementaryView.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Frontend/Browser/Tabs/Views/TabTitleSupplementaryView.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/firefoxFavicon/floorpFavicon/g' "$FILE"
    echo "  ✓ TabTitleSupplementaryView.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# TabWebViewPreview.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/TabManagement/TabWebViewPreview.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/\.faviconFox/.floorpFavicon/g' "$FILE"
    echo "  ✓ TabWebViewPreview.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# SummarizeCoordinator.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Coordinators/SummarizeCoordinator.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"faviconFox"/"floorpFavicon"/g' "$FILE"
    echo "  ✓ SummarizeCoordinator.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# DownloadLiveActivity.swift
FILE="$PROJECT_ROOT/firefox-ios/WidgetKit/DownloadManager/DownloadLiveActivity.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' \
        -e 's/firefoxIcon/floorpIcon/g' \
        -e 's/firefoxIconSize/floorpIconSize/g' \
        "$FILE"
    echo "  ✓ DownloadLiveActivity.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# ImageButtonWithLabel.swift
FILE="$PROJECT_ROOT/firefox-ios/WidgetKit/ImageButtonWithLabel.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"faviconFox"/"floorpFavicon"/g' "$FILE"
    echo "  ✓ ImageButtonWithLabel.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# QuickLink.swift
FILE="$PROJECT_ROOT/firefox-ios/WidgetKit/QuickLink.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"faviconFox"/"floorpFavicon"/g' "$FILE"
    echo "  ✓ QuickLink.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# RouteBuilder.swift
FILE="$PROJECT_ROOT/firefox-ios/Client/Coordinators/Router/RouteBuilder.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' \
        -e 's/openWithFirefox/openWithFloorp/g' \
        -e 's/isOpeningWithFirefoxExtension/isOpeningWithFloorpExtension/g' \
        "$FILE"
    echo "  ✓ RouteBuilder.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# DefaultSuggestedSites.swift
FILE="$PROJECT_ROOT/firefox-ios/Storage/DefaultSuggestedSites.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"firefox-jp"/"floorp-jp"/g' "$FILE"
    echo "  ✓ DefaultSuggestedSites.swift"
else
    echo "  ⚠ Not found: $FILE"
fi

# MenuItemProvider.swift (focus-ios)
FILE="$PROJECT_ROOT/focus-ios/Blockzilla/Menu/Protocol/MenuItemProvider.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"open_in_firefox_icon"/"open_in_floorp_icon"/g' "$FILE"
    echo "  ✓ MenuItemProvider.swift (focus-ios)"
else
    echo "  ⚠ Not found: $FILE"
fi

# OnboardingScreen.swift (test)
FILE="$PROJECT_ROOT/firefox-ios/firefox-ios-tests/Tests/XCUITests/PageScreens/OnboardingScreen.swift"
if [[ -f "$FILE" ]]; then
    run_cmd sed -i '' 's/"firefoxLoader"/"floorpLoader"/g' "$FILE"
    echo "  ✓ OnboardingScreen.swift (test)"
else
    echo "  ⚠ Not found: $FILE"
fi

echo ""
# ============================================================================
# 3. xcassets Image Set Folder Renames
# ============================================================================
echo ">>> Step 3: xcassets image set renames..."

rename_imageset() {
    local base_dir="$1"
    local old_name="$2"
    local new_name="$3"
    local old_path="${base_dir}/${old_name}.imageset"
    local new_path="${base_dir}/${new_name}.imageset"

    if [[ -d "$old_path" && ! -d "$new_path" ]]; then
        run_cmd mv "$old_path" "$new_path"
        echo "  ✓ ${old_name}.imageset → ${new_name}.imageset"
    elif [[ -d "$new_path" ]]; then
        echo "  ≈ Already renamed: ${new_name}.imageset"
    else
        echo "  ⚠ Not found: ${old_path}"
    fi
}

# faviconFox → floorpFavicon
rename_imageset "$PROJECT_ROOT/firefox-ios/Client/Assets/Images.xcassets" "faviconFox" "floorpFavicon"
rename_imageset "$PROJECT_ROOT/firefox-ios/WidgetKit/Assets.xcassets" "faviconFox" "floorpFavicon"

# logoFirefoxLarge → logoFloorpLarge
rename_imageset "$PROJECT_ROOT/firefox-ios/Client/Assets/Images.xcassets" "logoFirefoxLarge" "logoFloorpLarge"
rename_imageset "$PROJECT_ROOT/firefox-ios/Extensions/ShareTo/Images.xcassets" "logoFirefoxLarge" "logoFloorpLarge"
rename_imageset "$PROJECT_ROOT/SampleComponentLibraryApp/SampleComponentLibraryApp/Assets.xcassets" "logoFirefoxLarge" "logoFloorpLarge"

# firefoxLoader → floorpLoader
rename_imageset "$PROJECT_ROOT/BrowserKit/Sources/OnboardingKit/Media.xcassets" "firefoxLoader" "floorpLoader"

# firefox-jp → floorp-jp
rename_imageset "$PROJECT_ROOT/BrowserKit/Sources/SiteImageView/BundledTopSitesFavicons.xcassets" "firefox-jp" "floorp-jp"

# open_in_firefox_icon → open_in_floorp_icon
rename_imageset "$PROJECT_ROOT/focus-ios/Blockzilla/Assets.xcassets" "open_in_firefox_icon" "open_in_floorp_icon"

echo ""
# ============================================================================
# 4. Contents.json Filename References
# ============================================================================
echo ">>> Step 4: Contents.json filename references..."

update_contents_json() {
    local dir="$1"
    local old_file="$2"
    local new_file="$3"

    local contents_file="${dir}/Contents.json"
    if [[ -f "$contents_file" ]]; then
        if grep -q "$old_file" "$contents_file" 2>/dev/null; then
            run_cmd sed -i '' "s/${old_file}/${new_file}/g" "$contents_file"
            echo "  ✓ Updated: ${contents_file##*/} (${old_file} → ${new_file})"
        fi
    fi
}

# logoFirefoxLarge.pdf → logoFloorpLarge.pdf
for dir in \
    "$PROJECT_ROOT/firefox-ios/Client/Assets/Images.xcassets/logoFloorpLarge.imageset" \
    "$PROJECT_ROOT/firefox-ios/Extensions/ShareTo/Images.xcassets/logoFloorpLarge.imageset" \
    "$PROJECT_ROOT/SampleComponentLibraryApp/SampleComponentLibraryApp/Assets.xcassets/logoFloorpLarge.imageset"; do
    update_contents_json "$dir" "logoFirefoxLarge.pdf" "logoFloorpLarge.pdf"
done

# firefoxLoader.pdf → floorpLoader.pdf
update_contents_json "$PROJECT_ROOT/BrowserKit/Sources/OnboardingKit/Media.xcassets/floorpLoader.imageset" "firefoxLoader.pdf" "floorpLoader.pdf"

# firefox-jp.png → floorp-jp.png
update_contents_json "$PROJECT_ROOT/BrowserKit/Sources/SiteImageView/BundledTopSitesFavicons.xcassets/floorp-jp.imageset" "firefox-jp.png" "floorp-jp.png"

# open_in_firefox_icon.pdf → open_in_floorp_icon.pdf
update_contents_json "$PROJECT_ROOT/focus-ios/Blockzilla/Assets.xcassets/open_in_floorp_icon.imageset" "open_in_firefox_icon.pdf" "open_in_floorp_icon.pdf"

echo ""
# ============================================================================
# 5. Image File Renames
# ============================================================================
echo ">>> Step 5: Image file renames..."

rename_file() {
    local dir="$1"
    local old_name="$2"
    local new_name="$3"
    local old_path="${dir}/${old_name}"
    local new_path="${dir}/${new_name}"

    if [[ -f "$old_path" && ! -f "$new_path" ]]; then
        run_cmd mv "$old_path" "$new_path"
        echo "  ✓ ${old_name} → ${new_name}"
    elif [[ -f "$new_path" ]]; then
        echo "  ≈ Already renamed: ${new_name}"
    else
        echo "  ⚠ Not found: ${old_path}"
    fi
}

# logoFirefoxLarge.pdf → logoFloorpLarge.pdf
for dir in \
    "$PROJECT_ROOT/firefox-ios/Client/Assets/Images.xcassets/logoFloorpLarge.imageset" \
    "$PROJECT_ROOT/firefox-ios/Extensions/ShareTo/Images.xcassets/logoFloorpLarge.imageset" \
    "$PROJECT_ROOT/SampleComponentLibraryApp/SampleComponentLibraryApp/Assets.xcassets/logoFloorpLarge.imageset"; do
    rename_file "$dir" "logoFirefoxLarge.pdf" "logoFloorpLarge.pdf"
done

# firefoxLoader.pdf → floorpLoader.pdf
rename_file "$PROJECT_ROOT/BrowserKit/Sources/OnboardingKit/Media.xcassets/floorpLoader.imageset" "firefoxLoader.pdf" "floorpLoader.pdf"

# firefox-jp.png → floorp-jp.png
rename_file "$PROJECT_ROOT/BrowserKit/Sources/SiteImageView/BundledTopSitesFavicons.xcassets/floorp-jp.imageset" "firefox-jp.png" "floorp-jp.png"

# open_in_firefox_icon.pdf → open_in_floorp_icon.pdf
rename_file "$PROJECT_ROOT/focus-ios/Blockzilla/Assets.xcassets/open_in_floorp_icon.imageset" "open_in_firefox_icon.pdf" "open_in_floorp_icon.pdf"

echo ""
# ============================================================================
# 6. Swift File Renames
# ============================================================================
echo ">>> Step 6: Swift file renames..."

rename_swift_file() {
    local dir="$1"
    local old_name="$2"
    local new_name="$3"
    local old_path="${dir}/${old_name}"
    local new_path="${dir}/${new_name}"

    if [[ -f "$old_path" && ! -f "$new_path" ]]; then
        run_cmd mv "$old_path" "$new_path"
        echo "  ✓ ${old_name} → ${new_name}"
    elif [[ -f "$new_path" ]]; then
        echo "  ≈ Already renamed: ${new_name}"
    else
        echo "  ⚠ Not found: ${old_path}"
    fi
}

# FirefoxURLBuilding.swift → FloorpURLBuilding.swift
rename_swift_file "$PROJECT_ROOT/BrowserKit/Sources/ActionExtensionKit" "FirefoxURLBuilding.swift" "FloorpURLBuilding.swift"

# FirefoxURLBuilderTests.swift → FloorpURLBuilderTests.swift
rename_swift_file "$PROJECT_ROOT/BrowserKit/Tests/ActionExtensionKitTests" "FirefoxURLBuilderTests.swift" "FloorpURLBuilderTests.swift"

# ============================================================================
# 7. Disable All Telemetry
# ============================================================================
echo ">>> Step 7: Disable all telemetry..."

# TelemetryWrapper.swift — early return in setup() and initGlean()
FILE="$PROJECT_ROOT/firefox-ios/Client/Telemetry/TelemetryWrapper.swift"
if [[ -f "$FILE" ]]; then
    # Disable setup() by adding early return after the opening brace
    if ! grep -q 'Floorp: All telemetry is disabled' "$FILE"; then
        run_cmd sed -i '' '/func setup(profile:/,/^{/{
            /^{/a\
\        // Floorp: All telemetry is disabled\
\        return
        }' "$FILE"
        echo "  ✓ TelemetryWrapper.setup() disabled"
    else
        echo "  ≈ TelemetryWrapper.setup() already disabled"
    fi

    # Disable initGlean() by adding early return
    if ! grep -q 'Floorp: Glean telemetry initialization disabled' "$FILE"; then
        run_cmd sed -i '' '/private func initGlean/,/^{/{
            /^{/a\
\        // Floorp: Glean telemetry initialization disabled\
\        return
        }' "$FILE"
        echo "  ✓ TelemetryWrapper.initGlean() disabled"
    else
        echo "  ≈ TelemetryWrapper.initGlean() already disabled"
    fi
else
    echo "  ⚠ Not found: $FILE"
fi

# MetricKitWrapper.swift — early return in beginObservingMXPayloads()
FILE="$PROJECT_ROOT/firefox-ios/Client/Telemetry/MetricKit/MetricKitWrapper.swift"
if [[ -f "$FILE" ]]; then
    if ! grep -q 'Floorp: MetricKit disabled' "$FILE"; then
        run_cmd sed -i '' '/func beginObservingMXPayloads/,/^{/{
            /^{/a\
\        // Floorp: MetricKit disabled\
\        return
        }' "$FILE"
        echo "  ✓ MetricKitWrapper.beginObservingMXPayloads() disabled"
    else
        echo "  ≈ MetricKitWrapper already disabled"
    fi
else
    echo "  ⚠ Not found: $FILE"
fi

# SentryWrapper.swift — early return in startWithConfigureOptions()
FILE="$PROJECT_ROOT/BrowserKit/Sources/Common/Logger/Wrapper/SentryWrapper.swift"
if [[ -f "$FILE" ]]; then
    if ! grep -q 'Floorp: Sentry crash reporting disabled' "$FILE"; then
        run_cmd sed -i '' '/public func startWithConfigureOptions/,/^{/{
            /^{/a\
\        // Floorp: Sentry crash reporting disabled\
\        return
        }' "$FILE"
        echo "  ✓ SentryWrapper.startWithConfigureOptions() disabled"
    else
        echo "  ≈ SentryWrapper already disabled"
    fi
else
    echo "  ⚠ Not found: $FILE"
fi

echo ""

echo "============================================="
if $DRY_RUN; then
    echo " DRY RUN COMPLETE — no changes were made"
    echo " Run without --dry-run to apply changes"
else
    echo " Rebranding complete!"
    echo ""
    echo " Next steps:"
    echo "   1. Build the project to verify changes"
    echo "   2. git add -A && git commit -m 'feat: rebrand Firefox → Floorp'"
fi
echo "============================================="
