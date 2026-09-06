// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit
import WebKit

extension Notification.Name {
    static let floorpNativeWebExtensionActionsDidChange = Notification.Name(
        "FloorpNativeWebExtensionActionsDidChange"
    )
}

/// Tracks a WebView whose document must remain alive because WebKit still owns
/// an asynchronous JavaScript callback. UI owners may detach the view, but
/// must not stop its document while `mustPreserve(_:)` is true. Callback
/// timeouts can promote the document to permanent, process-lifetime retention.
@MainActor
enum FloorpNativeWebExtensionProcessLifetimeWebViewRegistry {
    private struct InFlightEntry {
        let webView: WKWebView
        var count: Int
        var teardownGraceNanoseconds: UInt64
    }

    private struct TeardownGraceEntry {
        let webView: WKWebView
        let token: UUID
        let durationNanoseconds: UInt64
    }

    private static var retained = [ObjectIdentifier: WKWebView]()
    private static var inFlight = [ObjectIdentifier: InFlightEntry]()
    private static var teardownGrace = [ObjectIdentifier: TeardownGraceEntry]()

    static func beginOperation(in webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        if var entry = inFlight[identifier] {
            entry.count += 1
            inFlight[identifier] = entry
        } else {
            let inheritedGrace = teardownGrace.removeValue(forKey: identifier)?
                .durationNanoseconds ?? 0
            inFlight[identifier] = InFlightEntry(
                webView: webView,
                count: 1,
                teardownGraceNanoseconds: inheritedGrace
            )
        }
    }

    static func endOperation(
        in webView: WKWebView,
        teardownGraceNanoseconds: UInt64 = 0
    ) {
        let identifier = ObjectIdentifier(webView)
        guard var entry = inFlight[identifier] else { return }
        entry.teardownGraceNanoseconds = max(
            entry.teardownGraceNanoseconds,
            teardownGraceNanoseconds
        )
        if entry.count == 1 {
            inFlight.removeValue(forKey: identifier)
            scheduleTeardownGrace(
                for: webView,
                durationNanoseconds: entry.teardownGraceNanoseconds
            )
        } else {
            entry.count -= 1
            inFlight[identifier] = entry
        }
    }

    private static func scheduleTeardownGrace(
        for webView: WKWebView,
        durationNanoseconds: UInt64
    ) {
        guard durationNanoseconds > 0 else { return }
        let identifier = ObjectIdentifier(webView)
        let token = UUID()
        teardownGrace[identifier] = TeardownGraceEntry(
            webView: webView,
            token: token,
            durationNanoseconds: durationNanoseconds
        )
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }
            guard teardownGrace[identifier]?.token == token else { return }
            teardownGrace.removeValue(forKey: identifier)
        }
    }

    static func retain(_ webView: WKWebView) {
        retained[ObjectIdentifier(webView)] = webView
    }

    static func isPermanentlyRetained(_ webView: WKWebView) -> Bool {
        retained[ObjectIdentifier(webView)] != nil
    }

    static func mustPreserve(_ webView: WKWebView) -> Bool {
        let identifier = ObjectIdentifier(webView)
        return retained[identifier] != nil
            || inFlight[identifier] != nil
            || teardownGrace[identifier] != nil
    }
}

@MainActor
final class FloorpNativeWebExtensionHost: NSObject {
    private enum BackgroundContentLoadCompletion {
        case succeeded
        case failed(any Error)
    }

    @MainActor
    private final class BackgroundContentLoadGate {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = continuation
        }

