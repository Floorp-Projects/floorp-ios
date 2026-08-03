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
    var pageZoom: CGFloat { get }
    var stateDidChange: (@MainActor () -> Void)? { get set }

    func setNavigationExecutor(_ executor: FloorpWebPanelNavigationExecutor?)
    @discardableResult
    func load(_ request: URLRequest) -> FloorpWebPanelNavigationIdentity?
    @discardableResult
    func goBack() -> FloorpWebPanelNavigationIdentity?
    @discardableResult
    func goForward() -> FloorpWebPanelNavigationIdentity?
    @discardableResult
    func reload() -> FloorpWebPanelNavigationIdentity?
    @discardableResult
    func reloadFromOrigin() -> FloorpWebPanelNavigationIdentity?
    func stopLoading()
    func setPageZoom(_ pageZoom: CGFloat)
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
    var pageZoom: CGFloat { tabWebView?.pageZoom ?? 1 }

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

    @discardableResult
    func load(_ request: URLRequest) -> FloorpWebPanelNavigationIdentity? {
        guard let navigation = tabWebView?.load(request) else { return nil }
        return FloorpWebPanelNavigationIdentity(navigation)
    }

    @discardableResult
    func goBack() -> FloorpWebPanelNavigationIdentity? {
        guard let navigation = tabWebView?.goBack() else { return nil }
        return FloorpWebPanelNavigationIdentity(navigation)
    }

    @discardableResult
    func goForward() -> FloorpWebPanelNavigationIdentity? {
        guard let navigation = tabWebView?.goForward() else { return nil }
        return FloorpWebPanelNavigationIdentity(navigation)
    }

    @discardableResult
    func reload() -> FloorpWebPanelNavigationIdentity? {
        guard let navigation = tabWebView?.reload() else { return nil }
        return FloorpWebPanelNavigationIdentity(navigation)
    }

    @discardableResult
    func reloadFromOrigin() -> FloorpWebPanelNavigationIdentity? {
        guard let navigation = tabWebView?.reloadFromOrigin() else { return nil }
        return FloorpWebPanelNavigationIdentity(navigation)
    }

    func stopLoading() {
        tabWebView?.stopLoading()
    }

    func setPageZoom(_ pageZoom: CGFloat) {
        guard let tabWebView, tabWebView.pageZoom != pageZoom else { return }
        tabWebView.pageZoom = pageZoom
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

    private let nativeSetter: NativeSetter

    init(
        nativeSetter: @escaping NativeSetter = { webView, isSuppressed, callback in
            // Public WebKit exposes all-media suspension, not audio-only mute.
            // Keep UI and accessibility wording aligned with pause/resume.
            webView.setAllMediaPlaybackSuspended(isSuppressed) {
                callback?.call()
            }
        }
    ) {
        self.nativeSetter = nativeSetter
    }

    func transition(
        on webView: WKWebView,
        isSuppressed: Bool,
        completion: @escaping Completion
    ) {
        let callback = NativeCallbackBox {
            completion(.success(()))
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

private struct FloorpWebPanelPendingMediaPauseChange {
    let previousIsUserMediaPaused: Bool
    let requestedIsUserMediaPaused: Bool
    let requestedRevision: UInt64
    var effectiveSuppressionTarget: Bool
    let completion: FloorpWebPanelMediaPauseCompletion
}

private struct FloorpWebPanelMediaPlaybackSuppressionReasons: Equatable {
    let isHidden: Bool
    let isUserMediaPaused: Bool

    var shouldSuppress: Bool {
        isHidden || isUserMediaPaused
    }
}

@MainActor
final class FloorpWebPanelWebViewSession: FloorpWebPanelSessionProtocol {
    private struct ReloadReasons: OptionSet, Equatable {
        let rawValue: Int

        static let contentMode = ReloadReasons(rawValue: 1 << 0)
        static let imageRules = ReloadReasons(rawValue: 1 << 1)
        static let manual = ReloadReasons(rawValue: 1 << 2)
    }

    private enum ReloadState: Equatable {
        case idle
        case starting(ReloadReasons)
        case navigating(FloorpWebPanelNavigationIdentity, ReloadReasons)
    }

    let key: FloorpWebPanelSessionKey
    let sessionIdentifier = UUID()
    private(set) var state: FloorpWebPanelSessionState
    private var runtime: (any FloorpWebPanelWebViewRuntime)?
    private var blockerTab: FloorpWebPanelContentBlockerTab?
    private var contentRuleInstaller: (any FloorpWebPanelContentRuleInstalling)?
    private var noImageModeScriptController:
        (any FloorpWebPanelNoImageModeScriptControlling)?
    private let imageContentBlockingEnabled: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private var imageBlockingPreferenceObserver: FloorpWebPanelNotificationObservation?
    private var navigationExecutor: FloorpWebPanelNavigationExecutor?
    private var privateBrowsingSessionLease: WKPrivateBrowsingSessionLease?
    private var webPanelFindTarget: (any FloorpWebPanelFindTarget)?
    private var observers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()
    private var installationGeneration = UUID()
    private var areContentRulesReady = false
    private var lastObservedImageContentBlockingEnabled: Bool
    private var lastAppliedImageContentBlockingEnabled: Bool
    private var isImageBlockingRefreshInFlight = false
    private var hasStartedInitialLoad = false
    private var imageBlockingRefreshGeneration = UUID()
    private var pendingInitialLoadURL: URL?
    private var pendingRestorationCandidateURL: URL?
    private var loadedContentMode: FloorpWebPanelContentMode
    private var hasIssuedNavigation = false
    private var pendingReloadReasons = ReloadReasons()
    private var reloadState = ReloadState.idle
    private var reloadRetryRequiresExplicitTrigger = false
    private var isInvalidated = false
    private(set) var isVisible = true
    private var desiredMediaPlaybackSuppression = false
    private var desiredMediaPlaybackSuppressionReasons =
        FloorpWebPanelMediaPlaybackSuppressionReasons(
            isHidden: false,
            isUserMediaPaused: false
        )
    private var appliedMediaPlaybackSuppression = false
    private var isMediaPlaybackTransitionInFlight = false
    private var failedMediaPlaybackSuppression: Bool?
    private var mediaPlaybackTransitionGeneration = UUID()
    private var mediaPlaybackSuppressionReasonGeneration = UUID()
    private var pendingMediaPauseChange: FloorpWebPanelPendingMediaPauseChange?
    private var mediaPauseMutationDepth = 0
    private var isDeliveringMediaPauseCompletions = false
    private var mediaPauseCompletionDeliveries = [(
        completion: FloorpWebPanelMediaPauseCompletion,
        result: Result<Void, Error>
    )]()

    var contentView: UIView? {
        runtime?.contentView
    }

    var isContentModeReloadPending: Bool {
        if pendingReloadReasons.contains(.contentMode) {
            return true
        }
        switch reloadState {
        case .idle:
            return false
        case .starting(let reasons), .navigating(_, let reasons):
            return reasons.contains(.contentMode)
        }
    }

    var findTarget: (any FloorpWebPanelFindTarget)? {
        isInvalidated ? nil : webPanelFindTarget
    }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        runtime: any FloorpWebPanelWebViewRuntime,
        contentRuleInstallerFactory: any FloorpWebPanelContentRuleInstallerFactory,
        noImageModeScriptControllerFactory:
            any FloorpWebPanelNoImageModeScriptControllerFactory =
                DefaultFloorpWebPanelNoImageModeScriptControllerFactory(),
        navigationExecutor: FloorpWebPanelNavigationExecutor,
        imageContentBlockingEnabled: @escaping @MainActor () -> Bool,
        notificationCenter: NotificationCenter = .default,
        restorationURL: URL? = nil,
        privateBrowsingSessionLease: WKPrivateBrowsingSessionLease? = nil
    ) {
        self.key = key
        self.state = FloorpWebPanelSessionState(configuration: configuration)
        self.runtime = runtime
        self.navigationExecutor = navigationExecutor
        self.imageContentBlockingEnabled = imageContentBlockingEnabled
        self.notificationCenter = notificationCenter
        let isImageContentBlockingEnabled = imageContentBlockingEnabled()
        self.lastObservedImageContentBlockingEnabled = isImageContentBlockingEnabled
        self.lastAppliedImageContentBlockingEnabled = isImageContentBlockingEnabled
        let safeRestorationURL = FloorpWebPanelRestorationPolicy.safeWebURL(restorationURL)
        self.pendingInitialLoadURL = safeRestorationURL ?? configuration.homeURL
        self.pendingRestorationCandidateURL = safeRestorationURL
        self.loadedContentMode = configuration.contentMode
        self.privateBrowsingSessionLease = privateBrowsingSessionLease

        runtime.setNavigationExecutor(navigationExecutor)
        navigationExecutor.contentModeDidCommit = { [weak self] navigationID, contentMode in
            self?.contentModeDidCommit(contentMode, navigationID: navigationID)
        }
        navigationExecutor.contentModeNavigationDidFail = { [weak self] navigationID in
            self?.contentModeNavigationDidFail(navigationID: navigationID)
        }
        applyPageZoom(configuration.zoomLevel)
        runtime.stateDidChange = { [weak self] in
            self?.synchronizeState()
        }

        if let webView = runtime.webView {
            webPanelFindTarget = DefaultFloorpWebPanelFindTarget(webView: webView)
            noImageModeScriptController = noImageModeScriptControllerFactory.makeController(
                for: webView,
                isEnabled: isImageContentBlockingEnabled
            )
            let blockerTab = FloorpWebPanelContentBlockerTab(
                isPrivate: key.isPrivate,
                webView: webView,
                imageContentBlockingEnabled: imageContentBlockingEnabled
            )
            self.blockerTab = blockerTab
            contentRuleInstaller = contentRuleInstallerFactory.makeInstaller(for: blockerTab)
        }
        observeImageBlockingPreferenceChanges()
        installRulesBeforeInitialLoad()
    }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration) {
        guard !isInvalidated else { return }
        let previousZoomLevel = state.configuration.zoomLevel
        let previousContentMode = state.configuration.contentMode
        state.configuration = configuration
        if previousZoomLevel != configuration.zoomLevel {
            applyPageZoom(configuration.zoomLevel)
        }
        if previousContentMode != configuration.contentMode {
            let shouldRetryAfterConfigurationChange = reloadRetryRequiresExplicitTrigger
            reloadRetryRequiresExplicitTrigger = false
            navigationExecutor?.updateContentMode(configuration.contentMode)
            if hasIssuedNavigation || runtime?.currentURL != nil {
                if loadedContentMode != configuration.contentMode {
                    pendingReloadReasons.insert(.contentMode)
                } else {
                    pendingReloadReasons.remove(.contentMode)
                }
            } else {
                loadedContentMode = configuration.contentMode
                pendingReloadReasons.remove(.contentMode)
            }
            if shouldRetryAfterConfigurationChange {
                startPendingReloadIfPossible(isExplicitRetry: true)
            }
        }
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
        guard areContentRulesReady, hasStartedInitialLoad else {
            pendingInitialLoadURL = state.configuration.homeURL
            return
        }
        performLoad(state.configuration.homeURL)
    }

    func goBack() {
        guard !isInvalidated, state.canGoBack else { return }
        performNavigation { runtime?.goBack() }
    }

    func goForward() {
        guard !isInvalidated, state.canGoForward else { return }
        performNavigation { runtime?.goForward() }
    }

    func reload() {
        guard !isInvalidated else { return }
        switch reloadState {
        case .idle:
            pendingReloadReasons.insert(.manual)
            startPendingReloadIfPossible(isExplicitRetry: true)
        case .starting, .navigating:
            // The in-flight reload already satisfies the user's request. In
            // particular, do not supersede a navigation before didStart binds
            // its content-mode identity.
            break
        }
    }

    func stopLoading() {
        guard !isInvalidated else { return }
        switch reloadState {
        case .idle:
            break
        case .starting(let reasons), .navigating(_, let reasons):
            pendingReloadReasons.formUnion(reasons)
            if loadedContentMode == state.configuration.contentMode {
                pendingReloadReasons.remove(.contentMode)
            }
            reloadState = .idle
            reloadRetryRequiresExplicitTrigger = true
        }
        runtime?.stopLoading()
    }

    func openCurrentPageInMainBrowser() {
        guard !isInvalidated, let currentURL = state.currentURL else { return }
        navigationExecutor?.openInMainBrowserIfSafe(currentURL)
    }

    func setVisible(_ isVisible: Bool) {
        guard !isInvalidated, self.isVisible != isVisible else { return }
        self.isVisible = isVisible
        if !isVisible {
            webPanelFindTarget?.endFindSession()
        }
        updateMediaPlaybackSuppression()
        resolvePendingMediaPauseChangeIfSettled()
        if isVisible {
            startPendingReloadIfPossible(isExplicitRetry: true)
        }
    }

    @discardableResult
    func applyPendingContentModeReload() -> Bool {
        guard pendingReloadReasons.contains(.contentMode) else {
            return false
        }
        return startPendingReloadIfPossible(isExplicitRetry: true)
    }

    @discardableResult
    private func startPendingReloadIfPossible(
        isExplicitRetry: Bool = false
    ) -> Bool {
        guard !isInvalidated,
              isVisible,
              !pendingReloadReasons.isEmpty,
              reloadState == .idle,
              isExplicitRetry || !reloadRetryRequiresExplicitTrigger,
              let runtime,
              runtime.currentURL != nil else {
            return false
        }
        reloadRetryRequiresExplicitTrigger = false
        let reasons = pendingReloadReasons
        webPanelFindTarget?.endFindSession()
        reloadState = .starting(reasons)
        let navigationID = reasons.contains(.contentMode)
            ? runtime.reloadFromOrigin()
            : runtime.reload()
        guard reloadState == .starting(reasons) else {
            // A synchronous explicit navigation adopted these reasons while
            // the reload API was returning its navigation identity.
            return reloadState != .idle
        }
        guard let navigationID else {
            reloadState = .idle
            reloadRetryRequiresExplicitTrigger = true
            return false
        }
        pendingReloadReasons.subtract(reasons)
        reloadState = .navigating(navigationID, reasons)
        return true
    }

    @discardableResult
    func setUserMediaPaused(
        _ isUserMediaPaused: Bool,
        completion: @escaping FloorpWebPanelMediaPauseCompletion
    ) -> Bool {
        guard !isInvalidated, runtime != nil, state.isUserMediaPaused != isUserMediaPaused else {
            return false
        }
        beginMediaPauseMutation()
        defer { endMediaPauseMutation() }

        let supersededChange = pendingMediaPauseChange
        let previousIsUserMediaPaused = state.isUserMediaPaused
        let requestedEffectiveSuppression = !isVisible || isUserMediaPaused
        state.isUserMediaPaused = isUserMediaPaused
        state.userMediaStateRevision += 1
        let requestedRevision = state.userMediaStateRevision
        pendingMediaPauseChange = FloorpWebPanelPendingMediaPauseChange(
            previousIsUserMediaPaused: previousIsUserMediaPaused,
            requestedIsUserMediaPaused: isUserMediaPaused,
            requestedRevision: requestedRevision,
            effectiveSuppressionTarget: requestedEffectiveSuppression,
            completion: completion
        )
        if let supersededChange {
            enqueueMediaPauseCompletion(supersededChange.completion, result: .success(()))
        }
        notifyObservers()
        updateMediaPlaybackSuppression()
        resolvePendingMediaPauseChangeIfSettled()
        return true
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
        imageBlockingRefreshGeneration = UUID()
        mediaPlaybackTransitionGeneration = UUID()
        pendingInitialLoadURL = nil
        pendingRestorationCandidateURL = nil
        pendingReloadReasons = []
        reloadState = .idle
        reloadRetryRequiresExplicitTrigger = false
        isMediaPlaybackTransitionInFlight = false
        isImageBlockingRefreshInFlight = false
        failedMediaPlaybackSuppression = nil
        pendingMediaPauseChange = nil
        mediaPauseCompletionDeliveries.removeAll()
        observers.removeAll()
        imageBlockingPreferenceObserver?.invalidate()
        imageBlockingPreferenceObserver = nil
        noImageModeScriptController?.invalidate()
        noImageModeScriptController = nil
        contentRuleInstaller?.invalidate()
        contentRuleInstaller = nil
        blockerTab?.detach()
        blockerTab = nil
        webPanelFindTarget?.invalidate()
        webPanelFindTarget = nil
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
        guard lastObservedImageContentBlockingEnabled
                == lastAppliedImageContentBlockingEnabled else {
            startImageBlockingRefreshIfNeeded()
            return
        }
        performPendingInitialLoad()
    }

    private func performPendingInitialLoad() {
        guard !isInvalidated, !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        guard let initialLoadURL = pendingInitialLoadURL else { return }
        pendingInitialLoadURL = nil
        performLoad(initialLoadURL)
    }

    private func observeImageBlockingPreferenceChanges() {
        let observer = notificationCenter.addObserver(
            forName: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.imageBlockingPreferenceDidChange()
            }
        }
        imageBlockingPreferenceObserver = FloorpWebPanelNotificationObservation(
            observer: observer,
            notificationCenter: notificationCenter
        )
    }

    private func imageBlockingPreferenceDidChange() {
        guard !isInvalidated else { return }
        let isEnabled = imageContentBlockingEnabled()
        guard isEnabled != lastObservedImageContentBlockingEnabled else { return }
        lastObservedImageContentBlockingEnabled = isEnabled
        reloadRetryRequiresExplicitTrigger = false
        noImageModeScriptController?.setEnabled(isEnabled)
        guard areContentRulesReady else { return }
        startImageBlockingRefreshIfNeeded()
    }

    private func startImageBlockingRefreshIfNeeded() {
        guard !isInvalidated,
              areContentRulesReady,
              !isImageBlockingRefreshInFlight,
              lastObservedImageContentBlockingEnabled
                != lastAppliedImageContentBlockingEnabled,
              let contentRuleInstaller else {
            return
        }
        let target = lastObservedImageContentBlockingEnabled
        let generation = imageBlockingRefreshGeneration
        isImageBlockingRefreshInFlight = true
        contentRuleInstaller.refresh { [weak self] in
            guard let self,
                  !self.isInvalidated,
                  self.imageBlockingRefreshGeneration == generation else {
                return
            }
            self.isImageBlockingRefreshInFlight = false
            self.lastAppliedImageContentBlockingEnabled = target
            if self.lastObservedImageContentBlockingEnabled
                != self.lastAppliedImageContentBlockingEnabled {
                self.startImageBlockingRefreshIfNeeded()
            } else if !self.hasStartedInitialLoad {
                self.performPendingInitialLoad()
            } else {
                self.pendingReloadReasons.insert(.imageRules)
                self.startPendingReloadIfPossible(isExplicitRetry: true)
            }
        }
    }

    private func performLoad(_ url: URL) {
        hasIssuedNavigation = true
        performNavigation { runtime?.load(URLRequest(url: url)) }
    }

    private func performNavigation(
        _ startNavigation: () -> FloorpWebPanelNavigationIdentity?
    ) {
        let previousReloadState = reloadState
        var reasons = pendingReloadReasons
        switch previousReloadState {
        case .idle:
            break
        case .starting(let activeReasons), .navigating(_, let activeReasons):
            reasons.formUnion(activeReasons)
        }
        guard !reasons.isEmpty else {
            _ = startNavigation()
            return
        }
        reloadRetryRequiresExplicitTrigger = false
        if previousReloadState == .idle {
            reloadState = .starting(reasons)
        }
        guard let navigationID = startNavigation() else {
            if previousReloadState == .idle,
               reloadState == .starting(reasons) {
                reloadState = .idle
            }
            reloadRetryRequiresExplicitTrigger = true
            return
        }
        pendingReloadReasons.subtract(reasons)
        reloadState = .navigating(navigationID, reasons)
    }

    private func applyPageZoom(_ zoomLevel: FloorpWebPanelZoomLevel) {
        let requestedPageZoom = CGFloat(zoomLevel.scale)
        guard let runtime, runtime.pageZoom != requestedPageZoom else { return }
        runtime.setPageZoom(requestedPageZoom)
    }

    private func updateMediaPlaybackSuppression(startTransition: Bool = true) {
        let reasons = FloorpWebPanelMediaPlaybackSuppressionReasons(
            isHidden: !isVisible,
            isUserMediaPaused: state.isUserMediaPaused
        )
        guard desiredMediaPlaybackSuppressionReasons != reasons else { return }
        desiredMediaPlaybackSuppressionReasons = reasons
        mediaPlaybackSuppressionReasonGeneration = UUID()
        desiredMediaPlaybackSuppression = reasons.shouldSuppress
        if var pendingMediaPauseChange,
           pendingMediaPauseChange.requestedIsUserMediaPaused == state.isUserMediaPaused {
            pendingMediaPauseChange.effectiveSuppressionTarget = reasons.shouldSuppress
            self.pendingMediaPauseChange = pendingMediaPauseChange
        }
        failedMediaPlaybackSuppression = nil
        if startTransition {
            startMediaPlaybackTransitionIfNeeded()
        }
    }

    private func startMediaPlaybackTransitionIfNeeded() {
        guard !isInvalidated,
              !isMediaPlaybackTransitionInFlight,
              desiredMediaPlaybackSuppression != appliedMediaPlaybackSuppression,
              failedMediaPlaybackSuppression != desiredMediaPlaybackSuppression,
              let runtime else {
            return
        }

        let target = desiredMediaPlaybackSuppression
        let generation = mediaPlaybackTransitionGeneration
        let reasonGeneration = mediaPlaybackSuppressionReasonGeneration
        let userOwnedRevision: UInt64? = pendingMediaPauseChange.flatMap { pendingChange in
            guard pendingChange.requestedRevision == state.userMediaStateRevision,
                  pendingChange.requestedIsUserMediaPaused == state.isUserMediaPaused,
                  pendingChange.effectiveSuppressionTarget == target,
                  pendingChange.requestedIsUserMediaPaused == target else {
                return nil
            }
            return pendingChange.requestedRevision
        }
        isMediaPlaybackTransitionInFlight = true
        runtime.setMediaPlaybackSuppressed(target) { [weak self] result in
            self?.handleMediaPlaybackTransitionResult(
                result,
                target: target,
                transitionGeneration: generation,
                reasonGeneration: reasonGeneration,
                userOwnedRevision: userOwnedRevision
            )
        }
    }

    private func handleMediaPlaybackTransitionResult(
        _ result: Result<Void, Error>,
        target: Bool,
        transitionGeneration: UUID,
        reasonGeneration: UUID,
        userOwnedRevision: UInt64?
    ) {
        guard !isInvalidated,
              mediaPlaybackTransitionGeneration == transitionGeneration else {
            return
        }
        beginMediaPauseMutation()
        defer { endMediaPauseMutation() }

        isMediaPlaybackTransitionInFlight = false
        var failedMediaPauseChange: FloorpWebPanelPendingMediaPauseChange?
        switch result {
        case .success:
            appliedMediaPlaybackSuppression = target
            failedMediaPlaybackSuppression = nil
        case .failure:
            failedMediaPlaybackSuppression = target
            failedMediaPauseChange = rollBackFailedMediaPauseChange(
                target: target,
                transitionUserOwnedRevision: userOwnedRevision
            )
            if mediaPlaybackSuppressionReasonGeneration != reasonGeneration {
                // The effective Bool can remain `true` while ownership moves
                // between user media pause and hidden lifecycle. Retry once
                // for the newer reason so hidden media remains suspended.
                failedMediaPlaybackSuppression = nil
            }
        }
        startMediaPlaybackTransitionIfNeeded()
        resolvePendingMediaPauseChangeIfSettled()
        if case .failure(let error) = result,
           let failedMediaPauseChange {
            enqueueMediaPauseCompletion(
                failedMediaPauseChange.completion,
                result: .failure(error)
            )
        }
    }

    private func rollBackFailedMediaPauseChange(
        target: Bool,
        transitionUserOwnedRevision: UInt64?
    ) -> FloorpWebPanelPendingMediaPauseChange? {
        guard let transitionUserOwnedRevision,
              let pendingMediaPauseChange,
              pendingMediaPauseChange.effectiveSuppressionTarget == target,
              pendingMediaPauseChange.requestedRevision
                == transitionUserOwnedRevision,
              state.isUserMediaPaused == pendingMediaPauseChange.requestedIsUserMediaPaused,
              state.userMediaStateRevision == pendingMediaPauseChange.requestedRevision else {
            return nil
        }
        self.pendingMediaPauseChange = nil
        state.isUserMediaPaused = pendingMediaPauseChange.previousIsUserMediaPaused
        state.userMediaStateRevision += 1
        notifyObservers()
        updateMediaPlaybackSuppression(startTransition: false)
        return pendingMediaPauseChange
    }

    private func resolvePendingMediaPauseChangeIfSettled() {
        guard !isMediaPlaybackTransitionInFlight,
              let pendingMediaPauseChange,
              desiredMediaPlaybackSuppression
                == pendingMediaPauseChange.effectiveSuppressionTarget,
              appliedMediaPlaybackSuppression
                == pendingMediaPauseChange.effectiveSuppressionTarget,
              state.isUserMediaPaused == pendingMediaPauseChange.requestedIsUserMediaPaused,
              state.userMediaStateRevision == pendingMediaPauseChange.requestedRevision else {
            return
        }
        self.pendingMediaPauseChange = nil
        enqueueMediaPauseCompletion(pendingMediaPauseChange.completion, result: .success(()))
    }

    private func beginMediaPauseMutation() {
        mediaPauseMutationDepth += 1
    }

    private func endMediaPauseMutation() {
        mediaPauseMutationDepth -= 1
        drainMediaPauseCompletionsIfPossible()
    }

    private func enqueueMediaPauseCompletion(
        _ completion: @escaping FloorpWebPanelMediaPauseCompletion,
        result: Result<Void, Error>
    ) {
        mediaPauseCompletionDeliveries.append((completion, result))
        drainMediaPauseCompletionsIfPossible()
    }

    private func drainMediaPauseCompletionsIfPossible() {
        guard mediaPauseMutationDepth == 0,
              !isDeliveringMediaPauseCompletions else {
            return
        }
        isDeliveringMediaPauseCompletions = true
        defer { isDeliveringMediaPauseCompletions = false }
        while !mediaPauseCompletionDeliveries.isEmpty {
            let delivery = mediaPauseCompletionDeliveries.removeFirst()
            delivery.completion(delivery.result)
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
        startPendingReloadIfPossible()
    }

    private func contentModeDidCommit(
        _ contentMode: FloorpWebPanelContentMode,
        navigationID: FloorpWebPanelNavigationIdentity
    ) {
        guard !isInvalidated else { return }
        switch reloadState {
        case .idle:
            break
        case .starting:
            return
        case .navigating(let activeNavigationID, _):
            guard activeNavigationID == navigationID else { return }
            reloadState = .idle
        }
        hasIssuedNavigation = true
        reloadRetryRequiresExplicitTrigger = false
        loadedContentMode = contentMode
        if contentMode != state.configuration.contentMode {
            pendingReloadReasons.insert(.contentMode)
        } else {
            pendingReloadReasons.remove(.contentMode)
        }
        if isVisible, !pendingReloadReasons.isEmpty {
            startPendingReloadIfPossible()
        }
    }

    private func contentModeNavigationDidFail(
        navigationID: FloorpWebPanelNavigationIdentity
    ) {
        guard !isInvalidated,
              case .navigating(let activeNavigationID, let reasons) = reloadState,
              activeNavigationID == navigationID else {
            return
        }
        reloadState = .idle
        pendingReloadReasons.formUnion(reasons)
        reloadRetryRequiresExplicitTrigger = true
        if loadedContentMode != state.configuration.contentMode {
            pendingReloadReasons.insert(.contentMode)
        } else {
            pendingReloadReasons.remove(.contentMode)
        }
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
    private let noImageModeScriptControllerFactory:
        any FloorpWebPanelNoImageModeScriptControllerFactory
    private let imageContentBlockingEnabled: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let openInMainBrowser: FloorpWebPanelNavigationExecutor.OpenInMainBrowser
    private let privateBrowsingSessionCoordinator: WKPrivateBrowsingSessionCoordinator

    init(
        profile: Profile,
        configurationProvider: (any FloorpWebPanelWebViewConfigurationProviding)? = nil,
        runtimeFactory: any FloorpWebPanelWebViewRuntimeFactory = DefaultFloorpWebPanelWebViewRuntimeFactory(),
        contentRuleInstallerFactory: (any FloorpWebPanelContentRuleInstallerFactory)? = nil,
        noImageModeScriptControllerFactory:
            any FloorpWebPanelNoImageModeScriptControllerFactory =
                DefaultFloorpWebPanelNoImageModeScriptControllerFactory(),
        imageContentBlockingEnabled: (@MainActor () -> Bool)? = nil,
        notificationCenter: NotificationCenter = .default,
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
        self.noImageModeScriptControllerFactory = noImageModeScriptControllerFactory
        self.imageContentBlockingEnabled = imageContentBlockingEnabled
            ?? { [prefs = profile.prefs] in NoImageModeHelper.isActivated(prefs) }
        self.notificationCenter = notificationCenter
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
        let webpagePreferences = webViewConfiguration.defaultWebpagePreferences
            ?? WKWebpagePreferences()
        webpagePreferences.preferredContentMode = configuration.contentMode
            .webKitPreferredContentMode
        webViewConfiguration.defaultWebpagePreferences = webpagePreferences
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
            noImageModeScriptControllerFactory: noImageModeScriptControllerFactory,
            navigationExecutor: FloorpWebPanelNavigationExecutor(
                windowUUID: key.windowUUID,
                isPrivate: key.isPrivate,
                contentMode: configuration.contentMode,
                openInMainBrowser: openInMainBrowser
            ),
            imageContentBlockingEnabled: imageContentBlockingEnabled,
            notificationCenter: notificationCenter,
            restorationURL: restorationURL,
            privateBrowsingSessionLease: privateBrowsingSessionLease
        )
    }
}
