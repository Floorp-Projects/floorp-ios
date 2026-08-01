#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

if ! command -v rg >/dev/null 2>&1; then
    echo "[FAIL] ripgrep (rg) is required for the Floorp branding check." >&2
    exit 2
fi

failures=0

pass() {
    printf '[PASS] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        return 0
    fi

    fail "Required file is missing: $file"
    return 1
}

require_fixed() {
    local file="$1"
    local expected="$2"
    local description="$3"

    if ! require_file "$file"; then
        return
    fi

    if rg --quiet --fixed-strings -- "$expected" "$file"; then
        pass "$description"
    else
        fail "$description (expected '$expected' in $file)"
    fi
}

forbid_fixed_in_files() {
    local forbidden="$1"
    local description="$2"
    shift 2

    if rg --quiet --fixed-strings -- "$forbidden" "$@"; then
        fail "$description"
        rg --line-number --fixed-strings -- "$forbidden" "$@" >&2 || true
    else
        pass "$description"
    fi
}

require_hash() {
    local file="$1"
    local expected_hash="$2"
    local description="$3"
    local digest

    if ! require_file "$file"; then
        return
    fi

    if command -v shasum >/dev/null 2>&1; then
        digest="$(shasum -a 256 "$file")"
    elif command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "$file")"
    else
        fail "A SHA-256 utility is required to inspect branded artwork."
        return
    fi
    digest="${digest%% *}"

    if [[ "$digest" == "$expected_hash" ]]; then
        pass "$description"
    else
        fail "$description ($file has unexpected SHA-256 $digest)"
    fi
}

APP_NAME_FILE="BrowserKit/Sources/Shared/AppName.swift"
PROJECT_FILE="firefox-ios/Client.xcodeproj/project.pbxproj"
RELEASE_CONFIG="firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
RELEASE_PLIST="firefox-ios/Client/FloorpReleaseInfo.plist"
RELEASE_ENTITLEMENTS="firefox-ios/Client/Entitlements/FloorpReleaseApplication.entitlements"

echo "Checking Floorp product name..."
if require_file "$APP_NAME_FILE"; then
    if rg --quiet 'case[[:space:]]+shortName[[:space:]]*=[[:space:]]*"Floorp"' "$APP_NAME_FILE"; then
        pass "AppName.shortName is Floorp"
    else
        fail "AppName.shortName must be exactly 'Floorp' in $APP_NAME_FILE"
    fi

    if rg --quiet 'case[[:space:]]+shortName[[:space:]]*=[[:space:]]*"Firefox"' "$APP_NAME_FILE"; then
        fail "AppName.shortName still identifies the installed app as Firefox"
    else
        pass "AppName.shortName no longer identifies the app as Firefox"
    fi
fi

echo "Checking Floorp legal URLs..."
LEGAL_FILES=(
    "BrowserKit/Sources/Shared/AppName.swift"
    "BrowserKit/Sources/Shared/SupportUtils.swift"
    "firefox-ios/Client/Frontend/Onboarding/Views/TermsOfServiceViewController.swift"
    "firefox-ios/Client/Frontend/Settings/Main/Privacy/PrivacyPolicySetting.swift"
    "firefox-ios/Client/Frontend/Settings/Main/About/YourRightsSetting.swift"
)

legal_files_available=true
for file in "${LEGAL_FILES[@]}"; do
    if ! require_file "$file"; then
        legal_files_available=false
    fi
done

