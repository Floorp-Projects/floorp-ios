#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

SEARCH_BACKEND="${FLOORP_BRANDING_SEARCH_BACKEND:-auto}"
case "$SEARCH_BACKEND" in
    auto)
        if command -v rg >/dev/null 2>&1; then
            SEARCH_BACKEND="rg"
        else
            SEARCH_BACKEND="grep"
        fi
        ;;
    rg)
        if ! command -v rg >/dev/null 2>&1; then
            echo "[FAIL] FLOORP_BRANDING_SEARCH_BACKEND=rg, but rg is unavailable." >&2
            exit 2
        fi
        ;;
    grep)
        if ! command -v grep >/dev/null 2>&1; then
            echo "[FAIL] The portable grep search backend is unavailable." >&2
            exit 2
        fi
        ;;
    *)
        echo "[FAIL] Unknown Floorp branding search backend: $SEARCH_BACKEND" >&2
        exit 2
        ;;
esac

search_fixed_quiet() {
    local expected="$1"
    shift

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --quiet --fixed-strings -- "$expected" "$@"
    else
        grep -Fq -- "$expected" "$@"
    fi
}

search_fixed_lines() {
    local expected="$1"
    shift

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --line-number --fixed-strings -- "$expected" "$@"
    else
        grep -FnH -- "$expected" "$@"
    fi
}

search_regex_quiet() {
    local pattern="$1"
    shift

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --quiet -- "$pattern" "$@"
    else
        grep -Eq -- "$pattern" "$@"
    fi
}

search_regex_ignore_case_quiet() {
    local pattern="$1"
    shift

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --quiet --ignore-case -- "$pattern" "$@"
    else
        grep -Eiq -- "$pattern" "$@"
    fi
}

search_regex_ignore_case_lines() {
    local pattern="$1"
    shift

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --line-number --ignore-case -- "$pattern" "$@"
    else
        grep -EinH -- "$pattern" "$@"
    fi
}

search_strings_regex_ignore_case_lines() {
    local pattern="$1"
    local search_path="$2"

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --line-number --ignore-case --glob '**/*.strings' -- \
            "$pattern" "$search_path"
    else
        find "$search_path" -type f -name '*.strings' \
            -exec grep -EinH -- "$pattern" {} +
    fi
}

archive_uses_configuration() {
    local scheme_file="$1"
    local expected_configuration="$2"

    awk -v expected="$expected_configuration" '
        /<ArchiveAction([[:space:]]|$)/ {
            in_archive_action = 1
        }
        in_archive_action && index($0, "buildConfiguration = \"" expected "\"") {
            found = 1
        }
        in_archive_action && /<\/ArchiveAction>/ {
            in_archive_action = 0
        }
        END {
            exit found ? 0 : 1
        }
    ' "$scheme_file"
}

plist_key_has_string_value() {
    local plist_file="$1"
    local key="$2"
    local expected_value="$3"

    awk -v expected_key="<key>${key}</key>" \
        -v expected_value="<string>${expected_value}</string>" '
        {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        }
        line == expected_key {
            awaiting_value = 1
            next
        }
        awaiting_value && line == expected_value {
            found = 1
            exit
        }
        awaiting_value && line != "" {
            exit
        }
        END {
            exit found ? 0 : 1
        }
    ' "$plist_file"
}

require_plist_string_value() {
    local plist_file="$1"
    local key="$2"
    local expected_value="$3"
    local description="$4"

    if ! require_file "$plist_file"; then
        return
    fi

    if plist_key_has_string_value "$plist_file" "$key" "$expected_value"; then
        pass "$description"
    else
        fail "$description ($key must map to $expected_value in $plist_file)"
    fi
}