        func startTimeout(
            id: UUID,
            identifier: String,
            timeoutNanoseconds: UInt64,
            onTimeout: @escaping @MainActor (UUID, any Error) -> Void
        ) {
            timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                onTimeout(
                    id,
                    FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(identifier)
                )
            }
        }

        func resolve(_ error: (any Error)?) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    @MainActor
    private final class StartupNavigationReadinessGate: NSObject, @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isResolved = false

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !isResolved, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    self.continuation = continuation
                }
            } onCancel: {
                Task { @MainActor [self] in
                    resolve()
                }
            }
        }

        func resolve() {
            guard !isResolved else { return }
            isResolved = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class ExtensionTabSurfaceCloseRequest {
        let token = UUID()
        let identifier: String
        let context: WKWebExtensionContext
        let tabIdentifier: ObjectIdentifier
        let webViewIdentifier: ObjectIdentifier
        let forceOnFailure: Bool
        weak var tab: Tab?
        weak var webView: WKWebView?
        weak var alert: UIAlertController?
        var task: Task<Void, Never>?
        var presentationTask: Task<Void, Never>?
        var presentationRetryCount = 0
        var didCompletePresentation = false
        private var completion: ((Bool) -> Void)?

        init(
            identifier: String,
            context: WKWebExtensionContext,
            tab: Tab,
            webView: WKWebView,
            forceOnFailure: Bool,
            completion: @escaping (Bool) -> Void
        ) {
            self.identifier = identifier
            self.context = context
            self.tabIdentifier = ObjectIdentifier(tab)
            self.webViewIdentifier = ObjectIdentifier(webView)
            self.forceOnFailure = forceOnFailure
            self.tab = tab
            self.webView = webView
            self.completion = completion
        }

        func takeCompletion() -> ((Bool) -> Void)? {
            defer { completion = nil }
            return completion
        }
    }

    private struct BackgroundReadinessJavaScriptValue: @unchecked Sendable {
        let value: Any?
    }

    /// Owns the weak WKNavigationDelegate relationship and both bounded
    /// continuations used by the uBO Lite readiness probe. `loadBackgroundContent`
    /// only means that WebKit created the background page; uBO's asynchronous
    /// `start()` can still be applying DNR rules and registering content scripts.
    @MainActor
    private final class BackgroundReadinessProbe: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var navigationContinuation: CheckedContinuation<Void, any Error>?
        private var javaScriptContinuation:
            CheckedContinuation<BackgroundReadinessJavaScriptValue, any Error>?
        private var timeoutTask: Task<Void, Never>?
        private var operationToken: UUID?
        private(set) var requiresProcessLifetimeRetention = false

        func load(
            _ url: URL,
            in webView: WKWebView,
            identifier: String,
            timeoutNanoseconds: UInt64
        ) async throws {
            self.webView = webView
            webView.navigationDelegate = self
            let token = UUID()
            operationToken = token
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    navigationContinuation = continuation
                    startTimeout(
                        token: token,
                        identifier: identifier,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    webView.load(URLRequest(url: url))
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancel(token: token)
                }
            }
        }

        func callAsyncJavaScript(
            _ functionBody: String,
            in webView: WKWebView,
            identifier: String,
            timeoutNanoseconds: UInt64
        ) async throws -> Any? {
            let token = UUID()
            operationToken = token
            let boxed: BackgroundReadinessJavaScriptValue = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    javaScriptContinuation = continuation
                    startTimeout(
                        token: token,
                        identifier: identifier,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    webView.callAsyncJavaScript(
                        functionBody,
                        arguments: [:],
                        in: nil,
                        in: .page
                    ) { [weak self] result in
                        Task { @MainActor in
                            self?.completeJavaScript(result, token: token)
                        }
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancel(token: token)
                }
            }
            return boxed.value
        }

        func invalidate() {
            // A timeout/cancellation means WebKit still owns a callback. Once
            // promoted to process-lifetime retention, invalidation is unsafe.
            guard !requiresProcessLifetimeRetention else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            operationToken = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
            navigationContinuation?.resume(throwing: CancellationError())
            navigationContinuation = nil
            javaScriptContinuation?.resume(throwing: CancellationError())
            javaScriptContinuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard webView === self.webView, let token = operationToken else { return }
            completeNavigation(.success(()), token: token)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: any Error
        ) {
            guard webView === self.webView, let token = operationToken else { return }
            completeNavigation(.failure(error), token: token)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            guard webView === self.webView, let token = operationToken else { return }
            completeNavigation(.failure(error), token: token)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView, let token = operationToken else { return }
            if javaScriptContinuation != nil {
                // The delegate notification can precede the native
                // callAsyncJavaScript completion.
                requiresProcessLifetimeRetention = true
            }
            failCurrentOperation(FloorpNativeWebExtensionError.hostUnavailable, token: token)
        }

        private func startTimeout(
            token: UUID,
            identifier: String,
            timeoutNanoseconds: UInt64
        ) {
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                self?.timeOut(token: token, identifier: identifier)
            }
        }

        private func completeNavigation(
            _ result: Result<Void, any Error>,
            token: UUID
        ) {
            guard operationToken == token, let continuation = navigationContinuation else { return }
            operationToken = nil
            navigationContinuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(with: result)
        }

        private func completeJavaScript(
            _ result: Result<Any, any Error>,
            token: UUID
        ) {
            guard operationToken == token, let continuation = javaScriptContinuation else { return }
            operationToken = nil
            javaScriptContinuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            switch result {
            case .success(let value):
                continuation.resume(returning: BackgroundReadinessJavaScriptValue(value: value))
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        private func timeOut(token: UUID, identifier: String) {
            guard operationToken == token else { return }
            let error = FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(identifier)
            // WebKit does not cancel an in-flight extension-page JavaScript call
            // when its UIProcess timeout fires. Releasing that page while the
            // WebContent callback is still pending can trip the iOS 26 Gestures
            // `idle -> failed(deinit)` transition.
            requiresProcessLifetimeRetention = true
            // Do not stop or detach the page. WebKit still owns the native
            // callback and must be allowed to finish against the retained page.
            if let continuation = navigationContinuation {
                navigationContinuation = nil
                operationToken = nil
                timeoutTask = nil
                continuation.resume(throwing: error)
            } else if let continuation = javaScriptContinuation {
                javaScriptContinuation = nil
                operationToken = nil
                timeoutTask = nil
                continuation.resume(throwing: error)
            }
        }

        private func cancel(token: UUID) {
            guard operationToken == token else { return }
            operationToken = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            // Task cancellation has the same ownership boundary as a timeout:
            // the native WebKit operation may outlive its Swift continuation.
            requiresProcessLifetimeRetention = true
            navigationContinuation?.resume(throwing: CancellationError())
            navigationContinuation = nil
            javaScriptContinuation?.resume(throwing: CancellationError())
            javaScriptContinuation = nil
        }

        private func failCurrentOperation(_ error: any Error, token: UUID) {
            if navigationContinuation != nil {
                completeNavigation(.failure(error), token: token)
            } else if javaScriptContinuation != nil {
                completeJavaScript(.failure(error), token: token)
            }
        }
    }

    /// Keeps an unsafe-to-release extension page and probe alive until process
    /// exit. The controller and host already use the same retirement boundary
    /// after a context load.
    @MainActor
    private final class BackgroundReadinessSurface {
        let context: WKWebExtensionContext
        let probe: BackgroundReadinessProbe
        let webView: WKWebView

        init(context: WKWebExtensionContext, configuration: WKWebViewConfiguration) {
            self.context = context
            probe = BackgroundReadinessProbe()
            webView = WKWebView(frame: .zero, configuration: configuration)
        }

        init(
            context: WKWebExtensionContext,
            probe: BackgroundReadinessProbe,
            webView: WKWebView
        ) {
            self.context = context
            self.probe = probe
            self.webView = webView
        }
    }

    private final class WeakTabManager {
        weak var value: (any TabManager)?

        init(_ value: any TabManager) {
            self.value = value
        }
    }

    private final class PresentedExtensionSurface {
        weak var viewController: UIViewController?
        let isPrivate: Bool

        init(viewController: UIViewController, isPrivate: Bool) {
            self.viewController = viewController
            self.isPrivate = isPrivate
        }
    }

    private final class ManagedActionPopup {
        struct PendingCloseTransition {
            let operation: String
            let perform: () throws -> Void
            let cancel: () -> Void
        }

        let token: UUID
        weak var viewController: FloorpNativeWebExtensionActionPopupViewController?
        weak var context: WKWebExtensionContext?
        weak var sourceTab: Tab?
        weak var sourceAdapter: FloorpNativeWebExtensionTab?
        let sourceWindow: WindowKey
        private var pendingCloseTransition: PendingCloseTransition?

        init(
            token: UUID,
            viewController: FloorpNativeWebExtensionActionPopupViewController,
            context: WKWebExtensionContext,
            sourceTab: Tab,
            sourceAdapter: FloorpNativeWebExtensionTab,
            sourceWindow: WindowKey
        ) {
            self.token = token
            self.viewController = viewController
            self.context = context
            self.sourceTab = sourceTab
            self.sourceAdapter = sourceAdapter
            self.sourceWindow = sourceWindow
        }

        func setPendingCloseTransition(
            operation: String,
            transition: @escaping () throws -> Void,
            cancellation: @escaping () -> Void
        ) -> Bool {
            guard pendingCloseTransition == nil else { return false }
            pendingCloseTransition = PendingCloseTransition(
                operation: operation,
                perform: transition,
                cancel: cancellation
            )
            return true
        }

        var hasPendingCloseTransition: Bool {
            pendingCloseTransition != nil
        }

        func takePendingCloseTransition() -> PendingCloseTransition? {
            defer { pendingCloseTransition = nil }
            return pendingCloseTransition
        }

        func discardPendingCloseTransition() {
            let transition = takePendingCloseTransition()
            transition?.cancel()
        }
    }

    /// Keeps a managed popup document alive until WebKit's native callback has
    /// actually been delivered. Host-forced popup retirement can happen while
    /// an extension API request is suspended, so the fixed UIKit teardown grace
    /// period alone is not a sufficient ownership boundary.
    @MainActor
    private final class ManagedActionPopupCallbackLease {
        private static let teardownGraceNanoseconds: UInt64 = 2_000_000_000

        private var webView: WKWebView?
        private var didFinish = false

        init(webView: WKWebView?) {
            self.webView = webView
            if let webView {
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.beginOperation(
                    in: webView
                )
            }
        }

        func finish(_ deliver: () -> Void) {
            guard !didFinish else { return }
            didFinish = true
            defer {
                if let webView {
                    FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(
                        in: webView,
                        teardownGraceNanoseconds: Self.teardownGraceNanoseconds
                    )
                    self.webView = nil
                }
            }
            deliver()
        }
    }

    private struct WindowKey: Hashable {
        let windowUUID: WindowUUID
        let isPrivate: Bool
    }

    private struct ConsumedContextKey: Hashable {
        let controllerIdentifier: UUID
        let profileIdentifier: String
        let contextIdentifier: String
    }

    private struct PreparedExtension {
        let item: FloorpNativeWebExtensionCatalogItem
        let package: FloorpNativeWebExtensionVerifiedPackage
        let webExtension: WKWebExtension
        let diagnostics: [FloorpNativeWebExtensionDiagnostic]
    }

    private struct ActionOrigin {
        let window: WindowKey
        let expiresAt: Date
    }

    private struct PreparedNavigation {
        let action: WKNavigationAction
        let tabIdentifier: ObjectIdentifier
        let generation: Int
        let focusGeneration: Int
        let readinessGeneration: Int
        let extensionTopologyGeneration: Int
    }

    struct NavigationProtectionFailure: Equatable {
        let extensionName: String
        let detail: String
    }

    private struct RecordedNavigationProtectionFailure {
        let generation: Int
        let failure: NavigationProtectionFailure
    }

    struct ActionInvocation {
        fileprivate let sourceTabIdentifier: ObjectIdentifier
        fileprivate let sourceWindowUUID: WindowUUID
        fileprivate let sourceIsPrivate: Bool
        fileprivate let sourceManagerIdentifier: ObjectIdentifier
        fileprivate let generation: Int
        fileprivate let focusGeneration: Int
        fileprivate let topologyGeneration: Int
    }

    private static let processLifecycleIdentifier = UUID()
    private static var hosts = [String: FloorpNativeWebExtensionHost]()
    // WebKit 26.5 can crash while destroying a process pool after a loaded
    // extension controller is unloaded or released. A removed profile is
    // already unusable through `isTornDown`; retain its loaded runtime as a
    // process-lifetime tombstone and let process termination reclaim it.
    private static var retiredHostsUntilProcessExit = [FloorpNativeWebExtensionHost]()
    private static var consumedContextKeys = Set<ConsumedContextKey>()

    static func install(for profile: Profile) throws -> FloorpNativeWebExtensionHost {
        let profileIdentifier = profile.localName()
        if let host = hosts[profileIdentifier] {
            return host
        }
        if retiredHostsUntilProcessExit.contains(where: { retiredHost in
            retiredHost.profileIdentifier == profileIdentifier
                && retiredHost.contexts.values.contains { $0.isLoaded }
        }) {
            throw FloorpNativeWebExtensionError.restartRequired(
                "Recreating the native WebExtension runtime"
            )
        }
        do {
            let host = try FloorpNativeWebExtensionHost(profile: profile)
            hosts[profileIdentifier] = host
            return host
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            throw error
        }
    }

    static func host(for profileIdentifier: String) -> FloorpNativeWebExtensionHost? {
        hosts[profileIdentifier]
    }

    static func remove(for profileIdentifier: String) {
        guard let host = hosts.removeValue(forKey: profileIdentifier) else { return }
        let requiresProcessLifetimeRetirement = host.hasEverAttemptedContextLoad
        host.tearDown()
        if requiresProcessLifetimeRetirement {
            retiredHostsUntilProcessExit.append(host)
        }
    }

    let controller: WKWebExtensionController
    let profileIdentifier: String

    private weak var profile: Profile?
    private let controllerIdentifier: UUID
    private let rootDirectory: URL
    private let registryStore: FloorpNativeWebExtensionRegistryStore
    private let installer: FloorpNativeWebExtensionPackageInstaller
    private let logger: Logger
    private var registry: FloorpNativeWebExtensionRegistry
    private var hostDiagnostics = [FloorpNativeWebExtensionDiagnostic]()
    private var contexts = [String: WKWebExtensionContext]()
    // `WKWebExtensionContext.webViewConfiguration` can gain an internal related
    // background web view after the extension starts. WebKit requires a related
    // web view and a newly created web view to use the same website data store,
    // so keep the pre-background template returned immediately after `load` for
    // extension surfaces that must use another store (notably private tabs).
    private var cleanSurfaceConfigurationTemplates = [
        ObjectIdentifier: WKWebViewConfiguration
    ]()
    private var tabAdapters = [ObjectIdentifier: FloorpNativeWebExtensionTab]()
    private var windowAdapters = [WindowKey: FloorpNativeWebExtensionWindow]()
    private var tabManagers = [WindowUUID: WeakTabManager]()
    private var announcedTabs = Set<ObjectIdentifier>()
    private var announcedWindows = Set<WindowKey>()
    private var lastActiveTabs = [WindowKey: ObjectIdentifier]()
    private var lastFocusedWindow: WindowKey?
    private var focusWasExplicitlyCleared = false
    private var activeTransitions = Set<String>()
    private var readyContextIdentifiers = Set<String>()
    private var lifecycleQuiescedContextIdentifiers = Set<String>()
    private var quarantinedContextIdentifiers = Set<String>()
    private var backgroundLoadGates = [UUID: BackgroundContentLoadGate]()
    private var pendingBackgroundLoadCallbacks = [UUID: WKWebExtensionContext]()
    private var backgroundLoadFollowerCounts = [UUID: Int]()
    private var backgroundLoadCompletionResults = [UUID: BackgroundContentLoadCompletion]()
    private var activeBackgroundReadinessOperations = [UUID: WKWebExtensionContext]()
    private var activeSurfaceCloseOperations = [UUID: WKWebExtensionContext]()
    private var retiredBackgroundReadinessSurfaces = [BackgroundReadinessSurface]()
    private var actionOrigins = [String: [ActionOrigin]]()
    private var presentedExtensionSurfaces = [String: [PresentedExtensionSurface]]()
    private var managedActionPopups = [String: ManagedActionPopup]()
    private var preparedNavigationActions = [ObjectIdentifier: PreparedNavigation]()
    private var navigationPreparationGenerations = [ObjectIdentifier: Int]()
    private var navigationProtectionFailures = [
        ObjectIdentifier: RecordedNavigationProtectionFailure
    ]()
    // Scene startup has a bounded UI budget, while WebKit background startup
    // can legitimately take longer. Keep the first HTTP(S) navigation waiting
    // for every enabled bundled blocker that was present at cold launch rather
    // than allowing that request to escape without extension protection.
    private var startupNavigationReadinessPendingIdentifiers = Set<String>()
    private var startupNavigationReadinessWaiters = [UUID: StartupNavigationReadinessGate]()
    private var verifiedNavigationReadinessRealms = [String: Set<Bool>]()
    private var navigationReadinessGeneration = 0
    private var actionInvocationGenerations = [ObjectIdentifier: Int]()
    private var extensionTabSurfaceCloseRequests = [
        ObjectIdentifier: ExtensionTabSurfaceCloseRequest
    ]()
    private var actionFocusGeneration = 0
    private var extensionTopologyGeneration = 0
    private var lifecycleGeneration = 0
    private var isTornDown = false
    private var isPublishingTeardownLifecycle = false
    private var hasEverAttemptedContextLoad = false

#if DEBUG || TESTING
    var registryPersistenceHookForTesting: ((FloorpNativeWebExtensionRegistry) throws -> Void)?
    var actionReadinessCompletedHookForTesting: ((String, Tab) -> Void)?
    var backgroundReadinessAttemptHookForTesting: ((String) -> Void)?
    var backgroundReadinessTransientFailureHookForTesting:
        ((String, Int) -> (any Error)?)?
    var backgroundReadinessResponseHookForTesting:
        ((String, Int) -> [String: Any]?)?
    var backgroundReadinessJavaScriptOverrideForTesting:
        ((String, Int, WKWebView) -> String?)?
    var startupRestoreReadinessHookForTesting:
        ((String) async -> Void)?
    var navigationCandidateReadinessCompletedHookForTesting:
        ((String, Tab) -> Void)?
    var navigationReadinessTimeoutHookForTesting:
        ((String, UInt64) -> Void)?
    var navigationPreparationCompletedHookForTesting:
        ((Tab, WKNavigationAction) -> Void)?
    var privateAccessCommitHookForTesting: ((String) -> Void)?
    var extensionSurfaceClosePreparationHookForTesting:
        ((String, WKWebView) async -> Bool)?
    var extensionTabCreationCompletionHookForTesting:
        ((String, Tab) async -> Void)?
    var privateAccessTransitionHookForTesting: ((String) -> Void)?
    var contextWillUnloadHookForTesting: ((String) -> Void)?

    static func resetControllerLoadHistoryForTesting(profileIdentifier: String) {
        consumedContextKeys = consumedContextKeys.filter {
            $0.profileIdentifier != profileIdentifier
        }
    }

    func setNavigationReadinessVerifiedForTesting(
        identifier: String,
        isPrivate: Bool
    ) {
        verifiedNavigationReadinessRealms[identifier, default: []].insert(isPrivate)
    }

    func isNavigationReadinessVerifiedForTesting(
        identifier: String,
        isPrivate: Bool
    ) -> Bool {
        verifiedNavigationReadinessRealms[identifier]?.contains(isPrivate) == true
    }

    func persistPermissionStateForTesting(_ context: WKWebExtensionContext) {
        persistPermissionState(for: context)
    }

    func registryRecordForTesting(
        identifier: String
    ) -> FloorpNativeWebExtensionRecord? {
        registry.extensions.first { $0.id == identifier }
    }

    func hasUnfinishedWebKitOperationForTesting(
        _ context: WKWebExtensionContext
    ) -> Bool {
        hasUnfinishedWebKitOperation(for: context)
    }

    func isContextQuarantinedForTesting(identifier: String) -> Bool {
        quarantinedContextIdentifiers.contains(identifier)
    }
#endif

    private init(profile: Profile, logger: Logger = DefaultLogger.shared) throws {
        FloorpNativeWebExtensionCatalog.registerBaseURLSchemes()
        self.profile = profile
        self.profileIdentifier = profile.localName()
        self.logger = logger
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw FloorpNativeWebExtensionError.protectedDataUnavailable
        }

        let directoryPath = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let rootDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .standardizedFileURL
        self.rootDirectory = rootDirectory
        let registryStore = FloorpNativeWebExtensionRegistryStore(
            url: rootDirectory.appendingPathComponent("registry-v2.json", isDirectory: false)
        )
        self.registryStore = registryStore
        self.installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: rootDirectory)

        do {
            self.registry = try registryStore.load()
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            registryStore.quarantineCorruptRegistry()
            self.registry = FloorpNativeWebExtensionRegistry()
            self.hostDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                phase: .host,
                error: error as NSError
            )]
        }

        let configuration = WKWebExtensionController.Configuration(
            identifier: registry.controllerIdentifier
        )
        configuration.defaultWebsiteDataStore = .default()
        self.controllerIdentifier = registry.controllerIdentifier
        self.controller = WKWebExtensionController(configuration: configuration)

        super.init()
        startupNavigationReadinessPendingIdentifiers = Set(
            registry.extensions.compactMap { record in
                let willBeEnabled = record.isEnabled
                    || (
                        record.unloadState?.enableOnNextColdLaunch == true
                            && record.unloadState?.processIdentifier
                                != Self.processLifecycleIdentifier
                    )
                guard willBeEnabled,
                      record.transactionState != .pendingPurge,
                      let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id),
                      item.requiresNavigationBackgroundReadiness,
                      item.navigationReadinessFailurePolicy == .failClosed else {
                    return nil
                }
                return record.id
            }
        )
        controller.delegate = self
        do {
            try persistRegistry()
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    func restoreInstalledExtensions() async {
        defer { finishAllStartupNavigationReadiness() }
        guard !isTornDown, !Task.isCancelled else { return }
        recoverInterruptedTransactions()
        var tabsNeedingReload = [ObjectIdentifier: Tab]()
        let restorationRecords = registry.extensions.enumerated().sorted { lhs, rhs in
            let lhsFailsClosed = FloorpNativeWebExtensionCatalog.item(identifier: lhs.element.id)?
                .navigationReadinessFailurePolicy == .failClosed
            let rhsFailsClosed = FloorpNativeWebExtensionCatalog.item(identifier: rhs.element.id)?
                .navigationReadinessFailurePolicy == .failClosed
            if lhsFailsClosed != rhsFailsClosed {
                return lhsFailsClosed
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for snapshotRecord in restorationRecords {
            defer { finishStartupNavigationReadiness(for: snapshotRecord.id) }
            guard !isTornDown, !Task.isCancelled else { return }
            guard var record = registry.extensions.first(where: { $0.id == snapshotRecord.id }),
                  record == snapshotRecord,
                  contexts[record.id] == nil else {
                continue
            }
            if let replacement = FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(record) {
                do {
                    try await installBundledExtension(
                        identifier: replacement.identifier,
                        replacingExpectedRecord: record
                    )
                } catch {
                    guard !isTornDown, !Task.isCancelled else { return }
                    guard registry.extensions.first(where: { $0.id == record.id }) == record else {
                        continue
                    }
                    updateRecord(record.id) {
                        $0.lastError = error.localizedDescription
                        $0.runtimeDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                            phase: .host,
                            error: error as NSError
                        )]
                    }
                    try? persistRegistry()
                    logger.log(
                        "Floorp: native WebExtension \(record.id) migration failed: \(error)",
                        level: .warning,
                        category: .setup
                    )
                }
                continue
            }

            let generation: Int
            do {
                generation = try beginTransition(for: record.id)
            } catch {
                continue
            }
            defer { endTransition(for: record.id) }
            setContextReady(false, identifier: record.id)
            setContextLifecycleQuiesced(true, identifier: record.id)
            if record.transactionState == .pendingPurge {
                do {
                    try await completePendingPurge(record, generation: generation)
                    try validateTransition(for: record.id, generation: generation)
                } catch {
                    guard !isTornDown, !Task.isCancelled else { return }
                    updateRecord(record.id) { $0.lastError = error.localizedDescription }
                    try? persistRegistry()
                }
                continue
            }
            let deferredEnable = record.unloadState?.enableOnNextColdLaunch == true
            let unloadedInThisProcess = record.unloadState?.processIdentifier
                == Self.processLifecycleIdentifier
            let shouldActivateDeferredEnable = deferredEnable && !unloadedInThisProcess
            if let unloadState = record.unloadState,
               !unloadState.enableOnNextColdLaunch,
               !unloadedInThisProcess {
                record.unloadState = nil
                replaceRecord(record)
            }
            var restoringContext: WKWebExtensionContext?
            var didAttemptContextLoad = false
            var affectedTabs = [Tab]()
            do {
#if DEBUG || TESTING
                if let startupRestoreReadinessHookForTesting {
                    await startupRestoreReadinessHookForTesting(record.id)
                }
#endif
                let context = try await makeContext(for: record)
                restoringContext = context
                try validateTransition(for: record.id, generation: generation)
                contexts[record.id] = context
                if shouldActivateDeferredEnable {
                    record.isEnabled = true
                    replaceRecord(record)
                }
                if record.isEnabled {
                    affectedTabs = tabsAffectedByRemoval(of: context, identifier: record.id)
                    didAttemptContextLoad = true
                    try loadContext(context, identifier: record.id)
                    try await waitForStableBackgroundReadinessIfRequired(
                        in: context,
                        identifier: record.id,
                        timeoutNanoseconds: coldBackgroundReadinessTimeout(
                            for: record.id
                        )
                    )
                    try validateTransition(for: record.id, generation: generation)
                    setContextReady(true, identifier: record.id)
                    for tab in tabsEligibleForInjection(of: context) {
                        tabsNeedingReload[ObjectIdentifier(tab)] = tab
                    }
                }
                observeContextChanges(in: context)
                if shouldActivateDeferredEnable {
                    record.unloadState = nil
                    record.lastError = nil
                    replaceRecord(record)
                }
                persistRuntimeDiagnostics(for: context)
            } catch {
                setContextReady(false, identifier: record.id)
                if let context = restoringContext {
                    if didAttemptContextLoad {
                        affectedTabs = mergingTabs(
                            affectedTabs,
                            tabsAffectedByRemoval(of: context, identifier: record.id)
                        )
                    }
                    let didUnload = unloadOrQuarantine(context, identifier: record.id)
                    if didUnload {
                        NotificationCenter.default.removeObserver(self, name: nil, object: context)
                    }
                    if didUnload, contexts[record.id] === context {
                        contexts.removeValue(forKey: record.id)
                    }
                }
                if didAttemptContextLoad {
                    reloadAfterRemovingExtension(from: affectedTabs, identifier: record.id)
                    clearSurfaceHistory(for: record.id)
                }
                guard !isTornDown, !Task.isCancelled else { return }
                updateRecord(record.id) {
                    if shouldActivateDeferredEnable {
                        $0.isEnabled = false
                        $0.unloadState = FloorpNativeWebExtensionUnloadState(
                            processIdentifier: Self.processLifecycleIdentifier,
                            enableOnNextColdLaunch: true
                        )
                    }
                    $0.lastError = error.localizedDescription
                    $0.runtimeDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                        phase: .host,
                        error: error as NSError
                    )]
                }
                logger.log(
                    "Floorp: native WebExtension \(record.id) restore failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
        if !isTornDown, !Task.isCancelled {
            reloadForNewlyAvailableExtension(in: Array(tabsNeedingReload.values))
            try? persistRegistry()
        }
    }

    func attach(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    func consumePreparedNavigation(_ navigationAction: WKNavigationAction) -> Bool {
        let key = ObjectIdentifier(navigationAction)
        guard let prepared = preparedNavigationActions.removeValue(forKey: key) else {
            return false
        }
        return prepared.action === navigationAction
            && navigationPreparationGenerations[prepared.tabIdentifier]
                == prepared.generation
            && actionFocusGeneration == prepared.focusGeneration
            && navigationReadinessGeneration == prepared.readinessGeneration
            && prepared.extensionTopologyGeneration == extensionTopologyGeneration
    }

    func beginNavigationPreparation(for tab: Tab) -> Int {
        invalidateActionInvocation(for: tab)
        dismissManagedActionPopups { $0.sourceTab === tab }
        let key = ObjectIdentifier(tab)
        let generation = (navigationPreparationGenerations[key] ?? 0) &+ 1
        navigationPreparationGenerations[key] = generation
        navigationProtectionFailures.removeValue(forKey: key)
        return generation
    }

    func navigationProtectionFailure(
        for tab: Tab,
        generation: Int
    ) -> NavigationProtectionFailure? {
        let key = ObjectIdentifier(tab)
        guard navigationPreparationGenerations[key] == generation,
              let recorded = navigationProtectionFailures[key],
              recorded.generation == generation else {
            return nil
        }
        return recorded.failure
    }

    func discardPreparedNavigation(_ navigationAction: WKNavigationAction) {
        preparedNavigationActions.removeValue(forKey: ObjectIdentifier(navigationAction))
    }

    func needsBackgroundReadiness(
        beforeNavigating tab: Tab,
        to url: URL
    ) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return false }
        let adapter = tabAdapter(for: tab)
        return registry.extensions.contains { record in
            guard recordWillBeEnabledDuringStartup(record),
                  FloorpNativeWebExtensionCatalog.item(identifier: record.id)?
                    .requiresNavigationBackgroundReadiness == true,
                  !tab.isPrivate || record.hasPrivateAccess else { return false }
            // An enabled blocker which has not reached a terminal, ready
            // context is itself a reason to defer navigation. In particular,
            // the scene may become visible after the bootstrap UI budget while
            // cold restoration is still starting uBO's DNR engine.
            guard readyContextIdentifiers.contains(record.id),
                  let context = contexts[record.id],
                  context.isLoaded,
                  canExpose(tab: tab, to: context) else { return true }
            if record.id == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier,
               verifiedNavigationReadinessRealms[record.id]?.contains(tab.isPrivate) == true {
                return false
            }
            return context.hasAccess(to: url, in: adapter)
        }
    }

    // swiftlint:disable:next function_body_length
    func prepareBackgroundContent(
        beforeNavigating tab: Tab,
        to url: URL,
        navigationAction: WKNavigationAction,
        generation: Int
    ) async -> Bool {
        let adapter = tabAdapter(for: tab)
        if startupNavigationReadinessPendingIdentifiers.contains(where: { identifier in
            navigationReadinessRecord(
                identifier: identifier,
                appliesTo: tab
            ) != nil
        }) {
            await waitForStartupNavigationReadiness()
        }
        let tabKey = ObjectIdentifier(tab)
        guard !isTornDown,
              !Task.isCancelled,
              navigationPreparationGenerations[tabKey] == generation else {
            return false
        }
        // A terminal restore error intentionally leaves the record enabled so
        // Settings can explain it. Blocking extensions stay fail-closed until
        // explicitly disabled; visual transforms such as Dark Reader fail open.
        if let blockedRecord = registry.extensions.first(where: { record in
            guard FloorpNativeWebExtensionCatalog.item(identifier: record.id)?
                .navigationReadinessFailurePolicy == .failClosed else {
                return false
            }
            guard navigationReadinessRecord(
                identifier: record.id,
                appliesTo: tab
            ) != nil else { return false }
            guard readyContextIdentifiers.contains(record.id),
                  let context = contexts[record.id],
                  context.isLoaded,
                  canExpose(tab: tab, to: context) else { return true }
            return false
        }) {
            recordNavigationProtectionFailure(
                for: tab,
                generation: generation,
                identifier: blockedRecord.id,
                detail: blockedRecord.lastError
            )
            return false
        }
        let readinessStart = DispatchTime.now().uptimeNanoseconds
        let readinessAddition = readinessStart.addingReportingOverflow(
            backgroundReadinessTimeout(
                for: FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
            )
        )
        let readinessDeadline = readinessAddition.overflow
            ? UInt64.max
            : readinessAddition.partialValue
        let remainingUBlockReadinessTimeout: () throws -> UInt64 = {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < readinessDeadline else {
                throw FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(
                    FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
                )
            }
            return readinessDeadline - now
        }
        readinessAttempt: for _ in 0..<4 {
            let topologyGeneration = extensionTopologyGeneration
            let focusGeneration = actionFocusGeneration
            let readinessGeneration = navigationReadinessGeneration
            let candidates = registry.extensions.compactMap { record -> (String, WKWebExtensionContext)? in
                guard record.isEnabled,
                      readyContextIdentifiers.contains(record.id),
                      FloorpNativeWebExtensionCatalog.item(identifier: record.id)?
                        .requiresNavigationBackgroundReadiness == true,
                      let context = contexts[record.id],
                      context.isLoaded,
                      canExpose(tab: tab, to: context),
                      context.hasAccess(to: url, in: adapter) else { return nil }
                return (record.id, context)
            }
            for (identifier, context) in candidates {
                let isUBlockOriginLite = identifier
                    == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
                let failsClosed = FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
                    .navigationReadinessFailurePolicy == .failClosed
                if isUBlockOriginLite,
                   verifiedNavigationReadinessRealms[identifier]?.contains(tab.isPrivate) == true {
                    continue
                }
                if isUBlockOriginLite,
                   lastFocusedWindow != WindowKey(
                       windowUUID: tab.windowUUID,
                       isPrivate: tab.isPrivate
                   ) {
                    return false
                }
                do {
                    let timeoutNanoseconds: UInt64
                    if isUBlockOriginLite {
                        timeoutNanoseconds = try remainingUBlockReadinessTimeout()
                    } else {
                        timeoutNanoseconds = 3_000_000_000
                    }
#if DEBUG || TESTING
                    navigationReadinessTimeoutHookForTesting?(
                        identifier,
                        timeoutNanoseconds
                    )
#endif
                    try await waitForStableBackgroundReadinessIfRequired(
                        in: context,
                        identifier: identifier,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                } catch {
                    logger.log(
                        "Floorp: native WebExtension \(identifier) navigation preflight failed: \(error)",
                        level: .warning,
                        category: .setup
                    )
                    if failsClosed {
                        recordNavigationProtectionFailure(
                            for: tab,
                            generation: generation,
                            identifier: identifier,
                            detail: error.localizedDescription
                        )
                        return false
                    }
                }
                if isUBlockOriginLite {
                    guard !isTornDown,
                          !Task.isCancelled,
                          navigationPreparationGenerations[tabKey] == generation else {
                        return false
                    }
                    // Do not publish a realm cache produced by a probe that
                    // overlapped a topology, focus, or ruleset mutation. The
                    // current state may have returned to an apparently valid
                    // value (for example A -> B -> A focus), but the probe
                    // still describes the earlier generation.
                    guard topologyGeneration == extensionTopologyGeneration,
                          focusGeneration == actionFocusGeneration,
                          readinessGeneration == navigationReadinessGeneration else {
                        continue readinessAttempt
                    }
                    guard readyContextIdentifiers.contains(identifier),
                          contexts[identifier] === context,
                          context.isLoaded,
                          lastFocusedWindow == WindowKey(
                              windowUUID: tab.windowUUID,
                              isPrivate: tab.isPrivate
                          ) else {
                        return false
                    }
                    verifiedNavigationReadinessRealms[identifier, default: []]
                        .insert(tab.isPrivate)
                }
#if DEBUG || TESTING
                navigationCandidateReadinessCompletedHookForTesting?(identifier, tab)
#endif
            }
            guard !isTornDown,
                  !Task.isCancelled,
                  navigationPreparationGenerations[tabKey] == generation else {
                return false
            }
            guard topologyGeneration == extensionTopologyGeneration else { continue }
            // Readiness is a snapshot of both extension topology and the
            // focused logical window. If focus changed while a later
            // candidate was settling, an earlier uBO probe may already have
            // been invalidated and must not be covered by a token stamped with
            // the newer focus generation.
            guard focusGeneration == actionFocusGeneration else { continue }
            // Options and extension actions can change uBO rules without
            // changing focus or host topology. Never publish a token based on
            // a probe that overlapped one of those semantic invalidations.
            guard readinessGeneration == navigationReadinessGeneration else { continue }
            preparedNavigationActions[ObjectIdentifier(navigationAction)] = PreparedNavigation(
                action: navigationAction,
                tabIdentifier: tabKey,
                generation: generation,
                focusGeneration: focusGeneration,
                readinessGeneration: readinessGeneration,
                extensionTopologyGeneration: topologyGeneration
            )
            navigationProtectionFailures.removeValue(forKey: tabKey)
#if DEBUG || TESTING
            navigationPreparationCompletedHookForTesting?(tab, navigationAction)
#endif
            return true
        }
        return false
    }

    private func recordNavigationProtectionFailure(
        for tab: Tab,
        generation: Int,
        identifier: String,
        detail: String?
    ) {
        let key = ObjectIdentifier(tab)
        guard navigationPreparationGenerations[key] == generation else { return }
        let record = registry.extensions.first { $0.id == identifier }
        let extensionName = record?.displayName
            ?? FloorpNativeWebExtensionCatalog.item(identifier: identifier)?.name
            ?? identifier
        let resolvedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failureDetail = resolvedDetail.flatMap { $0.isEmpty ? nil : $0 }
            ?? FloorpNativeWebExtensionError.extensionDisabled(identifier).localizedDescription
        navigationProtectionFailures[key] = RecordedNavigationProtectionFailure(
            generation: generation,
            failure: NavigationProtectionFailure(
                extensionName: extensionName,
                detail: failureDetail
            )
        )
    }

    private func navigationReadinessRecord(
        identifier: String,
        appliesTo tab: Tab
    ) -> FloorpNativeWebExtensionRecord? {
        guard let record = registry.extensions.first(where: { $0.id == identifier }),
              recordWillBeEnabledDuringStartup(record),
              FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
                .requiresNavigationBackgroundReadiness == true,
              !tab.isPrivate || record.hasPrivateAccess else {
            return nil
        }
        return record
    }

    private func recordWillBeEnabledDuringStartup(
        _ record: FloorpNativeWebExtensionRecord
    ) -> Bool {
        record.isEnabled
            || (
                record.unloadState?.enableOnNextColdLaunch == true
                    && record.unloadState?.processIdentifier
                        != Self.processLifecycleIdentifier
            )
    }

    private func backgroundReadinessTimeout(for identifier: String) -> UInt64 {
        FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
            .navigationReadinessFailurePolicy == .failClosed
            ? 90_000_000_000
            : 15_000_000_000
    }

    private func coldBackgroundReadinessTimeout(for identifier: String) -> UInt64 {
        // On a fresh uBO context WebKit compiles more than 100,000 static
        // rules and the dynamic regex realm before the first semantic probe
        // can return. Keep navigation/action probes bounded at 90 seconds,
        // while allowing cold install, restore, and re-enable enough time for
        // that one-time native compilation to finish on slower devices.
        identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
            ? 240_000_000_000
            : backgroundReadinessTimeout(for: identifier)
    }

    private func waitForStartupNavigationReadiness() async {
        guard !startupNavigationReadinessPendingIdentifiers.isEmpty,
              !isTornDown,
              !Task.isCancelled else { return }
        let waiterID = UUID()
        let gate = StartupNavigationReadinessGate()
        startupNavigationReadinessWaiters[waiterID] = gate
        guard !startupNavigationReadinessPendingIdentifiers.isEmpty,
              !isTornDown,
              !Task.isCancelled else {
            startupNavigationReadinessWaiters.removeValue(forKey: waiterID)
            return
        }
        await gate.wait()
        startupNavigationReadinessWaiters.removeValue(forKey: waiterID)
    }

    private func finishStartupNavigationReadiness(for identifier: String) {
        startupNavigationReadinessPendingIdentifiers.remove(identifier)
        guard startupNavigationReadinessPendingIdentifiers.isEmpty else { return }
        finishAllStartupNavigationReadinessWaiters()
    }

    private func finishAllStartupNavigationReadiness() {
        startupNavigationReadinessPendingIdentifiers.removeAll()
        finishAllStartupNavigationReadinessWaiters()
    }

    private func finishAllStartupNavigationReadinessWaiters() {
        let waiters = Array(startupNavigationReadinessWaiters.values)
        startupNavigationReadinessWaiters.removeAll()
        waiters.forEach { $0.resolve() }
    }

    func register(tabManager: any TabManager) {
        let uuid = tabManager.windowUUID
        guard tabManagers[uuid]?.value !== tabManager else { return }
        if tabManagers[uuid] != nil
            || announcedWindows.contains(where: { $0.windowUUID == uuid })
            || tabAdapters.values.contains(where: { $0.tab?.windowUUID == uuid }) {
            // Scene recreation can replace a manager while preserving its
            // WindowUUID. Close the old logical topology and detach its
            // callbacks before publishing the replacement manager.
            unregister(windowUUID: uuid)
        }
        tabManagers[uuid] = WeakTabManager(tabManager)
        tabManager.addDelegate(self)

        for isPrivate in [false, true] where !tabs(for: uuid, isPrivate: isPrivate).isEmpty {
            announceWindowIfNeeded(windowUUID: uuid, isPrivate: isPrivate)
        }
        tabManager.tabs.forEach { announceTabIfNeeded($0) }
        if let selectedTab = tabManager.selectedTab {
            didActivate(selectedTab)
            if sceneActivationState(for: uuid) == .foregroundActive {
                focus(windowUUID: uuid, isPrivate: selectedTab.isPrivate)
            }
        }
    }

    func unregister(windowUUID: WindowUUID) {
        guard tabManagers[windowUUID] != nil
            || announcedWindows.contains(where: { $0.windowUUID == windowUUID })
            || tabAdapters.values.contains(where: { $0.tab?.windowUUID == windowUUID }) else {
            return
        }
        extensionTabSurfaceCloseRequests.values
            .filter { $0.tab?.windowUUID == windowUUID }
            .forEach {
                resolveExtensionTabSurfaceCloseRequest(
                    $0,
                    shouldProceed: $0.forceOnFailure,
                    dismissAlert: true
                )
            }
        dismissManagedActionPopups { popup in
            popup.sourceWindow.windowUUID == windowUUID
        }
        if let manager = tabManagers[windowUUID]?.value {
            manager.removeDelegate(self, completion: nil)
        }
        let closingAdapters = tabAdapters.filter { $0.value.tab?.windowUUID == windowUUID }
        closingAdapters.forEach { key, adapter in
            if announcedTabs.remove(key) != nil {
                notifyDidCloseTab(adapter, windowIsClosing: true)
            }
            tabAdapters.removeValue(forKey: key)
            navigationPreparationGenerations.removeValue(forKey: key)
            navigationProtectionFailures.removeValue(forKey: key)
            actionInvocationGenerations.removeValue(forKey: key)
        }
        for isPrivate in [false, true] {
            let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
            if announcedWindows.remove(key) != nil,
               let adapter = windowAdapters[key] {
                notifyDidCloseWindow(adapter)
            }
            windowAdapters.removeValue(forKey: key)
            lastActiveTabs.removeValue(forKey: key)
        }
        tabManagers.removeValue(forKey: windowUUID)
        if isPublishingTeardownLifecycle {
            // Dependency teardown can release a scene's TabManager before the
            // native-extension host. Do not search the global WindowManager
            // for a replacement while this host is itself being dismantled:
            // the dependency container may already be unavailable, and every
            // logical window is about to close anyway. Publish one nil focus
            // update after all close notifications instead.
            if lastFocusedWindow?.windowUUID == windowUUID {
                setTrackedFocusedWindow(nil)
                focusWasExplicitlyCleared = true
            }
            return
        }
        if lastFocusedWindow?.windowUUID == windowUUID {
            focusAvailableWindow()
        } else {
            synchronizeFocusedWindows()
        }
    }

    /// Removes a scene's manager only when it is still the manager registered
    /// for that logical window. A delayed disconnect from a replaced scene must
    /// not tear down the replacement manager that reused its WindowUUID.
    func unregister(tabManager: any TabManager) {
        guard tabManagers[tabManager.windowUUID]?.value === tabManager else { return }
        unregister(windowUUID: tabManager.windowUUID)
    }

    func tabManager(for windowUUID: WindowUUID) -> (any TabManager)? {
        if let manager = tabManagers[windowUUID]?.value {
            return manager
        }
        let windowManager: WindowManager = AppContainer.shared.resolve()
        return windowManager.allWindowTabManagers().first { $0.windowUUID == windowUUID }
    }

    func tabs(for windowUUID: WindowUUID, isPrivate: Bool) -> [Tab] {
        guard let manager = tabManager(for: windowUUID) else { return [] }
        let managedTabs = isPrivate ? manager.privateTabs : manager.normalTabs
        return managedTabs.filter { announcedTabs.contains(ObjectIdentifier($0)) }
    }

    func activeTab(for windowUUID: WindowUUID, isPrivate: Bool) -> Tab? {
        let logicalTabs = tabs(for: windowUUID, isPrivate: isPrivate)
        guard !logicalTabs.isEmpty else { return nil }
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        if let selectedTab = tabManager(for: windowUUID)?.selectedTab,
           logicalTabs.contains(where: { $0 === selectedTab }) {
            return selectedTab
        }
        if let identifier = lastActiveTabs[key],
           let previousActiveTab = logicalTabs.first(where: { ObjectIdentifier($0) == identifier }) {
            return previousActiveTab
        }
        return logicalTabs.first
    }

    func tabAdapter(for tab: Tab) -> FloorpNativeWebExtensionTab {
        let key = ObjectIdentifier(tab)
        if let adapter = tabAdapters[key] {
            return adapter
        }
        let adapter = FloorpNativeWebExtensionTab(tab: tab, host: self)
        tabAdapters[key] = adapter
        return adapter
    }

    func windowAdapter(
        for windowUUID: WindowUUID,
        isPrivate: Bool
    ) -> FloorpNativeWebExtensionWindow {
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        if let adapter = windowAdapters[key] {
            return adapter
        }
        let adapter = FloorpNativeWebExtensionWindow(
            windowUUID: windowUUID,
            isPrivateBrowsing: isPrivate,
            host: self
        )
        windowAdapters[key] = adapter
        return adapter
    }

    func canExpose(tab: Tab, to context: WKWebExtensionContext) -> Bool {
        !tab.isPrivate || context.hasAccessToPrivateData
    }

    func canOperate(tab: Tab, in context: WKWebExtensionContext) -> Bool {
        guard currentEnabledIdentifier(for: context) != nil,
              canExpose(tab: tab, to: context),
              announcedTabs.contains(ObjectIdentifier(tab)),
              let manager = tabManagers[tab.windowUUID]?.value,
              manager.tabs.contains(where: { $0 === tab }) else {
            return false
        }
        return true
    }

    func canMutate(tab: Tab, in context: WKWebExtensionContext) -> Bool {
        currentReadyIdentifier(for: context) != nil && canOperate(tab: tab, in: context)
    }

    /// Selects a tab immediately unless the request came from a managed action
    /// popup. A popup-originated WebExtension API call must finish its native
    /// completion before selecting the destination, because selection dismisses
    /// the source popup and can otherwise destroy WebKit's pending callback.
    func requestActivation(
        of tab: Tab,
        requestedBy context: WKWebExtensionContext,
        cancellation: @escaping () -> Void = {}
    ) throws {
        guard canMutate(tab: tab, in: context),
              let manager = tabManager(for: tab.windowUUID) else {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        guard manager.selectedTab !== tab else { return }
        if try stageManagedActionPopupCloseTransition(
            for: context,
            operation: "tab activation",
            transition: { [weak self, weak tab, weak context] in
                guard let self, let tab, let context,
                      self.canMutate(tab: tab, in: context),
                      let manager = self.tabManager(for: tab.windowUUID) else {
                    throw FloorpNativeWebExtensionError.hostUnavailable
                }
                manager.selectTab(tab)
            },
            cancellation: cancellation
        ) {
            return
        }
        manager.selectTab(tab)
    }

    /// Fails before a create/duplicate operation mutates browser topology when
    /// its eventual activation could not be staged on the current popup.
    func validateDeferredActivation(requestedBy context: WKWebExtensionContext) throws {
        guard let identifier = currentReadyIdentifier(for: context),
              let popup = managedActionPopups[identifier],
              popup.context === context else { return }
        guard let sourceTab = popup.sourceTab,
              let sourceAdapter = popup.sourceAdapter,
              sourceAdapter.tab === sourceTab,
              isManagedTab(sourceTab),
              tabManager(for: popup.sourceWindow.windowUUID)?.selectedTab === sourceTab,
              lastFocusedWindow == popup.sourceWindow,
              canOperate(tab: sourceTab, in: context) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        guard !popup.hasPendingCloseTransition else {
            throw FloorpNativeWebExtensionError.unsupportedOperation(
                "action popup already has a pending browser transition"
            )
        }
    }

    /// Removes tabs created by an operation whose deferred activation could
    /// not be staged. Completion is delayed until the browser has processed
    /// every removal so WebKit never receives an error alongside live ghost
    /// topology from the failed operation.
    func rollbackCreatedTabsAfterFailedActivation(
        _ tabs: [Tab],
        from manager: any TabManager,
        completion: @escaping () -> Void
    ) {
        guard let tab = tabs.first else {
            completion()
            return
        }
        let remainingTabs = Array(tabs.dropFirst())
        guard manager.tabs.contains(where: { $0 === tab }) else {
            rollbackCreatedTabsAfterFailedActivation(
                remainingTabs,
                from: manager,
                completion: completion
            )
            return
        }
        guard manager.selectedTab !== tab else {
            // Another browser action may select the staged-created tab before
            // the originating popup closes itself. That external activation is
            // now authoritative; never delete the user's current tab while
            // cancelling the older popup transition.
            rollbackCreatedTabsAfterFailedActivation(
                remainingTabs,
                from: manager,
                completion: completion
            )
            return
        }
        manager.removeTabIfUnselected(tab.tabUUID) { [self] didRemove in
            if !didRemove {
                if manager.tabs.contains(where: { $0 === tab }),
                   manager.selectedTab !== tab {
                    // The normal removal path may be vetoed by an unrelated
                    // surface-preparation delegate. This tab was created only
                    // for the failed staged transition and was never selected,
                    // so synchronously remove that isolated topology instead.
                    manager.removeTabs([tab])
                }
                if manager.tabs.contains(where: { $0 === tab }) {
                    logger.log(
                        "Floorp: failed to roll back a tab after deferred activation was cancelled",
                        level: .warning,
                        category: .setup
                    )
                }
            }
            rollbackCreatedTabsAfterFailedActivation(
                remainingTabs,
                from: manager,
                completion: completion
            )
        }
    }

    func canOperate(
        windowUUID: WindowUUID,
        isPrivate: Bool,
        in context: WKWebExtensionContext
    ) -> Bool {
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        return currentEnabledIdentifier(for: context) != nil
            && (!isPrivate || context.hasAccessToPrivateData)
            && announcedWindows.contains(key)
            && tabManagers[windowUUID]?.value != nil
    }

    func canMutate(
        windowUUID: WindowUUID,
        isPrivate: Bool,
        in context: WKWebExtensionContext
    ) -> Bool {
        currentReadyIdentifier(for: context) != nil
            && canOperate(windowUUID: windowUUID, isPrivate: isPrivate, in: context)
    }

    /// Stores the UI side effect of a popup-originated API call without
    /// delaying that API's completion. The transition is eligible only while
    /// the popup's original tab, realm, and context remain current.
    private func stageManagedActionPopupCloseTransition(
        for context: WKWebExtensionContext,
        operation: String,
        transition: @escaping () throws -> Void,
        cancellation: @escaping () -> Void = {}
    ) throws -> Bool {
        guard let identifier = currentReadyIdentifier(for: context),
              let popup = managedActionPopups[identifier],
              popup.context === context else {
            return false
        }
        guard let sourceTab = popup.sourceTab,
              let sourceAdapter = popup.sourceAdapter,
              sourceAdapter.tab === sourceTab,
              isManagedTab(sourceTab),
              tabManager(for: popup.sourceWindow.windowUUID)?.selectedTab === sourceTab,
              lastFocusedWindow == popup.sourceWindow,
              canOperate(tab: sourceTab, in: context) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let sourceWindow = popup.sourceWindow
        let didStage = popup.setPendingCloseTransition(
            operation: operation,
            transition: { [weak self, weak context, weak sourceTab, weak sourceAdapter] in
                guard let self, let context, let sourceTab, let sourceAdapter,
                      self.currentReadyIdentifier(for: context) == identifier,
                      sourceAdapter.tab === sourceTab,
                      self.isManagedTab(sourceTab),
                      self.tabManager(for: sourceWindow.windowUUID)?.selectedTab === sourceTab,
                      self.lastFocusedWindow == sourceWindow,
                      self.canOperate(tab: sourceTab, in: context) else {
                    throw FloorpNativeWebExtensionError.hostUnavailable
                }
                try transition()
            },
            cancellation: cancellation
        )
        guard didStage else {
            throw FloorpNativeWebExtensionError.unsupportedOperation(
                "action popup already has a pending browser transition"
            )
        }
        return true
    }

    func focus(windowUUID: WindowUUID, isPrivate: Bool) {
        if let activationState = sceneActivationState(for: windowUUID),
           activationState != .foregroundActive {
            return
        }
        guard let manager = tabManager(for: windowUUID) else { return }
        if manager.selectedTab?.isPrivate != isPrivate {
            if let tab = activeTab(for: windowUUID, isPrivate: isPrivate) {
                manager.selectTab(tab)
            } else {
                return
            }
        }
        dismissManagedActionPopups { popup in
            guard let sourceTab = popup.sourceTab else { return true }
            return sourceTab.windowUUID != windowUUID
                || sourceTab.isPrivate != isPrivate
                || manager.selectedTab !== sourceTab
        }
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        let focusChanged = lastFocusedWindow != key
        setTrackedFocusedWindow(key)
        focusWasExplicitlyCleared = false
        announceWindowIfNeeded(windowUUID: windowUUID, isPrivate: isPrivate)
        if focusChanged {
            synchronizeFocusedWindows()
        }
    }

    func resignFocus(windowUUID: WindowUUID) {
        guard lastFocusedWindow?.windowUUID == windowUUID else { return }
        dismissManagedActionPopups { popup in
            popup.sourceWindow.windowUUID == windowUUID
        }
        focusAvailableWindow(excludingWindowUUID: windowUUID)
    }

    func requestFocus(windowUUID: WindowUUID, isPrivate: Bool) throws {
        guard let manager = tabManager(for: windowUUID) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        if manager.selectedTab?.isPrivate != isPrivate {
            guard let tab = activeTab(for: windowUUID, isPrivate: isPrivate) else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
            manager.selectTab(tab)
        }
        guard let scene = connectedScene(for: windowUUID) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        if scene.activationState == .foregroundActive {
            focus(windowUUID: windowUUID, isPrivate: isPrivate)
            return
        }

        UIApplication.shared.requestSceneSessionActivation(
            scene.session,
            userActivity: nil,
            options: nil
        ) { [weak self] error in
            self?.logger.log(
                "Floorp: native WebExtension window focus request failed: \(error)",
                level: .warning,
                category: .setup
            )
        }
    }

    func requestFocus(
        windowUUID: WindowUUID,
        isPrivate: Bool,
        requestedBy context: WKWebExtensionContext
    ) throws {
        guard canMutate(windowUUID: windowUUID, isPrivate: isPrivate, in: context) else {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        if try stageManagedActionPopupCloseTransition(
            for: context,
            operation: "window focus",
            transition: { [weak self, weak context] in
                guard let self, let context,
                      self.canMutate(
                          windowUUID: windowUUID,
                          isPrivate: isPrivate,
                          in: context
                      ) else {
                    throw FloorpNativeWebExtensionError.hostUnavailable
                }
                try self.requestFocus(windowUUID: windowUUID, isPrivate: isPrivate)
            }
        ) {
            return
        }
        try requestFocus(windowUUID: windowUUID, isPrivate: isPrivate)
    }

    func settingsItems() -> [FloorpNativeWebExtensionSettingsItem] {
        registry.extensions.map { record in
            let context = contexts[record.id]
            let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id)
            return FloorpNativeWebExtensionSettingsItem(
                identifier: record.id,
                name: record.displayName,
                summary: item?.summary,
                version: record.installedVersion,
                iconData: context?.webExtension.icon(for: CGSize(width: 64, height: 64))?.pngData(),
                source: item?.source ?? "Managed Floorp catalog",
                license: item?.license ?? "See package metadata",
                isEnabled: record.isEnabled,
                requiresRestartToEnable: record.unloadState?.enableOnNextColdLaunch == true,
                hasPrivateAccess: record.hasPrivateAccess,
                permissions: Set(record.grantedPermissions.map {
                    WKWebExtension.Permission(rawValue: $0.value).floorpDisplayName
                }).sorted(),
                optionalPermissions: context?.webExtension.optionalPermissions
                    .map(\.floorpDisplayName).sorted() ?? [],
                matchPatterns: record.grantedMatchPatterns.map(\.value).sorted(),
                optionalMatchPatterns: context?.webExtension.optionalPermissionMatchPatterns
                    .map(\.string).sorted() ?? [],
                hasOptionsPage: context?.optionsPageURL != nil,
                hasUpdate: item.map {
                    $0.expectedVersion != record.installedVersion || $0.expectedSHA256 != record.sha256
                } ?? false,
                diagnostics: record.packageDiagnostics + record.runtimeDiagnostics + hostDiagnostics,
                errorDescription: record.lastError
            )
        }
    }

    func installedContext(identifier: String) -> WKWebExtensionContext? {
        contexts[identifier]
    }

    func installationPreview(identifier: String) async throws -> FloorpNativeWebExtensionInstallationPreview {
        let prepared = try await prepareBundledExtension(identifier: identifier)
        let webExtension = prepared.webExtension
        return FloorpNativeWebExtensionInstallationPreview(
            identifier: identifier,
            name: webExtension.displayName ?? prepared.item.name,
            version: webExtension.version ?? "0",
            iconData: webExtension.icon(for: CGSize(width: 64, height: 64))?.pngData(),
            requiredPermissions: Set(webExtension.requestedPermissions.map(\.floorpDisplayName)).sorted(),
            optionalPermissions: Set(webExtension.optionalPermissions.map(\.floorpDisplayName)).sorted(),
            requiredMatchPatterns: webExtension.requestedPermissionMatchPatterns
                .map(\.string).sorted(),
            optionalMatchPatterns: webExtension.optionalPermissionMatchPatterns
                .map(\.string).sorted(),
            packageDiagnostics: prepared.diagnostics,
            source: prepared.item.source,
            license: prepared.item.license,
            minimumOS: prepared.item.minimumOS,
            isUpdate: registry.extensions.contains { $0.id == identifier }
        )
    }

    // swiftlint:disable:next function_body_length
    func installBundledExtension(
        identifier: String,
        replacingExpectedRecord expectedRecord: FloorpNativeWebExtensionRecord? = nil
    ) async throws {
        let generation = try beginTransition(for: identifier)
        defer { endTransition(for: identifier) }
        if let expectedRecord {
            guard registry.extensions.first(where: { $0.id == identifier }) == expectedRecord,
                  contexts[identifier] == nil else {
                return
            }
        }
        let prepared = try await prepareBundledExtension(identifier: identifier)
        try validateTransition(for: identifier, generation: generation)
        let item = prepared.item
        let webExtension = prepared.webExtension
        let previousRegistry = registry
        let allowedPermissions = webExtension.requestedPermissions.filter { $0 != .nativeMessaging }
        let deniedPermissions = webExtension.requestedPermissions.subtracting(allowedPermissions)
        let previousRecord = registry.extensions.first { $0.id == identifier }
        let previousContext = contexts[identifier]
        let shouldActivateDeferredEnable = previousRecord?.unloadState.map {
            $0.enableOnNextColdLaunch
                && $0.processIdentifier != Self.processLifecycleIdentifier
        } ?? false
        let contextIdentifier = previousRecord?.contextIdentifier ?? item.contextIdentifier
        if wasContextConsumedInThisController(contextIdentifier) {
            let operation = previousRecord == nil
                ? "Reinstalling this extension"
                : "Updating this extension"
            throw FloorpNativeWebExtensionError.restartRequired(operation)
        }
        let declaredPermissionValues = Set(
            webExtension.requestedPermissions.map(\.rawValue)
                + webExtension.optionalPermissions.map(\.rawValue)
        )
        let permissionDecisions = FloorpNativeWebExtensionPermissionDecisionReconciler.reconcile(
            previousGranted: previousRecord?.grantedPermissions ?? [],
            previousDenied: previousRecord?.deniedPermissions ?? [],
            declaredValues: declaredPermissionValues,
            requiredGrantedValues: Set(allowedPermissions.map(\.rawValue)),
            requiredDeniedValues: Set(deniedPermissions.map(\.rawValue))
        )
        let declaredPatternValues = Set(
            webExtension.requestedPermissionMatchPatterns.map(\.string)
                + webExtension.optionalPermissionMatchPatterns.map(\.string)
        )
        let patternDecisions = FloorpNativeWebExtensionPermissionDecisionReconciler.reconcile(
            previousGranted: previousRecord?.grantedMatchPatterns ?? [],
            previousDenied: previousRecord?.deniedMatchPatterns ?? [],
            declaredValues: declaredPatternValues,
            requiredGrantedValues: Set(webExtension.requestedPermissionMatchPatterns.map(\.string)),
            requiredDeniedValues: []
        )

        var record = FloorpNativeWebExtensionRecord(
            id: item.identifier,
            contextIdentifier: previousRecord?.contextIdentifier ?? item.contextIdentifier,
            baseURLHost: previousRecord?.baseURLHost ?? item.baseURLHost,
            packageSource: prepared.package.source,
            packageReference: prepared.package.reference,
            sha256: prepared.package.sha256,
            displayName: webExtension.displayName ?? item.name,
            installedVersion: webExtension.version ?? "0",
            isEnabled: shouldActivateDeferredEnable ? true : previousRecord?.isEnabled ?? true,
            unloadState: shouldActivateDeferredEnable ? nil : previousRecord?.unloadState,
            hasPrivateAccess: previousRecord?.hasPrivateAccess ?? false,
            grantedPermissions: permissionDecisions.granted,
            deniedPermissions: permissionDecisions.denied,
            grantedMatchPatterns: patternDecisions.granted,
            deniedMatchPatterns: patternDecisions.denied,
            hasRequestedOptionalAccessToAllHosts: declaredPatternValues.contains("<all_urls>")
                ? previousRecord?.hasRequestedOptionalAccessToAllHosts ?? false
                : false,
            packageDiagnostics: prepared.diagnostics,
            runtimeDiagnostics: [],
            installedAt: previousRecord?.installedAt ?? Date(),
            updatedAt: Date(),
            transactionState: .preparing,
            rollback: previousRecord?.rollbackSnapshot,
            lastError: nil
        )
        if let previousContext,
           hasUnfinishedWebKitOperation(for: previousContext) {
            throw FloorpNativeWebExtensionError.restartRequired(
                "Updating an extension with an unfinished WebKit operation"
            )
        }
        let previousContextWasReady = readyContextIdentifiers.contains(identifier)
        setContextReady(false, identifier: identifier)
        if let previousContext,
           previousContext.isLoaded,
           previousRecord?.isEnabled == true {
            do {
                try await waitForStableBackgroundReadinessIfRequired(
                    in: previousContext,
                    identifier: identifier
                )
                try validateTransition(for: identifier, generation: generation)
                guard !hasUnfinishedWebKitOperation(for: previousContext) else {
                    throw FloorpNativeWebExtensionError.restartRequired(
                        "Updating an extension with an unfinished WebKit operation"
                    )
                }
                setContextLifecycleQuiesced(true, identifier: identifier)
            } catch {
                if previousContextWasReady,
                   transitionIsValid(for: identifier, generation: generation),
                   contexts[identifier] === previousContext,
                   previousContext.isLoaded,
                   !quarantinedContextIdentifiers.contains(identifier) {
                    setContextReady(true, identifier: identifier)
                }
                throw error
            }
        } else {
            setContextLifecycleQuiesced(true, identifier: identifier)
        }
        var didPersistPreparingState = false
        let previousContextAffectedTabs = previousContext.map {
            tabsAffectedByRemoval(of: $0, identifier: identifier)
        } ?? []
        var newContextAffectedTabs = [Tab]()
        var didAttemptNewContextLoad = false
        var didStopObservingPreviousContext = false

        do {
            replaceRecord(record)
            try persistRegistry()
            didPersistPreparingState = true
            record.transactionState = .switching
            replaceRecord(record)
            try persistRegistry()

            if let previousContext, previousContext.isLoaded {
                NotificationCenter.default.removeObserver(
                    self,
                    name: nil,
                    object: previousContext
                )
                didStopObservingPreviousContext = true
                try controller.unload(previousContext)
                cleanSurfaceConfigurationTemplates.removeValue(
                    forKey: ObjectIdentifier(previousContext)
                )
            }
            let newContext = makeContext(webExtension: webExtension, record: record)
            contexts[identifier] = newContext
            observeContextChanges(in: newContext)
            if record.isEnabled {
                newContextAffectedTabs = tabsAffectedByRemoval(
                    of: newContext,
                    identifier: identifier
                )
                didAttemptNewContextLoad = true
                try loadContext(newContext, identifier: identifier)
            }
            if record.isEnabled {
                try await waitForStableBackgroundReadinessIfRequired(
                    in: newContext,
                    identifier: identifier,
                    timeoutNanoseconds: coldBackgroundReadinessTimeout(for: identifier)
                )
                try validateTransition(for: identifier, generation: generation)
                setContextReady(true, identifier: identifier)
            }
            Self.synchronizePermissionState(from: newContext, to: &record)
            record.runtimeDiagnostics = Self.diagnostics(newContext.errors, phase: .runtime)
            record.lastError = record.runtimeDiagnostics.last?.message
            record.transactionState = .stable
            record.rollback = nil
            replaceRecord(record)
            try persistRegistry()
            if let previousContext, previousContext !== newContext {
                NotificationCenter.default.removeObserver(self, name: nil, object: previousContext)
            }
            if record.isEnabled {
                let tabsToReload = mergingTabs(
                    previousContextAffectedTabs,
                    newContextAffectedTabs,
                    tabsEligibleForInjection(of: newContext)
                )
                reloadAfterRestoringExtension(
                    newContext,
                    in: tabsToReload,
                    identifier: identifier
                )
            }
        } catch {
            let installationError = error
            setContextReady(false, identifier: identifier)
            if !didPersistPreparingState {
                registry = previousRegistry
                if previousContextWasReady,
                   let previousContext,
                   contexts[identifier] === previousContext,
                   previousContext.isLoaded,
                   !quarantinedContextIdentifiers.contains(identifier) {
                    setContextLifecycleQuiesced(false, identifier: identifier)
                    synchronizeFocusedWindow(to: previousContext)
                    setContextReady(true, identifier: identifier)
                }
                try? persistRegistry()
                throw installationError
            }
            var canRestorePreviousContext = true
            if let newContext = contexts[identifier], newContext !== previousContext {
                if didAttemptNewContextLoad {
                    newContextAffectedTabs = mergingTabs(
                        newContextAffectedTabs,
                        tabsAffectedByRemoval(of: newContext, identifier: identifier)
                    )
                }
                canRestorePreviousContext = unloadOrQuarantine(
                    newContext,
                    identifier: identifier
                )
                if canRestorePreviousContext {
                    NotificationCenter.default.removeObserver(self, name: nil, object: newContext)
                }
            }
            guard transitionIsValid(for: identifier, generation: generation) else {
                throw error
            }
            guard canRestorePreviousContext else {
                let tabsToClean = mergingTabs(
                    previousContextAffectedTabs,
                    newContextAffectedTabs
                )
                reloadAfterRemovingExtension(from: tabsToClean, identifier: identifier)
                clearSurfaceHistory(for: identifier)
                updateRecord(identifier) { failed in
                    failed.lastError = "\(installationError.localizedDescription) Restart Floorp to recover."
                    failed.runtimeDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                        phase: .host,
                        error: installationError as NSError
                    )]
                }
                try? persistRegistry()
                throw installationError
            }
            if let previousRecord {
                replaceRecord(previousRecord)
                var restoredPreviousContext = false
                var didFailClosedRestoration = false
                if let previousContext {
                    if didStopObservingPreviousContext {
                        observeContextChanges(in: previousContext)
                    }
                    if didAttemptNewContextLoad {
                        newContextAffectedTabs = mergingTabs(
                            previousContextAffectedTabs,
                            newContextAffectedTabs,
                            tabsEligibleForInjection(of: previousContext)
                        )
                    }
                    contexts[identifier] = previousContext
                    if previousRecord.isEnabled {
                        do {
                            setContextLifecycleQuiesced(false, identifier: identifier)
                            if !previousContext.isLoaded {
                                try loadContext(previousContext, identifier: identifier)
                            }
                            guard previousContext.isLoaded else {
                                throw FloorpNativeWebExtensionError.hostUnavailable
                            }
                            try await waitForStableBackgroundReadinessIfRequired(
                                in: previousContext,
                                identifier: identifier,
                                timeoutNanoseconds: coldBackgroundReadinessTimeout(for: identifier)
                            )
                            try validateTransition(
                                for: identifier,
                                generation: generation
                            )
                            setContextReady(true, identifier: identifier)
                            restoredPreviousContext = true
                        } catch {
                            let restorationError = error
                            failClosedAfterRestorationFailure(
                                previousContext,
                                in: newContextAffectedTabs,
                                identifier: identifier,
                                desiredRecord: previousRecord,
                                operationError: installationError,
                                restorationError: restorationError
                            )
                            didFailClosedRestoration = true
                            try validateTransition(
                                for: identifier,
                                generation: generation
                            )
                        }
                    }
                } else {
                    contexts.removeValue(forKey: identifier)
                }
                if didAttemptNewContextLoad {
                    if restoredPreviousContext, let previousContext {
                        reloadAfterRestoringExtension(
                            previousContext,
                            in: newContextAffectedTabs,
                            identifier: identifier
                        )
                    } else if !didFailClosedRestoration {
                        reloadAfterRemovingExtension(
                            from: newContextAffectedTabs,
                            identifier: identifier
                        )
                        clearSurfaceHistory(for: identifier)
                    }
                }
                try? persistRegistry()
            } else {
                contexts.removeValue(forKey: identifier)
                if didAttemptNewContextLoad {
                    reloadAfterRemovingExtension(
                        from: newContextAffectedTabs,
                        identifier: identifier
                    )
                    clearSurfaceHistory(for: identifier)
                }
                record.transactionState = .pendingPurge
                record.rollback = nil
                record.lastError = installationError.localizedDescription
                replaceRecord(record)
                try? persistRegistry()
                do {
                    try await completePendingPurge(record, generation: generation)
                } catch {
                    if transitionIsValid(for: identifier, generation: generation) {
                        updateRecord(identifier) { pending in
                            pending.transactionState = .pendingPurge
                            pending.lastError = error.localizedDescription
                        }
                        try? persistRegistry()
                    }
                }
            }
            throw installationError
        }
    }

    // swiftlint:disable:next function_body_length
    func setEnabled(_ isEnabled: Bool, identifier: String) async throws {
        let generation = try beginTransition(for: identifier)
        defer { endTransition(for: identifier) }
        guard var record = registry.extensions.first(where: { $0.id == identifier }) else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        if !isEnabled,
           var unloadState = record.unloadState,
           unloadState.enableOnNextColdLaunch {
            let previous = record
            unloadState.enableOnNextColdLaunch = false
            record.unloadState = unloadState
            replaceRecord(record)
            do {
                try persistRegistry()
            } catch {
                replaceRecord(previous)
                throw error
            }
            return
        }
        guard record.isEnabled != isEnabled else { return }
        if !isEnabled, contexts[identifier] == nil {
            // A cold-restore failure can unload and remove the context while
            // retaining the enabled record and its diagnostics. Let the user
            // explicitly leave fail-closed mode without requiring that broken
            // context, while preserving the error that explains why it failed.
            let previous = record
            record.isEnabled = false
            record.unloadState = FloorpNativeWebExtensionUnloadState(
                processIdentifier: Self.processLifecycleIdentifier,
                enableOnNextColdLaunch: false
            )
            record.transactionState = .stable
            record.rollback = nil
            replaceRecord(record)
            do {
                try persistRegistry()
            } catch {
                replaceRecord(previous)
                throw error
            }
            setContextReady(false, identifier: identifier)
            setContextLifecycleQuiesced(true, identifier: identifier)
            if let popupToken = managedActionPopups[identifier]?.token {
                dismissManagedActionPopups { $0.token == popupToken }
            }
            dismissPresentedSurfaces(identifier: identifier)
            actionOrigins.removeValue(forKey: identifier)
            publishExtensionTopologyChange()
            return
        }
        if isEnabled,
           var unloadState = record.unloadState,
           unloadState.processIdentifier == Self.processLifecycleIdentifier {
            let previous = record
            unloadState.enableOnNextColdLaunch = true
            record.unloadState = unloadState
            record.transactionState = .stable
            record.rollback = nil
            replaceRecord(record)
            do {
                try persistRegistry()
            } catch {
                replaceRecord(previous)
                throw error
            }
            return
        }
        guard let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        if !isEnabled {
            let previous = record
            let affectedTabs = tabsAffectedByRemoval(
                of: context,
                identifier: identifier
            )
            record.isEnabled = false
            record.unloadState = nil
            record.transactionState = .stable
            record.rollback = nil
            record.lastError = nil
            replaceRecord(record)

            do {
                try persistRegistry()
            } catch {
                replaceRecord(previous)
                throw error
            }
            setContextReady(false, identifier: identifier)
            setContextLifecycleQuiesced(true, identifier: identifier)
            reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
            clearSurfaceHistory(for: identifier)

            var shutdownError: (any Error)?
            var shutdownAffectedTabs = affectedTabs
#if DEBUG || TESTING
            contextWillUnloadHookForTesting?(identifier)
#endif
            try validateTransition(for: identifier, generation: generation)
            if context.isLoaded {
                if hasUnfinishedWebKitOperation(for: context) {
                    // Do not stack a shutdown readiness request behind an
                    // already-delivered WebKit call. In particular, WebKit can
                    // serialize extension-page JavaScript, causing this second
                    // request to outlive the disable deadline and race DNR
                    // teardown. The active operation below forces quarantine.
                    shutdownError = FloorpNativeWebExtensionError.restartRequired(
                        "Disabling an extension with an unfinished WebKit operation"
                    )
                } else {
                    do {
                        try await waitForBackgroundReadinessIfRequired(
                            in: context,
                            identifier: identifier,
                            timeoutNanoseconds: 2_000_000_000
                        )
                    } catch {
                        shutdownError = error
                    }
                }
            }
            // Caller cancellation still requires fail-closed containment, but
            // a host teardown/generation change must not mutate or persist a
            // runtime that no longer belongs to this lifecycle.
            guard transitionBelongsToCurrentLifecycle(
                for: identifier,
                generation: generation
            ), contexts[identifier] === context,
                  var latestRecord = registry.extensions.first(where: { $0.id == identifier }) else {
                throw CancellationError()
            }
            // Close the durable permission snapshot before unload. WebKit can
            // synchronously clear live permissions while unloading; those are
            // runtime teardown events, not user decisions.
            if context.isLoaded {
                Self.synchronizePermissionState(from: context, to: &latestRecord)
            }
            record = latestRecord
            if context.isLoaded {
                shutdownAffectedTabs = mergingTabs(
                    affectedTabs,
                    tabsAffectedByRemoval(of: context, identifier: identifier)
                )
                if !unloadOrQuarantine(context, identifier: identifier) {
                    shutdownError = FloorpNativeWebExtensionError.unsupportedOperation(
                        "disabled extension context could not be unloaded"
                    )
                }
            }
            reloadAfterRemovingExtension(
                from: shutdownAffectedTabs,
                identifier: identifier
            )
            clearSurfaceHistory(for: identifier)
            record.isEnabled = false
            record.unloadState = FloorpNativeWebExtensionUnloadState(
                processIdentifier: Self.processLifecycleIdentifier,
                enableOnNextColdLaunch: false
            )
            record.transactionState = .stable
            record.rollback = nil
            if let shutdownError {
                record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
                    + [FloorpNativeWebExtensionDiagnostic(
                        phase: .host,
                        error: shutdownError as NSError
                    )]
                record.lastError = "The extension is disabled, but background shutdown did not "
                    + "complete safely: \(shutdownError.localizedDescription). "
                    + "Restart Floorp before using this extension again."
                logger.log(
                    "Floorp: disabled native WebExtension \(identifier), but shutdown did not "
                        + "complete safely: \(shutdownError)",
                    level: .warning,
                    category: .setup
                )
            } else {
                record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
                record.lastError = record.runtimeDiagnostics.last?.message
            }
            replaceRecord(record)
            try persistRegistry()
            guard transitionIsValid(for: identifier, generation: generation) else {
                throw CancellationError()
            }
            return
        }
        setContextReady(false, identifier: identifier)

        let previous = record
        record.rollback = record.rollbackSnapshot
        record.transactionState = .switching
        // Make the target read topology visible while WebKit synchronously loads
        // the context. Mutations and actions remain blocked until `setContextReady`.
        // The rollback snapshot still contains the prior enabled state.
        record.isEnabled = isEnabled
        record.unloadState = nil
        replaceRecord(record)
        let affectedTabs = tabsEligibleForInjection(of: context)

        do {
            try persistRegistry()
            try loadContext(context, identifier: identifier)
            try await waitForStableBackgroundReadinessIfRequired(
                in: context,
                identifier: identifier,
                timeoutNanoseconds: coldBackgroundReadinessTimeout(for: identifier)
            )
            try validateTransition(for: identifier, generation: generation)
            setContextReady(true, identifier: identifier)
            Self.synchronizePermissionState(from: context, to: &record)
            record.isEnabled = isEnabled
            record.unloadState = nil
            record.transactionState = .stable
            record.rollback = nil
            record.lastError = nil
            replaceRecord(record)
            try persistRegistry()
            reloadForNewlyAvailableExtension(in: affectedTabs)
        } catch {
            let operationError = error
            setContextReady(false, identifier: identifier)
            guard transitionIsValid(for: identifier, generation: generation) else {
                throw operationError
            }
            var disabledAfterAttempt = previous
            disabledAfterAttempt.unloadState = FloorpNativeWebExtensionUnloadState(
                processIdentifier: Self.processLifecycleIdentifier,
                enableOnNextColdLaunch: false
            )
            replaceRecord(disabledAfterAttempt)
            var didFailClosedRestoration = false
            if context.isLoaded {
                let didUnload = unloadOrQuarantine(context, identifier: identifier)
                if !didUnload {
                    failClosedAfterRestorationFailure(
                        context,
                        in: affectedTabs,
                        identifier: identifier,
                        desiredRecord: disabledAfterAttempt,
                        operationError: operationError,
                        restorationError: FloorpNativeWebExtensionError.unsupportedOperation(
                            "enable rollback could not unload the extension context"
                        )
                    )
                    didFailClosedRestoration = true
                    try validateTransition(for: identifier, generation: generation)
                }
            }
            if !didFailClosedRestoration {
                let tabsToClean = mergingTabs(
                    affectedTabs,
                    tabsAffectedByRemoval(of: context, identifier: identifier)
                )
                reloadAfterRemovingExtension(from: tabsToClean, identifier: identifier)
                clearSurfaceHistory(for: identifier)
            }
            try? persistRegistry()
            throw operationError
        }
    }

    // swiftlint:disable:next function_body_length
    func setPrivateAccess(_ allowed: Bool, identifier: String) async throws {
        let generation = try beginTransition(for: identifier)
        defer { endTransition(for: identifier) }
        guard registry.extensions.contains(where: { $0.id == identifier }),
              let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        let previous = context.hasAccessToPrivateData
        guard previous != allowed else { return }
        let wasOperational = currentLifecycleIdentifier(for: context) != nil
        let contextWasReady = readyContextIdentifiers.contains(identifier)
        var didChangePrivateAccess = false
        setContextReady(false, identifier: identifier)
#if DEBUG || TESTING
        privateAccessTransitionHookForTesting?(identifier)
#endif
        defer {
            let currentRecord = registry.extensions.first { $0.id == identifier }
            // A caller cancelling its Task must not strand an otherwise healthy
            // context in the not-ready state. Teardown and generation changes
            // still suppress publication into a retired host.
            let transitionRemainsValid = transitionBelongsToCurrentLifecycle(
                for: identifier,
                generation: generation
            )
            let canRestoreReadiness = transitionRemainsValid
                && contextWasReady
                && contexts[identifier] === context
                && context.isLoaded
                && currentRecord?.isEnabled == true
                && currentRecord?.transactionState == .stable
                && currentRecord?.hasPrivateAccess == context.hasAccessToPrivateData
            if canRestoreReadiness {
                setContextReady(true, identifier: identifier)
            } else if didChangePrivateAccess && transitionRemainsValid {
                publishExtensionTopologyChange()
            }
        }
        var readinessWarning: (any Error)?
        if wasOperational {
            do {
                try await waitForStableBackgroundReadinessIfRequired(
                    in: context,
                    identifier: identifier
                )
                try validateTransition(for: identifier, generation: generation)
            } catch {
                if allowed { throw error }
                guard transitionIsValid(for: identifier, generation: generation) else {
                    throw error
                }
                readinessWarning = error
            }
        }
        guard var record = registry.extensions.first(where: { $0.id == identifier }),
              contexts[identifier] === context else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        let previousRecord = record

        if !allowed {
            record.hasPrivateAccess = false
            record.transactionState = .stable
            record.rollback = nil
            if let readinessWarning {
                record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
                    + [FloorpNativeWebExtensionDiagnostic(
                        phase: .host,
                        error: readinessWarning as NSError
                    )]
                record.lastError = "Private access was revoked before background work settled: "
                    + readinessWarning.localizedDescription
            } else {
                record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
                record.lastError = record.runtimeDiagnostics.last?.message
            }
            replaceRecord(record)
            // Denial is durable before WebKit is allowed to expose any more
            // private state. The live setter removes private content scripts and
            // DNR rules without cycling the extension context.
            do {
                try persistRegistry()
            } catch {
                replaceRecord(previousRecord)
                throw error
            }
            dismissManagedActionPopups {
                $0.context === context && $0.sourceWindow.isPrivate
            }
            dismissPresentedSurfaces(identifier: identifier, isPrivate: true)
            actionOrigins[identifier]?.removeAll { $0.window.isPrivate }
            if actionOrigins[identifier]?.isEmpty == true {
                actionOrigins.removeValue(forKey: identifier)
            }
            if wasOperational {
                withdrawPrivateTopology(from: context)
            }
            context.hasAccessToPrivateData = false
            didChangePrivateAccess = true
            if wasOperational {
                removePrivateExtensionState(identifier: identifier)
                synchronizeFocusedWindow(to: context)
            }
            return
        }

        record.rollback = record.rollbackSnapshot
        record.transactionState = .switching
        // Advertise the target privacy topology durably before WebKit gains
        // private-data access. Because the context is intentionally not ready
        // during this transaction, private HTTP(S) navigation now fails
        // closed until readiness succeeds. The rollback snapshot retains the
        // prior denied state.
        record.hasPrivateAccess = true
        replaceRecord(record)
        do {
            try persistRegistry()
            context.hasAccessToPrivateData = true
            if wasOperational {
                announcePrivateTopology(to: context)
#if DEBUG || TESTING
                privateAccessCommitHookForTesting?(identifier)
#endif
                // Synchronizing focus lets uBO enqueue its Safari realm refresh.
                // Its readiness response does not complete until that queue and
                // startup DNR work have both drained.
                synchronizeFocusedWindow(to: context)
                try await waitForStableBackgroundReadinessIfRequired(
                    in: context,
                    identifier: identifier
                )
                try validateTransition(for: identifier, generation: generation)
            }
            guard var committedRecord = registry.extensions.first(where: { $0.id == identifier }),
                  contexts[identifier] === context else {
                throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
            }
            Self.synchronizePermissionState(from: context, to: &committedRecord)
            committedRecord.hasPrivateAccess = true
            committedRecord.transactionState = .stable
            committedRecord.rollback = nil
            committedRecord.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
            committedRecord.lastError = nil
            replaceRecord(committedRecord)
            try persistRegistry()
            didChangePrivateAccess = true
            if wasOperational {
                let privateTabs = tabManagers.values.compactMap(\.value)
                    .flatMap(\.privateTabs)
                    .filter(isManagedTab)
                reloadForNewlyAvailableExtension(in: privateTabs)
            }
        } catch {
            let operationError = error
            if wasOperational {
                withdrawPrivateTopology(from: context)
            }
            context.hasAccessToPrivateData = previous
            if wasOperational {
                removePrivateExtensionState(identifier: identifier)
            }
            var restoredRecord = previousRecord
            Self.synchronizePermissionState(from: context, to: &restoredRecord)
            replaceRecord(restoredRecord)
            try? persistRegistry()
            throw operationError
        }
    }

    func uninstall(identifier: String) async throws {
        let generation = try beginTransition(for: identifier)
        defer { endTransition(for: identifier) }
        guard var record = registry.extensions.first(where: { $0.id == identifier }) else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        let previousRecord = record
        let previousContextWasReady = readyContextIdentifiers.contains(identifier)
        setContextReady(false, identifier: identifier)
        setContextLifecycleQuiesced(true, identifier: identifier)
        let affectedTabs = contexts[identifier].map {
            tabsAffectedByRemoval(of: $0, identifier: identifier)
        } ?? []
        record.transactionState = .pendingPurge
        record.rollback = nil
        replaceRecord(record)
        var didPersistPendingPurge = false
        do {
            try persistRegistry()
            didPersistPendingPurge = true
            try await completePendingPurge(record, generation: generation)
            try validateTransition(for: identifier, generation: generation)
        } catch {
            if !didPersistPendingPurge {
                replaceRecord(previousRecord)
                if previousContextWasReady {
                    setContextLifecycleQuiesced(false, identifier: identifier)
                    if let context = contexts[identifier] {
                        synchronizeFocusedWindow(to: context)
                    }
                    setContextReady(true, identifier: identifier)
                }
                throw error
            }
            guard transitionIsValid(for: identifier, generation: generation) else {
                throw error
            }
            reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
            clearSurfaceHistory(for: identifier)
            throw error
        }
        reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
        clearSurfaceHistory(for: identifier)
    }

    // swiftlint:disable:next function_body_length
    func optionsViewController(
        identifier: String,
        sourceTab: Tab? = nil,
        isPrivate: Bool = false
    ) async throws -> UIViewController {
        guard let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        guard readyContextIdentifiers.contains(identifier), context.isLoaded else {
            throw FloorpNativeWebExtensionError.extensionDisabled(identifier)
        }
        guard let url = context.optionsPageURL else {
            throw FloorpNativeWebExtensionError.unsupportedOperation("options page")
        }
        if isPrivate, !context.hasAccessToPrivateData {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        if let sourceTab {
            guard sourceTab.isPrivate == isPrivate,
                  isManagedTab(sourceTab),
                  canOperate(tab: sourceTab, in: context) else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
        }
        try await waitForStableBackgroundReadinessIfRequired(
            in: context,
            identifier: identifier,
            timeoutNanoseconds: backgroundReadinessTimeout(for: identifier)
        )
        try Task.checkCancellation()
        guard currentReadyIdentifier(for: context) == identifier,
              contexts[identifier] === context,
              context.isLoaded else {
            throw FloorpNativeWebExtensionError.extensionDisabled(identifier)
        }
        if isPrivate, !context.hasAccessToPrivateData {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        if let sourceTab {
            let expectedWindow = WindowKey(
                windowUUID: sourceTab.windowUUID,
                isPrivate: sourceTab.isPrivate
            )
            guard sourceTab.isPrivate == isPrivate,
                  canOperate(tab: sourceTab, in: context),
                  tabManager(for: sourceTab.windowUUID)?.selectedTab === sourceTab,
                  lastFocusedWindow == expectedWindow else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
        }
        let websiteDataStore: WKWebsiteDataStore
        if isPrivate {
            guard let sourceTab,
                  !sourceTab.floorpNativeWebsiteDataStore.isPersistent else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
            websiteDataStore = sourceTab.floorpNativeWebsiteDataStore
        } else {
            websiteDataStore = sourceTab?.floorpNativeWebsiteDataStore ?? .default()
            guard websiteDataStore.isPersistent else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
        }
        guard let configuration = extensionSurfaceConfiguration(
            for: context,
            websiteDataStore: websiteDataStore,
            isPrivate: isPrivate
        ) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let preferredWindowUUID = sourceTab?.windowUUID
        let invalidateReadiness = { [weak self] in
            guard identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier else {
                return
            }
            self?.invalidateUBlockOriginLiteNavigationReadiness(isPrivate: isPrivate)
        }
        let prepareToClose: (@MainActor (WKWebView) async -> Bool)?
        if semanticReadinessPagePath(for: identifier) != nil {
            prepareToClose = { [weak self, weak context] webView in
                guard let self, let context,
                      self.currentReadyIdentifier(for: context) == identifier else {
                    return false
                }
                return await self.prepareExtensionSurfaceForClose(
                    webView,
                    context: context,
                    identifier: identifier,
                    timeoutNanoseconds: self.backgroundReadinessTimeout(for: identifier)
                )
            }
        } else {
            prepareToClose = nil
        }
        let page = FloorpNativeWebExtensionPageViewController(
            title: "\(context.webExtension.displayName ?? FloorpStrings.WebExtensions.genericExtensionName)"
                + " · \(FloorpStrings.WebExtensions.options)",
            url: url,
            configuration: configuration,
            openURLInBrowser: { [weak self] url in
                // Options can change uBO's enabled static rulesets without a
                // host-observable WebExtension event. Force the destination
                // navigation to reconcile the realm before it can load.
                invalidateReadiness()
                self?.openURLInBrowser(
                    url,
                    isPrivate: isPrivate,
                    preferredWindowUUID: preferredWindowUUID
                )
            },
            prepareToClose: prepareToClose,
            onClose: invalidateReadiness
        )
        let navigationController = UINavigationController(rootViewController: page)
        navigationController.isModalInPresentation = prepareToClose != nil
        trackPresentedSurface(
            navigationController,
            identifier: identifier,
            isPrivate: isPrivate
        )
        return navigationController
    }

    private func prepareExtensionSurfaceForClose(
        _ webView: WKWebView,
        context: WKWebExtensionContext,
        identifier: String,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        guard !Task.isCancelled,
              contexts[identifier] === context,
              currentReadyIdentifier(for: context) == identifier,
              !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry
                .isPermanentlyRetained(webView) else {
            return false
        }
        let closeOperationID = UUID()
        activeSurfaceCloseOperations[closeOperationID] = context
        FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.beginOperation(in: webView)
#if DEBUG || TESTING
        if let hook = extensionSurfaceClosePreparationHookForTesting {
            let result = await hook(identifier, webView)
            activeSurfaceCloseOperations.removeValue(forKey: closeOperationID)
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(in: webView)
            return result
        }
#endif
        let probe = BackgroundReadinessProbe()
        do {
            let raw = try await probe.callAsyncJavaScript(
                """
                if (typeof globalThis.floorpPrepareToClose !== 'function') {
                    return { ready: false, error: 'Floorp close preparation is unavailable' };
                }
                return await globalThis.floorpPrepareToClose();
                """,
                in: webView,
                identifier: identifier,
                timeoutNanoseconds: timeoutNanoseconds
            )
            activeSurfaceCloseOperations.removeValue(forKey: closeOperationID)
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(in: webView)
            probe.invalidate()
            guard let response = raw as? [String: Any],
                  response["ready"] as? Bool == true else {
                let detail = (raw as? [String: Any])?["error"] as? String
                    ?? "missing successful close-preparation response"
                logger.log(
                    "Floorp: native WebExtension \(identifier) options remain open: \(detail)",
                    level: .warning,
                    category: .setup
                )
                return false
            }
            return true
        } catch {
            activeSurfaceCloseOperations.removeValue(forKey: closeOperationID)
            if probe.requiresProcessLifetimeRetention {
                // The caller may explicitly close this page after a timeout,
                // while WebKit still owns its JavaScript callback. Retain the
                // complete page/probe pair so that callback remains reachable.
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.retain(webView)
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(in: webView)
                retiredBackgroundReadinessSurfaces.append(BackgroundReadinessSurface(
                    context: context,
                    probe: probe,
                    webView: webView
                ))
            } else {
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(in: webView)
                probe.invalidate()
            }
            logger.log(
                "Floorp: native WebExtension \(identifier) options close preparation failed: \(error)",
                level: .warning,
                category: .setup
            )
            return false
        }
    }

    /// Starts an interactive durability gate before a browser tab destroys a
    /// committed, hook-capable extension document. Returning `true` means this
    /// host owns `completion`; returning `false` means no gate applies and the
    /// caller may proceed synchronously.
    @discardableResult
    func prepareExtensionTabSurfaceForDestruction(
        in tab: Tab,
        expectedWebView: WKWebView,
        forceOnFailure: Bool = false,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isTornDown,
              tab.webView === expectedWebView,
              tab.floorpNativeHasCommittedDocument,
              isManagedTab(tab),
              let identifier = tab.floorpNativeWebExtensionContextIdentifier,
              semanticReadinessPagePath(for: identifier) != nil,
              let context = contexts[identifier],
              currentReadyIdentifier(for: context) == identifier else {
            return false
        }

        let key = ObjectIdentifier(tab)
        if let previous = extensionTabSurfaceCloseRequests[key] {
            resolveExtensionTabSurfaceCloseRequest(
                previous,
                shouldProceed: previous.forceOnFailure,
                dismissAlert: true
            )
        }
        guard isManagedTab(tab), tab.webView === expectedWebView else {
            return false
        }
        let request = ExtensionTabSurfaceCloseRequest(
            identifier: identifier,
            context: context,
            tab: tab,
            webView: expectedWebView,
            forceOnFailure: forceOnFailure,
            completion: completion
        )
        extensionTabSurfaceCloseRequests[key] = request
        expectedWebView.isUserInteractionEnabled = false
        runExtensionTabSurfaceClosePreparation(request)
        return true
    }

    private func runExtensionTabSurfaceClosePreparation(
        _ request: ExtensionTabSurfaceCloseRequest
    ) {
        request.presentationTask?.cancel()
        request.presentationTask = nil
        guard extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token == request.token,
              let tab = request.tab,
              let webView = request.webView,
              extensionTabSurfaceCloseRequestIsCurrent(request, tab: tab, webView: webView) else {
            resolveExtensionTabSurfaceCloseRequest(
                request,
                shouldProceed: request.forceOnFailure,
                dismissAlert: true
            )
            return
        }
        request.task?.cancel()
        // swiftlint:disable:next closure_body_length
        request.task = Task { @MainActor [weak self, request] in
            guard !Task.isCancelled, let self else {
                if !request.forceOnFailure,
                   request.tab?.webView === request.webView {
                    request.webView?.isUserInteractionEnabled = true
                }
                request.takeCompletion()?(request.forceOnFailure)
                return
            }
            guard self.extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token
                    == request.token,
                  self.extensionTabSurfaceCloseRequestIsCurrent(
                      request,
                      tab: tab,
                      webView: webView
                  ) else {
                self.resolveExtensionTabSurfaceCloseRequest(
                    request,
                    shouldProceed: request.forceOnFailure,
                    dismissAlert: true
                )
                return
            }
            let prepared = await self.prepareExtensionSurfaceForClose(
                webView,
                context: request.context,
                identifier: request.identifier,
                timeoutNanoseconds: self.backgroundReadinessTimeout(
                    for: request.identifier
                )
            )
            guard !Task.isCancelled,
                  self.extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token
                    == request.token,
                  self.extensionTabSurfaceCloseRequestIsCurrent(
                      request,
                      tab: tab,
                      webView: webView
                  ) else {
                self.resolveExtensionTabSurfaceCloseRequest(
                    request,
                    shouldProceed: request.forceOnFailure,
                    dismissAlert: true
                )
                return
            }
            request.task = nil
            if prepared {
                self.resolveExtensionTabSurfaceCloseRequest(
                    request,
                    shouldProceed: true,
                    dismissAlert: false
                )
            } else if request.forceOnFailure {
                self.resolveExtensionTabSurfaceCloseRequest(
                    request,
                    shouldProceed: true,
                    dismissAlert: false
                )
            } else {
                self.presentExtensionTabSurfaceCloseFailure(request)
            }
        }
    }

    private func extensionTabSurfaceCloseRequestIsCurrent(
        _ request: ExtensionTabSurfaceCloseRequest,
        tab: Tab,
        webView: WKWebView
    ) -> Bool {
        guard !isTornDown,
              ObjectIdentifier(tab) == request.tabIdentifier,
              ObjectIdentifier(webView) == request.webViewIdentifier,
              tab.webView === webView,
              tab.floorpNativeHasCommittedDocument,
              tab.floorpNativeWebExtensionContextIdentifier == request.identifier,
              isManagedTab(tab),
              contexts[request.identifier] === request.context else { return false }
        return currentReadyIdentifier(for: request.context) == request.identifier
    }

    private func presentExtensionTabSurfaceCloseFailure(
        _ request: ExtensionTabSurfaceCloseRequest
    ) {
        guard extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token == request.token,
              let tab = request.tab,
              let webView = request.webView,
              extensionTabSurfaceCloseRequestIsCurrent(request, tab: tab, webView: webView) else {
            resolveExtensionTabSurfaceCloseRequest(
                request,
                shouldProceed: request.forceOnFailure,
                dismissAlert: true
            )
            return
        }
        guard request.alert == nil else { return }
        guard let presenter = presenter(for: tabAdapter(for: tab)),
              presenter.viewIfLoaded?.window != nil,
              !(presenter is UIAlertController),
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed,
              presenter.presentedViewController == nil else {
            scheduleExtensionTabSurfaceCloseFailurePresentation(
                request,
                isPresentationRetry: true
            )
            return
        }

        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.optionsCloseFailureTitle,
            message: FloorpStrings.WebExtensions.optionsCloseFailureMessage,
            preferredStyle: .alert
        )
        request.alert = alert
        request.didCompletePresentation = false
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.continueEditing,
            style: .cancel
        ) { [weak self, request] _ in
            self?.resolveExtensionTabSurfaceCloseRequest(
                request,
                shouldProceed: false,
                dismissAlert: false
            )
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.retry,
            style: .default
        ) { [weak self, request] _ in
            guard let self,
                  self.extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token
                    == request.token else { return }
            request.alert = nil
            DispatchQueue.main.async { [weak self, request] in
                self?.runExtensionTabSurfaceClosePreparation(request)
            }
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.closeAnyway,
            style: .destructive
        ) { [weak self, request] _ in
            self?.resolveExtensionTabSurfaceCloseRequest(
                request,
                shouldProceed: true,
                dismissAlert: false
            )
        })
        presenter.present(alert, animated: true) { [weak self, request] in
            guard let self,
                  self.extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token
                    == request.token else { return }
            request.didCompletePresentation = true
        }
        scheduleExtensionTabSurfaceCloseFailurePresentation(request)
    }

    private func scheduleExtensionTabSurfaceCloseFailurePresentation(
        _ request: ExtensionTabSurfaceCloseRequest,
        isPresentationRetry: Bool = false
    ) {
        guard extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token == request.token else {
            return
        }
        if isPresentationRetry {
            request.presentationRetryCount += 1
            if request.presentationRetryCount == 40 {
                logger.log(
                    "Floorp: extension tab close failure is still waiting for a presenter.",
                    level: .warning,
                    category: .setup
                )
            }
        }
        request.presentationTask?.cancel()
        request.presentationTask = Task { @MainActor [weak self, request] in
            let delay: UInt64 = request.presentationRetryCount < 40
                ? 250_000_000
                : 2_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token
                    == request.token else { return }
            request.presentationTask = nil
            guard let tab = request.tab,
                  let webView = request.webView,
                  self.extensionTabSurfaceCloseRequestIsCurrent(
                      request,
                      tab: tab,
                      webView: webView
                  ) else {
                self.resolveExtensionTabSurfaceCloseRequest(
                    request,
                    shouldProceed: request.forceOnFailure,
                    dismissAlert: true
                )
                return
            }
            if let alert = request.alert {
                if alert.presentingViewController != nil
                    || alert.viewIfLoaded?.window != nil
                    || alert.isBeingPresented {
                    self.scheduleExtensionTabSurfaceCloseFailurePresentation(request)
                    return
                }
                request.alert = nil
                request.didCompletePresentation = false
            }
            self.presentExtensionTabSurfaceCloseFailure(request)
        }
    }

    private func resolveExtensionTabSurfaceCloseRequest(
        _ request: ExtensionTabSurfaceCloseRequest,
        shouldProceed: Bool,
        dismissAlert: Bool
    ) {
        guard extensionTabSurfaceCloseRequests[request.tabIdentifier]?.token == request.token else {
            return
        }
        extensionTabSurfaceCloseRequests.removeValue(forKey: request.tabIdentifier)
        request.task?.cancel()
        request.task = nil
        request.presentationTask?.cancel()
        request.presentationTask = nil
        let alert = request.alert
        request.alert = nil
        if dismissAlert,
           alert?.presentingViewController != nil || alert?.viewIfLoaded?.window != nil {
            alert?.dismiss(animated: false)
        }
        let canProceed: Bool
        if shouldProceed,
           let tab = request.tab,
           let webView = request.webView {
            canProceed = request.forceOnFailure
                ? ObjectIdentifier(tab) == request.tabIdentifier
                    && ObjectIdentifier(webView) == request.webViewIdentifier
                    && tab.webView === webView
                    && isManagedTab(tab)
                : extensionTabSurfaceCloseRequestIsCurrent(
                    request,
                    tab: tab,
                    webView: webView
                )
        } else {
            canProceed = false
        }
        if !canProceed,
           request.tab?.webView === request.webView {
            request.webView?.isUserInteractionEnabled = true
        }
        request.takeCompletion()?(canProceed)
    }

    private func cancelExtensionTabSurfaceClosePreparation(for tab: Tab) {
        guard let request = extensionTabSurfaceCloseRequests[ObjectIdentifier(tab)] else { return }
        resolveExtensionTabSurfaceCloseRequest(
            request,
            shouldProceed: false,
            dismissAlert: true
        )
    }