if $legal_files_available; then
    if rg --quiet --fixed-strings -- "https://floorp.app/terms" "${LEGAL_FILES[@]}"; then
        pass "Floorp Terms of Service URL is present in production UI code"
    else
        fail "Production UI code must reference https://floorp.app/terms"
    fi

    if rg --quiet --fixed-strings -- "https://floorp.app/privacy" "${LEGAL_FILES[@]}"; then
        pass "Floorp Privacy Policy URL is present in production UI code"
    else
        fail "Production UI code must reference https://floorp.app/privacy"
    fi

    forbid_fixed_in_files \
        "https://www.mozilla.org/about/legal/terms/firefox" \
        "Top-level Floorp legal UI does not use the Firefox Terms URL" \
        "${LEGAL_FILES[@]}"
    forbid_fixed_in_files \
        "https://www.mozilla.org/privacy/firefox" \
        "Top-level Floorp legal UI does not use the Firefox Privacy URL" \
        "${LEGAL_FILES[@]}"
    forbid_fixed_in_files \
        "https://ja.floorp.app" \
        "Top-level legal UI does not use the legacy locale-specific Floorp host" \
        "${LEGAL_FILES[@]}"
fi

echo "Checking Floorp data and external-service policy..."
require_fixed \
    "firefox-ios/Floorp/FloorpBootstrapper.swift" \
    "FloorpFlags.setSponsoredShortcutsDisabled(true)" \
    "Floorp startup disables Mozilla sponsored shortcuts"
require_fixed \
    "firefox-ios/Client/TermsOfServiceManager.swift" \
    "PrefsKeys.FeatureFlags.SponsoredShortcuts" \
    "Floorp persists the sponsored-shortcuts opt-out"
require_fixed \
    "firefox-ios/Client/Frontend/Home/UnifiedAds/UnifiedAdsProvider.swift" \
    "guard !FloorpFlags.isSponsoredShortcutsDisabled" \
    "Unified Ads provider enforces the Floorp policy"
require_fixed \
    "firefox-ios/Client/Frontend/Home/UnifiedAds/UnifiedAdsCallbackTelemetry.swift" \
    "guard !FloorpFlags.isSponsoredShortcutsDisabled" \
    "Unified Ads callbacks enforce the Floorp policy"
require_fixed \
    "firefox-ios/Client/Frontend/Home/Homepage/TopSites/DataManagement/GoogleTopSiteManager.swift" \
    "guard !FloorpFlags.isSponsoredShortcutsDisabled" \
    "Google partner-attributed pinned tile enforces the Floorp policy"
require_fixed \
    "firefox-ios/Client/Application/AppLaunchUtil.swift" \
    "TelemetryContextualIdentifier.clearUserDefaults()" \
    "Floorp clears legacy Unified Ads contextual identifiers"
require_fixed \
    "firefox-ios/Floorp/FloorpBootstrapper.swift" \
    "FloorpFlags.setAdAttributionDisabled(true)" \
    "Floorp startup disables advertising attribution"
require_fixed \
    "firefox-ios/Client/Application/ConversionValueUtil.swift" \
    "guard !FloorpFlags.isAdAttributionDisabled" \
    "SKAdNetwork postbacks enforce the Floorp policy"
require_fixed \
    "firefox-ios/firefox-ios-tests/Tests/FloorpCI.xctestplan" \
    "testFloorpDataCollectionPolicyPersistsAllDisabledPreferences()" \
    "Floorp CI runs the persisted data-policy test"
require_fixed \
    "firefox-ios/firefox-ios-tests/Tests/FloorpCI.xctestplan" \
    "test_floorpSponsoredContentPolicyHidesPartnerAndSponsoredTiles()" \
    "Floorp CI runs the sponsored-content policy test"
forbid_fixed_in_files \
    "SKAdNetworkItems" \
    "FloorpRelease contains no SKAdNetwork identifiers" \
    "$RELEASE_PLIST"
forbid_fixed_in_files \
    "AdjustAppToken" \
    "FloorpRelease contains no Adjust token" \
    "$RELEASE_PLIST"
require_fixed \
    "$RELEASE_CONFIG" \
    "MOZ_ALLOW_REMOTE_PUSH_NOTIFICATIONS = NO" \
    "Floorp remote push remains disabled"
require_fixed \
    "$RELEASE_CONFIG" \
    "MOZ_ALLOW_HOSTED_SUMMARIZER = NO" \
    "Floorp hosted summarizer remains disabled"

