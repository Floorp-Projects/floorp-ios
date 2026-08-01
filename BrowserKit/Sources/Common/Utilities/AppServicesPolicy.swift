// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Build-time policy for app services that may send user data to a remote service.
///
/// Xcode expands these values from the active configuration into Info.plist. A
/// service is enabled only by an explicit `YES`, so missing or malformed release
/// configuration fails closed.
public enum AppServicesPolicy {
    private enum Key {
        static let hostedSummarizer = "MozAllowHostedSummarizer"
        static let quickAnswers = "MozAllowQuickAnswers"
        static let remotePushNotifications = "MozAllowRemotePushNotifications"
    }

    public static var allowsHostedSummarizer: Bool {
        return isExplicitlyEnabled(applicationInfoDictionary[Key.hostedSummarizer])
    }

    public static var allowsQuickAnswers: Bool {
        return isExplicitlyEnabled(applicationInfoDictionary[Key.quickAnswers])
    }

    public static var allowsRemotePushNotifications: Bool {
        return isExplicitlyEnabled(applicationInfoDictionary[Key.remotePushNotifications])
    }

    static func isExplicitlyEnabled(_ value: Any?) -> Bool {
        return (value as? String) == "YES"
    }

    private static var applicationInfoDictionary: [String: Any] {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "appex" else {
            return bundle.infoDictionary ?? [:]
        }

        // An extension inherits the containing app's service policy.
        let appURL = bundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appURL)?.infoDictionary ?? [:]
    }
}
