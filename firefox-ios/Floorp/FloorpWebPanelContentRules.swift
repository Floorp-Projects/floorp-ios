// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Shared
import WebKit

@MainActor
protocol FloorpWebPanelNoImageModeScriptControlling: AnyObject {
    func setEnabled(_ isEnabled: Bool)
    func invalidate()
}

@MainActor
protocol FloorpWebPanelNoImageModeScriptControllerFactory {
    func makeController(
        for webView: WKWebView,
        isEnabled: Bool
    ) -> any FloorpWebPanelNoImageModeScriptControlling
}

@MainActor
final class DefaultFloorpWebPanelNoImageModeScriptControllerFactory:
    FloorpWebPanelNoImageModeScriptControllerFactory {
    func makeController(
        for webView: WKWebView,
        isEnabled: Bool
    ) -> any FloorpWebPanelNoImageModeScriptControlling {
        DefaultFloorpWebPanelNoImageModeScriptController(
            webView: webView,
            isEnabled: isEnabled
        )
    }
}

/// Applies the presentation half of the normal-tab No Image Mode contract
/// without installing the full normal-tab script bundle. Web panels do not own
/// the message handlers required by autofill, print, and other normal-tab
/// scripts, so injecting that bundle would expose unsupported bridges. This
/// uses the same style identifier, CSS, default content world, document-start
/// timing, and all-frame behavior as NoImageModeHelper.js.
@MainActor
final class DefaultFloorpWebPanelNoImageModeScriptController:
    FloorpWebPanelNoImageModeScriptControlling {
    private weak var webView: WKWebView?
    private var userContentController: WKUserContentController?
    private var ownedScriptIDs = Set<ObjectIdentifier>()
    private var lastEnabled: Bool?

    init(webView: WKWebView, isEnabled: Bool) {
        self.webView = webView
        self.userContentController = webView.configuration.userContentController
        setEnabled(isEnabled)
    }

    func setEnabled(_ isEnabled: Bool) {
        guard lastEnabled != isEnabled else { return }
        lastEnabled = isEnabled
        let source = Self.scriptSource(isEnabled: isEnabled)
        let script = WKUserScript.createInDefaultContentWorld(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        replaceOwnedScripts(with: [script])
        if webView?.url != nil {
            webView?.evaluateJavascriptInDefaultContentWorld(source)
        }
    }

    func invalidate() {
        replaceOwnedScripts(with: [])
        lastEnabled = nil
        webView = nil
        userContentController = nil
    }

    private func replaceOwnedScripts(with scripts: [WKUserScript]) {
        guard let userContentController else { return }
        let retainedScripts = userContentController.userScripts.filter {
            !ownedScriptIDs.contains(ObjectIdentifier($0))
        }
        userContentController.removeAllUserScripts()
        retainedScripts.forEach(userContentController.addUserScript)
        scripts.forEach(userContentController.addUserScript)
        ownedScriptIDs = Set(scripts.map(ObjectIdentifier.init))
    }

    private static func scriptSource(isEnabled: Bool) -> String {
        """
        (() => {
          const styleID = "__firefox__NoImageMode";
          const enabled = \(isEnabled ? "true" : "false");
          const apply = () => {
            const existing = document.getElementById(styleID);
            if (!enabled) {
              existing?.remove();
              return;
            }
            const style = existing ?? document.createElement("style");
            style.id = styleID;
            style.textContent = "*{background-image:none !important;}img{visibility:hidden !important;}";
            if (!existing) {
              document.documentElement.appendChild(style);
            }
          };
          if (document.documentElement) {
            apply();
          } else {
            document.addEventListener("DOMContentLoaded", apply, { once: true });
          }
        })();
        """
    }
}

final class FloorpWebPanelNotificationObservation: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(
        observer: NSObjectProtocol,
        notificationCenter: NotificationCenter = .default
    ) {
        self.observer = observer
        self.notificationCenter = notificationCenter
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }
}

@MainActor
protocol FloorpWebPanelContentRuleInstalling: AnyObject {
    func install(completion: @escaping @MainActor () -> Void)
    func refresh(completion: @escaping @MainActor () -> Void)
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
    private let imageContentBlockingEnabledProvider: @MainActor () -> Bool

    init(
        isPrivate: Bool,
        webView: WKWebView,
        imageContentBlockingEnabled: @escaping @MainActor () -> Bool
    ) {
        self.isPrivate = isPrivate
        self.webView = webView
        self.imageContentBlockingEnabledProvider = imageContentBlockingEnabled
    }

    func currentURL() -> URL? {
        webView?.url
    }

    func currentWebView() -> WKWebView? {
        webView
    }

    func imageContentBlockingEnabled() -> Bool {
        imageContentBlockingEnabledProvider()
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

    func refresh(completion: @escaping @MainActor () -> Void) {
        guard !isInvalidated, let blocker else {
            completion()
            return
        }
        blocker.setupForTab(completion: completion)
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
