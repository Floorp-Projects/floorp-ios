// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
@preconcurrency import WebKit

extension FloorpWebPanelContentMode {
    var webKitPreferredContentMode: WKWebpagePreferences.ContentMode {
        switch self {
        case .mobile: return .mobile
        case .desktop: return .desktop
        }
    }

    var userAgentPlatform: UserAgentPlatform {
        switch self {
        case .mobile: return .Mobile
        case .desktop: return .Desktop
        }
    }
}

/// Stable identity for one main-frame WebKit navigation. Keeping this type at
/// the runtime boundary prevents a failure from an older, superseded load from
/// being mistaken for the currently requested content-mode reload.
struct FloorpWebPanelNavigationIdentity: Hashable {
    private enum Value: Hashable {
        case webKit(ObjectIdentifier)
        case synthetic(UUID)
    }

    private let value: Value

    init(_ navigation: WKNavigation) {
        value = .webKit(ObjectIdentifier(navigation))
    }

    /// Supports runtimes that do not expose a `WKNavigation`, including unit
    /// test runtimes, while preserving a strongly typed session boundary.
    static func synthetic() -> Self {
        Self(value: .synthetic(UUID()))
    }

    private init(value: Value) {
        self.value = value
    }
}

enum FloorpWebPanelNavigationExecution: Equatable {
    case allow
    case openInMainBrowser(URL)
    case cancel
}

struct FloorpWebPanelMainBrowserRequest: Equatable {
    let url: URL
    let windowUUID: WindowUUID
    let isPrivate: Bool
}

@MainActor
struct FloorpWebPanelMainBrowserRouter {
    typealias OpenURLInNewTab = @MainActor (URL, Bool) -> Void

    private let windowUUID: WindowUUID
    private let openURLInNewTab: OpenURLInNewTab

    init(
        windowUUID: WindowUUID,
        openURLInNewTab: @escaping OpenURLInNewTab
    ) {
        self.windowUUID = windowUUID
        self.openURLInNewTab = openURLInNewTab
    }

    func open(_ request: FloorpWebPanelMainBrowserRequest) {
        guard request.windowUUID == windowUUID else { return }
        openURLInNewTab(request.url, request.isPrivate)
    }
}

@MainActor
final class FloorpWebPanelNavigationExecutor: NSObject, WKNavigationDelegate, WKUIDelegate {
    typealias OpenInMainBrowser = @MainActor (FloorpWebPanelMainBrowserRequest) -> Void
    typealias CurrentTime = @MainActor () -> TimeInterval
    typealias ContentModeDidCommit = @MainActor (
        FloorpWebPanelNavigationIdentity,
        FloorpWebPanelContentMode
    ) -> Void
    typealias ContentModeNavigationDidFail = @MainActor (
        FloorpWebPanelNavigationIdentity
    ) -> Void

    private let windowUUID: WindowUUID
    private let isPrivate: Bool
    private let minimumPopupInterval: TimeInterval
    private let currentTime: CurrentTime
    private let openInMainBrowserHandler: OpenInMainBrowser
    private(set) var contentMode: FloorpWebPanelContentMode
    var contentModeDidCommit: ContentModeDidCommit?
    var contentModeNavigationDidFail: ContentModeNavigationDidFail?
    private var lastPopupOpenTime: TimeInterval?
    /// Every allowed main-frame navigation needs an identity-bound marker so
    /// the session can retire coalesced reload intent on commit or failure.
    /// The associated mode is applied to WebKit only for HTTP(S); for the
    /// separately allowed exact `about:blank`, it records the mode that will
    /// apply to the next eligible Web navigation without mutating UA or
    /// `WKWebpagePreferences`.
    private var pendingMainFrameNavigationMode: FloorpWebPanelContentMode?
    private var navigationModesByID = [
        FloorpWebPanelNavigationIdentity: FloorpWebPanelContentMode
    ]()
    private var isInvalidated = false

    init(
        windowUUID: WindowUUID,
        isPrivate: Bool,
        contentMode: FloorpWebPanelContentMode = .mobile,
        minimumPopupInterval: TimeInterval = 0.75,
        currentTime: @escaping CurrentTime = { ProcessInfo.processInfo.systemUptime },
        openInMainBrowser: @escaping OpenInMainBrowser
    ) {
        self.windowUUID = windowUUID
        self.isPrivate = isPrivate
        self.contentMode = contentMode
        self.minimumPopupInterval = max(0, minimumPopupInterval)
        self.currentTime = currentTime
        self.openInMainBrowserHandler = openInMainBrowser
    }

