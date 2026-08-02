// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
@preconcurrency import WebKit

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

    private let windowUUID: WindowUUID
    private let isPrivate: Bool
    private let minimumPopupInterval: TimeInterval
    private let currentTime: CurrentTime
    private let openInMainBrowserHandler: OpenInMainBrowser
    private var lastPopupOpenTime: TimeInterval?
    private var isInvalidated = false

    init(
        windowUUID: WindowUUID,
        isPrivate: Bool,
        minimumPopupInterval: TimeInterval = 0.75,
        currentTime: @escaping CurrentTime = { ProcessInfo.processInfo.systemUptime },
        openInMainBrowser: @escaping OpenInMainBrowser
    ) {
        self.windowUUID = windowUUID
        self.isPrivate = isPrivate
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
        let target: FloorpWebPanelNavigationTarget
        if forceNewWindow || navigationAction.targetFrame == nil {
            target = .newWindow
        } else if navigationAction.targetFrame?.isMainFrame == true {
            target = .mainFrame
        } else {
            target = .subframe
        }

        let decision = FloorpWebPanelNavigationPolicy.decision(
            for: FloorpWebPanelNavigationRequest(
                url: navigationAction.request.url,
                target: target
            )
        )
        return execution(
            for: decision,
            isUserInitiated: navigationAction.navigationType == .linkActivated,
            at: currentTime()
        )
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