#if DEBUG || TESTING
    func retryExtensionTabSurfaceCloseAfterFailureForTesting(_ tab: Tab) {
        guard let request = extensionTabSurfaceCloseRequests[ObjectIdentifier(tab)] else { return }
        request.alert?.dismiss(animated: false)
        request.alert = nil
        runExtensionTabSurfaceClosePreparation(request)
    }

    func keepExtensionTabSurfaceOpenAfterFailureForTesting(_ tab: Tab) {
        guard let request = extensionTabSurfaceCloseRequests[ObjectIdentifier(tab)] else { return }
        resolveExtensionTabSurfaceCloseRequest(
            request,
            shouldProceed: false,
            dismissAlert: true
        )
    }

    func closeExtensionTabSurfaceAnywayAfterFailureForTesting(_ tab: Tab) {
        guard let request = extensionTabSurfaceCloseRequests[ObjectIdentifier(tab)] else { return }
        resolveExtensionTabSurfaceCloseRequest(
            request,
            shouldProceed: true,
            dismissAlert: true
        )
    }
#endif

    func actionItems(for tab: Tab?) -> [FloorpNativeWebExtensionActionItem] {
        guard let tab else { return [] }
        let adapter = tabAdapter(for: tab)
        return registry.extensions.compactMap { record in
            guard record.isEnabled,
                  readyContextIdentifiers.contains(record.id),
                  let context = contexts[record.id],
                  context.isLoaded,
                  canOperate(tab: tab, in: context),
                  let action = context.action(for: adapter) else { return nil }
            return FloorpNativeWebExtensionActionItem(
                contextIdentifier: record.id,
                label: action.label.isEmpty ? record.displayName : action.label,
                version: record.installedVersion,
                icon: action.icon(for: CGSize(width: 32, height: 32)),
                isEnabled: action.isEnabled
            )
        }
    }

    func reserveActionInvocation(for tab: Tab) throws -> ActionInvocation {
        guard !isTornDown,
              isManagedTab(tab),
              let manager = tabManagers[tab.windowUUID]?.value,
              manager.selectedTab === tab else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let activationState = sceneActivationState(for: tab.windowUUID)
        guard activationState == nil || activationState == .foregroundActive else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let adapter = tabAdapter(for: tab)
        let windowKey = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        let tabKey = ObjectIdentifier(tab)
        let previousTab = lastActiveTabs[windowKey].flatMap { identifier in
            tabs(for: tab.windowUUID, isPrivate: tab.isPrivate)
                .first { ObjectIdentifier($0) == identifier }
        }
        let focusChanged = lastFocusedWindow != windowKey
        let activeTabChanged = lastActiveTabs[windowKey] != tabKey
        announceTabIfNeeded(tab)
        setTrackedFocusedWindow(windowKey)
        focusWasExplicitlyCleared = false
        lastActiveTabs[windowKey] = tabKey
        if activeTabChanged {
            invalidateUBlockOriginLiteNavigationReadiness(
                isPrivate: tab.isPrivate
            )
            notifyDidActivateTab(
                adapter,
                previousActiveTab: previousTab.map(tabAdapter(for:))
            )
        }
        if focusChanged || activeTabChanged {
            synchronizeFocusedWindows()
        }
        return ActionInvocation(
            sourceTabIdentifier: tabKey,
            sourceWindowUUID: tab.windowUUID,
            sourceIsPrivate: tab.isPrivate,
            sourceManagerIdentifier: ObjectIdentifier(manager),
            generation: beginActionInvocation(for: tab),
            focusGeneration: actionFocusGeneration,
            topologyGeneration: extensionTopologyGeneration
        )
    }