echo "Checking localized permission descriptions..."
if rg --files firefox-ios/Client --glob '**/*.lproj/InfoPlist.strings' | rg --quiet '.'; then
    if rg --quiet --ignore-case 'firefox' firefox-ios/Client --glob '**/*.lproj/InfoPlist.strings'; then
        fail "Client InfoPlist permission/localized values still name the app Firefox"
        rg --files-with-matches --ignore-case 'firefox' firefox-ios/Client \
            --glob '**/*.lproj/InfoPlist.strings' >&2 || true
    else
        pass "Client InfoPlist localized values do not name the app Firefox"
    fi
else
    fail "No localized Client InfoPlist.strings files were found"
fi

if require_file "$RELEASE_PLIST"; then
    permission_pattern='<key>NS[A-Za-z]+UsageDescription</key>[[:space:]]*<string>[^<]*firefox[^<]*</string>'
    if rg --quiet --ignore-case --multiline "$permission_pattern" "$RELEASE_PLIST"; then
        fail "FloorpReleaseInfo.plist contains a Firefox permission description"
        rg --line-number --ignore-case --multiline "$permission_pattern" "$RELEASE_PLIST" >&2 || true
    else
        pass "FloorpReleaseInfo.plist contains no Firefox permission description"
    fi
fi

# Product names are not translated or transliterated. Keep this pattern scoped
# to user-facing product values so Firefox Account, Sync, and Suggest remain
# correctly attributed to Mozilla services.
LEGACY_PRODUCT_NAME_PATTERN='(?:firefox|firefok[[:alpha:]]*|Фаерфокс|Файрфокс|Фајерфокс|ファイアフォックス|火狐|فایرفاکس|فايرفوكس|ෆයර්ෆොක්ස්|ഫയർ.?ഫോക്സ്|ফায়ারফক্স|ফায়ারফক্স|फायरफॉक्स|फ़ायरफ़ॉक्स|ਫਾਇਰਫਾਕਸ|ਫਾਇਰਫੌਕਸ|ಫೈರ್ಫಾಕ್ಸ್|ఫైర్ఫాక్స్|பயர்பாக்ஸ்|பயர்பாஃசு|ไฟร์ฟอกซ์|파이어[[:space:]]*폭스|ଫାୟାରଫକ୍ସ|ⴼⴰⵢⵔⴼⵓⴽⵙ)'

LEGACY_PRODUCT_VALUE_PATTERN='=\s*"[^"\n]*(?:'"$LEGACY_PRODUCT_NAME_PATTERN"')'

# Keep the guard itself honest: a quoting/escaping regression here would make
# every localization check below pass without inspecting any real value.
if printf '%s\n' '"Synthetic" = "Open Firefox";' \
    | rg --quiet --ignore-case --pcre2 "$LEGACY_PRODUCT_VALUE_PATTERN"; then
    pass "Legacy product-name value matcher detects a synthetic Firefox value"
else
    fail "Legacy product-name value matcher is not matching localization values"
fi

check_no_legacy_product_value() {
    local search_path="$1"
    local description="$2"
    local matches

    matches="$(rg --line-number --ignore-case --pcre2 \
        "$LEGACY_PRODUCT_VALUE_PATTERN" \
        "$search_path" --glob '**/*.strings' || true)"
    if [[ -n "$matches" ]]; then
        fail "$description"
        printf '%s\n' "$matches" >&2
    else
        pass "$description"
    fi
}

check_no_legacy_product_value \
    "firefox-ios/Client" \
    "Client permission/localized values contain no translated Firefox product name"
check_no_legacy_product_value \
    "firefox-ios/Extensions/ActionExtension" \
    "Action extension values contain no translated Firefox product name"
check_no_legacy_product_value \
    "firefox-ios/WidgetKit" \
    "Widget values contain no translated Firefox product name"

