// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import Storage
import UIKit
import WebEngine
@preconcurrency import WebKit

@MainActor
protocol FloorpWebPanelWebViewConfigurationProviding {
    func configuration(isPrivate: Bool) -> WKWebViewConfiguration
}

@MainActor
final class DefaultFloorpWebPanelWebViewConfigurationProvider:
    FloorpWebPanelWebViewConfigurationProviding {
    private let profile: Profile
    private let privateBrowsingSessionCoordinator: WKPrivateBrowsingSessionCoordinator

    init(
        profile: Profile,
        privateBrowsingSessionCoordinator: WKPrivateBrowsingSessionCoordinator = .shared
    ) {
        self.profile = profile
        self.privateBrowsingSessionCoordinator = privateBrowsingSessionCoordinator
    }

    func configuration(isPrivate: Bool) -> WKWebViewConfiguration {
        let parameters = WKWebViewParameters(
            blockPopups: profile.prefs.boolForKey(PrefsKeys.KeyBlockPopups) ?? true,
            isPrivate: isPrivate,
            autoPlay: AutoplayAccessors.getMediaTypesRequiringUserActionForPlayback(profile.prefs),
            schemeHandler: InternalSchemeHandler()
        )
        return DefaultWKEngineConfigurationProvider(
            privateBrowsingSessionCoordinator: privateBrowsingSessionCoordinator
        ).createConfiguration(parameters: parameters)
            .webViewConfiguration
    }
}

@MainActor
protocol FloorpWebPanelWebViewRuntime: AnyObject {
    var contentView: UIView? { get }
    var webView: WKWebView? { get }
    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var stateDidChange: (@MainActor () -> Void)? { get set }

    func setNavigationExecutor(_ executor: FloorpWebPanelNavigationExecutor?)
    func load(_ request: URLRequest)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    func invalidate()
}

@MainActor
protocol FloorpWebPanelWebViewRuntimeFactory {
    func makeRuntime(
        configuration: WKWebViewConfiguration,
        windowUUID: WindowUUID,
        certStore: CertStore
    ) -> any FloorpWebPanelWebViewRuntime
}

@MainActor
final class DefaultFloorpWebPanelWebViewRuntimeFactory: FloorpWebPanelWebViewRuntimeFactory {
    func makeRuntime(
        configuration: WKWebViewConfiguration,
        windowUUID: WindowUUID,
        certStore: CertStore
    ) -> any FloorpWebPanelWebViewRuntime {
        DefaultFloorpWebPanelWebViewRuntime(
            configuration: configuration,
            windowUUID: windowUUID,
            certStore: certStore
        )
    }
}

@MainActor
private final class DefaultFloorpWebPanelWebViewRuntime:
    NSObject,
    FloorpWebPanelWebViewRuntime,
    TabWebViewDelegate {
    var stateDidChange: (@MainActor () -> Void)?
    private var tabWebView: TabWebView?
    private var observations = [NSKeyValueObservation]()

    var contentView: UIView? { tabWebView }
    var webView: WKWebView? { tabWebView }
    var currentURL: URL? { tabWebView?.url }
    var pageTitle: String? { tabWebView?.title }
    var canGoBack: Bool { tabWebView?.canGoBack ?? false }
    var canGoForward: Bool { tabWebView?.canGoForward ?? false }
    var isLoading: Bool { tabWebView?.isLoading ?? false }
    var estimatedProgress: Double { tabWebView?.estimatedProgress ?? 0 }

    init(
        configuration: WKWebViewConfiguration,
        windowUUID: WindowUUID,
        certStore: CertStore
    ) {
        super.init()
        let webView = TabWebView(
            frame: .zero,
            configuration: configuration,
            windowUUID: windowUUID,
            certStore: certStore
        )
        webView.configure(delegate: self, navigationDelegate: nil)
        webView.accessibilityLabel = .WebViewAccessibilityLabel
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        tabWebView = webView
        observe(webView)
    }

    func setNavigationExecutor(_ executor: FloorpWebPanelNavigationExecutor?) {
        tabWebView?.navigationDelegate = executor
        tabWebView?.uiDelegate = executor
    }

    func load(_ request: URLRequest) {
        tabWebView?.load(request)
    }

    func goBack() {
        tabWebView?.goBack()
    }

    func goForward() {
        tabWebView?.goForward()
    }

    func reload() {
        tabWebView?.reload()
    }

    func stopLoading() {
        tabWebView?.stopLoading()
    }

    func invalidate() {
        stateDidChange = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        tabWebView?.stopLoading()
        tabWebView?.navigationDelegate = nil
        tabWebView?.uiDelegate = nil
        tabWebView?.removeAllUserScripts()
        tabWebView?.configuration.userContentController.removeAllContentRuleLists()
        tabWebView?.removeFromSuperview()
        tabWebView = nil
    }

    func tabWebView(
        _ tabWebView: TabWebView,
        didSelectFindInPageForSelection selection: String
    ) {}

    func tabWebViewSearchWithFirefox(
        _ tabWebViewSearchWithFirefox: TabWebView,
        didSelectSearchWithFirefoxForSelection selection: String
    ) {}

    func tabWebViewShouldShowAccessoryView(_ tabWebView: TabWebView) -> Bool {
        true
    }

    private func observe(_ webView: TabWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                self?.notifyStateDidChange()
            },
        ]
    }

    nonisolated private func notifyStateDidChange() {
        Task { @MainActor [weak self] in
            self?.stateDidChange?()
        }
    }
}

