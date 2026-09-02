// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit
import Shared
import Common

class NightModeHelper: TabContentScript {
    private enum NightModeKeys {
        static let Status = "profile.NightModeStatus"
        static let DarkThemeEnabled = "NightModeEnabledDarkTheme"
    }

    static func name() -> String {
        return "NightMode"
    }

    func scriptMessageHandlerNames() -> [String]? {
        return []
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceiveScriptMessage message: WKScriptMessage
    ) {
        // Retained as a no-op for source compatibility. Floorp uses the
        // curated Dark Reader extension for website darkening.
    }

    static func jsCallbackBuilder(_ enabled: Bool) -> String {
        return "window.__firefox__.NightMode.setEnabled(\(enabled))"
    }

    @MainActor
    static func toggle(
        _ userDefaults: UserDefaultsInterface = UserDefaults.standard
    ) {
        setNightMode(userDefaults, enabled: false)
    }

    @MainActor
    static func setNightMode(
        _ userDefaults: UserDefaultsInterface = UserDefaults.standard,
        enabled: Bool
    ) {
        _ = enabled
        userDefaults.set(false, forKey: NightModeKeys.Status)
        let windowManager: WindowManager = AppContainer.shared.resolve()
        for tabManager in windowManager.allWindowTabManagers() {
            for tab in tabManager.tabs {
                tab.nightMode = false
                tab.webView?.scrollView.indicatorStyle = .default
            }
        }
    }

    static func isActivated(_ userDefaults: UserDefaultsInterface = UserDefaults.standard) -> Bool {
        _ = userDefaults
        return false
    }

    // MARK: - Temporary functions
    // These functions are only here to help with the night mode experiment
    // and will be removed once a decision from that experiment is reached.
    // TODO: https://mozilla-hub.atlassian.net/browse/FXIOS-8475
    // Reminder: Any future refactors for 8475 need to work with multi-window.
    @MainActor
    static func turnOff(
        _ userDefaults: UserDefaultsInterface = UserDefaults.standard
    ) {
        setNightMode(userDefaults, enabled: false)
    }

    static func cleanNightModeDefaults(
        _ userDefaults: UserDefaultsInterface = UserDefaults.standard
    ) {
        userDefaults.removeObject(forKey: NightModeKeys.Status)
        userDefaults.removeObject(forKey: NightModeKeys.DarkThemeEnabled)
    }
}