PRODUCT_STRING_KEYS=(
    "About"
    "CoverSheet.v24.ETP.Description"
    "DefaultBrowserCard.BetterInternet.Description.v108"
    "DefaultBrowserCard.BetterInternet.Title.v108"
    "DefaultBrowserCard.Description"
    "DefaultBrowserCard.NextLevel.Description.v108"
    "DefaultBrowserCard.PeaceOfMind.Description.v108"
    "DefaultBrowserCard.PeaceOfMind.Title.v108"
    "DefaultBrowserOnboarding.Description3"
    "ErrorPages.CertWarning.Description"
    "Firefox won’t remember any of your history or cookies, but new bookmarks will be saved."
    "Firefox.HomePage.Title"
    "FxHomepage.Wallpaper.ButtonLabel.v99"
    "Intro.Slides.Welcome.Title.v2"
    "Logins.PasscodeRequirement.Warning"
    "Logins.WelcomeView.Title2"
    "Looks like Firefox crashed previously. Would you like to restore your tabs?"
    "Oops! Firefox crashed"
    "OpenURL.Error.Message"
    "PhotoLibrary.FirefoxWouldLikeAccessTitle"
    "ScanQRCode.PermissionError.Message.v100"
    "SendTo.NotSignedIn.Message"
    "Settings.Disconnect.Body"
    "Settings.Home.Option.Description.v101"
    "Settings.Home.Option.StartAtHome.Description"
    "Settings.Home.Option.Wallpaper.Accessibility.AmethystWallpaper.v99"
    "Settings.Home.Option.Wallpaper.Accessibility.BeachHillsWallpaper.v100"
    "Settings.Home.Option.Wallpaper.Accessibility.CeruleanWallpaper.v99"
    "Settings.Home.Option.Wallpaper.Accessibility.DefaultWallpaper.v99"
    "Settings.Home.Option.Wallpaper.Accessibility.SunriseWallpaper.v99"
    "Settings.Home.Option.Wallpaper.Accessibility.TwilightHillsWallpaper.v100"
    "Settings.Home.Option.Wallpaper.SwitchTitle.v99"
    "Settings.NewTab.Option.FirefoxHome"
    "Settings.OfferClipboardBar.Status"
    "Settings.Siri.SectionDescription"
    "ShareExtension.LoadInBackgroundActionDone.Title"
    "ShareExtension.OpenInFirefoxAction.Title"
    "ShareExtension.SeachInFirefoxAction.Title"
    "TodayWidget.FirefoxShortcutGalleryDescription"
    "TodayWidget.NewSearchButtonLabelV1"
    "TodayWidget.OpenFirefoxLabel"
    "TodayWidget.QuickActionGalleryDescription"
    "TodayWidget.QuickActionsGalleryTitleV2"
    "TodayWidget.SearchInFirefoxTitle"
    "TodayWidget.SearchInFirefoxV2"
    "UIMenuItem.SearchWithFirefox"
    "You don’t have any tabs open in Firefox on your other devices."
)

product_string_failures=""
product_key_pattern='^"\QAbout\E"\s*=\s*"[^"\n]*(?:'"$LEGACY_PRODUCT_NAME_PATTERN"')'
if printf '%s\n' '"About" = "About Firefox";' \
    | rg --quiet --ignore-case --pcre2 "$product_key_pattern"; then
    pass "Product-key matcher detects a synthetic Firefox value"
else
    fail "Product-key matcher is not matching allowlisted localization values"
fi

for key in "${PRODUCT_STRING_KEYS[@]}"; do
    product_key_pattern='^"\Q'"$key"'\E"\s*=\s*"[^"\n]*(?:'"$LEGACY_PRODUCT_NAME_PATTERN"')'
    matches="$(rg --line-number --ignore-case --pcre2 \
        "$product_key_pattern" \
        firefox-ios/Shared --glob '**/*.strings' || true)"
    if [[ -n "$matches" ]]; then
        product_string_failures+="${matches}"$'\n'
    fi