    func execution(
        for decision: FloorpWebPanelNavigationDecision,
        isUserInitiated: Bool,
        at time: TimeInterval
    ) -> FloorpWebPanelNavigationExecution {
        guard !isInvalidated else { return .cancel }

        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openInMainBrowser(let url):
            guard isUserInitiated else { return .cancel }
            if let lastPopupOpenTime,
               time - lastPopupOpenTime < minimumPopupInterval {
                return .cancel
            }
            lastPopupOpenTime = time
            return .openInMainBrowser(url)
        }
    }

    func invalidate() {
        isInvalidated = true
        pendingMainFrameNavigationMode = nil
        navigationModesByID.removeAll()
        contentModeDidCommit = nil
        contentModeNavigationDidFail = nil
    }

    func updateContentMode(_ contentMode: FloorpWebPanelContentMode) {
        guard !isInvalidated else { return }
        self.contentMode = contentMode
    }

    func openInMainBrowserIfSafe(_ url: URL) {
        guard !isInvalidated,
              case .openInMainBrowser(let safeURL) = FloorpWebPanelNavigationPolicy.decision(
                  for: FloorpWebPanelNavigationRequest(url: url, target: .newWindow)
              ) else {
            return
        }
        openInMainBrowser(safeURL)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let execution = execution(for: navigationAction)
        apply(execution, decisionHandler: decisionHandler)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (
            WKNavigationActionPolicy,
            WKWebpagePreferences
        ) -> Void
    ) {
        let request = navigationRequest(for: navigationAction)
        let execution = execution(for: navigationAction)
        if execution == .allow {
            applyContentMode(to: webView, preferences: preferences, for: request)
        }
        apply(execution, preferences: preferences, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard let navigation else { return }
        bindPendingContentMode(to: FloorpWebPanelNavigationIdentity(navigation))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard let navigation else { return }
        commitContentModeNavigation(FloorpWebPanelNavigationIdentity(navigation))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        guard let navigation else { return }
        failContentModeNavigation(FloorpWebPanelNavigationIdentity(navigation))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard let navigation else { return }
        failContentModeNavigation(FloorpWebPanelNavigationIdentity(navigation))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let execution = execution(for: navigationAction, forceNewWindow: true)
        if case .openInMainBrowser(let url) = execution {
            openInMainBrowser(url)
        }
        return nil
    }

    private func execution(
        for navigationAction: WKNavigationAction,
        forceNewWindow: Bool = false
    ) -> FloorpWebPanelNavigationExecution {
        let request = navigationRequest(
            for: navigationAction,
            forceNewWindow: forceNewWindow
        )
        let decision = FloorpWebPanelNavigationPolicy.decision(for: request)
        return execution(
            for: decision,
            isUserInitiated: navigationAction.navigationType == .linkActivated,
            at: currentTime()
        )
    }

    private func navigationRequest(
        for navigationAction: WKNavigationAction,
        forceNewWindow: Bool = false
    ) -> FloorpWebPanelNavigationRequest {
        let target: FloorpWebPanelNavigationTarget
        if forceNewWindow || navigationAction.targetFrame == nil {
            target = .newWindow
        } else if navigationAction.targetFrame?.isMainFrame == true {
            target = .mainFrame
        } else {
            target = .subframe
        }

        return FloorpWebPanelNavigationRequest(
            url: navigationAction.request.url,
            target: target
        )
    }

    @discardableResult
    func applyContentMode(
        to webView: WKWebView,
        preferences: WKWebpagePreferences,
        for request: FloorpWebPanelNavigationRequest
    ) -> Bool {
        guard !isInvalidated,
              case .mainFrame = request.target,
              let url = request.url,
              FloorpWebPanelNavigationPolicy.decision(for: request) == .allow else {
            return false
        }
        pendingMainFrameNavigationMode = contentMode
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        preferences.preferredContentMode = contentMode.webKitPreferredContentMode
        let domain = url.baseDomain ?? url.host ?? ""
        webView.customUserAgent = UserAgent.getUserAgent(
            domain: domain,
            platform: contentMode.userAgentPlatform
        )
        return true
    }

    func bindPendingContentMode(to navigationID: FloorpWebPanelNavigationIdentity) {
        guard !isInvalidated, let pendingMainFrameNavigationMode else { return }
        self.pendingMainFrameNavigationMode = nil
        navigationModesByID[navigationID] = pendingMainFrameNavigationMode
    }

    func commitContentModeNavigation(_ navigationID: FloorpWebPanelNavigationIdentity) {
        guard !isInvalidated,
              let committedMode = navigationModesByID.removeValue(
                  forKey: navigationID
              ) else {
            return
        }
        contentModeDidCommit?(navigationID, committedMode)
    }

    func failContentModeNavigation(_ navigationID: FloorpWebPanelNavigationIdentity) {
        guard !isInvalidated,
              navigationModesByID.removeValue(forKey: navigationID) != nil else {
            return
        }
        contentModeNavigationDidFail?(navigationID)
    }

    private func apply(
        _ execution: FloorpWebPanelNavigationExecution,
        decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        switch execution {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openInMainBrowser(let url):
            decisionHandler(.cancel)
            openInMainBrowser(url)
        }
    }

    private func apply(
        _ execution: FloorpWebPanelNavigationExecution,
        preferences: WKWebpagePreferences,
        decisionHandler: @MainActor (
            WKNavigationActionPolicy,
            WKWebpagePreferences
        ) -> Void
    ) {
        switch execution {
        case .allow:
            decisionHandler(.allow, preferences)
        case .cancel:
            decisionHandler(.cancel, preferences)
        case .openInMainBrowser(let url):
            decisionHandler(.cancel, preferences)
            openInMainBrowser(url)
        }
    }

    private func openInMainBrowser(_ url: URL) {
        openInMainBrowserHandler(
            FloorpWebPanelMainBrowserRequest(
                url: url,
                windowUUID: windowUUID,
                isPrivate: isPrivate
            )
        )
    }
}