@MainActor
final class FloorpWebPanelWebViewSession: FloorpWebPanelSessionProtocol {
    let key: FloorpWebPanelSessionKey
    private(set) var state: FloorpWebPanelSessionState
    private var runtime: (any FloorpWebPanelWebViewRuntime)?
    private var blockerTab: FloorpWebPanelContentBlockerTab?
    private var contentRuleInstaller: (any FloorpWebPanelContentRuleInstalling)?
    private var navigationExecutor: FloorpWebPanelNavigationExecutor?
    private var privateBrowsingSessionLease: WKPrivateBrowsingSessionLease?
    private var observers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()
    private var installationGeneration = UUID()
    private var areContentRulesReady = false
    private var hasPendingHomeLoad = true
    private var isInvalidated = false

    var contentView: UIView? {
        runtime?.contentView
    }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        runtime: any FloorpWebPanelWebViewRuntime,
        contentRuleInstallerFactory: any FloorpWebPanelContentRuleInstallerFactory,
        navigationExecutor: FloorpWebPanelNavigationExecutor,
        privateBrowsingSessionLease: WKPrivateBrowsingSessionLease? = nil
    ) {
        self.key = key
        self.state = FloorpWebPanelSessionState(configuration: configuration)
        self.runtime = runtime
        self.navigationExecutor = navigationExecutor
        self.privateBrowsingSessionLease = privateBrowsingSessionLease

        runtime.setNavigationExecutor(navigationExecutor)
        runtime.stateDidChange = { [weak self] in
            self?.synchronizeState()
        }

        if let webView = runtime.webView {
            let blockerTab = FloorpWebPanelContentBlockerTab(
                isPrivate: key.isPrivate,
                webView: webView
            )
            self.blockerTab = blockerTab
            contentRuleInstaller = contentRuleInstallerFactory.makeInstaller(for: blockerTab)
        }
        installRulesBeforeInitialLoad()
    }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration) {
        guard !isInvalidated else { return }
        state.configuration = configuration
        notifyObservers()
    }

    @discardableResult
    func addStateObserver(
        _ observer: @escaping @MainActor (FloorpWebPanelSessionState) -> Void
    ) -> UUID? {
        guard !isInvalidated else { return nil }
        let identifier = UUID()
        observers[identifier] = observer
        observer(state)
        return identifier
    }

    func removeStateObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }

    func loadHome() {
        guard !isInvalidated else { return }
        guard areContentRulesReady else {
            hasPendingHomeLoad = true
            return
        }
        performHomeLoad()
    }

    func goBack() {
        guard !isInvalidated, state.canGoBack else { return }
        runtime?.goBack()
    }

    func goForward() {
        guard !isInvalidated, state.canGoForward else { return }
        runtime?.goForward()
    }

    func reload() {
        guard !isInvalidated else { return }
        runtime?.reload()
    }

    func stopLoading() {
        guard !isInvalidated else { return }
        runtime?.stopLoading()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        installationGeneration = UUID()
        hasPendingHomeLoad = false
        observers.removeAll()
        contentRuleInstaller?.invalidate()
        contentRuleInstaller = nil
        blockerTab?.detach()
        blockerTab = nil
        navigationExecutor?.invalidate()
        navigationExecutor = nil
        runtime?.stateDidChange = nil
        runtime?.invalidate()
        runtime = nil
        privateBrowsingSessionLease?.invalidate()
        privateBrowsingSessionLease = nil
    }

    private func installRulesBeforeInitialLoad() {
        guard let contentRuleInstaller else {
            finishContentRuleInstallation()
            return
        }
        let generation = installationGeneration
        contentRuleInstaller.install { [weak self] in
            guard let self,
                  !self.isInvalidated,
                  self.installationGeneration == generation else {
                return
            }
            self.finishContentRuleInstallation()
        }
    }

    private func finishContentRuleInstallation() {
        guard !isInvalidated, !areContentRulesReady else { return }
        areContentRulesReady = true
        guard hasPendingHomeLoad else { return }
        hasPendingHomeLoad = false
        performHomeLoad()
    }

    private func performHomeLoad() {
        runtime?.load(URLRequest(url: state.configuration.homeURL))
    }

    private func synchronizeState() {
        guard !isInvalidated, let runtime else { return }
        state.currentURL = runtime.currentURL
        state.pageTitle = runtime.pageTitle
        state.canGoBack = runtime.canGoBack
        state.canGoForward = runtime.canGoForward
        state.isLoading = runtime.isLoading
        state.estimatedProgress = min(max(runtime.estimatedProgress, 0), 1)
        notifyObservers()
    }

    private func notifyObservers() {
        let currentState = state
        Array(observers.values).forEach { $0(currentState) }
    }
}