done

if [[ -n "$product_string_failures" ]]; then
    fail "Floorp product localization values contain a translated Firefox name"
    printf '%s' "$product_string_failures" >&2
else
    pass "Floorp product localization values contain no translated Firefox name"
fi

echo "Checking FloorpRelease identity contracts..."
require_fixed "$RELEASE_CONFIG" "FLOORP_DEVELOPMENT_TEAM = DV2U35YBHT" "Floorp Apple Team ID is fixed"
require_fixed "$RELEASE_CONFIG" "FLOORP_APP_GROUP_IDENTIFIER = group.app.floorp.Floorp.DV2U35YBHT" "Floorp App Group is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_BUNDLE_DISPLAY_NAME = Floorp" "Release display name is Floorp"
require_fixed "$RELEASE_CONFIG" "MOZ_BUNDLE_ID = app.floorp.Floorp" "Release bundle ID is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_PRODUCT_NAME = Floorp" "Release product name is Floorp"
require_fixed "$RELEASE_CONFIG" "MOZ_PUBLIC_URL_SCHEME = floorp" "Public URL scheme is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_INTERNAL_URL_SCHEME = floorp-internal" "Internal URL scheme is fixed"

require_fixed "$RELEASE_ENTITLEMENTS" '$(AppIdentifierPrefix)app.floorp.Floorp' "Floorp keychain group is fixed"
require_fixed "$RELEASE_PLIST" '$(FLOORP_APP_GROUP_IDENTIFIER)' "Release plist uses the Floorp App Group setting"
require_fixed "$RELEASE_PLIST" "app.floorp.sync.part1" "Background sync task 1 is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.sync.part2" "Background sync task 2 is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.surface.notification.refresh" "Notification refresh task is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.suggest.ingest" "Suggest ingestion task is fixed"
require_fixed "$RELEASE_PLIST" '$(PRODUCT_BUNDLE_IDENTIFIER).browsing' "Browsing user activity identifier follows the release bundle ID"
require_fixed "$RELEASE_PLIST" '$(PRODUCT_BUNDLE_IDENTIFIER).newTab' "New-tab user activity identifier follows the release bundle ID"

echo "Checking inherited runtime key boundary..."
require_fixed "$RELEASE_CONFIG" "MOZ_BUNDLE_ID" "Inherited MOZ_* build-setting contract is retained"
require_fixed "$RELEASE_PLIST" "MozSharedContainerIdentifier" "MozSharedContainerIdentifier runtime key is retained"
require_fixed "$RELEASE_PLIST" "MozPublicURLScheme" "MozPublicURLScheme runtime key is retained"
require_fixed "$RELEASE_PLIST" "MozInternalURLScheme" "MozInternalURLScheme runtime key is retained"

RELEASE_IDENTITY_FILES=(
    "$RELEASE_CONFIG"
    "$RELEASE_PLIST"
    "$RELEASE_ENTITLEMENTS"
)
if rg --quiet --ignore-case \
    --regexp 'org\.mozilla\.' \
    --regexp 'group\.org\.mozilla' \
    --regexp '43AQ936H96' \
    "${RELEASE_IDENTITY_FILES[@]}"; then
    fail "FloorpRelease contains a concrete Mozilla bundle, App Group, or Team identifier"
    rg --line-number --ignore-case \
        --regexp 'org\.mozilla\.' \
        --regexp 'group\.org\.mozilla' \
        --regexp '43AQ936H96' \
        "${RELEASE_IDENTITY_FILES[@]}" >&2 || true
else
    pass "FloorpRelease contains no concrete Mozilla release identifier"
fi

echo "Checking canonical Floorp artwork..."
FLOORP_LOGO_HASH="a29a8d8122051058005daa1bc8ebe775eb764961ee874444ac0c21576d1332b5"
FLOORP_WORDMARK_HASH="3f0bbca9e6418b692521c7ef550e37271364c7acb84e8c697376b3e261e85fee"