find_permission_description_matches() {
    local file="$1"

    if [[ "$SEARCH_BACKEND" == "rg" ]]; then
        command rg --line-number --ignore-case --multiline \
            '<key>NS[A-Za-z]+UsageDescription</key>[[:space:]]*<string>[^<]*firefox[^<]*</string>' \
            "$file"
        return
    fi

    # Info.plist is line-oriented in this repository. This state machine keeps
    # the fallback portable instead of relying on GNU-only multiline grep.
    awk '
        {
            lower_line = tolower($0)
        }
        lower_line ~ /<key>ns[a-z]+usagedescription<\/key>/ {
            key_line = $0
            key_line_number = NR
            next
        }
        key_line != "" && lower_line ~ /<string>[^<]*firefox[^<]*<\/string>/ {
            printf "%s:%d:%s\n%s:%d:%s\n", FILENAME, key_line_number, key_line, FILENAME, NR, $0
            found = 1
            key_line = ""
            next
        }
        key_line != "" && (lower_line ~ /<string>/ || lower_line ~ /<key>/) {
            key_line = ""
        }
        END {
            exit found ? 0 : 1
        }
    ' "$file"
}

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

    if search_fixed_quiet "$expected" "$file"; then
        pass "$description"
    else
        fail "$description (expected '$expected' in $file)"
    fi
}

forbid_fixed_in_files() {
    local forbidden="$1"
    local description="$2"
    shift 2

    if search_fixed_quiet "$forbidden" "$@"; then
        fail "$description"
        search_fixed_lines "$forbidden" "$@" >&2 || true
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

require_grayscale_png() {
    local file="$1"
    local description="$2"
    local png_header
    local color_type

    if ! require_file "$file"; then
        return
    fi

    if ! command -v od >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then
        fail "Standard od and tr utilities are required to inspect PNG metadata."
        return
    fi

    png_header="$(od -An -tx1 -N 16 "$file" | tr -d '[:space:]')"
    if [[ "$png_header" != "89504e470d0a1a0a0000000d49484452" ]]; then
        fail "$description ($file does not start with a valid PNG IHDR chunk)"
        return
    fi

    # In a PNG IHDR chunk, byte offset 25 is the color type. Values 0 and 4
    # represent grayscale without and with alpha, respectively.
    color_type="$(od -An -tu1 -j 25 -N 1 "$file" | tr -d '[:space:]')"
    case "$color_type" in
        0|4)
            pass "$description"
            ;;
        *)
            fail "$description ($file has PNG color type ${color_type:-unknown}; expected 0 or 4)"
            ;;
    esac
}

require_opaque_rgb_png() {
    local file="$1"
    local description="$2"
    local png_header
    local color_type

    if ! require_file "$file"; then
        return
    fi

    if ! command -v od >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then
        fail "Standard od and tr utilities are required to inspect PNG metadata."
        return
    fi

    png_header="$(od -An -tx1 -N 16 "$file" | tr -d '[:space:]')"
    if [[ "$png_header" != "89504e470d0a1a0a0000000d49484452" ]]; then
        fail "$description ($file does not start with a valid PNG IHDR chunk)"
        return
    fi

    # In a PNG IHDR chunk, byte offset 25 is the color type. Value 2 is
    # truecolor RGB without an alpha channel, as required for the default icon.
    color_type="$(od -An -tu1 -j 25 -N 1 "$file" | tr -d '[:space:]')"
    if [[ "$color_type" == "2" ]]; then
        pass "$description"
    else
        fail "$description ($file has PNG color type ${color_type:-unknown}; expected 2)"
    fi
}

APP_NAME_FILE="BrowserKit/Sources/Shared/AppName.swift"
PROJECT_FILE="firefox-ios/Client.xcodeproj/project.pbxproj"
FLOORP_SCHEME_FILE="firefox-ios/Client.xcodeproj/xcshareddata/xcschemes/Floorp.xcscheme"
RELEASE_CONFIG="firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
RELEASE_PLIST="firefox-ios/Client/FloorpReleaseInfo.plist"
RELEASE_ENTITLEMENTS="firefox-ios/Client/Entitlements/FloorpReleaseApplication.entitlements"
TERMS_LINK_FILE="firefox-ios/Client/Frontend/Browser/TermsOfUse/TermsOfUseStrings.swift"
CREDENTIAL_STORYBOARD="firefox-ios/CredentialProvider/CredentialList.storyboard"
BOOTSTRAPPER_FILE="firefox-ios/Floorp/FloorpBootstrapper.swift"
DEPENDENCY_HELPER_FILE="firefox-ios/Client/Application/DependencyHelper.swift"
APP_LAUNCH_FILE="firefox-ios/Client/Application/AppLaunchUtil.swift"
FEATURE_FLAGS_PROVIDER_FILE="firefox-ios/Client/FeatureFlags/FeatureFlagsProvider.swift"
APP_SERVICES_POLICY_FILE="BrowserKit/Sources/Common/Utilities/AppServicesPolicy.swift"
QUICK_ANSWERS_FACTORY_FILE="BrowserKit/Sources/QuickAnswersKit/Backend/ResultsService/ResultsServiceFactory.swift"
QUICK_ANSWERS_ERROR_FILE="BrowserKit/Sources/QuickAnswersKit/UI/ErrorHandler.swift"
QUICK_ANSWERS_OPT_IN_FILE="BrowserKit/Sources/QuickAnswersKit/UI/OptInView.swift"
FLOORP_TEST_PLAN="firefox-ios/firefox-ios-tests/Tests/FloorpCI.xctestplan"

