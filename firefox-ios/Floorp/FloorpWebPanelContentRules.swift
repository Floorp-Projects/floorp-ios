// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Shared
import WebKit

private final class FloorpWebPanelNotificationObservation: @unchecked Sendable {
    private var observer: NSObjectProtocol?

    init(observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}

@MainActor
protocol FloorpWebPanelContentRuleInstalling: AnyObject {
    func install(completion: @escaping @MainActor () -> Void)
    func invalidate()
}

@MainActor
protocol FloorpWebPanelContentRuleInstallerFactory {
    func makeInstaller(
        for tab: ContentBlockerTab
    ) -> any FloorpWebPanelContentRuleInstalling
}

@MainActor
final class FloorpWebPanelContentBlockerTab: ContentBlockerTab {
    let isPrivate: Bool
    private weak var webView: WKWebView?

    init(isPrivate: Bool, webView: WKWebView) {
        self.isPrivate = isPrivate
        self.webView = webView
    }

    func currentURL() -> URL? {
        webView?.url
    }

    func currentWebView() -> WKWebView? {
        webView
    }

    func imageContentBlockingEnabled() -> Bool {
        false
    }

    func detach() {
        webView = nil
    }
}

@MainActor
final class DefaultFloorpWebPanelContentRuleInstallerFactory:
    FloorpWebPanelContentRuleInstallerFactory {
    private let prefs: Prefs

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    func makeInstaller(
        for tab: ContentBlockerTab
    ) -> any FloorpWebPanelContentRuleInstalling {
        DefaultFloorpWebPanelContentRuleInstaller(tab: tab, prefs: prefs)
    }
}

@MainActor
private final class DefaultFloorpWebPanelContentRuleInstaller:
    FloorpWebPanelContentRuleInstalling {
    private weak var tab: ContentBlockerTab?
    private let prefs: Prefs
    private var blocker: FirefoxTabContentBlocker?
    private var readinessObserver: FloorpWebPanelNotificationObservation?
    private var pendingCompletion: (@MainActor () -> Void)?
    private var isInvalidated = false

    init(tab: ContentBlockerTab, prefs: Prefs) {
        self.tab = tab
        self.prefs = prefs
    }

    func install(completion: @escaping @MainActor () -> Void) {
        guard !isInvalidated else {
            completion()
            return
        }
        pendingCompletion = completion
        let contentBlocker = ContentBlocker.shared
        guard !contentBlocker.setupCompleted else {
            installCurrentRules()
            return
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .contentBlockerTabSetupRequired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard ContentBlocker.shared.setupCompleted else { return }
                self?.installCurrentRules()
            }
        }
        readinessObserver = FloorpWebPanelNotificationObservation(observer: observer)
        if contentBlocker.setupCompleted {
            installCurrentRules()
        }
    }

    func invalidate() {
        isInvalidated = true
        pendingCompletion = nil
        removeReadinessObserver()
        blocker = nil
    }

    private func installCurrentRules() {
        guard !isInvalidated,
              blocker == nil,
              let tab,
              let completion = pendingCompletion else {
            return
        }
        pendingCompletion = nil
        removeReadinessObserver()
        let blocker = FirefoxTabContentBlocker(
            tab: tab,
            prefs: prefs,
            setupImmediately: false
        )
        self.blocker = blocker
        blocker.setupForTab(completion: completion)
    }

    private func removeReadinessObserver() {
        guard let readinessObserver else { return }
        readinessObserver.invalidate()
        self.readinessObserver = nil
    }
}
