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
    func setMediaPlaybackSuppressed(
        _ isSuppressed: Bool,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    )
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
    private var mediaPlaybackController: FloorpWebPanelMediaPlaybackController?

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
        mediaPlaybackController = FloorpWebPanelMediaPlaybackController(webView: webView)
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

    func setMediaPlaybackSuppressed(
        _ isSuppressed: Bool,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard let mediaPlaybackController else {
            completion(.failure(FloorpWebPanelMediaPlaybackError.runtimeUnavailable))
            return
        }
        mediaPlaybackController.setSuppressed(isSuppressed, completion: completion)
    }

    func invalidate() {
        stateDidChange = nil
        mediaPlaybackController?.invalidate()
        mediaPlaybackController = nil
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
final class FloorpWebPanelMediaPlaybackTransitioner {
    typealias Completion = @MainActor (Result<Void, Error>) -> Void
    typealias NativeCallback = @MainActor () -> Void
    typealias NativeSetter = @MainActor (
        _ webView: WKWebView,
        _ isSuppressed: Bool,
        _ callback: NativeCallbackBox?
    ) -> Void
    typealias ScriptEvaluator = @MainActor (
        _ webView: WKWebView,
        _ completion: CompletionBox
    ) -> Void

    @MainActor
    final class NativeCallbackBox {
        private var callback: NativeCallback?

        init(_ callback: @escaping NativeCallback) {
            self.callback = callback
        }

        func call() {
            let callback = callback
            self.callback = nil
            callback?()
        }
    }

    @MainActor
    final class CompletionBox {
        private var completion: Completion?

        init(_ completion: @escaping Completion) {
            self.completion = completion
        }

        func finish(with result: Result<Void, Error>) {
            let completion = completion
            self.completion = nil
            completion?(result)
        }
    }

    private let nativeSetter: NativeSetter
    private let scriptEvaluator: ScriptEvaluator

    init(
        nativeSetter: @escaping NativeSetter = { webView, isSuppressed, callback in
            webView.setAllMediaPlaybackSuspended(isSuppressed) {
                callback?.call()
            }
        },
        scriptEvaluator: @escaping ScriptEvaluator = { webView, completion in
            webView.evaluateJavaScript(
                FloorpWebPanelMediaPlaybackScript.suppress,
                in: nil,
                in: .defaultClient
            ) { result in
                completion.finish(with: result.map { _ in () })
            }
        }
    ) {
        self.nativeSetter = nativeSetter
        self.scriptEvaluator = scriptEvaluator
    }

    func transition(
        on webView: WKWebView,
        isSuppressed: Bool,
        completion: @escaping Completion
    ) {
        let scriptEvaluator = scriptEvaluator
        let callback = NativeCallbackBox { [weak webView] in
            guard isSuppressed else {
                completion(.success(()))
                return
            }
            guard let webView else {
                completion(.failure(FloorpWebPanelMediaPlaybackError.runtimeUnavailable))
                return
            }

            // Native suspension remains authoritative. This one-shot pause is
            // best effort and deliberately avoids persistent DOM mutations.
            scriptEvaluator(webView, CompletionBox(completion))
        }
        nativeSetter(webView, isSuppressed, callback)
    }

    func enforceFinalSuppression(on webView: WKWebView) {
        nativeSetter(webView, true, nil)
    }
}

@MainActor
private final class FloorpWebPanelMediaPlaybackTransition {
    private weak var webView: WKWebView?
    private let transitioner: FloorpWebPanelMediaPlaybackTransitioner
    private var completion: FloorpWebPanelMediaPlaybackTransitioner.Completion?
    private var isInvalidated = false

    init(
        webView: WKWebView,
        transitioner: FloorpWebPanelMediaPlaybackTransitioner,
        completion: @escaping FloorpWebPanelMediaPlaybackTransitioner.Completion
    ) {
        self.webView = webView
        self.transitioner = transitioner
        self.completion = completion
    }

    func finish(with result: Result<Void, Error>) {
        guard !isInvalidated else {
            if let webView {
                transitioner.enforceFinalSuppression(on: webView)
            }
            return
        }
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        completion = nil
        if let webView {
            transitioner.enforceFinalSuppression(on: webView)
        }
    }
}

@MainActor
final class FloorpWebPanelMediaPlaybackController {
    private weak var webView: WKWebView?
    private let transitioner: FloorpWebPanelMediaPlaybackTransitioner
    private var isSuppressed = false
    private var transitionGeneration = UUID()
    private var activeTransition: FloorpWebPanelMediaPlaybackTransition?

    init(
        webView: WKWebView,
        transitioner: FloorpWebPanelMediaPlaybackTransitioner = .init()
    ) {
        self.webView = webView
        self.transitioner = transitioner
    }

    func setSuppressed(
        _ isSuppressed: Bool,
        completion: @escaping FloorpWebPanelMediaPlaybackTransitioner.Completion
    ) {
        guard self.isSuppressed != isSuppressed else {
            completion(.success(()))
            return
        }
        guard let webView, activeTransition == nil else {
            completion(.failure(FloorpWebPanelMediaPlaybackError.runtimeUnavailable))
            return
        }

        self.isSuppressed = isSuppressed
        let generation = UUID()
        transitionGeneration = generation
        let transition = FloorpWebPanelMediaPlaybackTransition(
            webView: webView,
            transitioner: transitioner
        ) { [weak self] result in
            guard let self, transitionGeneration == generation else { return }
            activeTransition = nil
            completion(result)
        }
        activeTransition = transition
        transitioner.transition(
            on: webView,
            isSuppressed: isSuppressed
        ) { [transition] result in
            transition.finish(with: result)
        }
    }

    func invalidate() {
        transitionGeneration = UUID()
        if let activeTransition {
            activeTransition.invalidate()
        } else if let webView {
            transitioner.enforceFinalSuppression(on: webView)
        }
        activeTransition = nil
        self.webView = nil
    }
}

private enum FloorpWebPanelMediaPlaybackError: Error {
    case runtimeUnavailable
}

private enum FloorpWebPanelMediaPlaybackScript {
    static let suppress = #"""
    (() => {
      for (const element of document.querySelectorAll("audio, video")) {
        element.pause();
      }
      return true;
    })();
    """#
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
    private var pendingInitialLoadURL: URL?
    private var pendingRestorationCandidateURL: URL?
    private var isInvalidated = false
    private var isVisible = true
    private var desiredMediaPlaybackSuppression = false
    private var appliedMediaPlaybackSuppression = false
    private var isMediaPlaybackTransitionInFlight = false
    private var mediaPlaybackTransitionGeneration = UUID()
    private(set) var isAudioMuted = false

    var contentView: UIView? {
        runtime?.contentView
    }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        runtime: any FloorpWebPanelWebViewRuntime,
        contentRuleInstallerFactory: any FloorpWebPanelContentRuleInstallerFactory,
        navigationExecutor: FloorpWebPanelNavigationExecutor,
        restorationURL: URL? = nil,
        privateBrowsingSessionLease: WKPrivateBrowsingSessionLease? = nil
    ) {
        self.key = key
        self.state = FloorpWebPanelSessionState(configuration: configuration)
        self.runtime = runtime
        self.navigationExecutor = navigationExecutor
        let safeRestorationURL = FloorpWebPanelRestorationPolicy.safeWebURL(restorationURL)
        self.pendingInitialLoadURL = safeRestorationURL ?? configuration.homeURL
        self.pendingRestorationCandidateURL = safeRestorationURL
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
        pendingRestorationCandidateURL = nil
        guard areContentRulesReady else {
            pendingInitialLoadURL = state.configuration.homeURL
            return
        }
        performLoad(state.configuration.homeURL)
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

    func openCurrentPageInMainBrowser() {
        guard !isInvalidated, let currentURL = state.currentURL else { return }
        navigationExecutor?.openInMainBrowserIfSafe(currentURL)
    }

    func setVisible(_ isVisible: Bool) {
        guard !isInvalidated, self.isVisible != isVisible else { return }
        self.isVisible = isVisible
        updateMediaPlaybackSuppression()
    }

    func setAudioMuted(_ isMuted: Bool) {
        guard !isInvalidated, isAudioMuted != isMuted else { return }
        isAudioMuted = isMuted
        updateMediaPlaybackSuppression()
    }

    func restorationURLForUnload() -> URL? {
        guard !isInvalidated else { return nil }
        if let runtimeURL = runtime?.currentURL {
            // A non-nil runtime URL is authoritative. In particular, do not
            // fall back to stale safe state when the latest URL is unsafe.
            return FloorpWebPanelRestorationPolicy.safeWebURL(runtimeURL)
        }
        if let pendingRestorationCandidateURL {
            return pendingRestorationCandidateURL
        }
        return FloorpWebPanelRestorationPolicy.safeWebURL(state.currentURL)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        installationGeneration = UUID()
        mediaPlaybackTransitionGeneration = UUID()
        pendingInitialLoadURL = nil
        pendingRestorationCandidateURL = nil
        isMediaPlaybackTransitionInFlight = false
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
        guard let initialLoadURL = pendingInitialLoadURL else { return }
        pendingInitialLoadURL = nil
        performLoad(initialLoadURL)
    }

    private func performLoad(_ url: URL) {
        runtime?.load(URLRequest(url: url))
    }

    private func updateMediaPlaybackSuppression() {
        let shouldSuppress = !isVisible || isAudioMuted
        guard desiredMediaPlaybackSuppression != shouldSuppress else { return }
        desiredMediaPlaybackSuppression = shouldSuppress
        startMediaPlaybackTransitionIfNeeded()
    }

    private func startMediaPlaybackTransitionIfNeeded() {
        guard !isInvalidated,
              !isMediaPlaybackTransitionInFlight,
              desiredMediaPlaybackSuppression != appliedMediaPlaybackSuppression,
              let runtime else {
            return
        }

        let target = desiredMediaPlaybackSuppression
        let generation = mediaPlaybackTransitionGeneration
        isMediaPlaybackTransitionInFlight = true
        runtime.setMediaPlaybackSuppressed(target) { [weak self] _ in
            guard let self,
                  !self.isInvalidated,
                  self.mediaPlaybackTransitionGeneration == generation else {
                return
            }
            self.isMediaPlaybackTransitionInFlight = false
            self.appliedMediaPlaybackSuppression = target
            self.startMediaPlaybackTransitionIfNeeded()
        }
    }

    private func synchronizeState() {
        guard !isInvalidated, let runtime else { return }
        let currentURL = runtime.currentURL
        if currentURL != nil {
            pendingRestorationCandidateURL = nil
        }
        state.currentURL = currentURL
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
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
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
                windowUUID: key.windowUUID,
                isPrivate: key.isPrivate,
                openInMainBrowser: openInMainBrowser
            ),
            restorationURL: restorationURL,
            privateBrowsingSessionLease: privateBrowsingSessionLease
        )
    }
}