echo "Checking Floorp product name..."
if require_file "$APP_NAME_FILE"; then
    if search_regex_quiet 'case[[:space:]]+shortName[[:space:]]*=[[:space:]]*"Floorp"' "$APP_NAME_FILE"; then
        pass "AppName.shortName is Floorp"
    else
        fail "AppName.shortName must be exactly 'Floorp' in $APP_NAME_FILE"
    fi

    if search_regex_quiet 'case[[:space:]]+shortName[[:space:]]*=[[:space:]]*"Firefox"' "$APP_NAME_FILE"; then
        fail "AppName.shortName still identifies the installed app as Firefox"
    else
        pass "AppName.shortName no longer identifies the app as Firefox"
    fi
fi

echo "Checking Floorp legal URLs..."
LEGAL_FILES=(
    "BrowserKit/Sources/Shared/AppName.swift"
    "BrowserKit/Sources/Shared/SupportUtils.swift"
    "$TERMS_LINK_FILE"
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
    if search_fixed_quiet "https://floorp.app/terms" "${LEGAL_FILES[@]}"; then
        pass "Floorp Terms of Service URL is present in production UI code"
    else
        fail "Production UI code must reference https://floorp.app/terms"
    fi

    if search_fixed_quiet "https://floorp.app/privacy" "${LEGAL_FILES[@]}"; then
        pass "Floorp Privacy Policy URL is present in production UI code"
    else
        fail "Production UI code must reference https://floorp.app/privacy"
    fi

    require_fixed \
        "$APP_NAME_FILE" \
        "https://github.com/Floorp-Projects/floorp-ios#readme" \
        "Settings Help uses the official Floorp iOS project hub"
    require_fixed \
        "$APP_NAME_FILE" \
        "https://floorp.app/terms?utm_source=floorp-ios&utm_medium=in-product&utm_campaign=terms-of-use" \
        "Terms Learn more uses the canonical Floorp legal document"
    require_fixed \
        "$TERMS_LINK_FILE" \
        "return SupportUtils.URLForTermsOfUseLearnMore" \
        "Terms Learn more is separate from general Settings Help"
    require_fixed \
        "$APP_NAME_FILE" \
        "https://blog.floorp.app/en/categories/release/" \
        "Floorp release notes use the current published index"
    forbid_fixed_in_files \
        "https://docs.floorp.app/docs/features/" \
        "Floorp iOS Help does not use the desktop feature index" \
        "$APP_NAME_FILE" \
        "$TERMS_LINK_FILE"
    forbid_fixed_in_files \
        "https://blog.floorp.app/categories/release" \
        "Floorp release notes do not use the removed unlocalized route" \
        "$APP_NAME_FILE"

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
    "$DEPENDENCY_HELPER_FILE" \
    "FloorpBootstrapper.configure()" \
    "Dependency bootstrap invokes the Floorp policy entry point"
require_fixed \
    "$BOOTSTRAPPER_FILE" \
    "FloorpFlags.setTelemetryDisabled(true)" \
    "Floorp startup activates the telemetry policy"
require_fixed \
    "$BOOTSTRAPPER_FILE" \
    "FloorpFlags.setSponsoredShortcutsDisabled(true)" \
    "Floorp startup disables Mozilla sponsored shortcuts"
require_fixed \
    "$APP_LAUNCH_FILE" \
    "TermsOfUseMigration(prefs: profile.prefs).migrateToFloorpTermsIfNeeded()" \
    "Pre-launch setup migrates inherited Mozilla consent before use"
require_fixed \
    "$APP_LAUNCH_FILE" \
    "termsOfServiceManager.enforceFloorpDataCollectionPreferences()" \
    "Pre-launch setup persists the Floorp data policy before services start"
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
    "$APP_LAUNCH_FILE" \
    "TelemetryContextualIdentifier.clearUserDefaults()" \
    "Floorp clears legacy Unified Ads contextual identifiers"
require_fixed \
    "$BOOTSTRAPPER_FILE" \
    "FloorpFlags.setAdAttributionDisabled(true)" \
    "Floorp startup disables advertising attribution"
require_fixed \
    "firefox-ios/Client/Application/ConversionTracking/ConversionEventTracker.swift" \
    "guard !FloorpFlags.isAdAttributionDisabled" \
    "SKAdNetwork postbacks enforce the Floorp policy"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testFloorpDataCollectionPolicyPersistsAllDisabledPreferences()" \
    "Floorp CI runs the persisted data-policy test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testPreLaunchMigrationMakesInheritedAcceptanceEligibleForFloorpTerms()" \
    "Floorp CI runs the pre-launch legal-migration wiring test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testGivenTelemetryDisabledAndTosDisabled_ThenContextIdIsNotSet()" \
    "Floorp CI runs the pre-launch telemetry-policy wiring test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "test_floorpSponsoredContentPolicyHidesPartnerAndSponsoredTiles()" \
    "Floorp CI runs the sponsored-content policy test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testSponsoredShortcuts_floorpPolicyOverridesPersistedOptIn()" \
    "Floorp CI runs the centralized sponsored-content preference test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testFetchTiles_whenFloorpDisablesSponsoredContent_doesNotRequestAds()" \
    "Floorp CI runs the Unified Ads provider policy test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testFloorpSponsoredContentPolicy_blocksCallbacksAndGlean()" \
    "Floorp CI runs the Unified Ads callback policy test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testRecord_floorpAttributionPolicyDisabled_doesNotEmitConversionValue()" \
    "Floorp CI runs the advertising-attribution policy test"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testURLs_UseSeparateFloorpDestinationsForHelpAndTermsInformation()" \
    "Floorp CI checks the iOS Help and Terms link boundary"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testMicrosurveyDelegate_showPrivacyWithContentParams_callsRouterDismiss_andCreatesNewTab()" \
    "Floorp CI checks the microsurvey privacy-link boundary"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testShouldShowTermsOfUse_ReturnsTrue_WhenFloorpPolicyIsActiveAndNimbusIsDisabled()" \
    "Floorp CI checks legal re-consent without Nimbus rollout"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testGivenTosDisabled_ThenContextIdIsSet()" \
    "Floorp CI covers the non-Floorp telemetry initialization path"
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
require_fixed \
    "$RELEASE_CONFIG" \
    "MOZ_ALLOW_QUICK_ANSWERS = NO" \
    "Floorp Quick Answers App Attest service remains disabled"
require_plist_string_value \
    "$RELEASE_PLIST" \
    "MozAllowRemotePushNotifications" \
    "\$(MOZ_ALLOW_REMOTE_PUSH_NOTIFICATIONS)" \
    "FloorpRelease wires the remote-push policy to runtime"
require_plist_string_value \
    "$RELEASE_PLIST" \
    "MozAllowHostedSummarizer" \
    "\$(MOZ_ALLOW_HOSTED_SUMMARIZER)" \
    "FloorpRelease wires the hosted-summarizer policy to runtime"
require_plist_string_value \
    "$RELEASE_PLIST" \
    "MozAllowQuickAnswers" \
    "\$(MOZ_ALLOW_QUICK_ANSWERS)" \
    "FloorpRelease wires the Quick Answers policy to runtime"
require_fixed \
    "$APP_SERVICES_POLICY_FILE" \
    "public static var allowsQuickAnswers: Bool" \
    "Runtime exposes the fail-closed Quick Answers build policy"
require_fixed \
    "$FEATURE_FLAGS_PROVIDER_FILE" \
    "flag == .quickAnswers, !allowsQuickAnswers" \
    "Feature exposure cannot bypass the Quick Answers app policy"
require_fixed \
    "$QUICK_ANSWERS_FACTORY_FILE" \
    "guard allowsQuickAnswers else" \
    "Quick Answers blocks App Attest client creation when disallowed"
require_fixed \
    "BrowserKit/Tests/QuickAnswersKitTests/ResultsService/ResultsServiceFactoryTests.swift" \
    "test_make_whenQuickAnswersDisallowed_doesNotCreateAppAttestClient" \
    "Quick Answers tests the no-client-creation policy boundary"
require_fixed \
    "$FLOORP_TEST_PLAN" \
    "testIsEnabled_quickAnswersDisallowedByAppPolicy_returnsFalseWithoutConsultingNimbus()" \
    "Floorp CI checks that Nimbus cannot enable disallowed Quick Answers"
require_fixed \
    "$CREDENTIAL_STORYBOARD" \
    "sync your passwords with Firefox Sync" \
    "Credential Provider retains the Firefox Sync service name"
require_fixed \
    "$CREDENTIAL_STORYBOARD" \
    "save them in Floorp or sync them with Firefox Sync" \
    "Credential Provider attributes additional synced logins correctly"
forbid_fixed_in_files \
    "passwords you’ve already saved to Floorp" \
    "Credential Provider does not claim synced passwords originated in Floorp" \
    "$CREDENTIAL_STORYBOARD"
forbid_fixed_in_files \
    "save them to Floorp" \
    "Credential Provider does not claim all additional logins must originate in Floorp" \
    "$CREDENTIAL_STORYBOARD"
forbid_fixed_in_files \
    "sync with Floorp" \
    "Credential Provider does not rename Firefox Sync as Floorp" \
    "$CREDENTIAL_STORYBOARD"
forbid_fixed_in_files \
    "account Floorp" \
    "Localized disconnect copy does not invent a Floorp account service" \
    "firefox-ios/Shared/it.lproj/Localizable.strings"

echo "Checking localized permission descriptions..."
info_plist_files="$(find firefox-ios/Client -type f -path '*.lproj/InfoPlist.strings' -print)"
if [[ -n "$info_plist_files" ]]; then
    info_plist_matches=""
    while IFS= read -r file; do
        if search_regex_ignore_case_quiet 'firefox' "$file"; then
            info_plist_matches+="${file}"$'\n'
        fi
    done <<< "$info_plist_files"

    if [[ -n "$info_plist_matches" ]]; then
        fail "Client InfoPlist permission/localized values still name the app Firefox"
        printf '%s' "$info_plist_matches" >&2
    else
        pass "Client InfoPlist localized values do not name the app Firefox"
    fi
else
    fail "No localized Client InfoPlist.strings files were found"
fi

if require_file "$RELEASE_PLIST"; then
    permission_matches="$(find_permission_description_matches "$RELEASE_PLIST" || true)"
    if [[ -n "$permission_matches" ]]; then
        fail "FloorpReleaseInfo.plist contains a Firefox permission description"
        printf '%s\n' "$permission_matches" >&2
    else
        pass "FloorpReleaseInfo.plist contains no Firefox permission description"
    fi
fi

# Product names are not translated or transliterated. Keep this pattern scoped
# to user-facing product values so Firefox Account, Sync, and Suggest remain
# correctly attributed to Mozilla services.
LEGACY_PRODUCT_NAME_PATTERN='(firefox|firefok[[:alpha:]]*|Фаерфокс|Файрфокс|Фајерфокс|ファイアフォックス|火狐|فایرفاکس|فايرفوكس|ෆයර්ෆොක්ස්|ഫയർ.?ഫോക്സ്|ফায়ারফক্স|ফায়ারফক্স|फायरफॉक्स|फ़ायरफ़ॉक्स|ਫਾਇਰਫਾਕਸ|ਫਾਇਰਫੌਕਸ|ಫೈರ್ಫಾಕ್ಸ್|ఫైర్ఫాక్స్|பயர்பாக்ஸ்|பயர்பாஃசு|ไฟร์ฟอกซ์|파이어[[:space:]]*폭스|ଫାୟାରଫକ୍ସ|ⴼⴰⵢⵔⴼⵓⴽⵙ)'

LEGACY_PRODUCT_VALUE_PATTERN='=[[:space:]]*"[^"]*'"$LEGACY_PRODUCT_NAME_PATTERN"

# Keep the guard itself honest: a quoting/escaping regression here would make
# every localization check below pass without inspecting any real value.
if printf '%s\n' '"Synthetic" = "Open Firefox";' \
    | search_regex_ignore_case_quiet "$LEGACY_PRODUCT_VALUE_PATTERN"; then
    pass "Legacy product-name value matcher detects a synthetic Firefox value"
else
    fail "Legacy product-name value matcher is not matching localization values"
fi

check_no_legacy_product_value() {
    local search_path="$1"
    local description="$2"
    local matches

    matches="$(search_strings_regex_ignore_case_lines \
        "$LEGACY_PRODUCT_VALUE_PATTERN" \
        "$search_path" || true)"
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
    "CameraAccess.DisabledAlertMessage.v153"
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
line_has_legacy_product_for_key() {
    local line="$1"
    local key="$2"

    [[ "$line" == "\"$key\""* ]] \
        && printf '%s\n' "$line" \
            | search_regex_ignore_case_quiet "$LEGACY_PRODUCT_VALUE_PATTERN"
}

if line_has_legacy_product_for_key '"About" = "About Firefox";' "About"; then
    pass "Product-key matcher detects a synthetic Firefox value"
else
    fail "Product-key matcher is not matching allowlisted localization values"
fi

product_value_candidates="$(search_strings_regex_ignore_case_lines \
    "$LEGACY_PRODUCT_VALUE_PATTERN" \
    firefox-ios/Shared || true)"
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    line_content="${candidate#*:}"
    line_content="${line_content#*:}"
    for key in "${PRODUCT_STRING_KEYS[@]}"; do
        if [[ "$line_content" == "\"$key\""* ]]; then
            product_string_failures+="${candidate}"$'\n'
            break
        fi
    done
done <<< "$product_value_candidates"

if [[ -n "$product_string_failures" ]]; then
    fail "Floorp product localization values contain a translated Firefox name"
    printf '%s' "$product_string_failures" >&2
else
    pass "Floorp product localization values contain no translated Firefox name"
fi

forbid_fixed_in_files \
    "Allow Firefox to access" \
    "Quick Answers permission errors do not name the installed app Firefox" \
    "$QUICK_ANSWERS_ERROR_FILE"
forbid_fixed_in_files \
    "a Firefox partner" \
    "Quick Answers opt-in does not invent Firefox ownership for its provider" \
    "$QUICK_ANSWERS_OPT_IN_FILE"
require_fixed \
    "$QUICK_ANSWERS_ERROR_FILE" \
    "Allow Floorp to access the Microphone." \
    "Quick Answers microphone error names Floorp"
require_fixed \
    "$QUICK_ANSWERS_OPT_IN_FILE" \
    "a third-party answer provider" \
    "Quick Answers describes its currently unverified provider neutrally"

echo "Checking FloorpRelease identity contracts..."
require_fixed "$RELEASE_CONFIG" "FLOORP_DEVELOPMENT_TEAM = DV2U35YBHT" "Floorp Apple Team ID is fixed"
if search_regex_quiet '^FLOORP_APP_STORE_ID[[:space:]]*=[[:space:]]*$' "$RELEASE_CONFIG"; then
    pass "Internal TestFlight keeps the unpublished App Store rating link hidden"
else
    fail "Keep FLOORP_APP_STORE_ID empty until the public App Store listing is live"
fi
require_fixed "$RELEASE_CONFIG" "FLOORP_APP_GROUP_IDENTIFIER = group.app.floorp.Floorp.DV2U35YBHT" "Floorp App Group is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_BUNDLE_DISPLAY_NAME = Floorp" "Release display name is Floorp"
require_fixed "$RELEASE_CONFIG" "MOZ_BUNDLE_ID = app.floorp.Floorp" "Release bundle ID is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_PRODUCT_NAME = Floorp" "Release product name is Floorp"
require_fixed "$RELEASE_CONFIG" "MOZ_PUBLIC_URL_SCHEME = floorp" "Public URL scheme is fixed"
require_fixed "$RELEASE_CONFIG" "MOZ_INTERNAL_URL_SCHEME = floorp-internal" "Internal URL scheme is fixed"

require_fixed "$RELEASE_ENTITLEMENTS" "\$(AppIdentifierPrefix)app.floorp.Floorp" "Floorp keychain group is fixed"
forbid_fixed_in_files \
    "com.apple.developer.web-browser" \
    "FloorpRelease omits the unapproved default-browser entitlement" \
    "$RELEASE_ENTITLEMENTS"
require_fixed "$RELEASE_PLIST" "\$(FLOORP_APP_GROUP_IDENTIFIER)" "Release plist uses the Floorp App Group setting"
require_fixed "$RELEASE_PLIST" "app.floorp.sync.part1" "Background sync task 1 is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.sync.part2" "Background sync task 2 is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.surface.notification.refresh" "Notification refresh task is fixed"
require_fixed "$RELEASE_PLIST" "app.floorp.suggest.ingest" "Suggest ingestion task is fixed"
require_fixed "$RELEASE_PLIST" "\$(PRODUCT_BUNDLE_IDENTIFIER).browsing" "Browsing user activity identifier follows the release bundle ID"
require_fixed "$RELEASE_PLIST" "\$(PRODUCT_BUNDLE_IDENTIFIER).newTab" "New-tab user activity identifier follows the release bundle ID"

if require_file "$FLOORP_SCHEME_FILE"; then
    if archive_uses_configuration "$FLOORP_SCHEME_FILE" "FloorpRelease"; then
        pass "Floorp scheme archives with the FloorpRelease configuration"
    else
        fail "Floorp scheme must archive with the FloorpRelease configuration"
    fi
fi

if require_file "$PROJECT_FILE"; then
    if search_regex_quiet \
        'baseConfigurationReference = [[:xdigit:]]+ /\* FloorpRelease\.xcconfig \*/;' \
        "$PROJECT_FILE"; then
        pass "Xcode project wires FloorpRelease to FloorpRelease.xcconfig"
    else
        fail "Xcode project must wire FloorpRelease to FloorpRelease.xcconfig"
    fi
fi

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
release_identity_pattern='(org\.mozilla\.|group\.org\.mozilla|43AQ936H96)'
if search_regex_ignore_case_quiet \
    "$release_identity_pattern" \
    "${RELEASE_IDENTITY_FILES[@]}"; then
    fail "FloorpRelease contains a concrete Mozilla bundle, App Group, or Team identifier"
    search_regex_ignore_case_lines \
        "$release_identity_pattern" \
        "${RELEASE_IDENTITY_FILES[@]}" >&2 || true
else
    pass "FloorpRelease contains no concrete Mozilla release identifier"
fi

echo "Checking canonical Floorp artwork..."
FLOORP_LOGO_HASH="a29a8d8122051058005daa1bc8ebe775eb764961ee874444ac0c21576d1332b5"
FLOORP_WORDMARK_HASH="3f0bbca9e6418b692521c7ef550e37271364c7acb84e8c697376b3e261e85fee"

if require_file "$PROJECT_FILE"; then
    if sed -n '/57E51B7531BD23BED254B3D5 \/\* FloorpRelease \*\//,/^[[:space:]]*};/p' "$PROJECT_FILE" \
        | search_regex_quiet 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'; then
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
    "a16249a3edf1accb968c40a0680f07889dbe99572bbe191edae9d8383d06ed8f" \
    "Primary app icon uses the approved Floorp artwork"
require_opaque_rgb_png \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore.png" \
    "Primary default app icon uses an RGB PNG without an alpha channel"
require_hash \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore-dark.png" \
    "10df560e6b2ddc405a7add6957e97b49cdcd2abe2a1b78297b4a56b578208095" \
    "Primary dark app icon uses the approved Floorp artwork"
require_hash \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore-tinted.png" \
    "f3a3166d1781e877fd7e1522530e40655d6507807117be011625a325a38b2ef6" \
    "Primary tinted app icon uses the approved Floorp artwork"
require_grayscale_png \
    "firefox-ios/Client/Assets/AppIcons.xcassets/AppIcon.appiconset/appstore-tinted.png" \
    "Primary tinted app icon uses a grayscale PNG color model"
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