#if DEBUG || TESTING
    func performAction(
        contextIdentifier: String,
        for tab: Tab
    ) async throws {
        let invocation = try reserveActionInvocation(for: tab)
        try await performAction(
            contextIdentifier: contextIdentifier,
            for: tab,
            invocation: invocation
        )
    }
#endif

    // swiftlint:disable:next function_body_length
    func performAction(
        contextIdentifier: String,
        for tab: Tab,
        invocation: ActionInvocation
    ) async throws {
        guard actionInvocationIsCurrent(invocation, for: tab) else {
            throw CancellationError()
        }
        defer { finishActionInvocation(invocation, for: tab) }
        guard readyContextIdentifiers.contains(contextIdentifier),
              let context = contexts[contextIdentifier], context.isLoaded else {
            throw FloorpNativeWebExtensionError.extensionDisabled(contextIdentifier)
        }
        guard canOperate(tab: tab, in: context) else {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        guard let manager = tabManagers[tab.windowUUID]?.value,
              ObjectIdentifier(manager) == invocation.sourceManagerIdentifier,
              manager.selectedTab === tab else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let activationState = sceneActivationState(for: tab.windowUUID)
        guard activationState == nil || activationState == .foregroundActive else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let adapter = tabAdapter(for: tab)
        let windowKey = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        if contextIdentifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier {
            // A popup can change uBO's filtering mode asynchronously. Force
            // every navigation after the popup opens to reconcile with the
            // background mutation queue instead of trusting an older realm
            // readiness result.
            invalidateUBlockOriginLiteNavigationReadiness(isPrivate: tab.isPrivate)
        }
        // iOS background pages are always nonpersistent. Explicitly finish waking
        // the extension before its popup begins sending runtime messages.
        try await waitForStableBackgroundReadinessIfRequired(
            in: context,
            identifier: contextIdentifier,
            timeoutNanoseconds: backgroundReadinessTimeout(for: contextIdentifier)
        )
#if DEBUG || TESTING
        actionReadinessCompletedHookForTesting?(contextIdentifier, tab)
#endif
        guard actionInvocationIsCurrent(invocation, for: tab) else {
            throw CancellationError()
        }
        let currentActivationState = sceneActivationState(for: tab.windowUUID)
        guard readyContextIdentifiers.contains(contextIdentifier),
              contexts[contextIdentifier] === context,
              context.isLoaded,
              canOperate(tab: tab, in: context),
              tabManagers[tab.windowUUID]?.value === manager,
              manager.selectedTab === tab,
              lastFocusedWindow == windowKey,
              currentActivationState == nil || currentActivationState == .foregroundActive else {
            throw FloorpNativeWebExtensionError.extensionDisabled(contextIdentifier)
        }
        let popupPath = FloorpNativeWebExtensionCatalog.item(identifier: contextIdentifier)?
            .actionPopupPath
        let managedAction: WKWebExtension.Action?
        if popupPath != nil {
            guard let action = context.action(for: adapter),
                  action.isEnabled,
                  action.presentsPopup else {
                throw FloorpNativeWebExtensionError.unsupportedOperation(
                    "bundled action popup unavailable"
                )
            }
            guard await closeManagedActionPopupsAfterPreparing(where: { _ in true }),
                  actionInvocationIsCurrent(invocation, for: tab),
                  readyContextIdentifiers.contains(contextIdentifier),
                  contexts[contextIdentifier] === context,
                  context.isLoaded,
                  canOperate(tab: tab, in: context),
                  let refreshedAction = context.action(for: adapter),
                  refreshedAction.isEnabled,
                  refreshedAction.presentsPopup else {
                throw FloorpNativeWebExtensionError.unsupportedOperation(
                    "existing action popup could not finish closing"
                )
            }
            managedAction = refreshedAction
        } else {
            managedAction = nil
        }
        let expiresAt = Date().addingTimeInterval(60)
        var origins = actionOrigins[contextIdentifier]?.filter { $0.expiresAt > Date() } ?? []
        origins.removeAll { $0.window == windowKey }
        origins.append(ActionOrigin(
            window: windowKey,
            expiresAt: expiresAt
        ))
        actionOrigins[contextIdentifier] = origins
        if let popupPath, let managedAction {
            let popupToken = UUID()
            context.userGesturePerformed(in: adapter)
            managedAction.hasUnreadBadgeText = false
            do {
                try await presentBundledActionPopup(
                    path: popupPath,
                    context: context,
                    identifier: contextIdentifier,
                    sourceTab: tab,
                    sourceAdapter: adapter,
                    token: popupToken
                )
            } catch {
                // A superseding action can replace this pending presentation
                // before its transition retry completes. Never let the stale
                // attempt clear the replacement popup's fresh user gesture.
                if let currentPopup = managedActionPopups[contextIdentifier] {
                    if currentPopup.token == popupToken {
                        dismissManagedActionPopups { $0.token == popupToken }
                    }
                } else {
                    context.clearUserGesture(in: adapter)
                }
                throw error
            }
            return
        }
        context.performAction(for: adapter)
    }

    /// Returns true when the caller must cancel the current navigation because
    /// the tab is being rebuilt with a context-specific WebKit configuration.
    func routeNavigationIfNeeded(
        tab: Tab,
        url: URL,
        navigationType: WKNavigationType
    ) -> Bool {
        let destination = controller.extensionContext(for: url)
        let currentIdentifier = tab.floorpNativeWebExtensionContextIdentifier
        let destinationIdentifier = destination.flatMap(identifier(for:))

        if let destination, tab.isPrivate, !destination.hasAccessToPrivateData {
            return true
        }

        // A close-preparation callback can outlive its UI timeout. Cancel the
        // policy decision on that document and perform the destination load in
        // a fresh WebView, leaving the old page retained and untouched.
        if let preservedWebView = tab.webView,
           FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(preservedWebView) {
            DispatchQueue.main.async { [weak self, weak tab, weak preservedWebView] in
                guard let self, let tab, let preservedWebView,
                      self.isManagedTab(tab),
                      tab.webView === preservedWebView else { return }
                self.routePreservedNavigation(in: tab, to: url)
            }
            return true
        }

        guard currentIdentifier != destinationIdentifier else {
            if tab.consumeFloorpNativePreserveForwardNavigation() {
                return false
            }
            if navigationType != .backForward, navigationType != .reload,
               tab.webView?.url != url {
                tab.discardFloorpNativeSurfaceForwardHistory()
            }
            return false
        }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.isManagedTab(tab) else { return }
            let currentDestination = self.controller.extensionContext(for: url)
            let currentDestinationIdentifier = currentDestination.flatMap(self.identifier(for:))
            if let currentDestination,
               self.currentReadyIdentifier(for: currentDestination) == nil {
                if let blankURL = URL(string: "about:blank") {
                    self.switchSurface(in: tab, to: nil, loading: blankURL)
                }
                return
            }
            if let currentDestination,
               tab.isPrivate,
               !currentDestination.hasAccessToPrivateData {
                return
            }
            if tab.floorpNativeWebExtensionContextIdentifier == currentDestinationIdentifier {
                tab.loadRequest(URLRequest(url: url))
                return
            }
            tab.recordFloorpNativeSurfaceTransition(
                toContextIdentifier: currentDestinationIdentifier,
                url: url
            )
            self.switchSurface(in: tab, to: currentDestination, loading: url)
        }
        return true
    }

    private func routePreservedNavigation(in tab: Tab, to url: URL) {
        let destination = controller.extensionContext(for: url)
        let destinationIdentifier = destination.flatMap(identifier(for:))
        if let destination, currentReadyIdentifier(for: destination) == nil {
            if let blankURL = URL(string: "about:blank") {
                switchSurface(
                    in: tab,
                    to: nil,
                    loading: blankURL,
                    forceRebuild: true
                )
            }
            return
        }
        if let destination, tab.isPrivate, !destination.hasAccessToPrivateData {
            return
        }
        if tab.floorpNativeWebExtensionContextIdentifier != destinationIdentifier {
            tab.recordFloorpNativeSurfaceTransition(
                toContextIdentifier: destinationIdentifier,
                url: url
            )
        } else {
            tab.discardFloorpNativeSurfaceForwardHistory()
        }
        switchSurface(
            in: tab,
            to: destination,
            loading: url,
            forceRebuild: true
        )
    }

    func load(
        url: URL,
        in tab: Tab,
        requestedBy context: WKWebExtensionContext? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard isManagedTab(tab) else {
            completion?(false)
            return
        }
        let destination = controller.extensionContext(for: url)
        if let destination, tab.isPrivate, !destination.hasAccessToPrivateData {
            completion?(false)
            return
        }
        if let context {
            guard currentReadyIdentifier(for: context) != nil else {
                completion?(false)
                return
            }
            if let destination, context !== destination,
               !context.hasAccess(to: url, in: tabAdapter(for: tab)) {
                completion?(false)
                return
            }
        }

        let currentIdentifier = tab.floorpNativeWebExtensionContextIdentifier
        let destinationIdentifier = destination.flatMap(identifier(for:))
        let performLoad = { [weak self, weak tab] in
            guard let self, let tab, self.isManagedTab(tab) else {
                completion?(false)
                return
            }
            let currentDestination = self.controller.extensionContext(for: url)
            let currentDestinationIdentifier = currentDestination.flatMap(self.identifier(for:))
            guard currentDestinationIdentifier == destinationIdentifier,
                  !tab.isPrivate || currentDestination?.hasAccessToPrivateData != false else {
                if tab.webView?.isUserInteractionEnabled == false {
                    tab.webView?.isUserInteractionEnabled = true
                }
                completion?(false)
                return
            }
            if tab.floorpNativeWebExtensionContextIdentifier != destinationIdentifier {
                tab.recordFloorpNativeSurfaceTransition(
                    toContextIdentifier: destinationIdentifier,
                    url: url
                )
                self.switchSurface(in: tab, to: currentDestination, loading: url)
            } else {
                tab.discardFloorpNativeSurfaceForwardHistory()
                tab.loadRequest(URLRequest(url: url))
            }
            completion?(true)
        }

        // Programmatic `tabs.update` can cross the WebKit configuration
        // boundary without producing a policy callback on the old web view.
        // Prepare that committed extension document before replacing it. A
        // same-surface load still goes through BrowserViewController's exact
        // navigation-action gate, avoiding a speculative one-shot bypass.
        if currentIdentifier != destinationIdentifier,
           let webView = tab.webView,
           prepareExtensionTabSurfaceForDestruction(
               in: tab,
               expectedWebView: webView,
               completion: { shouldLoad in
                   if shouldLoad {
                       performLoad()
                   } else {
                       completion?(false)
                   }
               }
           ) {
            return
        }
        performLoad()
    }

    func recordCommittedNavigation(in tab: Tab, url: URL) {
        invalidateActionInvocation(for: tab)
        dismissManagedActionPopups { $0.sourceTab === tab }
        tab.commitFloorpNativeSurfaceNavigation(url: url)
    }

    @discardableResult
    func goBackAcrossSurface(in tab: Tab) -> Bool {
        guard let target = tab.floorpNativeSurfaceBackTarget,
              let context = context(forSurfaceIdentifier: target.contextIdentifier),
              !tab.isPrivate || context?.hasAccessToPrivateData != false else {
            return false
        }
        weak let sourceWebView = tab.webView
        let navigate = { [weak self, weak tab, weak sourceWebView] in
            guard let self, let tab,
                  tab.floorpNativeSurfaceBackTarget == target,
                  let currentContext = self.context(
                      forSurfaceIdentifier: target.contextIdentifier
                  ),
                  !tab.isPrivate || currentContext?.hasAccessToPrivateData != false else {
                if tab?.webView === sourceWebView {
                    sourceWebView?.isUserInteractionEnabled = true
                }
                return
            }
            _ = tab.moveFloorpNativeSurfaceHistoryBack()
            tab.preserveFloorpNativeForwardHistoryForNextNavigation()
            self.switchSurface(
                in: tab,
                to: currentContext,
                loading: target.url,
                forceRebuild: true
            )
        }
        if let webView = tab.webView,
           prepareExtensionTabSurfaceForDestruction(
               in: tab,
               expectedWebView: webView,
               completion: { shouldNavigate in
                   if shouldNavigate { navigate() }
               }
           ) {
            return true
        }
        navigate()
        return true
    }

    @discardableResult
    func goForwardAcrossSurface(in tab: Tab) -> Bool {
        guard let target = tab.floorpNativeSurfaceForwardTarget,
              let context = context(forSurfaceIdentifier: target.contextIdentifier),
              !tab.isPrivate || context?.hasAccessToPrivateData != false else {
            return false
        }
        weak let sourceWebView = tab.webView
        let navigate = { [weak self, weak tab, weak sourceWebView] in
            guard let self, let tab,
                  tab.floorpNativeSurfaceForwardTarget == target,
                  let currentContext = self.context(
                      forSurfaceIdentifier: target.contextIdentifier
                  ),
                  !tab.isPrivate || currentContext?.hasAccessToPrivateData != false else {
                if tab?.webView === sourceWebView {
                    sourceWebView?.isUserInteractionEnabled = true
                }
                return
            }
            _ = tab.moveFloorpNativeSurfaceHistoryForward()
            tab.preserveFloorpNativeForwardHistoryForNextNavigation()
            self.switchSurface(
                in: tab,
                to: currentContext,
                loading: target.url,
                forceRebuild: true
            )
        }
        if let webView = tab.webView,
           prepareExtensionTabSurfaceForDestruction(
               in: tab,
               expectedWebView: webView,
               completion: { shouldNavigate in
                   if shouldNavigate { navigate() }
               }
           ) {
            return true
        }
        navigate()
        return true
    }

    func tabPropertiesDidChange(_ properties: WKWebExtension.TabChangedProperties, for tab: Tab) {
        let adapter = tabAdapter(for: tab)
        forEachLoadedContext(exposingPrivateData: tab.isPrivate) { context in
            context.didChangeTabProperties(properties, for: adapter)
        }
    }

    func removeLegacyRuntimeData() {
        guard let profile else { return }
        if profile.files.exists("WebExtensions") {
            try? profile.files.remove("WebExtensions")
        }
        let obsoleteNativeRegistry = rootDirectory.appendingPathComponent("registry.json")
        if FileManager.default.fileExists(atPath: obsoleteNativeRegistry.path) {
            try? FileManager.default.removeItem(at: obsoleteNativeRegistry)
        }
        let privateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextensions-private", isDirectory: true)
        if FileManager.default.fileExists(atPath: privateRoot.path) {
            try? FileManager.default.removeItem(at: privateRoot)
        }
        profile.prefs.removeObjectForKey("webExtensions.darkReaderMV3InitialInstallCompleted")
    }

    private func switchSurface(
        in tab: Tab,
        to context: WKWebExtensionContext?,
        loading url: URL,
        forceRebuild: Bool = false
    ) {
        if let context,
           let identifier = identifier(for: context),
           let configuration = extensionSurfaceConfiguration(
               for: context,
               websiteDataStore: tab.floorpNativeWebsiteDataStore,
               isPrivate: tab.isPrivate
           ) {
            tab.replaceWebViewForNativeWebExtension(
                contextIdentifier: identifier,
                configuration: configuration,
                url: url,
                forceRebuild: forceRebuild
            )
        } else {
            tab.replaceWebViewForNativeWebExtension(
                contextIdentifier: nil,
                configuration: nil,
                url: url,
                forceRebuild: forceRebuild
            )
        }
    }

    static func configureExtensionSurface(
        _ configuration: WKWebViewConfiguration,
        websiteDataStore: WKWebsiteDataStore,
        isPrivate _: Bool
    ) {
        configuration.websiteDataStore = websiteDataStore
        // WebKit shares the context template's user-content controller across
        // configuration copies. Every live extension surface needs its own
        // controller so browser helpers can register the same handler names
        // without colliding or routing messages to another tab.
        configuration.userContentController = WKUserContentController()
    }

    private func extensionSurfaceConfiguration(
        for context: WKWebExtensionContext,
        websiteDataStore: WKWebsiteDataStore,
        isPrivate: Bool
    ) -> WKWebViewConfiguration? {
        let liveTemplate = context.webViewConfiguration
        let template: WKWebViewConfiguration?
        if liveTemplate?.websiteDataStore === websiteDataStore {
            template = liveTemplate
        } else {
            template = cleanSurfaceConfigurationTemplates[ObjectIdentifier(context)]
        }
        guard let configuration = template?.copy() as? WKWebViewConfiguration else {
            return nil
        }
        Self.configureExtensionSurface(
            configuration,
            websiteDataStore: websiteDataStore,
            isPrivate: isPrivate
        )
        assert(configuration.webExtensionController === controller)
        assert(configuration.websiteDataStore === websiteDataStore)
        return configuration
    }

    private func identifier(for context: WKWebExtensionContext) -> String? {
        contexts.first(where: { $0.value === context })?.key
    }

    private func currentEnabledIdentifier(for context: WKWebExtensionContext) -> String? {
        guard !isTornDown,
              context.isLoaded,
              let identifier = identifier(for: context),
              !quarantinedContextIdentifiers.contains(identifier),
              contexts[identifier] === context,
              registry.extensions.contains(where: {
                  $0.id == identifier && $0.isEnabled && $0.transactionState != .pendingPurge
              }) else {
            return nil
        }
        return identifier
    }

    private func currentReadyIdentifier(for context: WKWebExtensionContext) -> String? {
        guard let identifier = currentEnabledIdentifier(for: context),
              readyContextIdentifiers.contains(identifier) else { return nil }
        return identifier
    }

    private func currentLifecycleIdentifier(for context: WKWebExtensionContext) -> String? {
        guard let identifier = currentEnabledIdentifier(for: context),
              !lifecycleQuiescedContextIdentifiers.contains(identifier) else { return nil }
        return identifier
    }

    private func context(forSurfaceIdentifier identifier: String?) -> WKWebExtensionContext?? {
        guard let identifier else { return .some(nil) }
        guard readyContextIdentifiers.contains(identifier),
              let context = contexts[identifier], context.isLoaded else { return nil }
        return .some(context)
    }

    private func clearSurfaceHistory(for identifier: String, isPrivate: Bool? = nil) {
        for adapter in tabAdapters.values {
            guard let tab = adapter.tab,
                  isPrivate == nil || tab.isPrivate == isPrivate else { continue }
            tab.removeFloorpNativeSurfaceHistoryEntries(contextIdentifier: identifier)
        }
    }

    private func tabsAffectedByRemoval(
        of context: WKWebExtensionContext,
        identifier: String
    ) -> [Tab] {
        tabManagers.values.compactMap(\.value).flatMap(\.tabs).filter { tab in
            if tab.floorpNativeWebExtensionContextIdentifier == identifier {
                return true
            }
            guard canExpose(tab: tab, to: context),
                  let url = tab.webView?.url ?? tab.url else { return false }
            return context.hasAccess(to: url, in: tabAdapter(for: tab))
        }
    }

    private func tabsEligibleForInjection(of context: WKWebExtensionContext) -> [Tab] {
        tabManagers.values.compactMap(\.value).flatMap(\.tabs).filter { tab in
            guard canExpose(tab: tab, to: context),
                  let url = tab.webView?.url ?? tab.url else { return false }
            return context.hasAccess(to: url, in: tabAdapter(for: tab))
        }
    }

    private func waitForBackgroundReadinessIfRequired(
        in context: WKWebExtensionContext,
        identifier: String,
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        runsLifecycleStabilityHook: Bool = false
    ) async throws {
        guard context.isLoaded,
              context.webExtension.hasBackgroundContent,
              FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
                .requiresBackgroundReadiness == true else { return }
        try Task.checkCancellation()
        if semanticReadinessPagePath(for: identifier) != nil {
            try await waitForBundledExtensionInitialization(
                in: context,
                identifier: identifier,
                timeoutNanoseconds: timeoutNanoseconds,
                runsLifecycleStabilityHook: runsLifecycleStabilityHook
            )
            return
        }
        try await loadBackgroundContent(
            in: context,
            identifier: identifier,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    private func loadBackgroundContent(
        in context: WKWebExtensionContext,
        identifier: String,
        timeoutNanoseconds: UInt64
    ) async throws {
        if let pendingID = pendingBackgroundLoadCallbacks.first(where: {
            $0.value === context
        })?.key {
            backgroundLoadFollowerCounts[pendingID, default: 0] += 1
            defer { releaseBackgroundLoadFollower(id: pendingID) }
            try await waitForPendingBackgroundLoadCallback(
                id: pendingID,
                identifier: identifier,
                timeoutNanoseconds: timeoutNanoseconds
            )
            return
        }
        let gateID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = BackgroundContentLoadGate(continuation: continuation)
                backgroundLoadGates[gateID] = gate
                guard !Task.isCancelled else {
                    resolveBackgroundLoadGate(id: gateID, error: CancellationError())
                    return
                }
                // The Swift timeout resolves only our waiter. WebKit retains
                // its completion handler until the native load actually ends,
                // so keep the context non-unloadable until that callback fires.
                pendingBackgroundLoadCallbacks[gateID] = context
                gate.startTimeout(
                    id: gateID,
                    identifier: identifier,
                    timeoutNanoseconds: timeoutNanoseconds
                ) { [weak self] id, error in
                    self?.resolveBackgroundLoadGate(id: id, error: error)
                }
                context.loadBackgroundContent { [weak self] error in
                    Task { @MainActor in
                        self?.completeBackgroundLoadCallback(id: gateID, error: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.resolveBackgroundLoadGate(id: gateID, error: CancellationError())
            }
        }
    }

    private func waitForStableBackgroundReadinessIfRequired(
        in context: WKWebExtensionContext,
        identifier: String,
        timeoutNanoseconds: UInt64 = 90_000_000_000
    ) async throws {
        guard context.isLoaded,
              context.webExtension.hasBackgroundContent,
              FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
                .requiresBackgroundReadiness == true else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let addition = start.addingReportingOverflow(timeoutNanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue
        let remainingTimeout: () throws -> UInt64 = {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(identifier)
            }
            return deadline - now
        }

        while true {
            synchronizeFocusedWindow(to: context)
            let observedFocusGeneration = actionFocusGeneration
            try await waitForBackgroundReadinessIfRequired(
                in: context,
                identifier: identifier,
                timeoutNanoseconds: try remainingTimeout(),
                runsLifecycleStabilityHook: true
            )
            // uBO itself waits until realm-ruleset promise identity is stable.
            // Only its logical-window/privacy-realm focus changes require
            // another host probe. Dark Reader has no realm-specific startup
            // state, so unrelated focus churn must not starve its readiness.
            if identifier != FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
                || observedFocusGeneration == actionFocusGeneration {
                return
            }
        }
    }

    private func resolveBackgroundLoadGate(id: UUID, error: (any Error)?) {
        backgroundLoadGates.removeValue(forKey: id)?.resolve(error)
    }

    private func completeBackgroundLoadCallback(id: UUID, error: (any Error)?) {
        if backgroundLoadFollowerCounts[id, default: 0] > 0 {
            backgroundLoadCompletionResults[id] = error.map {
                BackgroundContentLoadCompletion.failed($0)
            } ?? .succeeded
        }
        pendingBackgroundLoadCallbacks.removeValue(forKey: id)
        resolveBackgroundLoadGate(id: id, error: error)
    }

    private func releaseBackgroundLoadFollower(id: UUID) {
        guard let count = backgroundLoadFollowerCounts[id] else { return }
        if count == 1 {
            backgroundLoadFollowerCounts.removeValue(forKey: id)
            backgroundLoadCompletionResults.removeValue(forKey: id)
        } else {
            backgroundLoadFollowerCounts[id] = count - 1
        }
    }

    private func hasPendingBackgroundLoadCallback(
        for context: WKWebExtensionContext
    ) -> Bool {
        pendingBackgroundLoadCallbacks.values.contains { $0 === context }
    }

    private func waitForPendingBackgroundLoadCallback(
        id: UUID,
        identifier: String,
        timeoutNanoseconds: UInt64
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let addition = start.addingReportingOverflow(timeoutNanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue
        while pendingBackgroundLoadCallbacks[id] != nil {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(identifier)
            }
            try await Task.sleep(nanoseconds: min(25_000_000, deadline - now))
        }
        guard let result = backgroundLoadCompletionResults[id] else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        switch result {
        case .succeeded:
            return
        case .failed(let error):
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private func waitForBundledExtensionInitialization(
        in context: WKWebExtensionContext,
        identifier: String,
        timeoutNanoseconds: UInt64,
        runsLifecycleStabilityHook: Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let addition = start.addingReportingOverflow(timeoutNanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue
        let remainingTimeout: () throws -> UInt64 = {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw FloorpNativeWebExtensionError.backgroundContentStartupTimedOut(identifier)
            }
            return deadline - now
        }

        guard let readinessPagePath = semanticReadinessPagePath(for: identifier),
              let catalogItem = FloorpNativeWebExtensionCatalog.item(identifier: identifier) else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let readinessURL = context.baseURL.appendingPathComponent(readinessPagePath)
        guard readinessURL.scheme == context.baseURL.scheme,
              readinessURL.host == context.baseURL.host else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        let readinessScript: String
        if identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier {
            readinessScript = """
            const initial = await browser.runtime.sendMessage({ what: 'floorpReadiness' });
            if (initial?.foregroundReconciliationRequired !== true) {
                return initial;
            }
            const module = await import(browser.runtime.getURL('js/floorp-reconcile.js'));
            const reconciled = await module.reconcileProtection();
            if (reconciled?.ready !== true) {
                return reconciled;
            }
            return await browser.runtime.sendMessage({ what: 'floorpReadiness' });
            """
        } else {
            readinessScript =
                "return await browser.runtime.sendMessage({ what: 'floorpReadiness' });"
        }

        var attempt = 0
        var didLoadBackgroundContent = false
        while true {
            try Task.checkCancellation()
            guard context.isLoaded,
                  let configuration = context.webViewConfiguration else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
            attempt += 1
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            let remainingBudget = try remainingTimeout()
            // uBO Lite can legitimately spend longer than 15 seconds compiling
            // and enabling its DNR rulesets on a cold launch. A timed-out
            // callAsyncJavaScript callback cannot be abandoned or retried
            // safely, so give its fail-closed probe the full bounded deadline.
            // Delivered WebKit errors still retry below without extending it.
            let attemptBudget = identifier
                == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
                ? remainingBudget
                : min(remainingBudget, 15_000_000_000)
            let attemptAddition = attemptStart.addingReportingOverflow(attemptBudget)
            let attemptDeadline = attemptAddition.overflow
                ? UInt64.max
                : attemptAddition.partialValue
            let remainingAttemptTimeout: () throws -> UInt64 = {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < attemptDeadline else {
                    throw FloorpNativeWebExtensionError
                        .backgroundContentStartupTimedOut(identifier)
                }
                return attemptDeadline - now
            }
            // Keep WebKit's extension-page configuration intact and instantiate
            // the page before explicitly waking the MV3 background. Replacing
            // its content controller, or constructing the first detached page
            // after that wake, can fail in iOS 26's private Gestures state machine.
            let readinessSurface = BackgroundReadinessSurface(
                context: context,
                configuration: configuration
            )
            let probe = readinessSurface.probe
            let readinessOperationID = UUID()
            // A semantic probe can run outside a lifecycle transition (for
            // example, navigation preflight or action presentation). Register
            // it before the first WebKit await so a concurrent disable/update
            // cannot unload its context out from under the native callback.
            activeBackgroundReadinessOperations[readinessOperationID] = context
            let result: Any?
            do {
                try await probe.load(
                    readinessURL,
                    in: readinessSurface.webView,
                    identifier: identifier,
                    timeoutNanoseconds: min(
                        try remainingAttemptTimeout(),
                        5_000_000_000
                    )
                )
                if !didLoadBackgroundContent {
                    try await loadBackgroundContent(
                        in: context,
                        identifier: identifier,
                        timeoutNanoseconds: try remainingTimeout()
                    )
                    didLoadBackgroundContent = true
                }
#if DEBUG || TESTING
                if let injectedError = backgroundReadinessTransientFailureHookForTesting?(
                    identifier,
                    attempt
                ) {
                    throw injectedError
                }
#endif
                // Recreate the WebView for every attempt: WebKit can evict either
                // this page or the nonpersistent background page while an
                // extension is still completing asynchronous startup work.
                result = try await {
#if DEBUG || TESTING
                    if let injectedResponse = backgroundReadinessResponseHookForTesting?(
                        identifier,
                        attempt
                    ) {
                        return injectedResponse
                    }
                    let functionBody = backgroundReadinessJavaScriptOverrideForTesting?(
                        identifier,
                        attempt,
                        readinessSurface.webView
                    ) ?? readinessScript
#else
                    let functionBody = readinessScript
#endif
                    return try await probe.callAsyncJavaScript(
                        functionBody,
                        in: readinessSurface.webView,
                        identifier: identifier,
                        timeoutNanoseconds: try remainingAttemptTimeout()
                    )
                }()
            } catch {
                let shouldRetry = shouldRetryBundledExtensionReadinessProbe(after: error)
                if probe.requiresProcessLifetimeRetention {
                    // A timed-out or cancelled WebKit operation still owns a
                    // native callback. Keep the complete page/probe pair alive
                    // and untouched until process exit.
                    retiredBackgroundReadinessSurfaces.append(readinessSurface)
                } else {
                    // A delivered WebKit error has completed its callback. It
                    // may be retryable, but retaining that completed attempt
                    // would exhaust WebContent resources across later retries.
                    probe.invalidate()
                }
                activeBackgroundReadinessOperations.removeValue(
                    forKey: readinessOperationID
                )
                await Task.yield()
                await Task.yield()
                guard shouldRetry,
                      !hasUnfinishedWebKitOperation(for: context),
                      (try? remainingTimeout()) != nil else {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            probe.invalidate()
            activeBackgroundReadinessOperations.removeValue(forKey: readinessOperationID)
            await Task.yield()
            await Task.yield()
            try await Task.sleep(nanoseconds: min(try remainingTimeout(), 100_000_000))

            // A concrete negative response is the extension reporting a real
            // startup failure. Only a failed or vanished WebKit probe is
            // transient; semantic failures stay fail-closed.
            let readiness = result as? [String: Any]
            guard readiness?["ready"] as? Bool == true,
                  readiness?["version"] as? String == catalogItem.expectedVersion,
                  readiness?["foregroundReconciliationRequired"] as? Bool != true else {
                let detail = readiness?["error"] as? String
                    ?? "missing or mismatched readiness response"
                throw FloorpNativeWebExtensionError.unsupportedOperation(
                    "\(catalogItem.name) background readiness: \(detail)"
                )
            }
#if DEBUG || TESTING
            if runsLifecycleStabilityHook {
                backgroundReadinessAttemptHookForTesting?(identifier)
            }
#endif
            try Task.checkCancellation()
            return
        }
    }

    private func semanticReadinessPagePath(for identifier: String) -> String? {
        switch identifier {
        case FloorpNativeWebExtensionCatalog.darkReader.identifier:
            return "floorp-readiness.html"
        case FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier:
            return "web_accessible_resources/noop.html"
        default:
            return nil
        }
    }

    private func shouldRetryBundledExtensionReadinessProbe(
        after error: any Error
    ) -> Bool {
        if error is CancellationError { return false }
        if let hostError = error as? FloorpNativeWebExtensionError {
            switch hostError {
            case .backgroundContentStartupTimedOut, .hostUnavailable:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain else { return false }
        if let code = WKError.Code(rawValue: nsError.code) {
            switch code {
            case .unknown, .webContentProcessTerminated, .webViewInvalidated:
                // Codes are stable across the user's locale. These failures
                // mean the probe disappeared rather than uBO reporting a bad
                // startup.
                return true
            default:
                break
            }
        }
        // Older WebKit builds have reported the same transient bridge loss as
        // a generic JavaScript error. Keep a narrow compatibility fallback;
        // the code-based cases above remain the primary classifier.
        let message = nsError.localizedDescription.lowercased()
        let transientFragments = ["jscontextref", "invalidtransition"]
        return transientFragments.contains(where: message.contains)
    }

    private func hasRetiredBackgroundReadinessSurface(
        for context: WKWebExtensionContext
    ) -> Bool {
        retiredBackgroundReadinessSurfaces.contains { $0.context === context }
    }

    private func hasUnfinishedWebKitOperation(
        for context: WKWebExtensionContext
    ) -> Bool {
        hasRetiredBackgroundReadinessSurface(for: context)
            || hasPendingBackgroundLoadCallback(for: context)
            || activeBackgroundReadinessOperations.values.contains { $0 === context }
            || activeSurfaceCloseOperations.values.contains { $0 === context }
    }

    private func setContextReady(_ isReady: Bool, identifier: String) {
        if !isReady {
            extensionTabSurfaceCloseRequests.values
                .filter { $0.identifier == identifier }
                .forEach {
                    resolveExtensionTabSurfaceCloseRequest(
                        $0,
                        shouldProceed: $0.forceOnFailure,
                        dismissAlert: true
                    )
                }
            verifiedNavigationReadinessRealms.removeValue(forKey: identifier)
            if let popupToken = managedActionPopups[identifier]?.token {
                dismissManagedActionPopups { $0.token == popupToken }
            }
            dismissPresentedSurfaces(identifier: identifier)
        }
        let changed: Bool
        if isReady, !quarantinedContextIdentifiers.contains(identifier) {
            changed = readyContextIdentifiers.insert(identifier).inserted
        } else {
            changed = readyContextIdentifiers.remove(identifier) != nil
            actionOrigins.removeValue(forKey: identifier)
        }
        if changed {
            publishExtensionTopologyChange()
        }
    }

    private func publishExtensionTopologyChange() {
        extensionTopologyGeneration &+= 1
        NotificationCenter.default.post(
            name: .floorpNativeWebExtensionActionsDidChange,
            object: self
        )
    }

    private func setContextLifecycleQuiesced(_ isQuiesced: Bool, identifier: String) {
        if isQuiesced {
            lifecycleQuiescedContextIdentifiers.insert(identifier)
        } else {
            lifecycleQuiescedContextIdentifiers.remove(identifier)
        }
    }

    private func loadContext(
        _ context: WKWebExtensionContext,
        identifier: String
    ) throws {
        guard !wasContextConsumedInThisController(context.uniqueIdentifier) else {
            setContextLifecycleQuiesced(true, identifier: identifier)
            throw FloorpNativeWebExtensionError.restartRequired("Loading this extension again")
        }
        hasEverAttemptedContextLoad = true
        markContextConsumed(context)
        setContextLifecycleQuiesced(false, identifier: identifier)
        cleanSurfaceConfigurationTemplates.removeValue(forKey: ObjectIdentifier(context))
        do {
            try controller.load(context)
            guard let configuration = context.webViewConfiguration?.copy()
                as? WKWebViewConfiguration else {
                throw FloorpNativeWebExtensionError.hostUnavailable
            }
            cleanSurfaceConfigurationTemplates[ObjectIdentifier(context)] = configuration
        } catch {
            setContextLifecycleQuiesced(true, identifier: identifier)
            throw error
        }
    }

    private func beginTransition(for identifier: String) throws -> Int {
        guard !isTornDown, !Task.isCancelled else {
            throw CancellationError()
        }
        guard activeTransitions.insert(identifier).inserted else {
            throw FloorpNativeWebExtensionError.operationAlreadyInProgress(identifier)
        }
        return lifecycleGeneration
    }

    private func endTransition(for identifier: String) {
        activeTransitions.remove(identifier)
    }

    private func transitionIsValid(for identifier: String, generation: Int) -> Bool {
        transitionBelongsToCurrentLifecycle(for: identifier, generation: generation)
            && !Task.isCancelled
    }

    private func transitionBelongsToCurrentLifecycle(
        for identifier: String,
        generation: Int
    ) -> Bool {
        !isTornDown
            && lifecycleGeneration == generation
            && activeTransitions.contains(identifier)
    }

    private func validateTransition(for identifier: String, generation: Int) throws {
        guard transitionIsValid(for: identifier, generation: generation) else {
            throw CancellationError()
        }
    }

    private func reloadForNewlyAvailableExtension(in tabs: [Tab]) {
        for tab in tabs where isManagedTab(tab)
            && tab.floorpNativeWebExtensionContextIdentifier == nil {
            tab.reload()
        }
    }

    private func isManagedTab(_ tab: Tab) -> Bool {
        announcedTabs.contains(ObjectIdentifier(tab))
            && tabManagers[tab.windowUUID]?.value?.tabs.contains(where: { $0 === tab }) == true
    }

    private func beginActionInvocation(for tab: Tab) -> Int {
        let key = ObjectIdentifier(tab)
        let generation = (actionInvocationGenerations[key] ?? 0) &+ 1
        actionInvocationGenerations[key] = generation
        return generation
    }

    private func invalidateActionInvocation(for tab: Tab) {
        let key = ObjectIdentifier(tab)
        actionInvocationGenerations[key] = (actionInvocationGenerations[key] ?? 0) &+ 1
    }

    private func actionInvocationIsCurrent(
        _ invocation: ActionInvocation,
        for tab: Tab
    ) -> Bool {
        guard let manager = tabManagers[invocation.sourceWindowUUID]?.value else {
            return false
        }
        return ObjectIdentifier(tab) == invocation.sourceTabIdentifier
            && tab.windowUUID == invocation.sourceWindowUUID
            && tab.isPrivate == invocation.sourceIsPrivate
            && actionInvocationGenerations[invocation.sourceTabIdentifier]
                == invocation.generation
            && actionFocusGeneration == invocation.focusGeneration
            && extensionTopologyGeneration == invocation.topologyGeneration
            && ObjectIdentifier(manager) == invocation.sourceManagerIdentifier
    }

    private func finishActionInvocation(_ invocation: ActionInvocation, for tab: Tab) {
        guard ObjectIdentifier(tab) == invocation.sourceTabIdentifier,
              actionInvocationGenerations[invocation.sourceTabIdentifier]
                == invocation.generation else { return }
        actionInvocationGenerations[invocation.sourceTabIdentifier] =
            invocation.generation &+ 1
    }

    private func setTrackedFocusedWindow(_ window: WindowKey?) {
        guard lastFocusedWindow != window else { return }
        actionFocusGeneration &+= 1
        lastFocusedWindow = window
        if let window {
            // uBO resets its per-realm Safari workaround whenever static
            // rulesets change. A logical focus transition is the point where
            // WebKit publishes that realm to the background page, so require
            // the first subsequent navigation to cross the readiness barrier
            // again. Same-window, same-realm browsing remains cached.
            invalidateUBlockOriginLiteNavigationReadiness(isPrivate: window.isPrivate)
        }
    }

    private func invalidateUBlockOriginLiteNavigationReadiness(isPrivate: Bool) {
        // Advance even when the realm is not currently cached. An invalidation
        // can race an in-flight probe just before that probe inserts its result.
        navigationReadinessGeneration &+= 1
        verifiedNavigationReadinessRealms[
            FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        ]?.remove(isPrivate)
    }

    private func mergingTabs(_ groups: [Tab]...) -> [Tab] {
        var merged = [ObjectIdentifier: Tab]()
        for tab in groups.flatMap({ $0 }) {
            merged[ObjectIdentifier(tab)] = tab
        }
        return Array(merged.values)
    }

    private func focusAvailableWindow(excludingWindowUUID: WindowUUID? = nil) {
        let candidates = announcedWindows.filter {
            $0.windowUUID != excludingWindowUUID
                && !tabs(for: $0.windowUUID, isPrivate: $0.isPrivate).isEmpty
                && isEligibleForExtensionFocus(windowUUID: $0.windowUUID)
        }.sorted { lhs, rhs in
            let lhsRank = focusReplacementRank(for: lhs)
            let rhsRank = focusReplacementRank(for: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.windowUUID != rhs.windowUUID {
                return lhs.windowUUID.uuidString < rhs.windowUUID.uuidString
            }
            return !lhs.isPrivate && rhs.isPrivate
        }
        let replacement = candidates.first(where: { key in
            guard let selectedTab = tabManager(for: key.windowUUID)?.selectedTab else {
                return false
            }
            return selectedTab.isPrivate == key.isPrivate
        }) ?? candidates.first
        setTrackedFocusedWindow(replacement)
        focusWasExplicitlyCleared = replacement == nil
        synchronizeFocusedWindows()
    }

    private func isEligibleForExtensionFocus(windowUUID: WindowUUID) -> Bool {
        guard let activationState = sceneActivationState(for: windowUUID) else {
            // Unit tests and pre-scene bootstrap have no connected UIScene yet.
            return true
        }
        return activationState == .foregroundActive
    }

    private func focusReplacementRank(for key: WindowKey) -> Int {
        let activationRank = switch sceneActivationState(for: key.windowUUID) {
        case .foregroundActive: 0
        case .foregroundInactive: 2
        case .background: 4
        case .unattached: 6
        case nil: 3
        @unknown default: 5
        }
        let selectedPrivacyPenalty = tabManager(for: key.windowUUID)?.selectedTab?.isPrivate
            == key.isPrivate ? 0 : 1
        return activationRank + selectedPrivacyPenalty
    }

    private func sceneActivationState(for windowUUID: WindowUUID) -> UIScene.ActivationState? {
        connectedScene(for: windowUUID)?.activationState
    }

    private func connectedScene(for windowUUID: WindowUUID) -> UIScene? {
        UIApplication.shared.connectedScenes.first { scene in
            (scene.delegate as? SceneDelegate)?.sceneCoordinator?.windowUUID == windowUUID
        }
    }

    private func openURLInBrowser(
        _ url: URL,
        isPrivate: Bool,
        preferredWindowUUID: WindowUUID? = nil
    ) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let sourceWindow = preferredWindowUUID.flatMap { windowUUID -> (any TabManager)? in
            guard let manager = tabManager(for: windowUUID),
                  manager.tabs.contains(where: { $0.isPrivate == isPrivate }) else { return nil }
            return manager
        }
        let focusedWindow = lastFocusedWindow.flatMap { key -> (any TabManager)? in
            guard key.isPrivate == isPrivate else { return nil }
            return tabManager(for: key.windowUUID)
        }
        guard let manager = sourceWindow
            ?? focusedWindow
            ?? tabManagers.values.compactMap(\.value).first(where: { manager in
                manager.tabs.contains(where: { $0.isPrivate == isPrivate })
            }) else {
            return
        }
        let parent = activeTab(for: manager.windowUUID, isPrivate: isPrivate)
        let tab = manager.addTab(
            nil as URLRequest?,
            afterTab: parent,
            zombie: false,
            isPrivate: isPrivate
        )
        announceTabIfNeeded(tab)
        load(url: url, in: tab)
        manager.selectTab(tab)
    }

    private func reloadAfterRemovingExtension(from tabs: [Tab], identifier: String) {
        for tab in tabs where isManagedTab(tab) {
            if tab.floorpNativeWebExtensionContextIdentifier == identifier,
               let blankURL = URL(string: "about:blank") {
                switchSurface(in: tab, to: nil, loading: blankURL)
            } else {
                tab.reload()
            }
        }
    }

    private func reloadAfterRestoringExtension(
        _ context: WKWebExtensionContext,
        in tabs: [Tab],
        identifier: String
    ) {
        for tab in tabs where isManagedTab(tab) {
            if tab.floorpNativeWebExtensionContextIdentifier == identifier,
               let url = tab.webView?.url ?? tab.url {
                switchSurface(in: tab, to: context, loading: url, forceRebuild: true)
            } else {
                tab.reload()
            }
        }
    }

    private func failClosedAfterReadinessFailure(
        _ context: WKWebExtensionContext,
        in tabs: [Tab],
        identifier: String
    ) {
        setContextReady(false, identifier: identifier)
        let tabsToClean = mergingTabs(
            tabs,
            tabsAffectedByRemoval(of: context, identifier: identifier)
        )
        _ = unloadOrQuarantine(context, identifier: identifier)
        reloadAfterRemovingExtension(from: tabsToClean, identifier: identifier)
        clearSurfaceHistory(for: identifier)
    }

    private func failClosedAfterRestorationFailure(
        _ context: WKWebExtensionContext,
        in tabs: [Tab],
        identifier: String,
        desiredRecord: FloorpNativeWebExtensionRecord,
        operationError: any Error,
        restorationError: any Error
    ) {
        failClosedAfterReadinessFailure(
            context,
            in: tabs,
            identifier: identifier
        )
        var failedRecord = desiredRecord
        failedRecord.transactionState = .stable
        failedRecord.rollback = nil
        failedRecord.lastError = "Restoration failed: \(restorationError.localizedDescription) "
            + "Original operation failed: \(operationError.localizedDescription). "
            + "Restart Floorp before using this extension."
        failedRecord.runtimeDiagnostics = [FloorpNativeWebExtensionDiagnostic(
            phase: .host,
            error: restorationError as NSError
        )]
        replaceRecord(failedRecord)
        logger.log(
            "Floorp: native WebExtension \(identifier) operation failed: \(operationError); "
                + "restoration also failed and was closed safely: \(restorationError)",
            level: .warning,
            category: .setup
        )
    }

    @discardableResult
    private func unloadOrQuarantine(
        _ context: WKWebExtensionContext,
        identifier: String
    ) -> Bool {
        setContextLifecycleQuiesced(true, identifier: identifier)
        if hasUnfinishedWebKitOperation(for: context) {
            logger.log(
                "Floorp: deferred native WebExtension \(identifier) unload because a WebKit "
                    + "operation is still finishing; restart required",
                level: .warning,
                category: .setup
            )
            quarantinedContextIdentifiers.insert(identifier)
            setContextReady(false, identifier: identifier)
            NotificationCenter.default.removeObserver(self, name: nil, object: context)
            // WebContent can still send API messages owned by the unfinished
            // operation. Keep WebKit's authorization snapshot unchanged so its
            // UIProcess validators do not reject those delayed messages.
            return false
        }
        // Permission notifications emitted synchronously by unload belong to
        // the retiring runtime and must not replace the durable pre-unload
        // snapshot. Queued direct saves are rejected by persistPermissionState.
        NotificationCenter.default.removeObserver(self, name: nil, object: context)
        guard context.isLoaded else {
            quarantinedContextIdentifiers.remove(identifier)
            cleanSurfaceConfigurationTemplates.removeValue(forKey: ObjectIdentifier(context))
            return true
        }
        do {
            try controller.unload(context)
        } catch {
            logger.log(
                "Floorp: failed to unload native WebExtension \(identifier); "
                    + "restart required: \(error)",
                level: .warning,
                category: .setup
            )
        }
        guard !context.isLoaded else {
            quarantinedContextIdentifiers.insert(identifier)
            setContextReady(false, identifier: identifier)
            context.hasAccessToPrivateData = false
            context.grantedPermissions = [:]
            context.grantedPermissionMatchPatterns = [:]
            return false
        }
        quarantinedContextIdentifiers.remove(identifier)
        cleanSurfaceConfigurationTemplates.removeValue(forKey: ObjectIdentifier(context))
        return true
    }

    private func markContextConsumed(_ context: WKWebExtensionContext) {
        Self.consumedContextKeys.insert(ConsumedContextKey(
            controllerIdentifier: controllerIdentifier,
            profileIdentifier: profileIdentifier,
            contextIdentifier: context.uniqueIdentifier
        ))
    }

    private func wasContextConsumedInThisController(_ contextIdentifier: String) -> Bool {
        Self.consumedContextKeys.contains(ConsumedContextKey(
            controllerIdentifier: controllerIdentifier,
            profileIdentifier: profileIdentifier,
            contextIdentifier: contextIdentifier
        ))
    }

    private func removePrivateExtensionState(identifier: String) {
        for manager in tabManagers.values.compactMap(\.value) {
            for tab in manager.privateTabs where isManagedTab(tab) {
                if tab.floorpNativeWebExtensionContextIdentifier == identifier,
                   let blankURL = URL(string: "about:blank") {
                    switchSurface(in: tab, to: nil, loading: blankURL)
                } else {
                    tab.reload()
                }
            }
        }
        clearSurfaceHistory(for: identifier, isPrivate: true)
    }

    private func announceWindowIfNeeded(windowUUID: WindowUUID, isPrivate: Bool) {
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        guard announcedWindows.insert(key).inserted else { return }
        let adapter = windowAdapter(for: windowUUID, isPrivate: isPrivate)
        forEachLoadedContext(exposingPrivateData: isPrivate) { context in
            context.didOpenWindow(adapter)
        }
        synchronizeFocusedWindows()
    }

    /// Publishes private windows and tabs to one context when the user grants
    /// private access after that context has already loaded. The controller's
    /// initial delegate snapshot cannot retroactively add this topology.
    private func announcePrivateTopology(to context: WKWebExtensionContext) {
        guard context.hasAccessToPrivateData,
              currentLifecycleIdentifier(for: context) != nil else { return }
        for manager in tabManagers.values.compactMap(\.value) {
            let windowKey = WindowKey(windowUUID: manager.windowUUID, isPrivate: true)
            guard announcedWindows.contains(windowKey) else { continue }
            context.didOpenWindow(windowAdapter(for: manager.windowUUID, isPrivate: true))
            for tab in manager.privateTabs where announcedTabs.contains(ObjectIdentifier(tab)) {
                context.didOpenTab(tabAdapter(for: tab))
            }
            if let activeTab = activeTab(for: manager.windowUUID, isPrivate: true) {
                context.didActivateTab(tabAdapter(for: activeTab), previousActiveTab: nil)
            }
        }
    }

    /// Removes the private half of the logical browser topology from one
    /// context before revoking its private-data access. Closing tabs before
    /// their logical windows mirrors normal scene teardown ordering.
    private func withdrawPrivateTopology(from context: WKWebExtensionContext) {
        guard context.hasAccessToPrivateData,
              currentLifecycleIdentifier(for: context) != nil else { return }
        for manager in tabManagers.values.compactMap(\.value) {
            let windowKey = WindowKey(windowUUID: manager.windowUUID, isPrivate: true)
            guard announcedWindows.contains(windowKey) else { continue }
            for tab in manager.privateTabs where announcedTabs.contains(ObjectIdentifier(tab)) {
                context.didCloseTab(tabAdapter(for: tab), windowIsClosing: true)
            }
            context.didCloseWindow(windowAdapter(for: manager.windowUUID, isPrivate: true))
        }
    }

    func announceTabIfNeeded(_ tab: Tab) {
        announceWindowIfNeeded(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        let key = ObjectIdentifier(tab)
        guard announcedTabs.insert(key).inserted else { return }
        let windowKey = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        if lastActiveTabs[windowKey] == nil {
            lastActiveTabs[windowKey] = key
        }
        let adapter = tabAdapter(for: tab)
        forEachLoadedContext(exposingPrivateData: tab.isPrivate) { context in
            context.didOpenTab(adapter)
        }
        synchronizeFocusedWindows()
    }

    private func didActivate(_ tab: Tab) {
        dismissManagedActionPopups { popup in
            guard let sourceTab = popup.sourceTab else { return true }
            // A restore or selection callback from a background UIScene must
            // not close the popup in the foreground scene. `focus` handles a
            // real scene-focus transfer; a selection in the same physical
            // window still invalidates the old tab's popup immediately.
            return sourceTab.windowUUID == tab.windowUUID && sourceTab !== tab
        }
        let key = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        let tabKey = ObjectIdentifier(tab)
        let previousActiveTabKey = lastActiveTabs[key]
        // Tab activation can occur in a background UIScene. SceneDelegate calls
        // `focus` when a scene actually becomes active; only a privacy switch in
        // the already-focused physical window may update focus from this callback.
        let activationState = sceneActivationState(for: tab.windowUUID)
        let canInitializeFocus = lastFocusedWindow == nil
            && !focusWasExplicitlyCleared
            && activationState == nil
        let canUpdateFocus = activationState == .foregroundActive
            || canInitializeFocus
            || lastFocusedWindow?.windowUUID == tab.windowUUID
        let focusChanged = canUpdateFocus && lastFocusedWindow != key
        let activeTabChanged = lastActiveTabs[key] != tabKey
        if activeTabChanged, let previousActiveTabKey {
            actionInvocationGenerations[previousActiveTabKey] =
                (actionInvocationGenerations[previousActiveTabKey] ?? 0) &+ 1
            navigationPreparationGenerations[previousActiveTabKey] =
                (navigationPreparationGenerations[previousActiveTabKey] ?? 0) &+ 1
        }
        announceTabIfNeeded(tab)
        lastActiveTabs[key] = tabKey
        if canUpdateFocus {
            setTrackedFocusedWindow(key)
            focusWasExplicitlyCleared = false
        }
        let adapter = tabAdapter(for: tab)
        let previousAdapter: FloorpNativeWebExtensionTab? = previousActiveTabKey.flatMap { previousKey in
            guard previousKey != tabKey,
                  announcedTabs.contains(previousKey),
                  let adapter = tabAdapters[previousKey],
                  adapter.tab != nil else { return nil }
            return adapter
        }
        if activeTabChanged {
            if canUpdateFocus {
                invalidateUBlockOriginLiteNavigationReadiness(isPrivate: tab.isPrivate)
            }
            notifyDidActivateTab(adapter, previousActiveTab: previousAdapter)
        }
        if focusChanged || activeTabChanged {
            synchronizeFocusedWindows()
        }
    }

    private func forEachLoadedContext(
        exposingPrivateData isPrivate: Bool,
        _ body: (WKWebExtensionContext) -> Void
    ) {
        for context in contexts.values where
            (isPublishingTeardownLifecycle
                ? context.isLoaded
                : currentLifecycleIdentifier(for: context) != nil)
            && (!isPrivate || context.hasAccessToPrivateData) {
            body(context)
        }
    }

    private func synchronizeFocusedWindows() {
        forEachLoadedContext(exposingPrivateData: false) { context in
            context.didFocusWindow(focusedWindow(for: context))
        }
    }

    private func synchronizeFocusedWindow(to context: WKWebExtensionContext) {
        guard currentLifecycleIdentifier(for: context) != nil else { return }
        context.didFocusWindow(focusedWindow(for: context))
    }

    private func notifyDidCloseTab(
        _ tab: FloorpNativeWebExtensionTab,
        windowIsClosing: Bool
    ) {
        let isPrivate = tab.tab?.isPrivate == true
        forEachLoadedContext(exposingPrivateData: isPrivate) { context in
            context.didCloseTab(tab, windowIsClosing: windowIsClosing)
        }
    }

    private func notifyDidCloseWindow(_ window: FloorpNativeWebExtensionWindow) {
        forEachLoadedContext(exposingPrivateData: window.isPrivateBrowsing) { context in
            context.didCloseWindow(window)
        }
    }

    private func notifyDidActivateTab(
        _ tab: FloorpNativeWebExtensionTab,
        previousActiveTab: FloorpNativeWebExtensionTab?
    ) {
        let isPrivate = tab.tab?.isPrivate == true
        forEachLoadedContext(exposingPrivateData: isPrivate) { context in
            context.didActivateTab(tab, previousActiveTab: previousActiveTab)
        }
    }

    private func makeContext(for record: FloorpNativeWebExtensionRecord) async throws -> WKWebExtensionContext {
        let package = try await installer.verifiedPackage(for: record)
        guard package.sha256 == record.sha256 else {
            throw FloorpNativeWebExtensionError.packageDigestMismatch(
                expected: record.sha256,
                actual: package.sha256
            )
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        let actualVersion = webExtension.version ?? "0"
        guard actualVersion == record.installedVersion else {
            throw FloorpNativeWebExtensionError.packageVersionMismatch(
                expected: record.installedVersion,
                actual: actualVersion
            )
        }
        let diagnostics = Self.diagnostics(webExtension.errors, phase: .package)
        if let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id) {
            let unapproved = diagnostics.filter { !item.approvedParseErrorCodes.contains($0.code) }
            if !unapproved.isEmpty {
                throw FloorpNativeWebExtensionError.unapprovedPackageDiagnostics(unapproved)
            }
        }
        updateRecord(record.id) { $0.packageDiagnostics = diagnostics }
        return makeContext(webExtension: webExtension, record: record)
    }

    private func prepareBundledExtension(identifier: String) async throws -> PreparedExtension {
        guard let item = FloorpNativeWebExtensionCatalog.item(identifier: identifier) else {
            throw FloorpNativeWebExtensionError.catalogResourceMissing(identifier)
        }
        let package = try await installer.verifiedBundledPackage(for: item)
        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        let actualVersion = webExtension.version ?? "0"
        guard actualVersion == item.expectedVersion else {
            throw FloorpNativeWebExtensionError.packageVersionMismatch(
                expected: item.expectedVersion,
                actual: actualVersion
            )
        }
        let diagnostics = Self.diagnostics(webExtension.errors, phase: .package)
        let unapproved = diagnostics.filter { !item.approvedParseErrorCodes.contains($0.code) }
        guard unapproved.isEmpty else {
            throw FloorpNativeWebExtensionError.unapprovedPackageDiagnostics(unapproved)
        }
        return PreparedExtension(
            item: item,
            package: package,
            webExtension: webExtension,
            diagnostics: diagnostics
        )
    }

    private func makeContext(
        webExtension: WKWebExtension,
        record: FloorpNativeWebExtensionRecord
    ) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.contextIdentifier
        let baseURLScheme = FloorpNativeWebExtensionCatalog.item(identifier: record.id)?.baseURLScheme
            ?? "webkit-extension"
        context.baseURL = URL(string: "\(baseURLScheme)://\(record.baseURLHost)/")!
        context.hasAccessToPrivateData = record.hasPrivateAccess
        context.hasRequestedOptionalAccessToAllHosts =
            record.hasRequestedOptionalAccessToAllHosts
        context.unsupportedAPIs = FloorpNativeWebExtensionCatalog.item(identifier: record.id)?
            .disabledAPIs ?? [
                "browser.runtime.connectNative",
                "browser.runtime.sendNativeMessage"
            ]
#if DEBUG
        context.isInspectable = true
        context.inspectionName = record.displayName
#endif
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: record.grantedPermissions
                .filter { $0.expiration > Date() }
                .map {
                    (WKWebExtension.Permission(rawValue: $0.value), $0.expiration)
                }
        )
        context.deniedPermissions = Dictionary(
            uniqueKeysWithValues: record.deniedPermissions
                .filter { $0.expiration > Date() }
                .map {
                    (WKWebExtension.Permission(rawValue: $0.value), $0.expiration)
                }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: record.grantedMatchPatterns.compactMap { decision in
                guard decision.expiration > Date(),
                      let pattern = try? WKWebExtension.MatchPattern(string: decision.value) else { return nil }
                return (pattern, decision.expiration)
            }
        )
        context.deniedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: record.deniedMatchPatterns.compactMap { decision in
                guard decision.expiration > Date(),
                      let pattern = try? WKWebExtension.MatchPattern(string: decision.value) else { return nil }
                return (pattern, decision.expiration)
            }
        )
        return context
    }

    private func observeContextChanges(in context: WKWebExtensionContext) {
        let names: [Notification.Name] = [
            WKWebExtensionContext.errorsDidUpdateNotification,
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification
        ]
        names.forEach { name in
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(permissionStateDidChange(_:)),
                name: name,
                object: context
            )
        }
    }

    @objc
    private func permissionStateDidChange(_ notification: Notification) {
        guard let context = notification.object as? WKWebExtensionContext else { return }
        if notification.name == WKWebExtensionContext.errorsDidUpdateNotification {
            persistRuntimeDiagnostics(for: context)
        } else {
            persistPermissionState(for: context)
        }
    }

    private func persistPermissionState(for context: WKWebExtensionContext) {
        guard !isTornDown,
              context.isLoaded,
              let identifier = identifier(for: context),
              contexts[identifier] === context,
              !quarantinedContextIdentifiers.contains(identifier),
              let record = registry.extensions.first(where: { $0.id == identifier }),
              record.transactionState != .pendingPurge,
              record.isEnabled || activeTransitions.contains(identifier) else { return }
        updateRecord(identifier) { record in
            Self.synchronizePermissionState(from: context, to: &record)
        }
        try? persistRegistry()
    }

    private static func synchronizePermissionState(
        from context: WKWebExtensionContext,
        to record: inout FloorpNativeWebExtensionRecord
    ) {
        record.grantedPermissions = context.grantedPermissions.map {
            FloorpNativeWebExtensionPermissionDecision(value: $0.key.rawValue, expiration: $0.value)
        }.sorted { $0.value < $1.value }
        record.deniedPermissions = context.deniedPermissions.map {
            FloorpNativeWebExtensionPermissionDecision(value: $0.key.rawValue, expiration: $0.value)
        }.sorted { $0.value < $1.value }
        record.grantedMatchPatterns = context.grantedPermissionMatchPatterns.map {
            FloorpNativeWebExtensionPermissionDecision(value: $0.key.string, expiration: $0.value)
        }.sorted { $0.value < $1.value }
        record.deniedMatchPatterns = context.deniedPermissionMatchPatterns.map {
            FloorpNativeWebExtensionPermissionDecision(value: $0.key.string, expiration: $0.value)
        }.sorted { $0.value < $1.value }
        record.hasRequestedOptionalAccessToAllHosts =
            context.hasRequestedOptionalAccessToAllHosts
    }

    private func persistRuntimeDiagnostics(for context: WKWebExtensionContext) {
        guard let identifier = identifier(for: context) else { return }
        updateRecord(identifier) { record in
            record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
            record.lastError = record.runtimeDiagnostics.last?.message
        }
        try? persistRegistry()
    }

    private static func diagnostics(
        _ errors: [Error],
        phase: FloorpNativeWebExtensionDiagnostic.Phase
    ) -> [FloorpNativeWebExtensionDiagnostic] {
        errors.map { FloorpNativeWebExtensionDiagnostic(phase: phase, error: $0 as NSError) }
    }

    private func replaceRecord(_ record: FloorpNativeWebExtensionRecord) {
        if let index = registry.extensions.firstIndex(where: { $0.id == record.id }) {
            registry.extensions[index] = record
        } else {
            registry.extensions.append(record)
        }
    }

    private func updateRecord(
        _ identifier: String,
        mutation: (inout FloorpNativeWebExtensionRecord) -> Void
    ) {
        guard let index = registry.extensions.firstIndex(where: { $0.id == identifier }) else { return }
        mutation(&registry.extensions[index])
    }

    private func persistRegistry() throws {
#if DEBUG || TESTING
        try registryPersistenceHookForTesting?(registry)
#endif
        try registryStore.save(registry)
    }

    private func recoverInterruptedTransactions() {
        var recovered = [FloorpNativeWebExtensionRecord]()
        for var record in registry.extensions {
            let outcome = record.recoverInterruptedTransaction()
            recovered.append(record)
            switch outcome {
            case .unchanged:
                break
            case .rolledBack:
                logger.log(
                    "Floorp: rolled back interrupted WebExtension transaction \(record.id)",
                    level: .warning,
                    category: .setup
                )
            case .pendingPurge:
                logger.log(
                    "Floorp: queued interrupted WebExtension install \(record.id) for data purge",
                    level: .warning,
                    category: .setup
                )
            }
        }
        registry.extensions = recovered
        try? persistRegistry()
    }

    private func completePendingPurge(
        _ record: FloorpNativeWebExtensionRecord,
        generation: Int
    ) async throws {
        setContextReady(false, identifier: record.id)
        setContextLifecycleQuiesced(true, identifier: record.id)
        if let context = contexts[record.id] {
            guard !hasUnfinishedWebKitOperation(for: context) else {
                throw FloorpNativeWebExtensionError.restartRequired(
                    "Purging an extension with an unfinished WebKit operation"
                )
            }
            NotificationCenter.default.removeObserver(self, name: nil, object: context)
            if context.isLoaded {
                try controller.unload(context)
            }
            guard !context.isLoaded else {
                throw FloorpNativeWebExtensionError.unsupportedOperation(
                    "unload extension before data purge"
                )
            }
            cleanSurfaceConfigurationTemplates.removeValue(forKey: ObjectIdentifier(context))
            contexts.removeValue(forKey: record.id)
        }

        // Unloading invalidates WebKit's in-memory session store. Asking for it
        // afterward produces an error instead of a purgeable data record.
        let dataTypes = WKWebExtensionController.allExtensionDataTypes.subtracting([.session])
        let dataRecords = await controller.dataRecords(ofTypes: dataTypes)
            .filter { $0.uniqueIdentifier == record.contextIdentifier }
        try validateTransition(for: record.id, generation: generation)
        if let error = dataRecords.flatMap(\.errors).first {
            throw error
        }
        if !dataRecords.isEmpty {
            await controller.removeData(ofTypes: dataTypes, from: dataRecords)
            try validateTransition(for: record.id, generation: generation)
            if let error = dataRecords.flatMap(\.errors).first {
                throw error
            }
        }

        let previousRegistry = registry
        registry.extensions.removeAll { $0.id == record.id }
        do {
            try persistRegistry()
        } catch {
            registry = previousRegistry
            throw error
        }

        if record.packageSource == .managed {
            do {
                try await installer.removeManagedPackage(reference: record.packageReference)
                try validateTransition(for: record.id, generation: generation)
            } catch {
                logger.log(
                    "Floorp: orphaned managed WebExtension package cleanup failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
    }

    private func tearDown() {
        // Publish an orderly close while the contexts can still receive
        // lifecycle events. Retired WebKit 26.5 runtimes then retain no logical
        // tabs or windows even though their unsafe process pools stay alive.
        let registeredWindows = Set(
            Array(tabManagers.keys)
                + announcedWindows.map(\.windowUUID)
                + windowAdapters.keys.map(\.windowUUID)
        )
        isTornDown = true
        lifecycleGeneration += 1
        extensionTopologyGeneration &+= 1
        activeTransitions.removeAll()
        isPublishingTeardownLifecycle = true
        registeredWindows.forEach { unregister(windowUUID: $0) }
        setTrackedFocusedWindow(nil)
        focusWasExplicitlyCleared = true
        synchronizeFocusedWindows()
        isPublishingTeardownLifecycle = false
        lifecycleQuiescedContextIdentifiers.formUnion(contexts.keys)
        dismissManagedActionPopups { _ in true }
        Array(presentedExtensionSurfaces.keys).forEach {
            dismissPresentedSurfaces(identifier: $0)
        }
        readyContextIdentifiers.removeAll()
        quarantinedContextIdentifiers.removeAll()
        actionOrigins.removeAll()
        preparedNavigationActions.removeAll()
        navigationPreparationGenerations.removeAll()
        navigationProtectionFailures.removeAll()
        finishAllStartupNavigationReadiness()
        verifiedNavigationReadinessRealms.removeAll()
        actionInvocationGenerations.removeAll()
        Array(extensionTabSurfaceCloseRequests.values).forEach {
            resolveExtensionTabSurfaceCloseRequest(
                $0,
                shouldProceed: false,
                dismissAlert: true
            )
        }
        let pendingBackgroundLoadGates = Array(backgroundLoadGates.values)
        backgroundLoadGates.removeAll()
        pendingBackgroundLoadGates.forEach { $0.resolve(CancellationError()) }
        NotificationCenter.default.removeObserver(self)
        tabManagers.values.compactMap(\.value).forEach { manager in
            manager.removeDelegate(self, completion: nil)
        }
        controller.delegate = nil
        tabManagers.removeAll()
        tabAdapters.removeAll()
        windowAdapters.removeAll()
        announcedTabs.removeAll()
        announcedWindows.removeAll()
        lastActiveTabs.removeAll()
        setTrackedFocusedWindow(nil)
        focusWasExplicitlyCleared = false
        // Keep loaded contexts and their controller alive until process exit.
        // `isTornDown` plus lifecycle quiescing prevents all host operations,
        // while avoiding WebKit's unsafe unload/deallocation path.
    }

    private func openWindows(for context: WKWebExtensionContext) -> [FloorpNativeWebExtensionWindow] {
        var windows = [FloorpNativeWebExtensionWindow]()
        for manager in tabManagers.values.compactMap(\.value) {
            if !tabs(for: manager.windowUUID, isPrivate: false).isEmpty {
                windows.append(windowAdapter(for: manager.windowUUID, isPrivate: false))
            }
            if context.hasAccessToPrivateData,
               !tabs(for: manager.windowUUID, isPrivate: true).isEmpty {
                windows.append(windowAdapter(for: manager.windowUUID, isPrivate: true))
            }
        }
        if let focused = lastFocusedWindow,
           let index = windows.firstIndex(where: {
               $0.windowUUID == focused.windowUUID && $0.isPrivateBrowsing == focused.isPrivate
           }) {
            let focusedWindow = windows.remove(at: index)
            windows.insert(focusedWindow, at: 0)
        }
        return windows
    }

    private func focusedWindow(for context: WKWebExtensionContext) -> FloorpNativeWebExtensionWindow? {
        if let key = lastFocusedWindow {
            guard !key.isPrivate || context.hasAccessToPrivateData else { return nil }
            guard announcedWindows.contains(key),
                  isEligibleForExtensionFocus(windowUUID: key.windowUUID),
                  !tabs(for: key.windowUUID, isPrivate: key.isPrivate).isEmpty else {
                return nil
            }
            return windowAdapter(for: key.windowUUID, isPrivate: key.isPrivate)
        }
        guard !focusWasExplicitlyCleared else { return nil }
        return openWindows(for: context).first {
            isEligibleForExtensionFocus(windowUUID: $0.windowUUID)
        }
    }

    private func recentActionOriginWindow(
        for context: WKWebExtensionContext,
        isPrivate: Bool
    ) -> FloorpNativeWebExtensionWindow? {
        guard let identifier = identifier(for: context),
              let origins = actionOrigins[identifier] else { return nil }
        let now = Date()
        let liveOrigins = origins.filter { origin in
            let key = origin.window
            return origin.expiresAt > now
                && (!key.isPrivate || context.hasAccessToPrivateData)
                && announcedWindows.contains(key)
                && !tabs(for: key.windowUUID, isPrivate: key.isPrivate).isEmpty
        }
        guard !liveOrigins.isEmpty else {
            actionOrigins.removeValue(forKey: identifier)
            return nil
        }
        actionOrigins[identifier] = liveOrigins
        // The bundled uBO compatibility patch always propagates `incognito`, so
        // the requested realm is authoritative even when two action popups overlap.
        guard let origin = liveOrigins.filter({ $0.window.isPrivate == isPrivate })
            .max(by: { $0.expiresAt < $1.expiresAt }) else {
            return nil
        }
        let key = origin.window
        return windowAdapter(for: key.windowUUID, isPrivate: key.isPrivate)
    }

    private func presenter(for tab: (any WKWebExtensionTab)?) -> UIViewController? {
        let tabViewController = (tab as? FloorpNativeWebExtensionTab)?.tab?.webView?.window?.rootViewController
        if let tabViewController {
            return Self.topViewController(from: tabViewController)
        }
        if let focused = lastFocusedWindow,
           let manager = tabManager(for: focused.windowUUID) {
            let focusedTabs = focused.isPrivate ? manager.privateTabs : manager.normalTabs
            let selectedTab = manager.selectedTab.flatMap { $0.isPrivate == focused.isPrivate ? $0 : nil }
            let candidates = [selectedTab].compactMap { $0 } + focusedTabs
            if let focusedRoot = candidates.lazy.compactMap({
                $0.webView?.window?.rootViewController
            }).first {
                return Self.topViewController(from: focusedRoot)
            }
        }
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        return root.flatMap(Self.topViewController(from:))
    }

    private func presentBundledActionPopup(
        path: String,
        context: WKWebExtensionContext,
        identifier: String,
        sourceTab: Tab,
        sourceAdapter: FloorpNativeWebExtensionTab,
        token: UUID
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            presentBundledActionPopup(
                path: path,
                context: context,
                identifier: identifier,
                sourceTab: sourceTab,
                sourceAdapter: sourceAdapter,
                token: token
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func actionPopupClosePreparation(
        for context: WKWebExtensionContext,
        identifier: String
    ) -> (@MainActor (WKWebView) async -> Bool)? {
        guard semanticReadinessPagePath(for: identifier) != nil else { return nil }
        return { [weak self, weak context] webView in
            guard let self, let context,
                  self.currentReadyIdentifier(for: context) == identifier else {
                return false
            }
            return await self.prepareExtensionSurfaceForClose(
                webView,
                context: context,
                identifier: identifier,
                timeoutNanoseconds: self.backgroundReadinessTimeout(for: identifier)
            )
        }
    }

    private func presentBundledActionPopup(
        path: String,
        context: WKWebExtensionContext,
        identifier: String,
        sourceTab: Tab,
        sourceAdapter: FloorpNativeWebExtensionTab,
        token: UUID,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        let sourceDataStore = sourceTab.floorpNativeWebsiteDataStore
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              currentReadyIdentifier(for: context) == identifier,
              sourceAdapter.tab === sourceTab,
              canOperate(tab: sourceTab, in: context),
              !sourceTab.isPrivate || !sourceDataStore.isPersistent,
              let configuration = extensionSurfaceConfiguration(
                  for: context,
                  websiteDataStore: sourceDataStore,
                  isPrivate: sourceTab.isPrivate
              ) else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        let popupURL = context.baseURL.appendingPathComponent(path)
        guard popupURL.scheme == context.baseURL.scheme,
              popupURL.host == context.baseURL.host else {
            completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("action popup URL"))
            return
        }

        let sourceWindow = WindowKey(
            windowUUID: sourceTab.windowUUID,
            isPrivate: sourceTab.isPrivate
        )
        let prepareToClose = actionPopupClosePreparation(
            for: context,
            identifier: identifier
        )
        let popup = FloorpNativeWebExtensionActionPopupViewController(
            url: popupURL,
            configuration: configuration,
            openURLInBrowser: { [weak self] url in
                self?.openURLInBrowser(
                    url,
                    isPrivate: sourceWindow.isPrivate,
                    preferredWindowUUID: sourceWindow.windowUUID
                )
            },
            prepareToClose: prepareToClose,
            onClose: {},
            onCloseDisposition: { [weak self, weak context, weak sourceAdapter] disposition in
                guard let self else { return }
                self.managedActionPopupDidClose(
                    identifier: identifier,
                    token: token,
                    context: context,
                    sourceAdapter: sourceAdapter,
                    sourceWindow: sourceWindow,
                    commitPendingTransition: disposition == .commitPendingTransition
                )
            },
            onPendingTransitionCancellation: { [weak self] in
                self?.discardManagedActionPopupCloseTransition(
                    identifier: identifier,
                    token: token
                )
            }
        )
        managedActionPopups[identifier] = ManagedActionPopup(
            token: token,
            viewController: popup,
            context: context,
            sourceTab: sourceTab,
            sourceAdapter: sourceAdapter,
            sourceWindow: sourceWindow
        )
        presentActionPopup(
            popup,
            for: sourceAdapter,
            expectedContext: context,
            validation: { [weak self, weak sourceTab, weak sourceAdapter] in
                guard let self, let sourceTab, let sourceAdapter else { return false }
                let sourceWindow = WindowKey(
                    windowUUID: sourceTab.windowUUID,
                    isPrivate: sourceTab.isPrivate
                )
                return self.managedActionPopups[identifier]?.token == token
                    && sourceAdapter.tab === sourceTab
                    && self.isManagedTab(sourceTab)
                    && self.tabManager(for: sourceTab.windowUUID)?.selectedTab === sourceTab
                    && self.lastFocusedWindow == sourceWindow
                    && self.canOperate(tab: sourceTab, in: context)
            }
        ) { [weak self, weak popup] error in
            if error != nil {
                if let managedPopup = self?.managedActionPopups[identifier],
                   managedPopup.token == token {
                    managedPopup.discardPendingCloseTransition()
                }
                popup?.closePopupImmediately(
                    animated: false,
                    preservingPendingCallbacks: true
                )
            }
            completionHandler(error)
        }
    }

    private func managedActionPopupDidClose(
        identifier: String,
        token: UUID,
        context: WKWebExtensionContext?,
        sourceAdapter: FloorpNativeWebExtensionTab?,
        sourceWindow: WindowKey,
        commitPendingTransition: Bool
    ) {
        guard let popup = managedActionPopups[identifier],
              popup.token == token else { return }
        let pendingCloseTransition: ManagedActionPopup.PendingCloseTransition?
        if commitPendingTransition {
            pendingCloseTransition = popup.takePendingCloseTransition()
        } else {
            popup.discardPendingCloseTransition()
            pendingCloseTransition = nil
        }
        if identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier {
            invalidateUBlockOriginLiteNavigationReadiness(isPrivate: sourceWindow.isPrivate)
        }
        if let context, let sourceAdapter {
            context.clearUserGesture(in: sourceAdapter)
        }
        actionOrigins[identifier]?.removeAll { $0.window == sourceWindow }
        if actionOrigins[identifier]?.isEmpty == true {
            actionOrigins.removeValue(forKey: identifier)
        }
        let viewController = managedActionPopups.removeValue(forKey: identifier)?.viewController
        presentedExtensionSurfaces[identifier]?.removeAll { surface in
            guard let surfaceController = surface.viewController else { return true }
            return surfaceController === viewController
        }
        if presentedExtensionSurfaces[identifier]?.isEmpty == true {
            presentedExtensionSurfaces.removeValue(forKey: identifier)
        }
        // Remove every reference to the old popup before applying its staged
        // transition. Tab activation synchronously publishes lifecycle events,
        // which must not treat this already-closed popup as a stale surface.
        if let pendingCloseTransition {
            do {
                try pendingCloseTransition.perform()
            } catch {
                pendingCloseTransition.cancel()
                logger.log(
                    "Floorp: deferred WebExtension \(pendingCloseTransition.operation) was cancelled: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
    }

    private func discardManagedActionPopupCloseTransition(
        identifier: String,
        token: UUID
    ) {
        guard let popup = managedActionPopups[identifier],
              popup.token == token else { return }
        popup.discardPendingCloseTransition()
    }

    private func dismissManagedActionPopups(
        where shouldDismiss: (ManagedActionPopup) -> Bool
    ) {
        let popups = managedActionPopups.filter { shouldDismiss($0.value) }
        for (identifier, popup) in popups {
            // Only a close initiated by the popup page should commit a staged
            // browser transition. Host teardown, focus changes, and superseding
            // action invocations invalidate it.
            popup.discardPendingCloseTransition()
            if let viewController = popup.viewController {
                // Lifecycle and topology changes cannot keep a stale popup
                // interactive while its source tab/context is disappearing.
                // User-initiated close paths use the async durability gate;
                // this host-forced path tears down immediately.
                viewController.closePopupImmediately(
                    animated: false,
                    preservingPendingCallbacks: true
                )
            } else {
                managedActionPopupDidClose(
                    identifier: identifier,
                    token: popup.token,
                    context: popup.context,
                    sourceAdapter: popup.sourceAdapter,
                    sourceWindow: popup.sourceWindow,
                    commitPendingTransition: false
                )
            }
        }
    }

    private func closeManagedActionPopupsAfterPreparing(
        where shouldClose: (ManagedActionPopup) -> Bool
    ) async -> Bool {
        let popups = managedActionPopups.filter { shouldClose($0.value) }
        for (identifier, popup) in popups {
            guard managedActionPopups[identifier]?.token == popup.token else { return false }
            popup.discardPendingCloseTransition()
            guard let viewController = popup.viewController else {
                managedActionPopupDidClose(
                    identifier: identifier,
                    token: popup.token,
                    context: popup.context,
                    sourceAdapter: popup.sourceAdapter,
                    sourceWindow: popup.sourceWindow,
                    commitPendingTransition: false
                )
                continue
            }
            guard await viewController.closePopupAfterPreparing(animated: false) else {
                return false
            }
            guard managedActionPopups[identifier]?.token != popup.token else { return false }
        }
        return true
    }

    private func presentActionPopup(
        _ popup: UIViewController,
        for tab: (any WKWebExtensionTab)?,
        expectedContext: WKWebExtensionContext,
        remainingTransitionRetries: Int = 4,
        validation: (() -> Bool)? = nil,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let identifier = currentReadyIdentifier(for: expectedContext) else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        guard validation?() != false else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        guard let presenter = presenter(for: tab), presenter.viewIfLoaded?.window != nil else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }

        let isTransitioning = presenter.isBeingDismissed
            || presenter.isBeingPresented
            || presenter.presentingViewController?.isBeingDismissed == true
            || presenter.presentedViewController != nil
        if isTransitioning {
            guard remainingTransitionRetries > 0 else {
                completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("action popup presentation"))
                return
            }
            let retry = { [weak self] in
                guard let self else {
                    completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                    return
                }
                self.presentActionPopup(
                    popup,
                    for: tab,
                    expectedContext: expectedContext,
                    remainingTransitionRetries: remainingTransitionRetries - 1,
                    validation: validation,
                    completionHandler: completionHandler
                )
            }
            if let transitionCoordinator = presenter.transitionCoordinator {
                transitionCoordinator.animate(alongsideTransition: nil) { _ in retry() }
            } else {
                DispatchQueue.main.async(execute: retry)
            }
            return
        }

        if let popover = popup.popoverPresentationController,
           popover.barButtonItem == nil,
           popover.sourceView == nil {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        let isPrivate = (tab as? FloorpNativeWebExtensionTab)?.tab?.isPrivate
            ?? focusedWindow(for: expectedContext)?.isPrivateBrowsing
            ?? false
        trackPresentedSurface(popup, identifier: identifier, isPrivate: isPrivate)
        presenter.present(popup, animated: true) {
            completionHandler(nil)
        }
    }

    private func trackPresentedSurface(
        _ viewController: UIViewController,
        identifier: String,
        isPrivate: Bool
    ) {
        var surfaces = presentedExtensionSurfaces[identifier]?.filter {
            $0.viewController != nil && $0.viewController !== viewController
        } ?? []
        surfaces.append(PresentedExtensionSurface(
            viewController: viewController,
            isPrivate: isPrivate
        ))
        presentedExtensionSurfaces[identifier] = surfaces
    }

    private func dismissPresentedSurfaces(identifier: String, isPrivate: Bool? = nil) {
        guard let surfaces = presentedExtensionSurfaces[identifier] else { return }
        var retained = [PresentedExtensionSurface]()
        for surface in surfaces {
            guard let viewController = surface.viewController else { continue }
            if isPrivate == nil || surface.isPrivate == isPrivate {
                if let popup = viewController as? FloorpNativeWebExtensionActionPopupViewController {
                    popup.closePopupImmediately(
                        animated: false,
                        preservingPendingCallbacks: true
                    )
                } else {
                    if let page = viewController as? FloorpNativeWebExtensionPageViewController {
                        page.prepareForHostTeardown()
                    }
                    if let navigation = viewController as? UINavigationController {
                        navigation.viewControllers
                            .compactMap { $0 as? FloorpNativeWebExtensionPageViewController }
                            .forEach { $0.prepareForHostTeardown() }
                    }
                    viewController.dismiss(animated: false)
                }
            } else {
                retained.append(surface)
            }
        }
        if retained.isEmpty {
            presentedExtensionSurfaces.removeValue(forKey: identifier)
        } else {
            presentedExtensionSurfaces[identifier] = retained
        }
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController,
           !presented.isBeingDismissed,
           presented.viewIfLoaded?.window != nil {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabs = root as? UITabBarController, let selected = tabs.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }

    private func prompt(
        title: String,
        message: String,
        in tab: (any WKWebExtensionTab)?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let presenter = presenter(for: tab) else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FloorpStrings.WebExtensions.cancel, style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: FloorpStrings.WebExtensions.allow, style: .default) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }
}

// MARK: - Browser lifecycle events

extension FloorpNativeWebExtensionHost: TabManagerDelegate {
    func tabManager(
        _ tabManager: any TabManager,
        prepareToRemoveTab tab: Tab,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard tabManagers[tabManager.windowUUID]?.value === tabManager,
              let webView = tab.webView else { return false }
        return prepareExtensionTabSurfaceForDestruction(
            in: tab,
            expectedWebView: webView,
            forceOnFailure: tab.isPrivate,
            completion: completion
        )
    }

    func tabManager(
        _ tabManager: any TabManager,
        didSelectedTabChange selectedTab: Tab,
        previousTab _: Tab?,
        isRestoring: Bool
    ) {
        guard tabManagers[tabManager.windowUUID]?.value === tabManager else { return }
        didActivate(selectedTab)
    }

    func tabManager(
        _ tabManager: any TabManager,
        didAddTab tab: Tab,
        placeNextToParentTab: Bool,
        isRestoring: Bool
    ) {
        // TabManager delegates run before a live tab creates its WKWebView so the
        // browser can install LegacyTabDelegate first. Defer only WebExtension
        // announcement until configureTab has finished without changing that order.
        let windowUUID = tabManager.windowUUID
        let managerReference = WeakTabManager(tabManager)
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self,
                  let tab,
                  !self.isTornDown,
                  Self.hosts[self.profileIdentifier] === self,
                  let manager = managerReference.value,
                  self.tabManagers[windowUUID]?.value === manager,
                  manager.tabs.contains(where: { $0 === tab }) else {
                return
            }
            self.announceTabIfNeeded(tab)
        }
    }

    func tabManager(_ tabManager: any TabManager, didRemoveTab tab: Tab, isRestoring: Bool) {
        guard tabManagers[tabManager.windowUUID]?.value === tabManager else { return }
        cancelExtensionTabSurfaceClosePreparation(for: tab)
        dismissManagedActionPopups { $0.sourceTab === tab }
        let key = ObjectIdentifier(tab)
        let adapter = tabAdapter(for: tab)
        let wasAnnounced = announcedTabs.remove(key) != nil
        let privacyKey = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        let remainingTabs = tabs(for: tab.windowUUID, isPrivate: tab.isPrivate)
        let closesLogicalWindow = remainingTabs.isEmpty && announcedWindows.contains(privacyKey)
        if wasAnnounced {
            notifyDidCloseTab(adapter, windowIsClosing: closesLogicalWindow)
        }
        tabAdapters.removeValue(forKey: key)
        navigationPreparationGenerations.removeValue(forKey: key)
        navigationProtectionFailures.removeValue(forKey: key)
        actionInvocationGenerations.removeValue(forKey: key)
        if lastActiveTabs[privacyKey] == key {
            let selectedReplacement = tabManager.selectedTab.flatMap { selectedTab in
                remainingTabs.first(where: { $0 === selectedTab })
            }
            if let replacement = selectedReplacement ?? remainingTabs.first {
                lastActiveTabs[privacyKey] = ObjectIdentifier(replacement)
                notifyDidActivateTab(
                    tabAdapter(for: replacement),
                    previousActiveTab: wasAnnounced ? adapter : nil
                )
            } else {
                lastActiveTabs.removeValue(forKey: privacyKey)
            }
        }
        if remainingTabs.isEmpty,
           announcedWindows.remove(privacyKey) != nil,
           let window = windowAdapters[privacyKey] {
            notifyDidCloseWindow(window)
            lastActiveTabs.removeValue(forKey: privacyKey)
            if lastFocusedWindow == privacyKey {
                focusAvailableWindow()
            }
        }
        synchronizeFocusedWindows()
    }

    func tabManagerDidRestoreTabs(_ tabManager: any TabManager) {
        guard tabManagers[tabManager.windowUUID]?.value === tabManager else { return }
        tabManager.tabs.forEach { announceTabIfNeeded($0) }
        if let selectedTab = tabManager.selectedTab {
            didActivate(selectedTab)
            if sceneActivationState(for: tabManager.windowUUID) == .foregroundActive {
                focus(windowUUID: tabManager.windowUUID, isPrivate: selectedTab.isPrivate)
            }
        }
    }
}

// MARK: - WebKit host delegate

extension FloorpNativeWebExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        openWindows(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow(for: extensionContext)
    }

    private func finishOpeningNewTab(
        using configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        identifier: String,
        window: FloorpNativeWebExtensionWindow,
        manager: any TabManager,
        popupToken: UUID?,
        finish: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard currentReadyIdentifier(for: extensionContext) == identifier,
              tabManager(for: window.windowUUID) === manager,
              !window.isPrivateBrowsing || extensionContext.hasAccessToPrivateData else {
            finish(nil, FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        let parent = (configuration.parentTab as? FloorpNativeWebExtensionTab)?.tab
        let tab = manager.addTab(
            nil as URLRequest?,
            afterTab: parent,
            zombie: false,
            isPrivate: window.isPrivateBrowsing
        )
        announceTabIfNeeded(tab)
        do {
            if configuration.shouldBeActive {
                try requestActivation(
                    of: tab,
                    requestedBy: extensionContext,
                    cancellation: { [weak self, weak tab] in
                        guard let self, let tab else { return }
                        self.rollbackCreatedTabsAfterFailedActivation(
                            [tab],
                            from: manager,
                            completion: {}
                        )
                    }
                )
            }
            if let url = configuration.url {
                load(url: url, in: tab, requestedBy: extensionContext)
            }
            let adapter = tabAdapter(for: tab)
#if DEBUG || TESTING
            if let hook = extensionTabCreationCompletionHookForTesting {
                Task { @MainActor [weak self, weak extensionContext, weak tab] in
                    guard let tab else {
                        finish(nil, FloorpNativeWebExtensionError.hostUnavailable)
                        return
                    }
                    await hook(identifier, tab)
                    guard let self else {
                        finish(nil, FloorpNativeWebExtensionError.hostUnavailable)
                        return
                    }
                    let originatingPopupIsCurrent = popupToken.map { token in
                        self.managedActionPopups[identifier]?.token == token
                    } ?? true
                    guard let extensionContext,
                          self.currentReadyIdentifier(for: extensionContext) == identifier,
                          self.isManagedTab(tab),
                          originatingPopupIsCurrent else {
                        self.rollbackCreatedTabsAfterFailedActivation(
                            [tab],
                            from: manager
                        ) {
                            finish(nil, FloorpNativeWebExtensionError.hostUnavailable)
                        }
                        return
                    }
                    finish(self.tabAdapter(for: tab), nil)
                }
                return
            }
#endif
            finish(adapter, nil)
        } catch {
            rollbackCreatedTabsAfterFailedActivation(
                [tab],
                from: manager
            ) {
                finish(nil, error)
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let identifier = currentReadyIdentifier(for: extensionContext) else {
            completionHandler(nil, FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        let requestedWindow = configuration.window as? FloorpNativeWebExtensionWindow
        let window = requestedWindow ?? focusedWindow(for: extensionContext)
        guard let window,
              !window.isPrivateBrowsing || extensionContext.hasAccessToPrivateData,
              let manager = tabManager(for: window.windowUUID) else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        do {
            if configuration.shouldBeActive {
                try validateDeferredActivation(requestedBy: extensionContext)
            }
        } catch {
            completionHandler(nil, error)
            return
        }
        let popupToken: UUID?
        let popupWebView: WKWebView?
        if let popup = managedActionPopups[identifier],
           popup.context === extensionContext {
            popupToken = popup.token
            popupWebView = popup.viewController?.webView
        } else {
            popupToken = nil
            popupWebView = nil
        }
        let callbackLease = ManagedActionPopupCallbackLease(webView: popupWebView)
        let finish: ((any WKWebExtensionTab)?, (any Error)?) -> Void = { tab, error in
            callbackLease.finish {
                completionHandler(tab, error)
            }
        }
        finishOpeningNewTab(
            using: configuration,
            for: extensionContext,
            identifier: identifier,
            window: window,
            manager: manager,
            popupToken: popupToken,
            finish: finish
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard currentReadyIdentifier(for: extensionContext) != nil else {
            completionHandler(nil, FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        let isPrivate = configuration.shouldBePrivate
        let focusedSource = focusedWindow(for: extensionContext).flatMap {
            $0.isPrivateBrowsing == isPrivate ? $0 : nil
        }
        let sourceWindow = recentActionOriginWindow(
            for: extensionContext,
            isPrivate: isPrivate
        ) ?? focusedSource
        guard !isPrivate || extensionContext.hasAccessToPrivateData,
              let sourceWindow,
              let manager = tabManager(for: sourceWindow.windowUUID) else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        do {
            if configuration.shouldBeFocused {
                try validateDeferredActivation(requestedBy: extensionContext)
            }
        } catch {
            completionHandler(nil, error)
            return
        }

        let urls = configuration.tabURLs.isEmpty
            ? [URL(string: "about:blank")!]
            : configuration.tabURLs
        var createdTabs = [(tab: Tab, url: URL)]()
        var lastTab: Tab?
        for url in urls {
            let tab = manager.addTab(
                nil as URLRequest?,
                afterTab: lastTab,
                zombie: false,
                isPrivate: isPrivate
            )
            announceTabIfNeeded(tab)
            createdTabs.append((tab, url))
            lastTab = tab
        }
        do {
            if configuration.shouldBeFocused, let lastTab {
                try requestActivation(
                    of: lastTab,
                    requestedBy: extensionContext,
                    cancellation: { [weak self] in
                        self?.rollbackCreatedTabsAfterFailedActivation(
                            createdTabs.map(\.tab),
                            from: manager,
                            completion: {}
                        )
                    }
                )
            }
            for createdTab in createdTabs {
                load(
                    url: createdTab.url,
                    in: createdTab.tab,
                    requestedBy: extensionContext
                )
            }
        } catch {
            rollbackCreatedTabsAfterFailedActivation(
                createdTabs.map(\.tab),
                from: manager
            ) {
                completionHandler(nil, error)
            }
            return
        }
        let window = windowAdapter(for: manager.windowUUID, isPrivate: isPrivate)
        announceWindowIfNeeded(windowUUID: manager.windowUUID, isPrivate: isPrivate)
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let identifier = currentReadyIdentifier(for: extensionContext) else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        let usesManagedPopup = FloorpNativeWebExtensionCatalog.item(identifier: identifier)?
            .actionPopupPath != nil
        let managedPopup = managedActionPopups[identifier]
        let sourceWindow = managedPopup?.sourceWindow
        let sourceTab = managedPopup?.sourceTab
        let sourceAdapter = managedPopup?.sourceAdapter
        if usesManagedPopup {
            guard managedPopup?.context === extensionContext,
                  let sourceWindow,
                  let sourceTab,
                  let sourceAdapter,
                  sourceAdapter.tab === sourceTab else {
                completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                return
            }
            guard sourceWindow.isPrivate == sourceTab.isPrivate else {
                completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                return
            }
        }
        let isPrivate = sourceWindow?.isPrivate
            ?? focusedWindow(for: extensionContext)?.isPrivateBrowsing
            ?? false
        if usesManagedPopup {
            do {
                let didStage = try stageManagedActionPopupCloseTransition(
                    for: extensionContext,
                    operation: "options presentation"
                ) { [weak self, weak extensionContext, weak sourceTab, weak sourceAdapter] in
                    guard let self, let extensionContext else {
                        throw FloorpNativeWebExtensionError.hostUnavailable
                    }
                    self.presentOptionsPage(
                        identifier: identifier,
                        sourceWindow: sourceWindow,
                        sourceTab: sourceTab,
                        sourceAdapter: sourceAdapter,
                        isPrivate: isPrivate,
                        expectedContext: extensionContext
                    ) { [weak self] error in
                        guard let error else { return }
                        self?.logger.log(
                            "Floorp: deferred WebExtension options presentation failed: \(error)",
                            level: .warning,
                            category: .setup
                        )
                    }
                }
                guard didStage else {
                    completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                    return
                }
                // The popup page must regain control before it closes itself.
                // Presentation starts from managedActionPopupDidClose after the
                // old WebView no longer owns this WebExtension API callback.
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            return
        }

        presentOptionsPage(
            identifier: identifier,
            sourceWindow: nil,
            sourceTab: nil,
            sourceAdapter: nil,
            isPrivate: isPrivate,
            expectedContext: extensionContext,
            completionHandler: completionHandler
        )
    }

    private func presentOptionsPage(
        identifier: String,
        sourceWindow: WindowKey?,
        sourceTab: Tab?,
        sourceAdapter: FloorpNativeWebExtensionTab?,
        isPrivate: Bool,
        expectedContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // swiftlint:disable:next closure_body_length
        Task { @MainActor [weak self, weak expectedContext, weak sourceTab, weak sourceAdapter] in
            guard let self,
                  let expectedContext,
                  self.currentReadyIdentifier(for: expectedContext) == identifier else {
                completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                return
            }
            let validation: (() -> Bool)?
            if let sourceWindow {
                let sourceIsStillActive = { [weak self, weak sourceTab, weak sourceAdapter] in
                    guard let self, let sourceTab, let sourceAdapter else { return false }
                    return sourceAdapter.tab === sourceTab
                        && self.isManagedTab(sourceTab)
                        && self.tabManager(for: sourceWindow.windowUUID)?.selectedTab === sourceTab
                        && self.lastFocusedWindow == sourceWindow
                        && self.canOperate(tab: sourceTab, in: expectedContext)
                }
                guard sourceIsStillActive() else {
                    completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                    return
                }
                validation = sourceIsStillActive
            } else {
                validation = nil
            }
            do {
                let options = try await self.optionsViewController(
                    identifier: identifier,
                    sourceTab: sourceTab,
                    isPrivate: isPrivate
                )
                options.modalPresentationStyle = .formSheet
                self.presentActionPopup(
                    options,
                    for: sourceAdapter,
                    expectedContext: expectedContext,
                    validation: validation,
                    completionHandler: completionHandler
                )
            } catch {
                completionHandler(error)
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        guard currentReadyIdentifier(for: extensionContext) != nil else {
            completionHandler([], nil)
            return
        }
        let eligible = permissions.filter { $0 != .nativeMessaging }
        let detail = Set(eligible.map(\.floorpDisplayName))
            .sorted()
            .map { "• \($0)" }
            .joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.permissionRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            guard let self, let extensionContext,
                  allowed,
                  self.currentReadyIdentifier(for: extensionContext) != nil else {
                completionHandler([], nil)
                return
            }
            completionHandler(eligible, .distantFuture)
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard currentReadyIdentifier(for: extensionContext) != nil else {
            completionHandler([], nil)
            return
        }
        let detail = urls.map(\.absoluteString).sorted().prefix(8).map { "• \($0)" }.joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.websiteAccessRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            guard let self, let extensionContext,
                  allowed,
                  self.currentReadyIdentifier(for: extensionContext) != nil else {
                completionHandler([], nil)
                return
            }
            completionHandler(urls, .distantFuture)
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard currentReadyIdentifier(for: extensionContext) != nil else {
            completionHandler([], nil)
            return
        }
        let detail = matchPatterns.map(\.string).sorted().prefix(8).map { "• \($0)" }.joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.websiteAccessRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            guard let self, let extensionContext,
                  allowed,
                  self.currentReadyIdentifier(for: extensionContext) != nil else {
                completionHandler([], nil)
                return
            }
            completionHandler(matchPatterns, .distantFuture)
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        NotificationCenter.default.post(name: .floorpNativeWebExtensionActionsDidChange, object: self)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Never instantiate WebKit's popup view here. It always inherits the
        // controller's persistent default data store, including for private
        // source tabs. Bundled static popups are presented by `performAction`
        // in a tab-scoped configuration; unexpected programmatic popup requests
        // fail closed.
        action.closePopup()
        completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("programmatic action popup"))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(nil, FloorpNativeWebExtensionError.unsupportedOperation("native messaging"))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let error = FloorpNativeWebExtensionError.unsupportedOperation("native messaging")
        port.disconnect(throwing: error)
        completionHandler(error)
    }
}