@MainActor
final class DefaultFloorpWebPanelSessionFactory: FloorpWebPanelSessionFactory {
    private let profile: Profile
    private let configurationProvider: any FloorpWebPanelWebViewConfigurationProviding
    private let runtimeFactory: any FloorpWebPanelWebViewRuntimeFactory
    private let contentRuleInstallerFactory: any FloorpWebPanelContentRuleInstallerFactory
    private let openInMainBrowser: FloorpWebPanelNavigationExecutor.OpenInMainBrowser
    private let privateBrowsingSessionCoordinator: WKPrivateBrowsingSessionCoordinator

    init(
        profile: Profile,
        configurationProvider: (any FloorpWebPanelWebViewConfigurationProviding)? = nil,
        runtimeFactory: any FloorpWebPanelWebViewRuntimeFactory = DefaultFloorpWebPanelWebViewRuntimeFactory(),
        contentRuleInstallerFactory: (any FloorpWebPanelContentRuleInstallerFactory)? = nil,
        privateBrowsingSessionCoordinator: WKPrivateBrowsingSessionCoordinator = .shared,
        openInMainBrowser: @escaping FloorpWebPanelNavigationExecutor.OpenInMainBrowser
    ) {
        self.profile = profile
        self.configurationProvider = configurationProvider
            ?? DefaultFloorpWebPanelWebViewConfigurationProvider(
                profile: profile,
                privateBrowsingSessionCoordinator: privateBrowsingSessionCoordinator
            )
        self.runtimeFactory = runtimeFactory
        self.contentRuleInstallerFactory = contentRuleInstallerFactory
            ?? DefaultFloorpWebPanelContentRuleInstallerFactory(prefs: profile.prefs)
        self.openInMainBrowser = openInMainBrowser
        self.privateBrowsingSessionCoordinator = privateBrowsingSessionCoordinator
    }

    func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration
    ) throws -> any FloorpWebPanelSessionProtocol {
        let privateBrowsingSessionLease = key.isPrivate
            ? privateBrowsingSessionCoordinator.acquireLease()
            : nil
        let webViewConfiguration = configurationProvider.configuration(isPrivate: key.isPrivate)
        let runtime = runtimeFactory.makeRuntime(
            configuration: webViewConfiguration,
            windowUUID: key.windowUUID,
            certStore: profile.certStore
        )
        return FloorpWebPanelWebViewSession(
            key: key,
            configuration: configuration,
            runtime: runtime,
            contentRuleInstallerFactory: contentRuleInstallerFactory,
            navigationExecutor: FloorpWebPanelNavigationExecutor(
                openInMainBrowser: openInMainBrowser
            ),
            privateBrowsingSessionLease: privateBrowsingSessionLease
        )
    }
}
