// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation

extension AppInfo {
    public static var displayName: String {
        guard let displayName = applicationBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String else {
            fatalError("CFBundleDisplayName not found in info.plist")
        }
        return displayName
    }

    public static var majorAppVersion: String {
        return appVersion.components(separatedBy: ".").first!
    }

    // FIXME: FXIOS-13210 nonisolated(unsafe) because some tests need to mutate this global state
    /// The port for the internal webserver, tests can change this
    /// Please be aware that we needed to migrate this webserverPort in WebEngine.WKEngineInfo
    /// due to Shared target issues in #17721. This webserverPort needs to be deleted with
    /// FXIOS-7960 once the WebEngine package is integrated in Firefox iOS
    nonisolated(unsafe) public static var webserverPort = 6571

    /// Return the keychain access group.
    public static func keychainAccessGroupWithPrefix(_ prefix: String) -> String {
        var bundleIdentifier = baseBundleIdentifier
        if bundleIdentifier == "org.mozilla.ios.FennecEnterprise" {
            // Bug 1373726 - Base bundle identifier incorrectly generated for Nightly builds
            // This can be removed when we are able to fix the app group in the developer portal
            bundleIdentifier = "org.mozilla.ios.Fennec.enterprise"
        }
        return prefix + "." + bundleIdentifier
    }

    public static let debugPrefIsChinaEdition = "debugPrefIsChinaEdition"

    public static let isChinaEdition: Bool = {
        if UserDefaults.standard.bool(forKey: AppInfo.debugPrefIsChinaEdition) {
            return true
        }
        // FIXME: FXIOS-14170 China FxA is no longer available, do not enable ChinaEdition based on locale
        // return Locale.current.identifier == "zh_CN"
        return false
    }()

    /// The numeric App Store identifier for the current application.
    ///
    /// Floorp does not receive this value until its App Store Connect record exists,
    /// so callers must support an unset identifier.
    public static var appStoreId: String? {
        let value = applicationBundle.object(forInfoDictionaryKey: "AppStoreID") as? String
        return normalizedAppStoreId(value)
    }

    public static func normalizedAppStoreId(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("id") {
            value.removeFirst(2)
        }
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    /// Return the shared container identifier (also known as the app group) to be used with for example background
    /// http requests. It is the base bundle identifier with a "group." prefix.
    public static var sharedContainerIdentifier: String {
        var bundleIdentifier = baseBundleIdentifier
        if bundleIdentifier == "org.mozilla.ios.FennecEnterprise" {
            // Bug 1373726 - Base bundle identifier incorrectly generated for Nightly builds
            // This can be removed when we are able to fix the app group in the developer portal
            bundleIdentifier = "org.mozilla.ios.Fennec.enterprise"
        }
        return "group." + bundleIdentifier
    }
}