if require_file "$PROJECT_FILE"; then
    if sed -n '/57E51B7531BD23BED254B3D5 \/\* FloorpRelease \*\//,/^[[:space:]]*};/p' "$PROJECT_FILE" \
        | rg --quiet 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'; then
        pass "FloorpRelease selects the canonical stable AppIcon"
    else
        fail "FloorpRelease must select the canonical stable AppIcon"
    fi
fi

require_hash \
    "BrowserKit/Sources/OnboardingKit/Media.xcassets/floorpLoader.imageset/floorp-logo.svg" \
    "$FLOORP_LOGO_HASH" \
    "Launch/onboarding loader uses the desktop official Floorp mark"
require_hash \
    "firefox-ios/Client/Assets/Images.xcassets/logoFloorpLarge.imageset/floorp-logo.svg" \
    "$FLOORP_LOGO_HASH" \
    "Main-app large logo uses the desktop official Floorp mark"
require_hash \
    "firefox-ios/Extensions/ShareTo/Images.xcassets/logoFloorpLarge.imageset/floorp-logo.svg" \
    "$FLOORP_LOGO_HASH" \
    "Share extension large logo uses the desktop official Floorp mark"
require_hash \
    "firefox-ios/Client/Assets/Images.xcassets/fxHomeHeaderLogoBall.imageset/floorp-logo.svg" \
    "$FLOORP_LOGO_HASH" \
    "Home header uses the desktop official Floorp mark"
require_hash \
    "firefox-ios/Client/Assets/Images.xcassets/fxHomeHeaderLogoText.imageset/floorp-wordmark.svg" \
    "$FLOORP_WORDMARK_HASH" \
    "Home header uses the desktop official Floorp wordmark"

require_hash \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore.png" \
    "fad7b09c98584c346cf58a9c14332888be09ede6ca2f188fb36577e922d80f29" \
    "Primary app icon uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore-dark.png" \
    "10df560e6b2ddc405a7add6957e97b49cdcd2abe2a1b78297b4a56b578208095" \
    "Primary dark app icon uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore-tinted.png" \
    "1dbd6a739340ae92b5d51820d99070ea4f47778ff7186894e3646a25b744b11e" \
    "Primary tinted app icon uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/LiquidGlassAppIcons/AppIcon.icon/icon.json" \
    "048fb4219d24727a2fa77bc0874e710226eba344e166cae9df7765e61066b778" \
    "Primary Liquid Glass icon uses the approved Floorp composition"
require_hash \
    "firefox-ios/Client/Assets/LiquidGlassAppIcons/AppIcon.icon/Assets/nightly-1.svg" \
    "06f1419b59987939acadcfa45020ebc18714121d97cfaa6ff18515e79e14ef3f" \
    "Primary Liquid Glass icon layer 1 uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/LiquidGlassAppIcons/AppIcon.icon/Assets/nightly-2.svg" \
    "dd429c6b222769ec503e6a387269a5b97aab4345d537a0c74a9613a2a44fd7a4" \
    "Primary Liquid Glass icon layer 2 uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/LiquidGlassAppIcons/AppIcon.icon/Assets/nightly-3.svg" \
    "df55914738d67d644972d6eae3f70b22526e68145412bf4f5467e1e57efc75bc" \
    "Primary Liquid Glass icon layer 3 uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/LiquidGlassAppIcons/AppIcon.icon/Assets/nightly-4.svg" \
    "df55914738d67d644972d6eae3f70b22526e68145412bf4f5467e1e57efc75bc" \
    "Primary Liquid Glass icon layer 4 uses the approved Floorp artwork"

if (( failures > 0 )); then
    printf '\nFloorp branding check failed with %d issue(s).\n' "$failures" >&2
    exit 1
fi

echo
echo "Floorp branding check passed."
