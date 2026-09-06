// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import GCDWebServers
import Shared
import TestKit
import WebKit
import XCTest

@testable import Client

@MainActor
final class FloorpWebExtensionTestRuntimeRetainer {
    private final class Runtime {
        private var objects = [ObjectIdentifier: AnyObject]()
        private var resourceRoots = Set<URL>()

        func merge(
            controller: WKWebExtensionController,
            context: WKWebExtensionContext,
            objects: [AnyObject],
            resourceRoot: URL?
        ) {
            (([controller, context] as [AnyObject]) + objects).forEach {
                self.objects[ObjectIdentifier($0)] = $0
            }
            if let resourceRoot {
                resourceRoots.insert(resourceRoot.standardizedFileURL)
            }
        }
    }

    private static var runtimes = [ObjectIdentifier: Runtime]()

    private init() {}

    static func retain(
        controller: WKWebExtensionController,
        context: WKWebExtensionContext,
        objects: [AnyObject] = [],
        resourceRoot: URL? = nil
    ) {
        let key = ObjectIdentifier(context)
        let runtime = runtimes[key] ?? Runtime()
        runtime.merge(
            controller: controller,
            context: context,
            objects: objects,
            resourceRoot: resourceRoot
        )
        runtimes[key] = runtime
    }
}

@MainActor
private final class FloorpClosePreparationTestGate {
    private(set) var didBegin = false
    private var isReleased = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    var mayFinish: Bool {
        get { isReleased }
        set {
            isReleased = newValue
            guard newValue else { return }
            let pendingWaiters = waiters
            waiters.removeAll()
            pendingWaiters.forEach { $0.resume() }
        }
    }

    func waitUntilReleased() async -> Bool {
        didBegin = true
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
        return true
    }
}

@MainActor
final class FloorpNativeWebExtensionIntegrationTests: XCTestCase {
    func testBundledDarkReaderZIPIsVerifiedAndLoadsWithNativeWebKit() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let package = try await installer.verifiedBundledPackage(
            for: FloorpNativeWebExtensionCatalog.darkReader
        )
        XCTAssertEqual(
            package.sha256,
            "92f40f485205f61233185d1fb7cfb84b1dec243ebefc181d5f53943adc3c97c6"
        )
        XCTAssertEqual(package.url.pathExtension, "zip")

        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        XCTAssertEqual(webExtension.displayName, "Dark Reader")
        XCTAssertEqual(webExtension.version, "4.9.129")
        XCTAssertTrue(webExtension.errors.isEmpty)

        let isolationToken = UUID().uuidString.lowercased()
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier =
            "\(FloorpNativeWebExtensionCatalog.darkReader.contextIdentifier).catalog.\(isolationToken)"
        context.baseURL = URL(
            string: "webkit-extension://darkreader-catalog-\(isolationToken).floorp.internal/"
        )!
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)

        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension],
                resourceRoot: temporaryRoot
            )
        }
        try controller.load(context)

        XCTAssertTrue(context.isLoaded)
        XCTAssertNotNil(context.optionsPageURL)
        let action = try XCTUnwrap(context.action(for: nil))
        // Materializing an unpresented popup view controller makes WebKit tear down its
        // process pool asynchronously and can crash the next WebKit test on iOS 26.2.
        XCTAssertTrue(action.presentsPopup)
        XCTAssertTrue(webExtension.hasBackgroundContent)
        XCTAssertTrue(webExtension.hasInjectedContent)
        XCTAssertTrue(webExtension.requestedPermissions.contains(.storage))
        XCTAssertTrue(webExtension.requestedPermissions.contains(.scripting))
        XCTAssertFalse(webExtension.requestedPermissions.contains(.nativeMessaging))
    }

    func testActionPickerListsEveryActionAndDefersSelectionUntilDismissal() {
        let actions = [
            FloorpNativeWebExtensionActionItem(
                contextIdentifier: "dark-reader",
                label: "Dark Reader",
                version: "4.9.129",
                icon: nil,
                isEnabled: true
            ),
            FloorpNativeWebExtensionActionItem(
                contextIdentifier: "ubol",
                label: "uBlock Origin Lite",
                version: "2026.825.1619",
                icon: nil,
                isEnabled: true
            )
        ]
        var selections = [String]()
        var dismissalCompletion: (() -> Void)?
        let picker = FloorpNativeWebExtensionActionPickerViewController(
            actions: actions,
            windowUUID: UUID(),
            themeManager: MockThemeManager(),
            dismissalHandler: { dismissalCompletion = $0 },
            onSelection: { selections.append($0.contextIdentifier) }
        )

        picker.loadViewIfNeeded()

        XCTAssertEqual(picker.displayedChoiceTitles, ["Dark Reader", "uBlock Origin Lite"])
        XCTAssertEqual(picker.view.accessibilityIdentifier, "Floorp.NativeWebExtensions.ActionPicker")
        picker.selectChoice(identifier: "ubol")
        XCTAssertTrue(selections.isEmpty)

        dismissalCompletion?()
        dismissalCompletion?()

        XCTAssertEqual(selections, ["ubol"])
    }

    func testActionPickerSelectionRunsAfterTheSheetLeavesItsPresentationHierarchy() async throws {
        let action = FloorpNativeWebExtensionActionItem(
            contextIdentifier: "dark-reader",
            label: "Dark Reader",
            version: "4.9.129",
            icon: nil,
            isEnabled: true
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var picker: FloorpNativeWebExtensionActionPickerViewController?
        let selected = expectation(description: "Action selected after picker dismissal")
        picker = FloorpNativeWebExtensionActionPickerViewController(
            actions: [action],
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            onSelection: { selectedAction in
                XCTAssertEqual(selectedAction.contextIdentifier, action.contextIdentifier)
                XCTAssertNil(picker?.viewIfLoaded?.window)
                XCTAssertNil(picker?.presentingViewController)
                XCTAssertNil(root.presentedViewController)
                selected.fulfill()
            }
        )
        let actionPicker = try XCTUnwrap(picker)
        root.present(actionPicker, animated: false)

        actionPicker.selectChoice(identifier: action.contextIdentifier)

        await fulfillment(of: [selected], timeout: 1)
    }

    func testLogicalPrivacyWindowsAlwaysExposeAnActiveTabFromTheirOwnTabList() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let normalTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        let privateTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        fixture.host.register(tabManager: manager)
        XCTAssertEqual(fixture.context.openWindows.count, 2)
        XCTAssertEqual(fixture.context.openTabs.count, 2)

        let normalWindow = fixture.host.windowAdapter(
            for: manager.windowUUID,
            isPrivate: false
        )
        let privateWindow = fixture.host.windowAdapter(
            for: manager.windowUUID,
            isPrivate: true
        )
        assertActiveTabBelongsToWindow(normalWindow, context: fixture.context)
        assertActiveTabBelongsToWindow(privateWindow, context: fixture.context)

        manager.selectedTab = privateTab
        fixture.host.tabManager(
            manager,
            didSelectedTabChange: privateTab,
            previousTab: normalTab,
            isRestoring: false
        )

        assertActiveTabBelongsToWindow(normalWindow, context: fixture.context)
        assertActiveTabBelongsToWindow(privateWindow, context: fixture.context)
        XCTAssertTrue(normalWindow.activeTab(for: fixture.context) === fixture.host.tabAdapter(for: normalTab))
        XCTAssertTrue(privateWindow.activeTab(for: fixture.context) === fixture.host.tabAdapter(for: privateTab))
    }

    func testReenablingAfterDisableWaitsForColdLaunchWithoutLeavingExtensionEffects() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let normalTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        let privateTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        fixture.host.register(tabManager: manager)

        try await fixture.host.setEnabled(false, identifier: identifier)
        XCTAssertTrue(fixture.host.actionItems(for: normalTab).isEmpty)
        XCTAssertTrue(fixture.host.actionItems(for: privateTab).isEmpty)

        try await fixture.host.setEnabled(true, identifier: identifier)
        let queued = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(queued.isEnabled)
        XCTAssertTrue(queued.requiresRestartToEnable)
        XCTAssertFalse(fixture.context.isLoaded)
        XCTAssertTrue(fixture.host.actionItems(for: normalTab).isEmpty)
        XCTAssertTrue(fixture.host.actionItems(for: privateTab).isEmpty)
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )

        fixture.host.unregister(tabManager: manager)
        FloorpNativeWebExtensionHost.remove(for: fixture.profile.localName())
        let sameProcessHost = try FloorpNativeWebExtensionHost.install(for: fixture.profile)
        await sameProcessHost.restoreInstalledExtensions()
        let restoredQueue = try XCTUnwrap(
            sameProcessHost.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(restoredQueue.isEnabled)
        XCTAssertTrue(restoredQueue.requiresRestartToEnable)
        XCTAssertFalse(try XCTUnwrap(
            sameProcessHost.installedContext(identifier: identifier)
        ).isLoaded)
    }

    func testDisablePersistenceFailureRollsBackBeforeRuntimeMutation() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)

        let injectedError = NSError(
            domain: "FloorpNativeWebExtensionIntegrationTests.Persistence",
            code: 1
        )
        fixture.host.registryPersistenceHookForTesting = { registry in
            guard registry.extensions.first(where: { $0.id == identifier })?.isEnabled == false else {
                return
            }
            throw injectedError
        }
        defer { fixture.host.registryPersistenceHookForTesting = nil }

        do {
            try await fixture.host.setEnabled(false, identifier: identifier)
            XCTFail("A disable whose durable registry write fails must fail")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, injectedError.domain)
            XCTAssertEqual(error.code, injectedError.code)
        }

        let item = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(item.requiresRestartToEnable)
        XCTAssertTrue(fixture.context.isLoaded)
        XCTAssertTrue(fixture.host.canMutate(tab: tab, in: fixture.context))
        XCTAssertFalse(fixture.host.actionItems(for: tab).isEmpty)

        let persisted = try XCTUnwrap(
            registryStore(for: fixture.profile).load().extensions.first { $0.id == identifier }
        )
        XCTAssertTrue(persisted.isEnabled)
        XCTAssertNil(persisted.unloadState)
#else
        throw XCTSkip("The persistence failure hook is available only in test builds")
#endif
    }

    func testLatePermissionSaveCannotOverwriteCleanlyUnloadedContext() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier

        try await fixture.host.setEnabled(false, identifier: identifier)
        XCTAssertFalse(fixture.context.isLoaded)
        let durable = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )

        fixture.context.hasRequestedOptionalAccessToAllHosts.toggle()
        fixture.context.grantedPermissions = [:]
        fixture.context.deniedPermissions = [:]
        fixture.context.grantedPermissionMatchPatterns = [:]
        fixture.context.deniedPermissionMatchPatterns = [:]
        fixture.host.persistPermissionStateForTesting(fixture.context)

        let afterLateSave = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )
        XCTAssertEqual(afterLateSave.grantedPermissions, durable.grantedPermissions)
        XCTAssertEqual(afterLateSave.deniedPermissions, durable.deniedPermissions)
        XCTAssertEqual(afterLateSave.grantedMatchPatterns, durable.grantedMatchPatterns)
        XCTAssertEqual(afterLateSave.deniedMatchPatterns, durable.deniedMatchPatterns)
        XCTAssertEqual(
            afterLateSave.hasRequestedOptionalAccessToAllHosts,
            durable.hasRequestedOptionalAccessToAllHosts
        )
#else
        throw XCTSkip("The permission persistence seam is available only in test builds")
#endif
    }

    // swiftlint:disable:next function_body_length
    func testInFlightCloseQuarantinePreservesDurablePermissionsAndRejectsLateSave()
        async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let grantedExpiration = Date(timeIntervalSince1970: 1_900_000_000)
        let deniedExpiration = Date(timeIntervalSince1970: 2_000_000_000)
        fixture.context.setPermissionStatus(
            .grantedExplicitly,
            for: .contextMenus,
            expirationDate: grantedExpiration
        )
        fixture.host.persistPermissionStateForTesting(fixture.context)
        let before = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )
        XCTAssertEqual(
            before.grantedPermissions.first { $0.value == "contextMenus" }?.expiration,
            grantedExpiration
        )
        let options = try await fixture.host.optionsViewController(identifier: identifier)
        let navigation = try XCTUnwrap(options as? UINavigationController)
        let page = try XCTUnwrap(
            navigation.viewControllers.first as? FloorpNativeWebExtensionPageViewController
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.present(navigation, animated: false)
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(
            page.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        try await waitForDocumentCommit(
            in: webView,
            expectedOrigin: fixture.context.baseURL
        )
        let closeGate = FloorpClosePreparationTestGate()
        fixture.host.extensionSurfaceClosePreparationHookForTesting = { hookIdentifier, candidate in
            guard hookIdentifier == identifier, candidate === webView else { return false }
            return await closeGate.waitUntilReleased()
        }
        defer {
            closeGate.mayFinish = true
            fixture.host.extensionSurfaceClosePreparationHookForTesting = nil
        }

        page.requestCloseForTesting()
        for _ in 0..<80 where !closeGate.didBegin {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(closeGate.didBegin)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        )

        fixture.context.setPermissionStatus(
            .deniedExplicitly,
            for: .contextMenus,
            expirationDate: deniedExpiration
        )
        fixture.host.persistPermissionStateForTesting(fixture.context)
        let duringClose = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )
        XCTAssertNil(duringClose.grantedPermissions.first { $0.value == "contextMenus" })
        XCTAssertEqual(
            duringClose.deniedPermissions.first { $0.value == "contextMenus" }?.expiration,
            deniedExpiration
        )
        let runtimeHadPrivateAccess = fixture.context.hasAccessToPrivateData
        let runtimeGrantedPermissions = fixture.context.grantedPermissions
        let runtimeGrantedMatchPatterns = fixture.context.grantedPermissionMatchPatterns

        try await fixture.host.setEnabled(false, identifier: identifier)
        XCTAssertTrue(fixture.context.isLoaded)
        XCTAssertEqual(fixture.context.hasAccessToPrivateData, runtimeHadPrivateAccess)
        XCTAssertEqual(fixture.context.grantedPermissions, runtimeGrantedPermissions)
        XCTAssertEqual(
            fixture.context.grantedPermissionMatchPatterns,
            runtimeGrantedMatchPatterns
        )
        XCTAssertTrue(
            fixture.host.isContextQuarantinedForTesting(identifier: identifier)
        )
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        )
        let quarantined = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )
        XCTAssertNil(
            quarantined.grantedPermissions.first { $0.value == "contextMenus" }
        )
        XCTAssertEqual(
            quarantined.deniedPermissions.first { $0.value == "contextMenus" }?.expiration,
            deniedExpiration
        )
        XCTAssertEqual(quarantined.grantedMatchPatterns, before.grantedMatchPatterns)
        XCTAssertEqual(quarantined.deniedMatchPatterns, before.deniedMatchPatterns)
        XCTAssertEqual(
            quarantined.hasRequestedOptionalAccessToAllHosts,
            before.hasRequestedOptionalAccessToAllHosts
        )

        fixture.context.hasRequestedOptionalAccessToAllHosts.toggle()
        fixture.host.persistPermissionStateForTesting(fixture.context)
        let afterLateSave = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: identifier)
        )
        XCTAssertEqual(afterLateSave.grantedPermissions, quarantined.grantedPermissions)
        XCTAssertEqual(afterLateSave.deniedPermissions, quarantined.deniedPermissions)
        XCTAssertEqual(afterLateSave.grantedMatchPatterns, quarantined.grantedMatchPatterns)
        XCTAssertEqual(afterLateSave.deniedMatchPatterns, quarantined.deniedMatchPatterns)
        XCTAssertEqual(
            afterLateSave.hasRequestedOptionalAccessToAllHosts,
            quarantined.hasRequestedOptionalAccessToAllHosts
        )

        closeGate.mayFinish = true
        for _ in 0..<80 where
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        )
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testActiveSemanticReadinessProbeQuarantinesConcurrentDisableAndCompletesCallback()
        async throws {
#if DEBUG || TESTING
        executionTimeAllowance = 120
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let before = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: item.identifier)
        )
        var probeInvocationCount = 0
        var heldReadinessWebView: WKWebView?
        fixture.host.backgroundReadinessJavaScriptOverrideForTesting = { hookIdentifier, _, webView in
            guard hookIdentifier == item.identifier else { return nil }
            probeInvocationCount += 1
            guard probeInvocationCount == 1 else {
                return "return { ready: true, version: '\(item.expectedVersion)' };"
            }
            heldReadinessWebView = webView
            return """
            await new Promise(resolve => {
                globalThis.floorpReleaseHeldReadinessProbe = resolve;
                setTimeout(resolve, 15000);
            });
            delete globalThis.floorpReleaseHeldReadinessProbe;
            return { ready: true, version: '\(item.expectedVersion)' };
            """
        }
        defer {
            fixture.host.backgroundReadinessJavaScriptOverrideForTesting = nil
        }

        let optionsTask = Task { @MainActor in
            do {
                _ = try await fixture.host.optionsViewController(identifier: item.identifier)
                return true
            } catch {
                return false
            }
        }

        var didStartNativePromise = false
        for _ in 0..<200 {
            if let webView = heldReadinessWebView {
                let didInstallRelease = (try? await webView.evaluateJavaScript(
                    "typeof globalThis.floorpReleaseHeldReadinessProbe === 'function'"
                ) as? Bool) ?? false
                if didInstallRelease {
                    didStartNativePromise = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(didStartNativePromise)
        XCTAssertTrue(
            fixture.host.hasUnfinishedWebKitOperationForTesting(fixture.context)
        )
        let runtimeHadPrivateAccess = fixture.context.hasAccessToPrivateData
        let runtimeGrantedPermissions = fixture.context.grantedPermissions
        let runtimeGrantedMatchPatterns = fixture.context.grantedPermissionMatchPatterns

        try await fixture.host.setEnabled(false, identifier: item.identifier)

        XCTAssertTrue(fixture.context.isLoaded)
        XCTAssertEqual(fixture.context.hasAccessToPrivateData, runtimeHadPrivateAccess)
        XCTAssertEqual(fixture.context.grantedPermissions, runtimeGrantedPermissions)
        XCTAssertEqual(
            fixture.context.grantedPermissionMatchPatterns,
            runtimeGrantedMatchPatterns
        )
        XCTAssertTrue(
            fixture.host.isContextQuarantinedForTesting(identifier: item.identifier)
        )
        let disabled = try XCTUnwrap(
            fixture.host.registryRecordForTesting(identifier: item.identifier)
        )
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.grantedPermissions, before.grantedPermissions)
        XCTAssertEqual(disabled.deniedPermissions, before.deniedPermissions)
        XCTAssertEqual(disabled.grantedMatchPatterns, before.grantedMatchPatterns)
        XCTAssertEqual(disabled.deniedMatchPatterns, before.deniedMatchPatterns)
        XCTAssertEqual(
            disabled.hasRequestedOptionalAccessToAllHosts,
            before.hasRequestedOptionalAccessToAllHosts
        )
        XCTAssertTrue(
            fixture.host.hasUnfinishedWebKitOperationForTesting(fixture.context)
        )

        let readinessWebView = try XCTUnwrap(heldReadinessWebView)
        _ = try await readinessWebView.evaluateJavaScript(
            "globalThis.floorpReleaseHeldReadinessProbe?.(); true"
        )
        let didOpenOptions = await optionsTask.value
        XCTAssertFalse(didOpenOptions)
        for _ in 0..<80 where
            fixture.host.hasUnfinishedWebKitOperationForTesting(fixture.context) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(
            fixture.host.hasUnfinishedWebKitOperationForTesting(fixture.context)
        )
        let runtimeErrors = fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        XCTAssertFalse(runtimeErrors.localizedCaseInsensitiveContains("InvalidTransition"))
        XCTAssertFalse(
            runtimeErrors.localizedCaseInsensitiveContains(
                "Completion handler for function call is no longer reachable"
            )
        )
#else
        throw XCTSkip("The semantic-readiness JavaScript seam is available only in test builds")
#endif
    }

    func testDisableRemainsDurableWhenFinalDiagnosticsWriteFails() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let injectedError = NSError(
            domain: "FloorpNativeWebExtensionIntegrationTests.Persistence",
            code: 2
        )
        fixture.host.registryPersistenceHookForTesting = { registry in
            guard let record = registry.extensions.first(where: { $0.id == identifier }),
                  !record.isEnabled,
                  record.unloadState != nil else {
                return
            }
            throw injectedError
        }
        defer { fixture.host.registryPersistenceHookForTesting = nil }

        do {
            try await fixture.host.setEnabled(false, identifier: identifier)
            XCTFail("The final diagnostics write failure must be reported")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, injectedError.domain)
            XCTAssertEqual(error.code, injectedError.code)
        }

        let item = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(fixture.context.isLoaded)

        // The first, pre-unload write is the cold-launch authority. A later
        // diagnostics write failure must never leave the on-disk state enabled.
        let persisted = try XCTUnwrap(
            registryStore(for: fixture.profile).load().extensions.first { $0.id == identifier }
        )
        XCTAssertFalse(persisted.isEnabled)
#else
        throw XCTSkip("The persistence failure hook is available only in test builds")
#endif
    }

    func testCancellingDeferredEnableRollsBackWhenPersistenceFails() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        try await fixture.host.setEnabled(false, identifier: identifier)
        try await fixture.host.setEnabled(true, identifier: identifier)

        let injectedError = NSError(
            domain: "FloorpNativeWebExtensionIntegrationTests.Persistence",
            code: 3
        )
        fixture.host.registryPersistenceHookForTesting = { registry in
            guard let record = registry.extensions.first(where: { $0.id == identifier }),
                  let unloadState = record.unloadState,
                  !unloadState.enableOnNextColdLaunch else {
                return
            }
            throw injectedError
        }
        defer { fixture.host.registryPersistenceHookForTesting = nil }

        do {
            try await fixture.host.setEnabled(false, identifier: identifier)
            XCTFail("Cancelling a deferred enable whose durable write fails must fail")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, injectedError.domain)
            XCTAssertEqual(error.code, injectedError.code)
        }

        let item = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(item.requiresRestartToEnable)
        let persisted = try XCTUnwrap(
            registryStore(for: fixture.profile).load().extensions.first { $0.id == identifier }
        )
        XCTAssertFalse(persisted.isEnabled)
        XCTAssertEqual(persisted.unloadState?.enableOnNextColdLaunch, true)
#else
        throw XCTSkip("The persistence failure hook is available only in test builds")
#endif
    }

    func testSchedulingDeferredEnableRollsBackWhenPersistenceFails() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        try await fixture.host.setEnabled(false, identifier: identifier)

        let injectedError = NSError(
            domain: "FloorpNativeWebExtensionIntegrationTests.Persistence",
            code: 4
        )
        fixture.host.registryPersistenceHookForTesting = { registry in
            guard let record = registry.extensions.first(where: { $0.id == identifier }),
                  let unloadState = record.unloadState,
                  unloadState.enableOnNextColdLaunch else {
                return
            }
            throw injectedError
        }
        defer { fixture.host.registryPersistenceHookForTesting = nil }

        do {
            try await fixture.host.setEnabled(true, identifier: identifier)
            XCTFail("Scheduling a deferred enable whose durable write fails must fail")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, injectedError.domain)
            XCTAssertEqual(error.code, injectedError.code)
        }

        let item = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(item.requiresRestartToEnable)
        XCTAssertFalse(fixture.context.isLoaded)
        let persisted = try XCTUnwrap(
            registryStore(for: fixture.profile).load().extensions.first { $0.id == identifier }
        )
        XCTAssertFalse(persisted.isEnabled)
        XCTAssertEqual(persisted.unloadState?.enableOnNextColdLaunch, false)
#else
        throw XCTSkip("The persistence failure hook is available only in test builds")
#endif
    }

    func testPendingActionIsCancelledWhenMainFrameNavigationStartsDuringReadiness() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)
        XCTAssertFalse(fixture.host.actionItems(for: tab).isEmpty)

        var didBeginNavigation = false
        fixture.host.actionReadinessCompletedHookForTesting = { hookIdentifier, sourceTab in
            guard hookIdentifier == identifier else { return }
            didBeginNavigation = true
            _ = fixture.host.beginNavigationPreparation(for: sourceTab)
        }
        defer { fixture.host.actionReadinessCompletedHookForTesting = nil }

        do {
            try await fixture.host.performAction(contextIdentifier: identifier, for: tab)
            XCTFail("An action must not survive a main-frame navigation start")
        } catch is CancellationError {
            // Expected: the navigation epoch invalidates the pending action.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertTrue(didBeginNavigation)
        XCTAssertFalse(
            fixture.context.hasActiveUserGesture(in: fixture.host.tabAdapter(for: tab))
        )
#else
        throw XCTSkip("The action readiness hook is available only in test builds")
#endif
    }

    func testReservedActionIsCancelledWhenNavigationStartsBeforeAsyncExecution() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)

        // BrowserCoordinator reserves on the synchronous picker/toolbar callback,
        // before its unstructured Task gets a chance to run on the main actor.
        let invocation = try fixture.host.reserveActionInvocation(for: tab)
        let actionTask = Task { @MainActor in
            try await fixture.host.performAction(
                contextIdentifier: identifier,
                for: tab,
                invocation: invocation
            )
        }
        _ = fixture.host.beginNavigationPreparation(for: tab)

        do {
            try await actionTask.value
            XCTFail("A reserved click must not be rebound after navigation starts")
        } catch is CancellationError {
            // Expected: navigation invalidated the already-reserved token.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(
            fixture.context.hasActiveUserGesture(in: fixture.host.tabAdapter(for: tab))
        )
    }

    func testPendingActionIsCancelledWhenNavigationCommitsDuringReadiness() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)
        let committedURL = try XCTUnwrap(URL(string: "https://example.com/after-action"))

        var didCommitNavigation = false
        fixture.host.actionReadinessCompletedHookForTesting = { hookIdentifier, sourceTab in
            guard hookIdentifier == identifier else { return }
            didCommitNavigation = true
            fixture.host.recordCommittedNavigation(in: sourceTab, url: committedURL)
        }
        defer { fixture.host.actionReadinessCompletedHookForTesting = nil }

        do {
            try await fixture.host.performAction(contextIdentifier: identifier, for: tab)
            XCTFail("An action must not survive a committed source-tab navigation")
        } catch is CancellationError {
            // Expected: the document epoch invalidates the pending action.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertTrue(didCommitNavigation)
        XCTAssertFalse(
            fixture.context.hasActiveUserGesture(in: fixture.host.tabAdapter(for: tab))
        )
#else
        throw XCTSkip("The action readiness hook is available only in test builds")
#endif
    }

    func testPendingActionIsCancelledAfterTabSelectionMovesAwayAndBackDuringReadiness() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let sourceTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        let otherTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [sourceTab, otherTab]
        manager.normalTabs = [sourceTab, otherTab]
        manager.selectedTab = sourceTab
        fixture.host.register(tabManager: manager)

        var didMoveAwayAndBack = false
        fixture.host.actionReadinessCompletedHookForTesting = { hookIdentifier, actionTab in
            guard hookIdentifier == identifier else { return }
            didMoveAwayAndBack = true
            manager.selectedTab = otherTab
            fixture.host.tabManager(
                manager,
                didSelectedTabChange: otherTab,
                previousTab: actionTab,
                isRestoring: false
            )
            manager.selectedTab = actionTab
            fixture.host.tabManager(
                manager,
                didSelectedTabChange: actionTab,
                previousTab: otherTab,
                isRestoring: false
            )
        }
        defer { fixture.host.actionReadinessCompletedHookForTesting = nil }

        do {
            try await fixture.host.performAction(contextIdentifier: identifier, for: sourceTab)
            XCTFail("An action must not resume after its source tab was deselected")
        } catch is CancellationError {
            // Expected: moving away invalidates the invocation even after returning.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertTrue(didMoveAwayAndBack)
        XCTAssertTrue(manager.selectedTab === sourceTab)
        XCTAssertFalse(
            fixture.context.hasActiveUserGesture(in: fixture.host.tabAdapter(for: sourceTab))
        )
#else
        throw XCTSkip("The action readiness hook is available only in test builds")
#endif
    }

    func testHostTeardownClosesTopologyWhileDisableHasQuiescedTheContext() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        // `remove` retains the loaded runtime through process exit; its managed
        // package must remain on disk for the same lifetime.
        defer { FloorpNativeWebExtensionHost.remove(for: fixture.profile.localName()) }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let normalTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        let privateTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        fixture.host.register(tabManager: manager)

        XCTAssertEqual(fixture.context.openTabs.count, 2)
        XCTAssertEqual(fixture.context.openWindows.count, 2)
        fixture.host.contextWillUnloadHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier else { return }
            fixture.host.contextWillUnloadHookForTesting = nil
            FloorpNativeWebExtensionHost.remove(for: fixture.profile.localName())
        }

        do {
            try await fixture.host.setEnabled(false, identifier: identifier)
            XCTFail("Host removal during disable must cancel the transition")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertTrue(fixture.context.isLoaded)
        XCTAssertTrue(fixture.context.openTabs.isEmpty)
        XCTAssertTrue(fixture.context.openWindows.isEmpty)
        XCTAssertThrowsError(
            try FloorpNativeWebExtensionHost.install(for: fixture.profile)
        ) { error in
            guard let extensionError = error as? FloorpNativeWebExtensionError,
                  case .restartRequired = extensionError else {
                XCTFail("Expected restart-required host recreation error, got \(error)")
                return
            }
        }
#endif
    }

    func testHostTeardownDoesNotResolveReleasedWindowManagerDependencies() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let focusedWindowUUID = WindowUUID()
        let backgroundWindowUUID = WindowUUID()
        var focusedManager: MockTabManager? = MockTabManager(windowUUID: focusedWindowUUID)
        var backgroundManager: MockTabManager? = MockTabManager(windowUUID: backgroundWindowUUID)
        let focusedTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: focusedWindowUUID
        )
        let backgroundTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: backgroundWindowUUID
        )
        focusedManager?.tabs = [focusedTab]
        focusedManager?.normalTabs = [focusedTab]
        focusedManager?.selectedTab = focusedTab
        backgroundManager?.tabs = [backgroundTab]
        backgroundManager?.normalTabs = [backgroundTab]
        backgroundManager?.selectedTab = backgroundTab
        fixture.host.register(tabManager: try XCTUnwrap(focusedManager))
        fixture.host.register(tabManager: try XCTUnwrap(backgroundManager))
        fixture.host.focus(windowUUID: focusedWindowUUID, isPrivate: false)

        XCTAssertEqual(fixture.context.openTabs.count, 2)
        XCTAssertEqual(fixture.context.openWindows.count, 2)
        XCTAssertNotNil(fixture.context.focusedWindow)

        weak let releasedFocusedManager = focusedManager
        weak let releasedBackgroundManager = backgroundManager
        focusedManager = nil
        backgroundManager = nil
        XCTAssertNil(releasedFocusedManager)
        XCTAssertNil(releasedBackgroundManager)

        // Scene/dependency teardown may destroy WindowManager before the
        // extension host. Removal must close its cached logical topology
        // without consulting AppContainer for a replacement manager.
        FloorpNativeWebExtensionHost.remove(for: fixture.profile.localName())
        XCTAssertTrue(fixture.context.openTabs.isEmpty)
        XCTAssertTrue(fixture.context.openWindows.isEmpty)
        XCTAssertNil(fixture.context.focusedWindow)
        withExtendedLifetime((focusedTab, backgroundTab)) {}
    }

    func testHostTeardownDuringDisableReadinessCannotPersistStaleFinalRecord() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        var didRemoveHost = false
        fixture.host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            if !didRemoveHost {
                didRemoveHost = true
                FloorpNativeWebExtensionHost.remove(for: fixture.profile.localName())
            }
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.darkReader.expectedVersion
            ]
        }
        defer { fixture.host.backgroundReadinessResponseHookForTesting = nil }

        do {
            try await fixture.host.setEnabled(false, identifier: identifier)
            XCTFail("Host teardown during readiness must cancel the disable transition")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertTrue(didRemoveHost)
        let persisted = try XCTUnwrap(
            registryStore(for: fixture.profile).load().extensions.first { $0.id == identifier }
        )
        XCTAssertFalse(persisted.isEnabled)
        XCTAssertNil(persisted.unloadState)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testColdRestorePopulatesStartupTabsWithoutSyntheticCreatedEvents() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "topology_probe")
        let profile = profileFixture.profile
        // The managed package remains the resource base of a context retained
        // through process exit on iOS 26.5; keep its on-disk files alive too.
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let archiveData = try XCTUnwrap(
            Data(
                base64Encoded: Self.topologyProbeArchiveBase64,
                options: .ignoreUnknownCharacters
            )
        )
        try FileManager.default.createDirectory(
            at: profileFixture.rootDirectory,
            withIntermediateDirectories: true
        )
        let sourceArchive = profileFixture.rootDirectory.appendingPathComponent("topology-probe.zip")
        try archiveData.write(to: sourceArchive, options: .atomic)
        let digest = archiveData.sha256.map { String(format: "%02x", $0) }.joined()
        let nativeExtensionDirectory = URL(
            fileURLWithPath: try profile.files.getAndEnsureDirectory("WebExtensionsV2"),
            isDirectory: true
        )
        let installer = try FloorpNativeWebExtensionPackageInstaller(
            rootDirectory: nativeExtensionDirectory
        )
        let identifier = "floorp.test.topology-probe"
        let package = try await installer.stageManagedPackage(
            from: sourceArchive,
            catalogIdentifier: identifier,
            expectedSHA256: digest
        )
        let record = FloorpNativeWebExtensionRecord(
            id: identifier,
            contextIdentifier: "org.floorp.test.topology-probe.\(UUID().uuidString)",
            baseURLHost: "topology-probe-\(UUID().uuidString.lowercased())",
            packageSource: .managed,
            packageReference: package.reference,
            sha256: package.sha256,
            displayName: "Floorp Topology Probe",
            installedVersion: "1.0",
            grantedPermissions: [
                .init(value: "storage"),
                .init(value: "tabs")
            ],
            grantedMatchPatterns: [
                .init(value: "*://*/*")
            ]
        )
        let store = FloorpNativeWebExtensionRegistryStore(
            url: nativeExtensionDirectory.appendingPathComponent("registry-v2.json")
        )
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [record]))

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(injectedProfile: profile, injectedTabManager: manager)
        defer { dependencies.reset() }
        let existingTab = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/existing")),
            isPrivate: false
        )
        manager.selectTab(existingTab)
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        await host.restoreInstalledExtensions()
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))
        try await loadBackgroundContent(in: context)
        var probe = try await topologyProbeState(in: context, generationAtLeast: 1)
        XCTAssertEqual((probe["startupTabCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((probe["createdEventTotal"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(context.openTabs.count, 1)

        _ = manager.addTab(
            URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/new"))),
            afterTab: nil,
            zombie: false,
            isPrivate: false
        )
        probe = try await topologyProbeState(
            in: context,
            generationAtLeast: 1,
            createdEventTotalAtLeast: 1
        )
        XCTAssertEqual((probe["createdEventTotal"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(context.openTabs.count, 2)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    func testHostDefersDidAddAnnouncementUntilTabManagerFinishesCreatingWebView() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: fixture.profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        defer { fixture.cleanup() }
        fixture.host.register(tabManager: manager)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab

        fixture.host.tabManager(
            manager,
            didAddTab: tab,
            placeNextToParentTab: false,
            isRestoring: false
        )
        XCTAssertNil(tab.webView)
        XCTAssertTrue(fixture.context.openTabs.isEmpty)

        let configuration = WKWebViewConfiguration()
        fixture.host.attach(to: configuration)
        tab.createWebview(configuration: configuration)
        for _ in 0..<20 {
            if fixture.context.openTabs.contains(where: {
                ($0 as AnyObject) === (fixture.host.tabAdapter(for: tab) as AnyObject)
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(tab.webView)
        XCTAssertTrue(
            fixture.context.openTabs.contains {
                ($0 as AnyObject) === (fixture.host.tabAdapter(for: tab) as AnyObject)
            }
        )
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    func testRegisteringReplacementManagerClosesOldTopologyAndDetachesCallbacks() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        let windowUUID = WindowUUID.XCTestDefaultUUID
        let oldManager = FloorpUBOLRoutingTabManager(
            profile: fixture.profile,
            host: fixture.host,
            windowUUID: windowUUID
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: fixture.profile,
            injectedTabManager: oldManager
        )
        defer { dependencies.reset() }
        defer { fixture.cleanup() }
        let oldTab = oldManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/old")),
            isPrivate: false
        )
        oldManager.selectedTab = oldTab
        fixture.host.register(tabManager: oldManager)
        let oldAdapter = fixture.host.tabAdapter(for: oldTab)

        XCTAssertEqual(oldManager.registeredDelegateCount, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 1)

        let replacementManager = FloorpUBOLRoutingTabManager(
            profile: fixture.profile,
            host: fixture.host,
            windowUUID: windowUUID
        )
        let replacementTab = replacementManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/replacement")),
            isPrivate: false
        )
        replacementManager.selectedTab = replacementTab
        fixture.host.register(tabManager: replacementManager)

        XCTAssertEqual(oldManager.registeredDelegateCount, 0)
        XCTAssertEqual(replacementManager.registeredDelegateCount, 1)
        XCTAssertEqual(fixture.context.openWindows.count, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 1)
        XCTAssertTrue(
            fixture.context.openTabs.contains {
                ($0 as AnyObject) === (fixture.host.tabAdapter(for: replacementTab) as AnyObject)
            }
        )
        XCTAssertFalse(
            fixture.context.openTabs.contains {
                ($0 as AnyObject) === (oldAdapter as AnyObject)
            }
        )
        XCTAssertFalse(fixture.host.tabAdapter(for: oldTab) === oldAdapter)

        _ = oldManager.addTab(
            URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/stale-callback"))),
            afterTab: oldTab,
            zombie: false,
            isPrivate: false
        )
        fixture.host.tabManager(
            oldManager,
            didSelectedTabChange: oldTab,
            previousTab: nil,
            isRestoring: false
        )
        fixture.host.tabManager(
            oldManager,
            didRemoveTab: oldTab,
            isRestoring: false
        )
        fixture.host.tabManagerDidRestoreTabs(oldManager)
        fixture.host.unregister(tabManager: oldManager)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(replacementManager.registeredDelegateCount, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 1)
        XCTAssertTrue(
            fixture.context.openTabs.contains {
                ($0 as AnyObject) === (fixture.host.tabAdapter(for: replacementTab) as AnyObject)
            }
        )
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )

        fixture.host.unregister(tabManager: replacementManager)
        XCTAssertEqual(replacementManager.registeredDelegateCount, 0)
        XCTAssertTrue(fixture.context.openWindows.isEmpty)
        XCTAssertTrue(fixture.context.openTabs.isEmpty)
        fixture.host.unregister(tabManager: replacementManager)
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    func testPrivateFocusedWindowIsNotReplacedWithAnUnfocusedNormalWindow() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let normalTab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        let privateTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = privateTab
        fixture.host.register(tabManager: manager)
        XCTAssertEqual(fixture.context.openWindows.count, 1)
        XCTAssertNil(fixture.context.focusedWindow)
    }

    func testPrivateExtensionSurfaceUsesAnIsolatedUserContentController() {
        let configuration = WKWebViewConfiguration()
        let originalUserContentController = configuration.userContentController
        let privateDataStore = WKWebsiteDataStore.nonPersistent()

        FloorpNativeWebExtensionHost.configureExtensionSurface(
            configuration,
            websiteDataStore: privateDataStore,
            isPrivate: true
        )

        XCTAssertTrue(configuration.websiteDataStore === privateDataStore)
        XCTAssertFalse(configuration.userContentController === originalUserContentController)
    }

    func testNormalExtensionSurfaceUsesAnIsolatedUserContentController() {
        let configuration = WKWebViewConfiguration()
        let originalUserContentController = configuration.userContentController
        let dataStore = WKWebsiteDataStore.default()

        FloorpNativeWebExtensionHost.configureExtensionSurface(
            configuration,
            websiteDataStore: dataStore,
            isPrivate: false
        )

        XCTAssertTrue(configuration.websiteDataStore === dataStore)
        XCTAssertFalse(configuration.userContentController === originalUserContentController)
    }

    func testGrantingPrivateAccessReloadsOnlyExistingPrivateTabs() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)

        func makeTab(isPrivate: Bool, url: URL) -> (Tab, MockTabWebView) {
            let tab = makeHostTestTab(profile: fixture.profile, isPrivate: isPrivate)
            let configuration = WKWebViewConfiguration()
            fixture.host.attach(to: configuration)
            configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
            let webView = MockTabWebView(
                frame: .zero,
                configuration: configuration,
                windowUUID: manager.windowUUID,
                certStore: fixture.profile.certStore
            )
            webView.simulateObserverSetup(target: tab)
            webView.loadedURL = url
            tab.webView = webView
            tab.url = url
            return (tab, webView)
        }

        let normal = makeTab(
            isPrivate: false,
            url: try XCTUnwrap(URL(string: "https://example.com/normal"))
        )
        let privateTab = makeTab(
            isPrivate: true,
            url: try XCTUnwrap(URL(string: "https://example.com/private"))
        )
        manager.tabs = [normal.0, privateTab.0]
        manager.normalTabs = [normal.0]
        manager.privateTabs = [privateTab.0]
        manager.selectedTab = normal.0
        fixture.host.register(tabManager: manager)
        defer { fixture.host.unregister(tabManager: manager) }

        try await fixture.host.setPrivateAccess(
            true,
            identifier: FloorpNativeWebExtensionCatalog.darkReader.identifier
        )

        XCTAssertTrue(fixture.context.hasAccessToPrivateData)
        XCTAssertEqual(normal.1.reloadFromOriginCalled, 0)
        XCTAssertEqual(privateTab.1.reloadFromOriginCalled, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 2)
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    func testGrantingPrivateAccessPublishesThePrivateActiveTabEvent() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let privateTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: true,
            windowUUID: manager.windowUUID
        )
        privateTab.url = try XCTUnwrap(URL(string: "https://example.com/private-active"))
        manager.tabs = [privateTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = privateTab
        fixture.host.register(tabManager: manager)
        defer { fixture.host.unregister(tabManager: manager) }
        fixture.host.focus(windowUUID: manager.windowUUID, isPrivate: true)

        let template = try XCTUnwrap(fixture.context.webViewConfiguration)
        let configuration = try XCTUnwrap(template.copy() as? WKWebViewConfiguration)
        FloorpNativeWebExtensionHost.configureExtensionSurface(
            configuration,
            websiteDataStore: .default(),
            isPrivate: false
        )
        var eventWebView: WKWebView? = WKWebView(frame: .zero, configuration: configuration)

        func releaseEventWebView() async {
            eventWebView?.stopLoading()
            eventWebView?.navigationDelegate = nil
            eventWebView = nil
            await Task.yield()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        do {
            let webView = try XCTUnwrap(eventWebView)
            let navigation = FloorpWebExtensionNavigationWaiter()
            try await navigation.load(
                fixture.context.baseURL.appendingPathComponent("ui/devtools/index.html"),
                in: webView
            )
            _ = try await webView.callAsyncJavaScript(
                """
                window.floorpPrivateActivationEvents = [];
                browser.tabs.onActivated.addListener(info => {
                    window.floorpPrivateActivationEvents.push(info);
                });
                return true;
                """,
                arguments: [:],
                contentWorld: .page
            )

            try await fixture.host.setPrivateAccess(true, identifier: identifier)
            try await Task.sleep(nanoseconds: 100_000_000)

            let state = try await webView.callAsyncJavaScript(
                """
                const events = window.floorpPrivateActivationEvents ?? [];
                const latest = events.at(-1);
                const tab = latest ? await browser.tabs.get(latest.tabId) : null;
                return {
                    eventCount: events.length,
                    incognito: tab?.incognito === true,
                    active: tab?.active === true,
                };
                """,
                arguments: [:],
                contentWorld: .page
            ) as? [String: Any]
            let activationState = try XCTUnwrap(state)
            XCTAssertEqual((activationState["eventCount"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual(activationState["incognito"] as? Bool, true)
            XCTAssertEqual(activationState["active"] as? Bool, true)
            withExtendedLifetime(navigation) {}
        } catch {
            await releaseEventWebView()
            throw error
        }
        await releaseEventWebView()
    }

    func testPrivateAccessCyclesKeepTheLoadedContextAndNormalTabsStable() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)

        func makeTab(isPrivate: Bool, url: URL) -> (Tab, MockTabWebView) {
            let tab = makeHostTestTab(profile: fixture.profile, isPrivate: isPrivate)
            let configuration = WKWebViewConfiguration()
            fixture.host.attach(to: configuration)
            configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
            let webView = MockTabWebView(
                frame: .zero,
                configuration: configuration,
                windowUUID: manager.windowUUID,
                certStore: fixture.profile.certStore
            )
            webView.simulateObserverSetup(target: tab)
            webView.loadedURL = url
            tab.webView = webView
            tab.url = url
            return (tab, webView)
        }

        let normal = makeTab(
            isPrivate: false,
            url: try XCTUnwrap(URL(string: "https://example.com/normal-cycle"))
        )
        let privateTab = makeTab(
            isPrivate: true,
            url: try XCTUnwrap(URL(string: "https://example.com/private-cycle"))
        )
        manager.tabs = [normal.0, privateTab.0]
        manager.normalTabs = [normal.0]
        manager.privateTabs = [privateTab.0]
        manager.selectedTab = normal.0
        fixture.host.register(tabManager: manager)
        defer { fixture.host.unregister(tabManager: manager) }

        for _ in 0..<20 {
            try await fixture.host.setPrivateAccess(true, identifier: identifier)
            XCTAssertTrue(fixture.context.isLoaded)
            XCTAssertEqual(fixture.context.openTabs.count, 2)
            XCTAssertTrue(
                fixture.host.installedContext(identifier: identifier) === fixture.context
            )
            try await fixture.host.setPrivateAccess(false, identifier: identifier)
            XCTAssertTrue(fixture.context.isLoaded)
            XCTAssertEqual(fixture.context.openTabs.count, 1)
            XCTAssertTrue(
                fixture.host.installedContext(identifier: identifier) === fixture.context
            )
        }

        XCTAssertFalse(fixture.context.hasAccessToPrivateData)
        XCTAssertEqual(normal.1.reloadFromOriginCalled, 0)
        XCTAssertEqual(privateTab.1.reloadFromOriginCalled, 40)
        XCTAssertTrue(
            fixture.context.errors.isEmpty,
            fixture.context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    func testPrivateAccessChangesWhileDisabledDoNotReloadTabs() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier

        try await fixture.host.setEnabled(false, identifier: identifier)
        XCTAssertFalse(fixture.context.isLoaded)

        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        func makeTab(isPrivate: Bool, url: URL) -> (Tab, MockTabWebView) {
            let tab = makeHostTestTab(profile: fixture.profile, isPrivate: isPrivate)
            let configuration = WKWebViewConfiguration()
            fixture.host.attach(to: configuration)
            configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
            let webView = MockTabWebView(
                frame: .zero,
                configuration: configuration,
                windowUUID: manager.windowUUID,
                certStore: fixture.profile.certStore
            )
            webView.simulateObserverSetup(target: tab)
            webView.loadedURL = url
            tab.webView = webView
            tab.url = url
            return (tab, webView)
        }

        let normal = makeTab(
            isPrivate: false,
            url: try XCTUnwrap(URL(string: "https://example.com/disabled-normal"))
        )
        let privateTab = makeTab(
            isPrivate: true,
            url: try XCTUnwrap(URL(string: "https://example.com/disabled-private"))
        )
        manager.tabs = [normal.0, privateTab.0]
        manager.normalTabs = [normal.0]
        manager.privateTabs = [privateTab.0]
        manager.selectedTab = normal.0
        fixture.host.register(tabManager: manager)
        defer { fixture.host.unregister(tabManager: manager) }

        try await fixture.host.setPrivateAccess(true, identifier: identifier)
        XCTAssertTrue(fixture.context.hasAccessToPrivateData)
        try await fixture.host.setPrivateAccess(false, identifier: identifier)
        XCTAssertFalse(fixture.context.hasAccessToPrivateData)

        XCTAssertFalse(fixture.context.isLoaded)
        XCTAssertEqual(normal.1.reloadFromOriginCalled, 0)
        XCTAssertEqual(privateTab.1.reloadFromOriginCalled, 0)
        XCTAssertFalse(try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        ).isEnabled)
    }

    func testPrivateAccessTransitionQuiescesActionsAndPreservesPermissionChanges() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "private_transition")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: WindowUUID())
        let normalTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let privateTab = makeHostTestTab(
            profile: profile,
            isPrivate: true,
            windowUUID: manager.windowUUID
        )
        normalTab.url = try XCTUnwrap(URL(string: "https://example.com/normal-transition"))
        privateTab.url = try XCTUnwrap(URL(string: "https://example.com/private-transition"))
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        try await host.installBundledExtension(identifier: identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        let privateURL = try XCTUnwrap(privateTab.url)
        let updatedExpiration = Date(timeIntervalSince1970: 2_000_000_000)
        var observedPrivateTransition = false
        host.privateAccessCommitHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier,
                  context.hasAccessToPrivateData,
                  !observedPrivateTransition else { return }
            observedPrivateTransition = true
            XCTAssertFalse(host.canMutate(tab: normalTab, in: context))
            XCTAssertFalse(host.canMutate(tab: privateTab, in: context))
            XCTAssertTrue(
                host.needsBackgroundReadiness(
                    beforeNavigating: privateTab,
                    to: privateURL
                ),
                "Private HTTP(S) navigation must fail closed while access is being granted"
            )
            XCTAssertNotNil(context.focusedWindow)
            context.setPermissionStatus(
                .grantedExplicitly,
                for: .contextMenus,
                expirationDate: updatedExpiration
            )
        }
        defer { host.privateAccessCommitHookForTesting = nil }

        try await host.setPrivateAccess(true, identifier: identifier)

        XCTAssertTrue(observedPrivateTransition)
        XCTAssertTrue(host.canMutate(tab: normalTab, in: context))
        XCTAssertTrue(host.canMutate(tab: privateTab, in: context))
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        let persistedContextMenuPermission = try XCTUnwrap(
            store.load().extensions.first { $0.id == identifier }?.grantedPermissions.first {
                $0.value == WKWebExtension.Permission.contextMenus.rawValue
            }
        )
        XCTAssertEqual(persistedContextMenuPermission.expiration, updatedExpiration)
#else
        throw XCTSkip("The transition observation hook is available only in test builds")
#endif
    }

    func testCancelledPrivateAccessTransitionRestoresReadyActions() async throws {
#if DEBUG || TESTING
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        tab.url = try XCTUnwrap(URL(string: "https://example.com/cancelled-private-transition"))
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)
        defer { fixture.host.unregister(tabManager: manager) }
        fixture.host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        XCTAssertFalse(fixture.host.actionItems(for: tab).isEmpty)

        fixture.host.privateAccessTransitionHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier else { return }
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        defer { fixture.host.privateAccessTransitionHookForTesting = nil }

        let transition = Task { @MainActor in
            try await fixture.host.setPrivateAccess(false, identifier: identifier)
        }
        do {
            try await transition.value
            XCTFail("A cancelled private-access transition must fail")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertTrue(fixture.context.hasAccessToPrivateData)
        XCTAssertTrue(fixture.host.canMutate(tab: tab, in: fixture.context))
        XCTAssertFalse(fixture.host.actionItems(for: tab).isEmpty)
        XCTAssertTrue(try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        ).hasPrivateAccess)
#else
        throw XCTSkip("The transition cancellation hook is available only in test builds")
#endif
    }

    func testColdRestoreReloadsAnExistingPageAfterBackgroundContentIsReady() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "restore")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [makeRecord()]))

        let restoredHost = try FloorpNativeWebExtensionHost.install(for: profile)
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: profile, isPrivate: false)
        let configuration = WKWebViewConfiguration()
        restoredHost.attach(to: configuration)
        let webView = MockTabWebView(
            frame: .zero,
            configuration: configuration,
            windowUUID: manager.windowUUID,
            certStore: profile.certStore
        )
        webView.simulateObserverSetup(target: tab)
        webView.loadedURL = try XCTUnwrap(URL(string: "https://example.com/"))
        tab.webView = webView
        tab.url = webView.loadedURL
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        restoredHost.register(tabManager: manager)

        await restoredHost.restoreInstalledExtensions()

        XCTAssertEqual(webView.reloadFromOriginCalled, 1)
        let restoredItem = try XCTUnwrap(
            restoredHost.settingsItems().first {
                $0.identifier == FloorpNativeWebExtensionCatalog.darkReader.identifier
            }
        )
        XCTAssertTrue(restoredItem.isEnabled)
        XCTAssertNil(restoredItem.errorDescription)
        XCTAssertEqual(
            restoredHost.actionItems(for: tab).map(\.contextIdentifier),
            [FloorpNativeWebExtensionCatalog.darkReader.identifier]
        )
    }

    func testColdRestoreConsumesDeferredEnableFromPreviousProcess() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "deferred_enable_restore")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        var record = makeRecord()
        record.isEnabled = false
        record.unloadState = FloorpNativeWebExtensionUnloadState(
            processIdentifier: UUID(),
            enableOnNextColdLaunch: true
        )
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [record]))

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        await host.restoreInstalledExtensions()

        let restored = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == record.id }
        )
        XCTAssertTrue(restored.isEnabled)
        XCTAssertFalse(restored.requiresRestartToEnable)
        XCTAssertTrue(try XCTUnwrap(host.installedContext(identifier: record.id)).isLoaded)
        XCTAssertNil(try store.load().extensions.first?.unloadState)
    }

    func testColdRestoreMigratesThePreviousDarkReaderPackageWithoutLosingUserState() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_migration")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        var legacyRecord = makeRecord()
        let optionalPermissionExpiration = Date(timeIntervalSince1970: 2_000_000_000)
        legacyRecord.hasPrivateAccess = true
        legacyRecord.grantedPermissions.append(
            FloorpNativeWebExtensionPermissionDecision(
                value: WKWebExtension.Permission.contextMenus.rawValue,
                expiration: optionalPermissionExpiration
            )
        )
        legacyRecord.sha256 = FloorpNativeWebExtensionCatalog.previousDarkReaderSHA256
        legacyRecord.isEnabled = false
        legacyRecord.unloadState = FloorpNativeWebExtensionUnloadState(
            processIdentifier: UUID(),
            enableOnNextColdLaunch: true
        )
        let originalContextIdentifier = legacyRecord.contextIdentifier
        let originalBaseURLHost = legacyRecord.baseURLHost
        let originalInstalledAt = legacyRecord.installedAt
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [legacyRecord]))

        let restoredHost = try FloorpNativeWebExtensionHost.install(for: profile)
        await restoredHost.restoreInstalledExtensions()

        let migrated = try XCTUnwrap(
            restoredHost.settingsItems().first {
                $0.identifier == FloorpNativeWebExtensionCatalog.darkReader.identifier
            }
        )
        XCTAssertEqual(migrated.version, FloorpNativeWebExtensionCatalog.darkReader.expectedVersion)
        XCTAssertTrue(migrated.isEnabled)
        XCTAssertTrue(migrated.hasPrivateAccess)
        XCTAssertFalse(migrated.hasUpdate)
        XCTAssertNil(migrated.errorDescription)
        let migratedRegistry = try store.load()
        let migratedRecord = try XCTUnwrap(
            migratedRegistry.extensions.first {
                $0.id == FloorpNativeWebExtensionCatalog.darkReader.identifier
            }
        )
        XCTAssertEqual(migratedRecord.sha256, FloorpNativeWebExtensionCatalog.darkReader.expectedSHA256)
        XCTAssertEqual(
            migratedRecord.packageReference,
            FloorpNativeWebExtensionCatalog.darkReader.packageReference
        )
        XCTAssertEqual(migratedRecord.contextIdentifier, originalContextIdentifier)
        XCTAssertEqual(migratedRecord.baseURLHost, originalBaseURLHost)
        XCTAssertEqual(migratedRecord.installedAt, originalInstalledAt)
        XCTAssertTrue(migratedRecord.isEnabled)
        XCTAssertNil(migratedRecord.unloadState)
        XCTAssertEqual(migratedRecord.transactionState, .stable)
        XCTAssertNil(migratedRecord.rollback)
        XCTAssertNil(migratedRecord.lastError)
        XCTAssertEqual(
            migratedRecord.grantedPermissions.first {
                $0.value == WKWebExtension.Permission.contextMenus.rawValue
            }?.expiration,
            optionalPermissionExpiration
        )
    }

    // swiftlint:disable:next function_body_length
    func testColdRestoreMigratesTheInitialFloorpUBOLPackageToTheCurrentBuild() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_migration")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        var legacyRecord = makeUBOLRecord()
        legacyRecord.sha256 = FloorpNativeWebExtensionCatalog.initialFloorpUBlockOriginLiteSHA256
        var upstreamRecord = legacyRecord
        upstreamRecord.packageReference = "uBOLite_2026.825.1619.safari.zip"
        upstreamRecord.sha256 = FloorpNativeWebExtensionCatalog.legacyUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(upstreamRecord),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var previousDerivedRecord = legacyRecord
        previousDerivedRecord.sha256 = FloorpNativeWebExtensionCatalog
            .previousUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                previousDerivedRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preStorageSerializationRecord = legacyRecord
        preStorageSerializationRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preStorageSerializationUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preStorageSerializationRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preContentScriptSentinelRecord = legacyRecord
        preContentScriptSentinelRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preContentScriptSentinelUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preContentScriptSentinelRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preLocalStorageSentinelRecord = legacyRecord
        preLocalStorageSentinelRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preLocalStorageSentinelUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preLocalStorageSentinelRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preWakeReconciliationRecord = legacyRecord
        preWakeReconciliationRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preWakeContentScriptReconciliationUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preWakeReconciliationRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preDurableProtectionRecord = legacyRecord
        preDurableProtectionRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preDurableProtectionReconciliationUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preDurableProtectionRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var prePopupInitializationRetryRecord = legacyRecord
        prePopupInitializationRetryRecord.sha256 = FloorpNativeWebExtensionCatalog
            .prePopupInitializationRetryUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                prePopupInitializationRetryRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preSafariDNRNormalizationRecord = legacyRecord
        preSafariDNRNormalizationRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preSafariDNRNormalizationUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preSafariDNRNormalizationRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preUserDNRFailClosedRecord = legacyRecord
        preUserDNRFailClosedRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preUserDNRFailClosedUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preUserDNRFailClosedRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preSafariDNRKeeperRecord = legacyRecord
        preSafariDNRKeeperRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preSafariDNRKeeperUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preSafariDNRKeeperRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        var preSafariDNRPerStoreCapacityGuardRecord = legacyRecord
        preSafariDNRPerStoreCapacityGuardRecord.sha256 = FloorpNativeWebExtensionCatalog
            .preSafariDNRPerStoreCapacityGuardUBlockOriginLiteSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(
                preSafariDNRPerStoreCapacityGuardRecord
            ),
            FloorpNativeWebExtensionCatalog.uBlockOriginLite
        )
        let originalContextIdentifier = legacyRecord.contextIdentifier
        let originalBaseURLHost = legacyRecord.baseURLHost
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [legacyRecord]))

        let restoredHost = try FloorpNativeWebExtensionHost.install(for: profile)
        await restoredHost.restoreInstalledExtensions()

        let migrated = try XCTUnwrap(
            restoredHost.settingsItems().first {
                $0.identifier == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
            }
        )
        XCTAssertTrue(migrated.isEnabled)
        XCTAssertFalse(migrated.hasUpdate)
        XCTAssertNil(migrated.errorDescription)
        let migratedRegistry = try store.load()
        let migratedRecord = try XCTUnwrap(
            migratedRegistry.extensions.first {
                $0.id == FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
            }
        )
        XCTAssertEqual(
            migratedRecord.sha256,
            FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedSHA256
        )
        XCTAssertEqual(migratedRecord.contextIdentifier, originalContextIdentifier)
        XCTAssertEqual(migratedRecord.baseURLHost, originalBaseURLHost)
        XCTAssertEqual(migratedRecord.grantedPermissions, legacyRecord.grantedPermissions)
        XCTAssertEqual(migratedRecord.grantedMatchPatterns, legacyRecord.grantedMatchPatterns)
    }

    func testColdRestoreFinishesPendingPurgeInsteadOfMigratingPreviousBundledPackage() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "migration_pending_purge")
        let profile = profileFixture.profile
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        var pendingRecord = makeRecord()
        let isolationToken = UUID().uuidString.lowercased()
        pendingRecord.contextIdentifier += ".pending-purge.\(isolationToken)"
        pendingRecord.baseURLHost = "darkreader-pending-purge-\(isolationToken).floorp.internal"
        pendingRecord.sha256 = FloorpNativeWebExtensionCatalog.previousDarkReaderSHA256
        pendingRecord.isEnabled = false
        pendingRecord.transactionState = .pendingPurge
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [pendingRecord]))

        let restoredHost = try FloorpNativeWebExtensionHost.install(for: profile)
        await restoredHost.restoreInstalledExtensions()

        XCTAssertTrue(restoredHost.settingsItems().isEmpty)
        XCTAssertNil(restoredHost.installedContext(identifier: pendingRecord.id))
        XCTAssertTrue(try store.load().extensions.isEmpty)
    }

    func testUBOLReadinessRetriesUntilConcurrentTopologyChangesSettle() async throws {
#if DEBUG || TESTING
        // Repeated real WebKit probes can exceed the one-minute CI default on
        // a loaded Simulator even though every retry continues to make progress.
        executionTimeAllowance = 180
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_topology_readiness")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let manager = MockTabManager(windowUUID: WindowUUID())
        let normalTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let privateTab = makeHostTestTab(
            profile: profile,
            isPrivate: true,
            windowUUID: manager.windowUUID
        )
        let removableTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let persistentTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        manager.tabs = [normalTab, privateTab, removableTab]
        manager.normalTabs = [normalTab, removableTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        var readinessHookAttempts = 0
        var didExerciseTopologyMutation = false
        var didFocusPrivateDuringReadiness = false
        var sameRealmPropertyNotificationCount = 0
        host.backgroundReadinessAttemptHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier else { return }
            readinessHookAttempts += 1
            for _ in 0..<25 {
                host.tabPropertiesDidChange([.URL, .title, .loading], for: normalTab)
                sameRealmPropertyNotificationCount += 1
            }
            if !didExerciseTopologyMutation {
                didExerciseTopologyMutation = true
                manager.tabs.removeAll { $0 === removableTab }
                manager.normalTabs.removeAll { $0 === removableTab }
                host.tabManager(manager, didRemoveTab: removableTab, isRestoring: false)
                manager.tabs.append(persistentTab)
                manager.normalTabs.append(persistentTab)
                host.announceTabIfNeeded(persistentTab)
            }
            if readinessHookAttempts <= 9 {
                let focusesPrivate = !readinessHookAttempts.isMultiple(of: 2)
                didFocusPrivateDuringReadiness = didFocusPrivateDuringReadiness || focusesPrivate
                manager.selectedTab = focusesPrivate ? privateTab : normalTab
                host.focus(windowUUID: manager.windowUUID, isPrivate: focusesPrivate)
            }
        }
        defer { host.backgroundReadinessAttemptHookForTesting = nil }

        try await host.installBundledExtension(identifier: identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))

        XCTAssertEqual(readinessHookAttempts, 10)
        XCTAssertEqual(sameRealmPropertyNotificationCount, 250)
        XCTAssertTrue(didExerciseTopologyMutation)
        XCTAssertTrue(didFocusPrivateDuringReadiness)
        // This hook exercises installation readiness only. Private-access
        // publication has two additional, intentionally stable readiness gates.
        host.backgroundReadinessAttemptHookForTesting = nil
        try await host.setPrivateAccess(true, identifier: identifier)

        XCTAssertEqual(context.openWindows.count, 2)
        XCTAssertEqual(context.openTabs.count, 3)
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: normalTab) as AnyObject)
        })
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: privateTab) as AnyObject)
        })
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: persistentTab) as AnyObject)
        })
        XCTAssertFalse(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: removableTab) as AnyObject)
        })
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testUBOLReadinessRetriesTransientWebKitProbeFailuresWithFreshAttempts() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_readiness_probe_retry")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        var injectedFailureCount = 0
        var successfulResponseCount = 0
        host.backgroundReadinessTransientFailureHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier, injectedFailureCount < 2 else { return nil }
            injectedFailureCount += 1
            return FloorpNativeWebExtensionError.hostUnavailable
        }
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            successfulResponseCount += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        defer {
            host.backgroundReadinessTransientFailureHookForTesting = nil
            host.backgroundReadinessResponseHookForTesting = nil
        }

        try await host.installBundledExtension(identifier: identifier)

        XCTAssertEqual(injectedFailureCount, 2)
        XCTAssertEqual(successfulResponseCount, 1)
        host.backgroundReadinessTransientFailureHookForTesting = nil
        host.backgroundReadinessResponseHookForTesting = nil
        // Complete a real probe after the deterministic retry assertion so the
        // test cannot leave an incompletely initialized background behind.
        try await host.setPrivateAccess(true, identifier: identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))
        XCTAssertTrue(context.hasAccessToPrivateData)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )

        // A retryable error delivered through WebKit has completed its native
        // callback. Those failed attempts must be released instead of being
        // mistaken for timed-out callbacks and retained until process exit.
        try await host.uninstall(identifier: identifier)
        XCTAssertNil(host.installedContext(identifier: identifier))
        XCTAssertFalse(context.isLoaded)
        XCTAssertFalse(host.settingsItems().contains { $0.identifier == identifier })
#else
        throw XCTSkip("The background readiness hooks are available only in test builds")
#endif
    }

    func testUBOLReadinessDoesNotRetryExplicitNegativeResponse() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_readiness_negative")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        var responseCount = 0
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            responseCount += 1
            return [
                "ready": false,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion,
                "error": "explicit permanent failure"
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        do {
            try await host.installBundledExtension(identifier: identifier)
            XCTFail("An explicit negative readiness response must fail installation")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("explicit permanent failure"),
                error.localizedDescription
            )
        }
        XCTAssertEqual(responseCount, 1)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testDarkReaderReadinessRequiresSemanticAcknowledgement() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_readiness_negative")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        defer { profileFixture.cleanup() }
        let item = FloorpNativeWebExtensionCatalog.darkReader
        var responseCount = 0
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == item.identifier else { return nil }
            responseCount += 1
            return [
                "ready": false,
                "version": item.expectedVersion,
                "error": "injected Dark Reader storage durability failure"
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        do {
            try await host.installBundledExtension(identifier: item.identifier)
            XCTFail("Dark Reader must not activate without its semantic readiness acknowledgement")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("injected Dark Reader storage durability failure"),
                error.localizedDescription
            )
        }
        XCTAssertEqual(responseCount, 1)
        XCTAssertNil(host.installedContext(identifier: item.identifier))
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testUBOLNavigationReadinessCachesOnlySuccessfulRealmProbes() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_navigation_readiness")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        try await host.installBundledExtension(identifier: identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: WindowUUID(),
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let url = try XCTUnwrap(URL(string: "https://example.com/ubol-readiness"))
        let tab = manager.seedTab(url: url, isPrivate: false)
        manager.selectedTab = tab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        var shouldFail = true
        var responseCount = 0
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            responseCount += 1
            return [
                "ready": !shouldFail,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion,
                "error": shouldFail ? "injected realm readiness failure" : ""
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        let failedAction = MockNavigationAction(url: url, type: .linkActivated)
        let failedGeneration = host.beginNavigationPreparation(for: tab)
        let failedPreparation = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: failedAction,
            generation: failedGeneration
        )
        XCTAssertFalse(failedPreparation)
        XCTAssertFalse(host.consumePreparedNavigation(failedAction))
        let failedProtection = try XCTUnwrap(
            host.navigationProtectionFailure(for: tab, generation: failedGeneration)
        )
        XCTAssertEqual(failedProtection.extensionName, "uBlock Origin Lite")
        XCTAssertTrue(
            failedProtection.detail.contains("injected realm readiness failure"),
            failedProtection.detail
        )
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        shouldFail = false
        let successfulAction = MockNavigationAction(url: url, type: .linkActivated)
        let successfulGeneration = host.beginNavigationPreparation(for: tab)
        let successfulPreparation = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: successfulAction,
            generation: successfulGeneration
        )
        XCTAssertTrue(successfulPreparation)
        XCTAssertTrue(host.consumePreparedNavigation(successfulAction))
        XCTAssertNil(
            host.navigationProtectionFailure(
                for: tab,
                generation: successfulGeneration
            )
        )
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        XCTAssertEqual(responseCount, 2)

        let preparedThenStaleAction = MockNavigationAction(url: url, type: .linkActivated)
        let preparedThenStaleGeneration = host.beginNavigationPreparation(for: tab)
        let preparedThenStaleResult = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: preparedThenStaleAction,
            generation: preparedThenStaleGeneration
        )
        XCTAssertTrue(preparedThenStaleResult)
        _ = host.beginNavigationPreparation(for: tab)
        XCTAssertFalse(host.consumePreparedNavigation(preparedThenStaleAction))

        let preparedBeforeFocusLoss = MockNavigationAction(url: url, type: .linkActivated)
        let focusGeneration = host.beginNavigationPreparation(for: tab)
        let preparedBeforeFocusLossResult = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: preparedBeforeFocusLoss,
            generation: focusGeneration
        )
        XCTAssertTrue(preparedBeforeFocusLossResult)
        host.resignFocus(windowUUID: manager.windowUUID)
        XCTAssertFalse(host.consumePreparedNavigation(preparedBeforeFocusLoss))
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        host.backgroundReadinessResponseHookForTesting = nil
        try await host.setPrivateAccess(true, identifier: identifier)
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        XCTAssertTrue(context.hasAccessToPrivateData)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testNavigationReadinessRejectsFocusChangeAfterEarlierCandidate() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "multi_extension_focus_race")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        defer { profileFixture.cleanup() }
        let uBlockIdentifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let darkReaderIdentifier = FloorpNativeWebExtensionCatalog.darkReader.identifier

        // Preserve this order: the regression required uBO to settle first,
        // then focus to move while a later blocker was completing.
        try await host.installBundledExtension(identifier: uBlockIdentifier)
        try await host.installBundledExtension(identifier: darkReaderIdentifier)

        let targetManager = MockTabManager(windowUUID: WindowUUID())
        let targetTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: targetManager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/multi-extension-focus-race"))
        targetTab.url = url
        targetManager.tabs = [targetTab]
        targetManager.normalTabs = [targetTab]
        targetManager.selectedTab = targetTab

        let replacementManager = MockTabManager(windowUUID: WindowUUID())
        let replacementTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: replacementManager.windowUUID
        )
        replacementTab.url = try XCTUnwrap(URL(string: "https://example.org/replacement-focus"))
        replacementManager.tabs = [replacementTab]
        replacementManager.normalTabs = [replacementTab]
        replacementManager.selectedTab = replacementTab

        host.register(tabManager: targetManager)
        host.register(tabManager: replacementManager)
        defer {
            host.unregister(windowUUID: replacementManager.windowUUID)
            host.unregister(windowUUID: targetManager.windowUUID)
        }
        host.focus(windowUUID: targetManager.windowUUID, isPrivate: false)

        var uBlockProbeCount = 0
        host.backgroundReadinessResponseHookForTesting = { identifier, _ in
            guard identifier == uBlockIdentifier else { return nil }
            uBlockProbeCount += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        var completedIdentifiers = [String]()
        var didMoveFocus = false
        host.navigationCandidateReadinessCompletedHookForTesting = { identifier, tab in
            guard tab === targetTab else { return }
            completedIdentifiers.append(identifier)
            guard identifier == darkReaderIdentifier, !didMoveFocus else { return }
            didMoveFocus = true
            host.focus(windowUUID: replacementManager.windowUUID, isPrivate: false)
        }
        defer {
            host.backgroundReadinessResponseHookForTesting = nil
            host.navigationCandidateReadinessCompletedHookForTesting = nil
        }

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: targetTab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: targetTab,
            to: url,
            navigationAction: action,
            generation: generation
        )

        XCTAssertFalse(didPrepare)
        XCTAssertFalse(host.consumePreparedNavigation(action))
        XCTAssertTrue(didMoveFocus)
        XCTAssertEqual(Array(completedIdentifiers.prefix(2)), [uBlockIdentifier, darkReaderIdentifier])
        XCTAssertEqual(uBlockProbeCount, 1)
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: targetTab, to: url))
#else
        throw XCTSkip("The navigation readiness hooks are available only in test builds")
#endif
    }

    func testClosingUBOLOptionsInvalidatesSameRealmNavigationReadiness() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_options_readiness")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        defer { profileFixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        try await host.installBundledExtension(identifier: identifier)

        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/options-readiness"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        var probeCount = 0
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            probeCount += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: tab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: action,
            generation: generation
        )
        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.consumePreparedNavigation(action))
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        let optionsController = try await host.optionsViewController(
            identifier: identifier,
            sourceTab: tab,
            isPrivate: false
        )
        let navigation = try XCTUnwrap(
            optionsController as? UINavigationController
        )
        let page = try XCTUnwrap(
            navigation.viewControllers.first as? FloorpNativeWebExtensionPageViewController
        )
        page.prepareForHostTeardown()
        page.prepareForHostTeardown()

        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        let postOptionsAction = MockNavigationAction(url: url, type: .linkActivated)
        let postOptionsGeneration = host.beginNavigationPreparation(for: tab)
        let didPrepareAfterOptions = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: postOptionsAction,
            generation: postOptionsGeneration
        )
        XCTAssertTrue(didPrepareAfterOptions)
        XCTAssertTrue(host.consumePreparedNavigation(postOptionsAction))
        XCTAssertEqual(probeCount, 3)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testNavigationReadinessRetriesWhenUBOLOptionsInvalidateDuringLaterCandidate()
        async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_options_candidate_race")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        defer { profileFixture.cleanup() }
        let uBlockIdentifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let darkReaderIdentifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        try await host.installBundledExtension(identifier: uBlockIdentifier)
        try await host.installBundledExtension(identifier: darkReaderIdentifier)

        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/options-candidate-race"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        let optionsController = try await host.optionsViewController(
            identifier: uBlockIdentifier,
            sourceTab: tab,
            isPrivate: false
        )
        let optionsNavigation = try XCTUnwrap(
            optionsController as? UINavigationController
        )
        let optionsPage = try XCTUnwrap(
            optionsNavigation.viewControllers.first as? FloorpNativeWebExtensionPageViewController
        )
        var probeCount = 0
        host.backgroundReadinessResponseHookForTesting = { identifier, _ in
            guard identifier == uBlockIdentifier else { return nil }
            probeCount += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        var didCloseOptions = false
        host.navigationCandidateReadinessCompletedHookForTesting = { identifier, candidateTab in
            guard identifier == darkReaderIdentifier,
                  candidateTab === tab,
                  !didCloseOptions else { return }
            didCloseOptions = true
            optionsPage.prepareForHostTeardown()
        }
        defer {
            host.backgroundReadinessResponseHookForTesting = nil
            host.navigationCandidateReadinessCompletedHookForTesting = nil
        }

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: tab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: action,
            generation: generation
        )

        XCTAssertTrue(didCloseOptions)
        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.consumePreparedNavigation(action))
        XCTAssertEqual(probeCount, 2)
        XCTAssertTrue(
            host.isNavigationReadinessVerifiedForTesting(
                identifier: uBlockIdentifier,
                isPrivate: false
            )
        )
#else
        throw XCTSkip("The navigation readiness hooks are available only in test builds")
#endif
    }

    func testNavigationReadinessRetriesWhenUBOLOptionsInvalidateDuringUBlockProbe()
        async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_options_probe_race")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        defer { profileFixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        try await host.installBundledExtension(identifier: identifier)

        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/options-probe-race"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        let optionsController = try await host.optionsViewController(
            identifier: identifier,
            sourceTab: tab,
            isPrivate: false
        )
        let optionsNavigation = try XCTUnwrap(
            optionsController as? UINavigationController
        )
        let optionsPage = try XCTUnwrap(
            optionsNavigation.viewControllers.first
                as? FloorpNativeWebExtensionPageViewController
        )
        var probeCount = 0
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            probeCount += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        var navigationReadinessTimeouts = [UInt64]()
        var didInvalidateDuringProbe = false
        host.backgroundReadinessAttemptHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier,
                  !didInvalidateDuringProbe else { return }
            didInvalidateDuringProbe = true
            optionsPage.prepareForHostTeardown()
        }
        host.navigationReadinessTimeoutHookForTesting = { hookIdentifier, timeout in
            guard hookIdentifier == identifier else { return }
            navigationReadinessTimeouts.append(timeout)
        }
        defer {
            host.backgroundReadinessResponseHookForTesting = nil
            host.backgroundReadinessAttemptHookForTesting = nil
            host.navigationReadinessTimeoutHookForTesting = nil
        }

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: tab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: action,
            generation: generation
        )

        XCTAssertTrue(didInvalidateDuringProbe)
        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.consumePreparedNavigation(action))
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(navigationReadinessTimeouts.count, 2)
        XCTAssertLessThanOrEqual(navigationReadinessTimeouts[0], 90_000_000_000)
        XCTAssertLessThan(navigationReadinessTimeouts[1], navigationReadinessTimeouts[0])
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
#else
        throw XCTSkip("The navigation readiness hooks are available only in test builds")
#endif
    }

    // swiftlint:disable:next function_body_length
    func testColdUBOLRestorePastSceneBudgetKeepsLatestHTTPNavigationPending() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_slow_restore_gate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        var deferredRecord = makeUBOLRecord()
        deferredRecord.isEnabled = false
        deferredRecord.unloadState = FloorpNativeWebExtensionUnloadState(
            processIdentifier: UUID(),
            enableOnNextColdLaunch: true
        )
        try registryStore(for: profile).save(
            FloorpNativeWebExtensionRegistry(extensions: [deferredRecord])
        )

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/slow-cold-restore"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        let restoreStarted = expectation(description: "uBO cold restore reached delayed startup")
        var releaseContinuation: AsyncStream<Void>.Continuation?
        let releaseStream = AsyncStream<Void> { continuation in
            releaseContinuation = continuation
        }
        host.startupRestoreReadinessHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier else { return }
            restoreStarted.fulfill()
            for await _ in releaseStream { break }
        }
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        defer {
            releaseContinuation?.finish()
            host.startupRestoreReadinessHookForTesting = nil
            host.backgroundReadinessResponseHookForTesting = nil
        }

        let restoreTask = Task { @MainActor in
            await host.restoreInstalledExtensions()
        }
        await fulfillment(of: [restoreStarted], timeout: 10)

        XCTAssertFalse(
            host.needsBackgroundReadiness(
                beforeNavigating: tab,
                to: try XCTUnwrap(URL(string: "about:home"))
            )
        )
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        let cancelledAction = MockNavigationAction(url: url, type: .linkActivated)
        let cancelledGeneration = host.beginNavigationPreparation(for: tab)
        let cancelledPreparationFinished = expectation(
            description: "Cancelled startup navigation waiter finishes before restore"
        )
        let cancelledPreparation = Task { @MainActor in
            let result = await host.prepareBackgroundContent(
                beforeNavigating: tab,
                to: url,
                navigationAction: cancelledAction,
                generation: cancelledGeneration
            )
            XCTAssertFalse(result)
            cancelledPreparationFinished.fulfill()
        }
        await Task.yield()
        cancelledPreparation.cancel()
        await fulfillment(of: [cancelledPreparationFinished], timeout: 1)

        let staleAction = MockNavigationAction(url: url, type: .linkActivated)
        let staleGeneration = host.beginNavigationPreparation(for: tab)
        var staleFinished = false
        let stalePreparation = Task { @MainActor in
            let result = await host.prepareBackgroundContent(
                beforeNavigating: tab,
                to: url,
                navigationAction: staleAction,
                generation: staleGeneration
            )
            staleFinished = true
            return result
        }

        let currentAction = MockNavigationAction(url: url, type: .linkActivated)
        let currentGeneration = host.beginNavigationPreparation(for: tab)
        var currentFinished = false
        let currentPreparation = Task { @MainActor in
            let result = await host.prepareBackgroundContent(
                beforeNavigating: tab,
                to: url,
                navigationAction: currentAction,
                generation: currentGeneration
            )
            currentFinished = true
            return result
        }

        // FloorpBootstrapper releases the scene after eight seconds. Even
        // beyond that UI budget, neither the stale nor current HTTP request may
        // pass while the installed blocker is still restoring.
        try await Task.sleep(nanoseconds: 8_100_000_000)
        XCTAssertFalse(staleFinished)
        XCTAssertFalse(currentFinished)

        releaseContinuation?.yield()
        releaseContinuation?.finish()
        await restoreTask.value

        let staleResult = await stalePreparation.value
        let currentResult = await currentPreparation.value
        XCTAssertFalse(staleResult)
        XCTAssertTrue(currentResult)
        XCTAssertFalse(host.consumePreparedNavigation(staleAction))
        XCTAssertTrue(host.consumePreparedNavigation(currentAction))
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        XCTAssertTrue(
            try XCTUnwrap(host.installedContext(identifier: identifier)).errors.isEmpty
        )
#else
        throw XCTSkip("The startup restore hook is available only in test builds")
#endif
    }

    func testColdDarkReaderRestoreDoesNotHoldHTTPNavigation() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_slow_restore_gate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        try registryStore(for: profile).save(
            FloorpNativeWebExtensionRegistry(extensions: [makeRecord()])
        )

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/darkreader-slow-restore"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        let restoreStarted = expectation(description: "Dark Reader restore reached delayed startup")
        var releaseContinuation: AsyncStream<Void>.Continuation?
        let releaseStream = AsyncStream<Void> { continuation in
            releaseContinuation = continuation
        }
        host.startupRestoreReadinessHookForTesting = { identifier in
            guard identifier == item.identifier else { return }
            restoreStarted.fulfill()
            for await _ in releaseStream { break }
        }
        host.backgroundReadinessResponseHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return nil }
            return ["ready": true, "version": item.expectedVersion]
        }
        defer {
            releaseContinuation?.finish()
            host.startupRestoreReadinessHookForTesting = nil
            host.backgroundReadinessResponseHookForTesting = nil
        }

        let restoreTask = Task { @MainActor in
            await host.restoreInstalledExtensions()
        }
        await fulfillment(of: [restoreStarted], timeout: 10)
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: tab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: action,
            generation: generation
        )
        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.consumePreparedNavigation(action))
        XCTAssertNil(host.navigationProtectionFailure(for: tab, generation: generation))

        releaseContinuation?.yield()
        releaseContinuation?.finish()
        await restoreTask.value
        XCTAssertNotNil(host.installedContext(identifier: item.identifier))
#else
        throw XCTSkip("The startup restore hook is available only in test builds")
#endif
    }

    func testFailedColdUBOLRestoreStaysClosedUntilExplicitDisableAndCanQueueRetry()
        async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_failed_restore_gate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        try registryStore(for: profile).save(
            FloorpNativeWebExtensionRegistry(extensions: [makeUBOLRecord()])
        )

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/failed-cold-restore"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            return [
                "ready": false,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion,
                "error": "injected terminal cold-restore failure"
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        await host.restoreInstalledExtensions()

        let failed = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertTrue(failed.isEnabled)
        XCTAssertTrue(
            failed.errorDescription?.contains("injected terminal cold-restore failure") == true
        )
        XCTAssertNil(host.installedContext(identifier: identifier))
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))
        let blockedAction = MockNavigationAction(url: url, type: .linkActivated)
        let blockedGeneration = host.beginNavigationPreparation(for: tab)
        let blockedPreparation = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: blockedAction,
            generation: blockedGeneration
        )
        XCTAssertFalse(blockedPreparation)
        let protectionFailure = try XCTUnwrap(
            host.navigationProtectionFailure(
                for: tab,
                generation: blockedGeneration
            )
        )
        XCTAssertEqual(protectionFailure.extensionName, "uBlock Origin Lite")
        XCTAssertTrue(
            protectionFailure.detail.contains("injected terminal cold-restore failure"),
            protectionFailure.detail
        )
        let supersedingGeneration = host.beginNavigationPreparation(for: tab)
        XCTAssertNotEqual(supersedingGeneration, blockedGeneration)
        XCTAssertNil(
            host.navigationProtectionFailure(
                for: tab,
                generation: blockedGeneration
            )
        )

        try await host.setEnabled(false, identifier: identifier)
        let disabled = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertTrue(
            disabled.errorDescription?.contains("injected terminal cold-restore failure") == true
        )
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        try await host.setEnabled(true, identifier: identifier)
        let queued = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(queued.isEnabled)
        XCTAssertTrue(queued.requiresRestartToEnable)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testFailedColdDarkReaderRestoreFailsOpenWithoutSilentlyLosingDiagnostics()
        async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_failed_restore_gate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        try registryStore(for: profile).save(
            FloorpNativeWebExtensionRegistry(extensions: [makeRecord()])
        )

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let manager = MockTabManager(windowUUID: WindowUUID())
        let tab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/darkreader-failed-restore"))
        tab.url = url
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        host.register(tabManager: manager)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        host.backgroundReadinessResponseHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return nil }
            return [
                "ready": false,
                "version": item.expectedVersion,
                "error": "injected terminal Dark Reader restore failure"
            ]
        }
        defer { host.backgroundReadinessResponseHookForTesting = nil }

        await host.restoreInstalledExtensions()

        let failed = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == item.identifier }
        )
        XCTAssertTrue(failed.isEnabled)
        XCTAssertTrue(
            failed.errorDescription?.contains("injected terminal Dark Reader restore failure") == true
        )
        XCTAssertNil(host.installedContext(identifier: item.identifier))
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        let action = MockNavigationAction(url: url, type: .linkActivated)
        let generation = host.beginNavigationPreparation(for: tab)
        let didPrepare = await host.prepareBackgroundContent(
            beforeNavigating: tab,
            to: url,
            navigationAction: action,
            generation: generation
        )
        XCTAssertTrue(didPrepare)
        XCTAssertTrue(host.consumePreparedNavigation(action))
        XCTAssertNil(host.navigationProtectionFailure(for: tab, generation: generation))
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    func testPendingColdUBOLRestoreDoesNotGatePrivateNavigationWithoutPrivateAccess()
        throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_private_restore_gate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        try registryStore(for: profile).save(
            FloorpNativeWebExtensionRegistry(extensions: [makeUBOLRecord()])
        )

        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let manager = MockTabManager(windowUUID: WindowUUID())
        let normalTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let privateTab = makeHostTestTab(
            profile: profile,
            isPrivate: true,
            windowUUID: manager.windowUUID
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/private-without-access"))
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]

        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: normalTab, to: url))
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: privateTab, to: url))
    }

    func testUBOLReadinessUsesWKErrorCodeAcrossLocalizedDescriptions() async throws {
#if DEBUG || TESTING
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_localized_wkerror")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        var injectedFailures = 0
        var successfulResponses = 0
        host.backgroundReadinessTransientFailureHookForTesting = { hookIdentifier, attempt in
            guard hookIdentifier == identifier, attempt == 1 else { return nil }
            injectedFailures += 1
            return NSError(
                domain: WKError.errorDomain,
                code: WKError.Code.webContentProcessTerminated.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "一時的に処理を完了できませんでした"]
            )
        }
        host.backgroundReadinessResponseHookForTesting = { hookIdentifier, _ in
            guard hookIdentifier == identifier else { return nil }
            successfulResponses += 1
            return [
                "ready": true,
                "version": FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
            ]
        }
        defer {
            host.backgroundReadinessTransientFailureHookForTesting = nil
            host.backgroundReadinessResponseHookForTesting = nil
        }

        try await host.installBundledExtension(identifier: identifier)

        XCTAssertEqual(injectedFailures, 1)
        XCTAssertEqual(successfulResponses, 1)

        var nonRetryableFailures = 0
        host.backgroundReadinessTransientFailureHookForTesting = { hookIdentifier, attempt in
            guard hookIdentifier == identifier, attempt == 1 else { return nil }
            nonRetryableFailures += 1
            return NSError(
                domain: WKError.errorDomain,
                code: WKError.Code.javaScriptExceptionOccurred.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "一時的に処理を完了できませんでした"]
            )
        }
        do {
            try await host.setPrivateAccess(true, identifier: identifier)
            XCTFail("A non-transient WKError code must fail without retrying")
        } catch {
            XCTAssertEqual((error as NSError).code, WKError.Code.javaScriptExceptionOccurred.rawValue)
        }
        XCTAssertEqual(nonRetryableFailures, 1)
        XCTAssertEqual(successfulResponses, 1)
#else
        throw XCTSkip("The background readiness hook is available only in test builds")
#endif
    }

    // swiftlint:disable:next function_body_length
    func testUBOLReenableWaitsForColdLaunchAfterDisable() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_readiness")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        let identifier = FloorpNativeWebExtensionCatalog.uBlockOriginLite.identifier
        let manager = MockTabManager(windowUUID: WindowUUID())
        let normalTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        let privateTab = makeHostTestTab(
            profile: profile,
            isPrivate: true,
            windowUUID: manager.windowUUID
        )
        normalTab.url = try XCTUnwrap(URL(string: "https://example.com/normal-readiness"))
        privateTab.url = try XCTUnwrap(URL(string: "https://example.com/private-readiness"))
        manager.tabs = [normalTab, privateTab]
        manager.normalTabs = [normalTab]
        manager.privateTabs = [privateTab]
        manager.selectedTab = normalTab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        try await host.installBundledExtension(identifier: identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: identifier))
        try await host.setPrivateAccess(true, identifier: identifier)
        let enabled = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == identifier }
        )
        let runtimeHadPrivateAccess = context.hasAccessToPrivateData
        let runtimeGrantedPermissions = context.grantedPermissions
        let runtimeGrantedMatchPatterns = context.grantedPermissionMatchPatterns
        try await host.setEnabled(false, identifier: identifier)

#if DEBUG || TESTING
        let removableTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        removableTab.url = URL(string: "https://example.com/removable-readiness")
        let persistentTab = makeHostTestTab(
            profile: profile,
            isPrivate: false,
            windowUUID: manager.windowUUID
        )
        persistentTab.url = URL(string: "https://example.com/persistent-readiness")
        manager.tabs.append(removableTab)
        manager.normalTabs.append(removableTab)
        host.announceTabIfNeeded(removableTab)
        var readinessHookAttempts = 0
        var didExerciseTopologyMutation = false
        var didFocusPrivateDuringReadiness = false
        host.backgroundReadinessAttemptHookForTesting = { hookIdentifier in
            guard hookIdentifier == identifier else { return }
            readinessHookAttempts += 1
            if !didExerciseTopologyMutation {
                didExerciseTopologyMutation = true
                manager.tabs.removeAll { $0 === removableTab }
                manager.normalTabs.removeAll { $0 === removableTab }
                host.tabManager(manager, didRemoveTab: removableTab, isRestoring: false)
                manager.tabs.append(persistentTab)
                manager.normalTabs.append(persistentTab)
                host.announceTabIfNeeded(persistentTab)
            }
            if readinessHookAttempts <= 9 {
                let focusesPrivate = !readinessHookAttempts.isMultiple(of: 2)
                didFocusPrivateDuringReadiness = didFocusPrivateDuringReadiness || focusesPrivate
                manager.selectedTab = focusesPrivate ? privateTab : normalTab
                host.focus(windowUUID: manager.windowUUID, isPrivate: focusesPrivate)
            }
        }
        defer { host.backgroundReadinessAttemptHookForTesting = nil }
#endif

        try await host.setEnabled(true, identifier: identifier)
        let queued = try XCTUnwrap(
            host.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(queued.isEnabled)
        XCTAssertTrue(queued.requiresRestartToEnable)
        XCTAssertEqual(queued.permissions, enabled.permissions)
        XCTAssertEqual(queued.matchPatterns, enabled.matchPatterns)
        XCTAssertEqual(queued.hasPrivateAccess, enabled.hasPrivateAccess)
        // A readiness timeout deliberately keeps the loaded WebKit context
        // quarantined until process exit. The host must stay inert without
        // changing authorization while WebKit can still deliver an API message.
        if context.isLoaded {
            XCTAssertEqual(context.hasAccessToPrivateData, runtimeHadPrivateAccess)
            XCTAssertEqual(context.grantedPermissions, runtimeGrantedPermissions)
            XCTAssertEqual(
                context.grantedPermissionMatchPatterns,
                runtimeGrantedMatchPatterns
            )
            XCTAssertTrue(host.isContextQuarantinedForTesting(identifier: identifier))
            XCTAssertTrue(queued.errorDescription?.contains("Restart Floorp") == true)
        }
        XCTAssertFalse(host.canMutate(tab: normalTab, in: context))
        XCTAssertFalse(host.canMutate(tab: privateTab, in: context))
        XCTAssertTrue(host.actionItems(for: normalTab).isEmpty)
        XCTAssertTrue(host.actionItems(for: privateTab).isEmpty)
        if queued.requiresRestartToEnable {
            try await host.setEnabled(false, identifier: identifier)
            let cancelled = try XCTUnwrap(
                host.settingsItems().first { $0.identifier == identifier }
            )
            XCTAssertFalse(cancelled.isEnabled)
            XCTAssertFalse(cancelled.requiresRestartToEnable)
            XCTAssertEqual(cancelled.permissions, enabled.permissions)
            XCTAssertEqual(cancelled.matchPatterns, enabled.matchPatterns)
            XCTAssertEqual(cancelled.hasPrivateAccess, enabled.hasPrivateAccess)
            XCTAssertFalse(host.canMutate(tab: normalTab, in: context))
            XCTAssertFalse(host.canMutate(tab: privateTab, in: context))
            return
        }
#if DEBUG || TESTING
        XCTAssertGreaterThan(readinessHookAttempts, 9)
        XCTAssertTrue(didExerciseTopologyMutation)
        XCTAssertTrue(didFocusPrivateDuringReadiness)
        XCTAssertEqual(context.openWindows.count, 2)
        XCTAssertEqual(context.openTabs.count, 3)
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: normalTab) as AnyObject)
        })
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: privateTab) as AnyObject)
        })
        XCTAssertTrue(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: persistentTab) as AnyObject)
        })
        XCTAssertFalse(context.openTabs.contains {
            ($0 as AnyObject) === (host.tabAdapter(for: removableTab) as AnyObject)
        })
        let topologyConfiguration = try XCTUnwrap(context.webViewConfiguration)
        let topologyWebView = WKWebView(frame: .zero, configuration: topologyConfiguration)
        let topologyNavigation = FloorpWebExtensionNavigationWaiter()
        try await topologyNavigation.load(
            context.baseURL.appendingPathComponent("web_accessible_resources/noop.html"),
            in: topologyWebView
        )
        let topologyState = try await topologyWebView.floorpCallAsyncJavaScript(
            """
            const [tabs, windows, focused] = await Promise.all([
                browser.tabs.query({}),
                browser.windows.getAll({ populate: true }),
                browser.windows.getLastFocused({ populate: true }),
            ]);
            return {
                tabCount: tabs.length,
                windowCount: windows.length,
                focusedIncognito: focused?.incognito,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        ) as? [String: Any]
        XCTAssertEqual((topologyState?["tabCount"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((topologyState?["windowCount"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(topologyState?["focusedIncognito"] as? Bool, true)
        topologyWebView.stopLoading()
        topologyWebView.navigationDelegate = nil
        withExtendedLifetime(topologyNavigation) {}
        await Task.yield()
        await Task.yield()
        host.backgroundReadinessAttemptHookForTesting = nil
#endif

        for _ in 0..<2 {
            manager.selectedTab = normalTab
            host.focus(windowUUID: manager.windowUUID, isPrivate: false)
            manager.selectedTab = privateTab
            host.focus(windowUUID: manager.windowUUID, isPrivate: true)
            try await host.setPrivateAccess(false, identifier: identifier)

            manager.selectedTab = normalTab
            host.focus(windowUUID: manager.windowUUID, isPrivate: false)
            try await host.setPrivateAccess(true, identifier: identifier)
            manager.selectedTab = privateTab
            host.focus(windowUUID: manager.windowUUID, isPrivate: true)
            try await host.setEnabled(false, identifier: identifier)
            XCTAssertFalse(context.isLoaded)
            XCTAssertFalse(try XCTUnwrap(
                host.settingsItems().first { $0.identifier == identifier }
            ).isEnabled)
            try await host.setEnabled(true, identifier: identifier)
        }

        manager.selectedTab = normalTab
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)

        let installed = try XCTUnwrap(
            host.settingsItems().first {
                $0.identifier == identifier
            }
        )
        XCTAssertTrue(installed.isEnabled)
        XCTAssertEqual(installed.version, FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion)
        XCTAssertNil(installed.errorDescription)
        XCTAssertTrue(context.isLoaded)

        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = FloorpWebExtensionNavigationWaiter()
        defer { webView.stopLoading() }
        try await navigation.load(
            context.baseURL.appendingPathComponent("web_accessible_resources/noop.html"),
            in: webView
        )
        let state = try await webView.floorpCallAsyncJavaScript(
            """
            const readiness = await browser.runtime.sendMessage({ what: 'floorpReadiness' });
            const [enabled, dynamic, session, realmState] = await Promise.all([
                browser.declarativeNetRequest.getEnabledRulesets(),
                browser.declarativeNetRequest.getDynamicRules(),
                browser.declarativeNetRequest.getSessionRules(),
                browser.storage.session.get('safari.seenRealms'),
            ]);
            return {
                ready: readiness?.ready === true,
                version: readiness?.version,
                enabledCount: enabled.length,
                dynamicCount: dynamic.length,
                sessionCount: session.length,
                seenRealms: realmState?.['safari.seenRealms'],
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 15_000_000_000
        ) as? [String: Any]
        let readinessState = try XCTUnwrap(state)
        XCTAssertEqual(readinessState["ready"] as? Bool, true)
        XCTAssertEqual(
            readinessState["version"] as? String,
            FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
        )
        XCTAssertGreaterThan((readinessState["enabledCount"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertGreaterThanOrEqual(
            (readinessState["dynamicCount"] as? NSNumber)?.intValue ?? -1,
            0
        )
        XCTAssertGreaterThanOrEqual(
            (readinessState["sessionCount"] as? NSNumber)?.intValue ?? -1,
            0
        )
        XCTAssertEqual((readinessState["seenRealms"] as? NSNumber)?.intValue, 3)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        withExtendedLifetime(navigation) {}
    }

    func testBulkPrivateTabRemovalClosesTheLogicalWindowBeforeManagerMutation() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: true)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let firstTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        let secondTab = makeHostTestTab(profile: fixture.profile, isPrivate: true)
        manager.tabs = [firstTab, secondTab]
        manager.privateTabs = [firstTab, secondTab]
        manager.selectedTab = firstTab
        fixture.host.register(tabManager: manager)
        XCTAssertEqual(fixture.context.openWindows.count, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 2)
        manager.selectedTab = nil
        fixture.host.tabManager(manager, didRemoveTab: firstTab, isRestoring: false)
        XCTAssertEqual(fixture.context.openWindows.count, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 1)
        let logicalWindow = fixture.host.windowAdapter(for: manager.windowUUID, isPrivate: true)
        assertActiveTabBelongsToWindow(logicalWindow, context: fixture.context)
        XCTAssertTrue(logicalWindow.activeTab(for: fixture.context) === fixture.host.tabAdapter(for: secondTab))

        fixture.host.tabManager(manager, didRemoveTab: secondTab, isRestoring: false)

        XCTAssertTrue(fixture.context.openWindows.isEmpty)
        XCTAssertTrue(fixture.context.openTabs.isEmpty)
        manager.tabs = []
        manager.privateTabs = []
        manager.selectedTab = nil
    }

    func testUnregisteringFocusedSceneFocusesAnotherOpenWindow() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let firstWindowUUID = WindowUUID()
        let secondWindowUUID = WindowUUID()
        let firstManager = MockTabManager(windowUUID: firstWindowUUID)
        let secondManager = MockTabManager(windowUUID: secondWindowUUID)
        let firstTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: firstWindowUUID
        )
        let secondTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: secondWindowUUID
        )
        firstManager.tabs = [firstTab]
        firstManager.normalTabs = [firstTab]
        firstManager.selectedTab = firstTab
        secondManager.tabs = [secondTab]
        secondManager.normalTabs = [secondTab]
        secondManager.selectedTab = secondTab
        fixture.host.register(tabManager: firstManager)
        fixture.host.register(tabManager: secondManager)
        fixture.host.focus(windowUUID: secondWindowUUID, isPrivate: false)

        XCTAssertEqual(fixture.context.openWindows.count, 2)
        XCTAssertEqual(fixture.context.openTabs.count, 2)
        XCTAssertTrue(
            (fixture.context.focusedWindow as AnyObject)
                === (fixture.host.windowAdapter(for: secondWindowUUID, isPrivate: false) as AnyObject)
        )
        fixture.host.unregister(windowUUID: secondWindowUUID)

        XCTAssertEqual(fixture.context.openWindows.count, 1)
        XCTAssertEqual(fixture.context.openTabs.count, 1)
        XCTAssertTrue(
            (fixture.context.focusedWindow as AnyObject)
                === (fixture.host.windowAdapter(for: firstWindowUUID, isPrivate: false) as AnyObject)
        )
        fixture.host.unregister(windowUUID: firstWindowUUID)
    }

    func testResigningTheOnlyFocusedSceneClearsExtensionFocus() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)
        fixture.host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        XCTAssertNotNil(fixture.context.focusedWindow)

        fixture.host.resignFocus(windowUUID: manager.windowUUID)

        XCTAssertNil(fixture.context.focusedWindow)

        fixture.host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        XCTAssertTrue(
            (fixture.context.focusedWindow as AnyObject)
                === (fixture.host.windowAdapter(
                    for: manager.windowUUID,
                    isPrivate: false
                ) as AnyObject)
        )
    }

    func testUnregisteredStaleTabAdapterCannotReadOrMutateBrowserTab() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let manager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let tab = makeHostTestTab(profile: fixture.profile, isPrivate: false)
        tab.url = try XCTUnwrap(URL(string: "https://example.com/stale"))
        manager.tabs = [tab]
        manager.normalTabs = [tab]
        manager.selectedTab = tab
        fixture.host.register(tabManager: manager)
        let adapter = fixture.host.tabAdapter(for: tab)
        XCTAssertEqual(adapter.url(for: fixture.context), tab.url)

        fixture.host.unregister(windowUUID: manager.windowUUID)
        var mutationError: (any Error)?
        adapter.setZoomFactor(2, for: fixture.context) { mutationError = $0 }

        XCTAssertNil(adapter.url(for: fixture.context))
        XCTAssertEqual(tab.pageZoom, 1)
        XCTAssertNotNil(mutationError)
    }

    func testBackgroundSceneTabActivationDoesNotStealExtensionWindowFocus() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let foregroundWindowUUID = WindowUUID()
        let backgroundWindowUUID = WindowUUID()
        let foregroundManager = MockTabManager(windowUUID: foregroundWindowUUID)
        let backgroundManager = MockTabManager(windowUUID: backgroundWindowUUID)
        let foregroundTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: foregroundWindowUUID
        )
        let backgroundTab = makeHostTestTab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: backgroundWindowUUID
        )
        foregroundManager.tabs = [foregroundTab]
        foregroundManager.normalTabs = [foregroundTab]
        foregroundManager.selectedTab = foregroundTab
        backgroundManager.tabs = [backgroundTab]
        backgroundManager.normalTabs = [backgroundTab]
        backgroundManager.selectedTab = backgroundTab
        fixture.host.register(tabManager: foregroundManager)
        fixture.host.register(tabManager: backgroundManager)
        fixture.host.focus(windowUUID: foregroundWindowUUID, isPrivate: false)

        fixture.host.tabManager(
            backgroundManager,
            didSelectedTabChange: backgroundTab,
            previousTab: nil,
            isRestoring: false
        )

        XCTAssertTrue(
            (fixture.context.focusedWindow as AnyObject)
                === (fixture.host.windowAdapter(
                    for: foregroundWindowUUID,
                    isPrivate: false
                ) as AnyObject)
        )
    }

    func testUninstallPurgesPersistentDataAfterInvalidatingSessionStorage() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let contextIdentifier = fixture.context.uniqueIdentifier

        let recordsBeforeUninstall = await fixture.host.controller.dataRecords(
            ofTypes: WKWebExtensionController.allExtensionDataTypes
        )
        let recordBeforeUninstall = try XCTUnwrap(
            recordsBeforeUninstall.first { $0.uniqueIdentifier == contextIdentifier }
        )
        XCTAssertTrue(
            recordBeforeUninstall.errors.isEmpty,
            recordBeforeUninstall.errors.map(\.localizedDescription).joined(separator: "\n")
        )

        try await fixture.host.uninstall(identifier: identifier)

        XCTAssertNil(fixture.host.installedContext(identifier: identifier))
        XCTAssertFalse(fixture.host.settingsItems().contains { $0.identifier == identifier })
        let persistentDataTypes = WKWebExtensionController.allExtensionDataTypes
            .subtracting([.session])
        let remainingRecords = await fixture.host.controller.dataRecords(
            ofTypes: persistentDataTypes
        ).filter { $0.uniqueIdentifier == contextIdentifier }
        XCTAssertTrue(remainingRecords.flatMap(\.errors).isEmpty)
        XCTAssertTrue(
            remainingRecords.allSatisfy {
                $0.sizeInBytes(ofTypes: persistentDataTypes) == 0
            }
        )
    }

    func testLiveUpdateAndSameControllerReinstallRequireRestart() async throws {
        let fixture = try await makeHostContextFixture(hasPrivateAccess: false)
        defer { fixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let installedVersion = try XCTUnwrap(
            fixture.host.settingsItems().first { $0.identifier == identifier }
        ).version

        do {
            try await fixture.host.installBundledExtension(identifier: identifier)
            XCTFail("Updating a context in the controller that loaded it must require a restart")
        } catch {
            guard let extensionError = error as? FloorpNativeWebExtensionError,
                  case .restartRequired = extensionError else {
                XCTFail("Expected restart-required update error, got \(error)")
                return
            }
            XCTAssertEqual(
                error.localizedDescription,
                "Updating this extension requires restarting Floorp."
            )
        }

        XCTAssertTrue(fixture.host.installedContext(identifier: identifier) === fixture.context)
        XCTAssertTrue(fixture.context.isLoaded)
        XCTAssertEqual(
            fixture.host.settingsItems().first { $0.identifier == identifier }?.version,
            installedVersion
        )

        try await fixture.host.uninstall(identifier: identifier)
        XCTAssertNil(fixture.host.installedContext(identifier: identifier))

        do {
            try await fixture.host.installBundledExtension(identifier: identifier)
            XCTFail("Reinstalling a context unloaded by this controller must require a restart")
        } catch {
            guard let extensionError = error as? FloorpNativeWebExtensionError,
                  case .restartRequired = extensionError else {
                XCTFail("Expected restart-required reinstall error, got \(error)")
                return
            }
            XCTAssertEqual(
                error.localizedDescription,
                "Reinstalling this extension requires restarting Floorp."
            )
        }

        XCTAssertNil(fixture.host.installedContext(identifier: identifier))
        XCTAssertFalse(fixture.host.settingsItems().contains { $0.identifier == identifier })
    }

    func testNeverLoadedDisabledContextCanUpdateAfterColdProcessBoundary() async throws {
        let profileFixture = try makeIsolatedHostProfile(prefix: "cold_disabled_update")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let identifier = FloorpNativeWebExtensionCatalog.darkReader.identifier
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let store = FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
        var disabledRecord = makeRecord()
        disabledRecord.isEnabled = false
        disabledRecord.unloadState = FloorpNativeWebExtensionUnloadState(
            processIdentifier: UUID(),
            enableOnNextColdLaunch: false
        )
        try store.save(FloorpNativeWebExtensionRegistry(extensions: [disabledRecord]))

        let restoredHost = try FloorpNativeWebExtensionHost.install(for: profile)
        await restoredHost.restoreInstalledExtensions()
        let neverLoadedContext = try XCTUnwrap(
            restoredHost.installedContext(identifier: identifier)
        )
        XCTAssertFalse(neverLoadedContext.isLoaded)

        try await restoredHost.installBundledExtension(identifier: identifier)

        let updatedContext = try XCTUnwrap(restoredHost.installedContext(identifier: identifier))
        XCTAssertFalse(updatedContext === neverLoadedContext)
        XCTAssertFalse(updatedContext.isLoaded)
        let updatedItem = try XCTUnwrap(
            restoredHost.settingsItems().first { $0.identifier == identifier }
        )
        XCTAssertFalse(updatedItem.isEnabled)
        XCTAssertFalse(updatedItem.hasUpdate)
        XCTAssertNil(updatedItem.errorDescription)
    }

    func testOptionsPageExternalSameFrameLinkOpensBrowserAfterDismissal() async throws {
        let extensionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Floorp Options Link Test",
            "version": "1.0",
            "options_ui": ["page": "options.html"]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(
            "<a id='external' href='https://example.com/help'>Help</a>".utf8
        ).write(to: extensionRoot.appendingPathComponent("options.html"), options: .atomic)
        let webExtension = try await WKWebExtension(resourceBaseURL: extensionRoot)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "app.floorp.options-link.\(UUID().uuidString)"
        let controller = WKWebExtensionController(configuration: .init(identifier: UUID()))
        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension],
                resourceRoot: extensionRoot
            )
        }
        try controller.load(context)
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let destination = expectation(description: "External URL routed to Floorp")
        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(context.optionsPageURL),
            configuration: configuration,
            openURLInBrowser: { url in
                XCTAssertEqual(url.absoluteString, "https://example.com/help")
                destination.fulfill()
            }
        )
        let navigationController = UINavigationController(rootViewController: page)
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(page.view.subviews.first { $0 is WKWebView } as? WKWebView)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            controller.delegate = nil
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension, page, navigationController, root, window, webView],
                resourceRoot: extensionRoot
            )
        }
        for _ in 0..<40 {
            let isReady = try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && Boolean(document.getElementById('external'))"
            ) as? Bool
            if isReady == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hasExternalLink = try await webView.evaluateJavaScript(
            "Boolean(document.getElementById('external'))"
        ) as? Bool
        XCTAssertEqual(hasExternalLink, true)

        _ = try await webView.evaluateJavaScript("document.getElementById('external').click()")

        await fulfillment(of: [destination], timeout: 2)
        XCTAssertNil(root.presentedViewController)
    }

    func testOptionsPageWindowCloseDismissesPresentation() async throws {
        let extensionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Floorp Options Close Test",
            "description": "Exercises window.close from an extension options page.",
            "version": "1.0",
            "options_ui": ["page": "options.html"]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(
            "<button id='close'>Close</button><script src='options.js'></script>".utf8
        ).write(to: extensionRoot.appendingPathComponent("options.html"), options: .atomic)
        try Data(
            "document.getElementById('close').addEventListener('click', () => window.close());".utf8
        ).write(to: extensionRoot.appendingPathComponent("options.js"), options: .atomic)
        let webExtension = try await WKWebExtension(resourceBaseURL: extensionRoot)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "app.floorp.options-close.\(UUID().uuidString)"
        let controller = WKWebExtensionController(configuration: .init(identifier: UUID()))
        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension],
                resourceRoot: extensionRoot
            )
        }
        try controller.load(context)

        let template = try XCTUnwrap(context.webViewConfiguration)
        let configuration = try XCTUnwrap(template.copy() as? WKWebViewConfiguration)
        FloorpNativeWebExtensionHost.configureExtensionSurface(
            configuration,
            websiteDataStore: .default(),
            isPrivate: false
        )

        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(context.optionsPageURL),
            configuration: configuration
        )
        let navigationController = UINavigationController(rootViewController: page)
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(page.view.subviews.first { $0 is WKWebView } as? WKWebView)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            controller.delegate = nil
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension, page, navigationController, root, window, webView],
                resourceRoot: extensionRoot
            )
        }
        for _ in 0..<40 {
            if (try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && Boolean(document.getElementById('close'))"
            ) as? Bool) == true {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        _ = try await webView.evaluateJavaScript("document.getElementById('close').click(); true")
        for _ in 0..<40 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(root.presentedViewController)
    }

    // swiftlint:disable:next function_body_length
    func testOptionsNavigationCloseAnywayClosesPreservedSurfaceAndOpensExternalURL() async throws {
#if DEBUG || TESTING
        let destination = try XCTUnwrap(URL(string: "https://example.com/preserved-options"))
        var events = [String]()
        var preparationCount = 0
        var receivedPolicy: WKNavigationActionPolicy?
        var preservedWebView: WKWebView?
        let policyResolved = expectation(description: "Navigation policy cancelled")
        let surfaceClosed = expectation(description: "Options surface closed")
        let externalURLOpened = expectation(description: "External URL opened after dismissal")
        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            openURLInBrowser: { url in
                XCTAssertEqual(url, destination)
                events.append("opened")
                externalURLOpened.fulfill()
            },
            prepareToClose: { webView in
                preparationCount += 1
                preservedWebView = webView
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.beginOperation(in: webView)
                return false
            },
            onClose: {
                events.append("closed")
                surfaceClosed.fulfill()
            }
        )
        let navigationController = UINavigationController(rootViewController: page)
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            if let preservedWebView {
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(
                    in: preservedWebView
                )
            }
            page.prepareForHostTeardown()
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(
            page.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        try await waitForDocumentCommit(in: webView)

        page.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: destination, type: .linkActivated)
        ) { policy in
            receivedPolicy = policy
            events.append("policy")
            policyResolved.fulfill()
        }
        for _ in 0..<40 {
            if page.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(page.presentedViewController as? UIAlertController)
        XCTAssertEqual(preparationCount, 1)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        )

        page.closeAfterNavigationPreparationFailureForTesting()
        await fulfillment(
            of: [policyResolved, surfaceClosed, externalURLOpened],
            timeout: 2,
            enforceOrder: true
        )

        XCTAssertEqual(receivedPolicy, .cancel)
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(events, ["policy", "closed", "opened"])
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        )
#else
        throw XCTSkip("The navigation-preparation test seam is available only in test builds")
#endif
    }

    func testOptionsClosePreparationFailureOffersExplicitEscapeAndClosesOnce() async throws {
#if DEBUG || TESTING
        var closeAttemptCount = 0
        var onCloseCount = 0
        var completionCount = 0
        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            prepareToClose: { _ in
                closeAttemptCount += 1
                return false
            },
            onClose: { onCloseCount += 1 }
        )
        let navigationController = UINavigationController(rootViewController: page)
        navigationController.isModalInPresentation = true
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(
            page.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        try await waitForDocumentCommit(in: webView)

        page.requestCloseForTesting { completionCount += 1 }
        for _ in 0..<40 {
            if page.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let alert = try XCTUnwrap(page.presentedViewController as? UIAlertController)
        XCTAssertTrue(root.presentedViewController === navigationController)
        XCTAssertTrue(navigationController.isModalInPresentation)
        XCTAssertEqual(closeAttemptCount, 1)
        XCTAssertEqual(onCloseCount, 0)
        XCTAssertEqual(
            alert.actions.compactMap(\.title),
            [
                FloorpStrings.WebExtensions.continueEditing,
                FloorpStrings.WebExtensions.retry,
                FloorpStrings.WebExtensions.closeAnyway
            ]
        )
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .default, .destructive])
        XCTAssertEqual(page.navigationItem.rightBarButtonItem?.isEnabled, true)
        XCTAssertNil(page.navigationItem.prompt)

        page.closeAfterPreparationFailureForTesting()
        for _ in 0..<40 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(onCloseCount, 1)
        XCTAssertEqual(completionCount, 1)
        page.prepareForHostTeardown()
        XCTAssertEqual(onCloseCount, 1)
        XCTAssertEqual(completionCount, 1)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testOptionsClosePreparationFailureCanRetryAndThenClose() async throws {
#if DEBUG || TESTING
        var closeAttemptCount = 0
        var onCloseCount = 0
        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            prepareToClose: { _ in
                closeAttemptCount += 1
                return closeAttemptCount == 2
            },
            onClose: { onCloseCount += 1 }
        )
        let navigationController = UINavigationController(rootViewController: page)
        navigationController.isModalInPresentation = true
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(
            page.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        try await waitForDocumentCommit(in: webView)

        page.requestCloseForTesting()
        for _ in 0..<40 {
            if page.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(page.presentedViewController as? UIAlertController)

        page.retryCloseAfterPreparationFailureForTesting()
        for _ in 0..<80 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(closeAttemptCount, 2)
        XCTAssertEqual(onCloseCount, 1)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testOptionsAdaptiveDismissWaitsForPreparationAndBlocksWebInteraction() async throws {
#if DEBUG || TESTING
        let preparationGate = FloorpClosePreparationTestGate()
        var onCloseCount = 0
        let page = FloorpNativeWebExtensionPageViewController(
            title: "Options",
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            prepareToClose: { _ in
                await preparationGate.waitUntilReleased()
            },
            onClose: { onCloseCount += 1 }
        )
        let navigationController = UINavigationController(rootViewController: page)
        navigationController.isModalInPresentation = true
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            page.prepareForHostTeardown()
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(
            page.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        try await waitForDocumentCommit(in: webView)
        let presentationController = try XCTUnwrap(navigationController.presentationController)

        XCTAssertFalse(page.presentationControllerShouldDismiss(presentationController))
        page.presentationControllerDidAttemptToDismiss(presentationController)
        for _ in 0..<40 {
            if preparationGate.didBegin { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(preparationGate.didBegin)
        XCTAssertFalse(webView.isUserInteractionEnabled)
        XCTAssertTrue(root.presentedViewController === navigationController)
        XCTAssertEqual(onCloseCount, 0)

        preparationGate.mayFinish = true
        for _ in 0..<80 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(onCloseCount, 1)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testActionPopupCanCloseBeforeItsFirstDocumentCommits() async throws {
#if DEBUG || TESTING
        var closePreparationCount = 0
        var onCloseCount = 0
        var completionCount = 0
        let popup = FloorpNativeWebExtensionActionPopupViewController(
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            openURLInBrowser: { _ in },
            prepareToClose: { _ in
                closePreparationCount += 1
                return false
            },
            onClose: { onCloseCount += 1 }
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            popup.closePopupImmediately(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(popup, animated: false)
        popup.loadViewIfNeeded()

        XCTAssertTrue(
            popup.webView.configuration.userContentController.userScripts.contains {
                $0.source.contains("floorpPrepareToClose") && $0.source.contains("provisional: true")
            }
        )
        popup.requestCloseForTesting { completionCount += 1 }
        for _ in 0..<40 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(closePreparationCount, 0)
        XCTAssertEqual(onCloseCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertNil(popup.presentedViewController)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testActionPopupWaitsForClosePreparationBeforeDismissal() async throws {
#if DEBUG || TESTING
        let preparationGate = FloorpClosePreparationTestGate()
        var onCloseCount = 0
        var completionCount = 0
        let popup = FloorpNativeWebExtensionActionPopupViewController(
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            openURLInBrowser: { _ in },
            prepareToClose: { _ in
                await preparationGate.waitUntilReleased()
            },
            onClose: { onCloseCount += 1 }
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            popup.closePopupImmediately(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(popup, animated: false)
        popup.loadViewIfNeeded()
        try await waitForDocumentCommit(in: popup.webView)

        popup.requestCloseForTesting { completionCount += 1 }
        for _ in 0..<40 {
            if preparationGate.didBegin { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(preparationGate.didBegin)
        XCTAssertTrue(root.presentedViewController === popup)
        XCTAssertEqual(onCloseCount, 0)
        XCTAssertEqual(completionCount, 0)
        XCTAssertTrue(popup.isModalInPresentation)

        preparationGate.mayFinish = true
        for _ in 0..<80 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(onCloseCount, 1)
        XCTAssertEqual(completionCount, 1)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    // swiftlint:disable:next function_body_length
    func testActionPopupNavigationCloseAnywayClosesPreservedSurfaceAndOpensExternalURL() async throws {
#if DEBUG || TESTING
        let destination = try XCTUnwrap(URL(string: "https://example.com/preserved-popup"))
        var events = [String]()
        var preparationCount = 0
        var receivedPolicy: WKNavigationActionPolicy?
        var preservedWebView: WKWebView?
        let policyResolved = expectation(description: "Navigation policy cancelled")
        let surfaceClosed = expectation(description: "Action popup closed")
        let externalURLOpened = expectation(description: "External URL opened after dismissal")
        let popup = FloorpNativeWebExtensionActionPopupViewController(
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            openURLInBrowser: { url in
                XCTAssertEqual(url, destination)
                events.append("opened")
                externalURLOpened.fulfill()
            },
            prepareToClose: { webView in
                preparationCount += 1
                preservedWebView = webView
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.beginOperation(in: webView)
                return false
            },
            onClose: {
                events.append("closed")
                surfaceClosed.fulfill()
            }
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            if let preservedWebView {
                FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.endOperation(
                    in: preservedWebView
                )
            }
            popup.closePopupImmediately(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(popup, animated: false)
        popup.loadViewIfNeeded()
        try await waitForDocumentCommit(in: popup.webView)

        popup.webView(
            popup.webView,
            decidePolicyFor: MockNavigationAction(url: destination, type: .linkActivated)
        ) { policy in
            receivedPolicy = policy
            events.append("policy")
            policyResolved.fulfill()
        }
        for _ in 0..<40 {
            if popup.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(popup.presentedViewController as? UIAlertController)
        XCTAssertEqual(preparationCount, 1)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView)
        )

        popup.closeAfterNavigationPreparationFailureForTesting()
        await fulfillment(
            of: [policyResolved, surfaceClosed, externalURLOpened],
            timeout: 2,
            enforceOrder: true
        )

        XCTAssertEqual(receivedPolicy, .cancel)
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(events, ["policy", "closed", "opened"])
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView)
        )
#else
        throw XCTSkip("The navigation-preparation test seam is available only in test builds")
#endif
    }

    func testActionPopupClosePreparationFailureOffersRetryAndExplicitEscape() async throws {
#if DEBUG || TESTING
        var closeAttemptCount = 0
        var onCloseCount = 0
        let popup = FloorpNativeWebExtensionActionPopupViewController(
            url: try XCTUnwrap(URL(string: "about:blank")),
            configuration: WKWebViewConfiguration(),
            openURLInBrowser: { _ in },
            prepareToClose: { _ in
                closeAttemptCount += 1
                return false
            },
            onClose: { onCloseCount += 1 }
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            popup.closePopupImmediately(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(popup, animated: false)
        popup.loadViewIfNeeded()
        try await waitForDocumentCommit(in: popup.webView)

        popup.requestCloseForTesting()
        for _ in 0..<40 {
            if popup.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let firstAlert = try XCTUnwrap(popup.presentedViewController as? UIAlertController)
        XCTAssertEqual(closeAttemptCount, 1)
        XCTAssertEqual(onCloseCount, 0)
        XCTAssertEqual(
            firstAlert.actions.compactMap(\.title),
            [
                FloorpStrings.WebExtensions.continueEditing,
                FloorpStrings.WebExtensions.retry,
                FloorpStrings.WebExtensions.closeAnyway
            ]
        )

        // A delayed route acknowledgement may issue its script close while
        // this failure alert is already visible. Keep the existing request and
        // its live actions, while upgrading its close disposition in place.
        popup.requestCloseForTesting()
        await Task.yield()
        XCTAssertTrue(popup.presentedViewController === firstAlert)
        XCTAssertEqual(closeAttemptCount, 1)

        popup.retryCloseAfterPreparationFailureForTesting()
        for _ in 0..<80 {
            if closeAttemptCount == 2,
               popup.presentedViewController is UIAlertController {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(closeAttemptCount, 2)
        XCTAssertNotNil(popup.presentedViewController as? UIAlertController)
        XCTAssertTrue(root.presentedViewController === popup)
        XCTAssertEqual(onCloseCount, 0)

        popup.closeAfterPreparationFailureForTesting()
        for _ in 0..<80 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(onCloseCount, 1)
        popup.closePopupImmediately(animated: false)
        XCTAssertEqual(onCloseCount, 1)
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    func testNativeRegistryV2RoundTripsIdentityPermissionsAndTransactionState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FloorpNativeWebExtensionRegistryStore(
            url: root.appendingPathComponent("registry-v2.json")
        )

        let controllerIdentifier = UUID()
        var record = makeRecord()
        record.transactionState = .switching
        record.rollback = record.rollbackSnapshot
        let expected = FloorpNativeWebExtensionRegistry(
            controllerIdentifier: controllerIdentifier,
            extensions: [record]
        )

        try store.save(expected)
        let actual = try store.load()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.controllerIdentifier, controllerIdentifier)
        XCTAssertEqual(actual.schemaVersion, 2)
        XCTAssertEqual(actual.extensions.first?.contextIdentifier, "org.darkreader.floorp-ios")
        XCTAssertEqual(
            actual.extensions.first?.grantedPermissions.map(\.value),
            ["alarms", "fontSettings", "scripting", "storage"]
        )
        XCTAssertEqual(actual.extensions.first?.transactionState, .switching)
        XCTAssertEqual(actual.extensions.first?.hasRequestedOptionalAccessToAllHosts, true)
        XCTAssertEqual(
            actual.extensions.first?.rollback?.hasRequestedOptionalAccessToAllHosts,
            true
        )

        var corruptRecord = record
        corruptRecord.grantedPermissions.append(
            FloorpNativeWebExtensionPermissionDecision(value: "storage")
        )
        XCTAssertThrowsError(
            try store.save(
                FloorpNativeWebExtensionRegistry(
                    controllerIdentifier: controllerIdentifier,
                    extensions: [corruptRecord]
                )
            )
        )
    }

    func testKnownDarkReaderRecordsRequireBundledCompatibilityMigration() {
        var record = makeRecord()
        record.packageReference = "darkreader-chrome-mv3-4.9.129.zip"
        record.sha256 = FloorpNativeWebExtensionCatalog.legacyDarkReaderSHA256

        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(record),
            FloorpNativeWebExtensionCatalog.darkReader
        )

        record.packageReference = FloorpNativeWebExtensionCatalog.darkReader.packageReference
        record.sha256 = FloorpNativeWebExtensionCatalog.previousDarkReaderSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(record),
            FloorpNativeWebExtensionCatalog.darkReader
        )

        record.sha256 = FloorpNativeWebExtensionCatalog.preDurableStorageDarkReaderSHA256
        XCTAssertEqual(
            FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(record),
            FloorpNativeWebExtensionCatalog.darkReader
        )

        record.sha256 = FloorpNativeWebExtensionCatalog.darkReader.expectedSHA256
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(record))
    }

    func testBundledCompatibilityMigrationRejectsUntrustedRecordShapes() {
        var record = makeRecord()
        record.sha256 = FloorpNativeWebExtensionCatalog.previousDarkReaderSHA256

        var wrongReference = record
        wrongReference.packageReference = "unexpected.zip"
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(wrongReference))

        var wrongVersion = record
        wrongVersion.installedVersion = "4.9.128"
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(wrongVersion))

        var managed = record
        managed.packageSource = .managed
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(managed))

        var pendingPurge = record
        pendingPurge.transactionState = .pendingPurge
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(pendingPurge))

        var unknownDigest = record
        unknownDigest.sha256 = String(repeating: "a", count: 64)
        XCTAssertNil(FloorpNativeWebExtensionCatalog.replacementForLegacyBundledRecord(unknownDigest))
    }

    func testPermissionDecisionReconciliationPrunesStaleAuthorityAndResolvesConflicts() {
        let retainedExpiration = Date(timeIntervalSince1970: 1_234)
        let decisions = FloorpNativeWebExtensionPermissionDecisionReconciler.reconcile(
            previousGranted: [
                .init(value: "optional-retained", expiration: retainedExpiration),
                .init(value: "removed-grant"),
                .init(value: "required-denied")
            ],
            previousDenied: [
                .init(value: "optional-denied", expiration: retainedExpiration),
                .init(value: "removed-denial"),
                .init(value: "required-granted")
            ],
            declaredValues: [
                "optional-retained",
                "optional-denied",
                "required-granted",
                "required-denied"
            ],
            requiredGrantedValues: ["required-granted"],
            requiredDeniedValues: ["required-denied"]
        )

        XCTAssertEqual(
            decisions.granted.map(\.value),
            ["optional-retained", "required-granted"]
        )
        XCTAssertEqual(
            decisions.denied.map(\.value),
            ["optional-denied", "required-denied"]
        )
        XCTAssertEqual(
            decisions.granted.first { $0.value == "optional-retained" }?.expiration,
            retainedExpiration
        )
        XCTAssertEqual(
            decisions.denied.first { $0.value == "optional-denied" }?.expiration,
            retainedExpiration
        )
        XCTAssertTrue(
            Set(decisions.granted.map(\.value)).isDisjoint(with: decisions.denied.map(\.value))
        )
    }

    func testInterruptedTransactionRollbackRestoresPreviousPackageAndState() throws {
        var record = makeRecord()
        let rollback = record.rollbackSnapshot
        record.packageReference = "packages/floorp.bundled.darkreader/new/extension.zip"
        record.sha256 = String(repeating: "b", count: 64)
        record.installedVersion = "5.0.0"
        record.isEnabled = false
        record.hasRequestedOptionalAccessToAllHosts = false
        record.transactionState = .switching
        record.rollback = rollback

        let outcome = record.recoverInterruptedTransaction()

        XCTAssertEqual(outcome, .rolledBack)
        XCTAssertEqual(record.packageReference, FloorpNativeWebExtensionCatalog.darkReader.packageReference)
        XCTAssertEqual(record.installedVersion, "4.9.129")
        XCTAssertTrue(record.isEnabled)
        XCTAssertTrue(record.hasRequestedOptionalAccessToAllHosts)
        XCTAssertEqual(record.transactionState, .stable)
        XCTAssertNil(record.rollback)
    }

    func testLegacyRollbackWithoutOptionalAllHostsStateDecodesFailClosed() throws {
        let encoded = try JSONEncoder().encode(makeRecord().rollbackSnapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "hasRequestedOptionalAccessToAllHosts")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            FloorpNativeWebExtensionRollback.self,
            from: legacy
        )

        XCTAssertNil(decoded.hasRequestedOptionalAccessToAllHosts)
    }

    func testInterruptedFirstInstallIsRetainedAsPurgeTombstone() {
        var record = makeRecord()
        record.transactionState = .switching
        record.rollback = nil

        let outcome = record.recoverInterruptedTransaction()

        XCTAssertEqual(outcome, .pendingPurge)
        XCTAssertEqual(record.transactionState, .pendingPurge)
        XCTAssertFalse(record.isEnabled)
        XCTAssertNil(record.rollback)
        XCTAssertEqual(record.recoverInterruptedTransaction(), .unchanged)
    }

    func testRegistryRejectsDuplicateDeniedPermissionsAndMatchPatterns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FloorpNativeWebExtensionRegistryStore(
            url: root.appendingPathComponent("registry-v2.json")
        )

        var duplicatePermissions = makeRecord()
        let permission = FloorpNativeWebExtensionPermissionDecision(value: "nativeMessaging")
        duplicatePermissions.deniedPermissions = [permission, permission]
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [duplicatePermissions]))
        )

        var duplicatePatterns = makeRecord()
        let pattern = FloorpNativeWebExtensionPermissionDecision(value: "https://example.com/*")
        duplicatePatterns.deniedMatchPatterns = [pattern, pattern]
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [duplicatePatterns]))
        )

        var emptyDeniedPermission = makeRecord()
        emptyDeniedPermission.deniedPermissions = [.init(value: "")]
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [emptyDeniedPermission]))
        )

        var emptyDeniedPattern = makeRecord()
        emptyDeniedPattern.deniedMatchPatterns = [.init(value: "")]
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [emptyDeniedPattern]))
        )

        var conflictingPermission = makeRecord()
        conflictingPermission.deniedPermissions = conflictingPermission.grantedPermissions
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [conflictingPermission]))
        )

        var conflictingPattern = makeRecord()
        conflictingPattern.deniedMatchPatterns = conflictingPattern.grantedMatchPatterns
        XCTAssertThrowsError(
            try store.save(FloorpNativeWebExtensionRegistry(extensions: [conflictingPattern]))
        )
    }

    func testSurfaceHistoryPreservesCrossOriginBackForwardAndDropsForwardBranch() throws {
        let website = try XCTUnwrap(URL(string: "https://example.com/article"))
        let strictBlock = try XCTUnwrap(
            URL(string: "webkit-extension://ubol.floorp.internal/strictblock.html")
        )
        let replacement = try XCTUnwrap(URL(string: "https://example.org/new-branch"))
        var history = FloorpNativeWebExtensionSurfaceHistory()

        history.commit(contextIdentifier: nil, url: website)
        history.transition(
            from: .init(contextIdentifier: nil, url: website),
            to: .init(contextIdentifier: "ubol", url: strictBlock)
        )
        XCTAssertEqual(history.backTarget?.url, website)
        XCTAssertEqual(history.moveBack()?.url, website)
        XCTAssertEqual(history.forwardTarget?.url, strictBlock)
        XCTAssertEqual(history.moveForward()?.url, strictBlock)
        XCTAssertEqual(history.moveBack()?.url, website)

        history.discardForward()
        history.commit(contextIdentifier: nil, url: replacement)

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.currentEntry?.url, replacement)
    }

    func testSurfaceHistoryMergesWebViewBackListBeforeCrossingBoundary() throws {
        let firstWebsite = try XCTUnwrap(URL(string: "https://example.com/first"))
        let secondWebsite = try XCTUnwrap(URL(string: "https://example.com/second"))
        let extensionPage = try XCTUnwrap(
            URL(string: "webkit-extension://ubol.floorp.internal/dashboard.html")
        )
        let normalContext: String? = nil
        var history = FloorpNativeWebExtensionSurfaceHistory()

        history.transition(
            from: [
                .init(contextIdentifier: normalContext, url: firstWebsite),
                .init(contextIdentifier: normalContext, url: secondWebsite)
            ],
            to: .init(contextIdentifier: "ubol", url: extensionPage)
        )

        XCTAssertEqual(history.moveBack()?.url, secondWebsite)
        XCTAssertEqual(history.moveBack()?.url, firstWebsite)
        XCTAssertEqual(history.moveForward()?.url, secondWebsite)
        XCTAssertEqual(history.moveForward()?.url, extensionPage)
    }

    func testSurfaceHistoryRemovalOnlyPrunesMatchingExtensionEntries() throws {
        let firstPage = try XCTUnwrap(URL(string: "https://example.com/first"))
        let darkReaderPage = try XCTUnwrap(URL(string: "safari-web-extension://darkreader/popup/index.html"))
        let secondPage = try XCTUnwrap(URL(string: "https://example.com/second"))
        let uBOLPage = try XCTUnwrap(URL(string: "safari-web-extension://ubol/dashboard.html"))
        var history = FloorpNativeWebExtensionSurfaceHistory()

        history.commit(contextIdentifier: nil, url: firstPage)
        history.transition(
            from: history.currentEntry,
            to: .init(contextIdentifier: "darkreader", url: darkReaderPage)
        )
        history.transition(
            from: history.currentEntry,
            to: .init(contextIdentifier: nil, url: secondPage)
        )
        history.transition(
            from: history.currentEntry,
            to: .init(contextIdentifier: "ubol", url: uBOLPage)
        )

        history.removeEntries(contextIdentifier: "darkreader")

        XCTAssertEqual(history.entries.map(\.url), [firstPage, secondPage, uBOLPage])
        XCTAssertEqual(history.currentEntry?.url, uBOLPage)
        XCTAssertEqual(history.moveBack()?.url, secondPage)
        XCTAssertEqual(history.moveBack()?.url, firstPage)
        XCTAssertNil(history.moveBack())
        XCTAssertEqual(history.moveForward()?.url, secondPage)
    }

    func testSurfaceHistoryRemovalSelectsNearestSurvivingEntry() throws {
        let firstPage = try XCTUnwrap(URL(string: "https://example.com/first"))
        let darkReaderPage = try XCTUnwrap(URL(string: "safari-web-extension://darkreader/popup/index.html"))
        let secondPage = try XCTUnwrap(URL(string: "https://example.com/second"))
        var history = FloorpNativeWebExtensionSurfaceHistory()

        history.commit(contextIdentifier: nil, url: firstPage)
        history.transition(
            from: history.currentEntry,
            to: .init(contextIdentifier: "darkreader", url: darkReaderPage)
        )
        history.transition(
            from: history.currentEntry,
            to: .init(contextIdentifier: nil, url: secondPage)
        )
        _ = history.moveBack()

        history.removeEntries(contextIdentifier: "darkreader")

        XCTAssertEqual(history.currentEntry?.url, firstPage)
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.moveForward()?.url, secondPage)
    }

    func testBundledPackageRejectsDigestNotApprovedByCatalog() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let approved = FloorpNativeWebExtensionCatalog.darkReader
        let tamperedCatalog = FloorpNativeWebExtensionCatalogItem(
            identifier: approved.identifier,
            resourceName: approved.resourceName,
            resourceExtension: approved.resourceExtension,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedVersion: approved.expectedVersion,
            contextIdentifier: approved.contextIdentifier,
            baseURLScheme: approved.baseURLScheme,
            baseURLHost: approved.baseURLHost,
            actionPopupPath: approved.actionPopupPath,
            requiresBackgroundReadiness: approved.requiresBackgroundReadiness,
            requiresNavigationBackgroundReadiness: approved.requiresNavigationBackgroundReadiness,
            navigationReadinessFailurePolicy: approved.navigationReadinessFailurePolicy,
            minimumOS: approved.minimumOS,
            name: approved.name,
            summary: approved.summary,
            source: approved.source,
            sourceRevision: approved.sourceRevision,
            license: approved.license,
            approvedParseErrorCodes: approved.approvedParseErrorCodes,
            disabledAPIs: approved.disabledAPIs
        )

        do {
            _ = try await installer.verifiedBundledPackage(for: tamperedCatalog)
            XCTFail("A mismatched catalog digest must not be accepted")
        } catch FloorpNativeWebExtensionError.packageDigestMismatch(let expected, let actual) {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, approved.expectedSHA256)
        }
    }

    // swiftlint:disable:next function_body_length
    func testBundledUBOLCatalogPackageIsVerifiedLoadsAndDeclaresDNRAndUI() async throws {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        XCTAssertEqual(item.identifier, "floorp.bundled.ublock-origin-lite")
        XCTAssertEqual(item.expectedVersion, "2026.825.1619")
        XCTAssertEqual(
            item.expectedSHA256,
            "cfd521ed8a139ace31c00a0f5047caaa3fe15f61cfe2e3672981cafc373f4057"
        )
        XCTAssertEqual(item.minimumOS, FloorpOperatingSystemVersion(26, 0))
        XCTAssertEqual(item.license, "GPL-3.0-or-later")
        XCTAssertEqual(item.sourceRevision, "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b")
        XCTAssertEqual(item.baseURLScheme, "safari-web-extension")

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let package = try await installer.verifiedBundledPackage(for: item)
        XCTAssertEqual(package.sha256, item.expectedSHA256)
        XCTAssertEqual(package.url.lastPathComponent, item.packageReference)

        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        XCTAssertEqual(webExtension.displayName, item.name)
        XCTAssertEqual(webExtension.version, item.expectedVersion)
        XCTAssertTrue(
            webExtension.errors.isEmpty,
            webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        XCTAssertTrue(webExtension.requestedPermissions.contains(.declarativeNetRequest))
        XCTAssertTrue(webExtension.requestedPermissions.contains(.declarativeNetRequestFeedback))
        XCTAssertTrue(webExtension.requestedPermissions.contains(.declarativeNetRequestWithHostAccess))

        let dnr = try XCTUnwrap(webExtension.manifest["declarative_net_request"] as? [String: Any])
        let rulesets = try XCTUnwrap(dnr["rule_resources"] as? [[String: Any]])
        XCTAssertEqual(rulesets.count, 51)
        let browserSettings = try XCTUnwrap(
            webExtension.manifest["browser_specific_settings"] as? [String: Any]
        )
        let safariSettings = try XCTUnwrap(browserSettings["safari"] as? [String: Any])
        XCTAssertEqual(safariSettings["strict_min_version"] as? String, "26.0")

        FloorpNativeWebExtensionCatalog.registerBaseURLSchemes()
        let isolationToken = UUID().uuidString.lowercased()
        let context = WKWebExtensionContext(for: webExtension)
        // Keep this retained smoke-test runtime isolated from the production-host
        // identity used by later tests; WebKit extension state remains process-scoped.
        context.uniqueIdentifier = "\(item.contextIdentifier).catalog.\(isolationToken)"
        context.baseURL = URL(
            string: "\(item.baseURLScheme)://ubol-catalog-\(isolationToken).floorp.internal/"
        )!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, Date.distantFuture) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)

        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension],
                resourceRoot: temporaryRoot
            )
        }
        try controller.load(context)
        var retainedExtensionWebView: WKWebView?
        defer {
            retainedExtensionWebView?.stopLoading()
            retainedExtensionWebView?.navigationDelegate = nil
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: retainedExtensionWebView.map { [$0] } ?? [],
                resourceRoot: temporaryRoot
            )
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(context.isLoaded)
        let action = try XCTUnwrap(context.action(for: nil))
        // Popup presentation itself is exercised by the host and action-picker tests.
        XCTAssertTrue(action.presentsPopup)
        XCTAssertNotNil(context.optionsPageURL)
        XCTAssertEqual(context.optionsPageURL?.scheme, item.baseURLScheme)

        do {
            let webViewConfiguration = try XCTUnwrap(context.webViewConfiguration)
            let extensionWebView = WKWebView(frame: .zero, configuration: webViewConfiguration)
            retainedExtensionWebView = extensionWebView
            let navigation = FloorpWebExtensionNavigationWaiter()
            try await navigation.load(
                context.baseURL.appendingPathComponent("web_accessible_resources/noop.html"),
                in: extensionWebView
            )
            let runtime = try await extensionWebView.callAsyncJavaScript(
                """
                const extension = await import(browser.runtime.getURL('js/ext.js'));
                const config = await import(browser.runtime.getURL('js/config.js'));
                const debug = await import(browser.runtime.getURL('js/debug.js'));
                const initialReadiness =
                    await browser.runtime.sendMessage({ what: 'floorpReadiness' });
                let reconciliation = { ready: true };
                if (initialReadiness?.foregroundReconciliationRequired === true) {
                    const module = await import(
                        browser.runtime.getURL('js/floorp-reconcile.js')
                    );
                    reconciliation = await module.reconcileProtection();
                }
                const readiness = reconciliation?.ready === true
                    ? await browser.runtime.sendMessage({ what: 'floorpReadiness' })
                    : reconciliation;
                const registeredContentScripts =
                    await browser.scripting.getRegisteredContentScripts();
                return {
                    baseURL: browser.runtime.getURL(''),
                    flavor: extension.webextFlavor,
                    isSideloaded: debug.isSideloaded,
                    strictBlockMode: config.defaultConfig.strictBlockMode,
                    registeredContentScriptIDs:
                        registeredContentScripts.map(script => script.id),
                    readiness,
                    reconciliation
                };
                """,
                arguments: [:],
                contentWorld: .page
            ) as? [String: Any]
            let runtimeResult = try XCTUnwrap(runtime)
            XCTAssertTrue(
                (runtimeResult["baseURL"] as? String)?.hasPrefix("safari-web-extension:") == true
            )
            XCTAssertEqual(runtimeResult["flavor"] as? String, "safari")
            XCTAssertEqual(runtimeResult["isSideloaded"] as? Bool, true)
            XCTAssertEqual(runtimeResult["strictBlockMode"] as? Bool, false)
            let reconciliation = try XCTUnwrap(
                runtimeResult["reconciliation"] as? [String: Any]
            )
            XCTAssertEqual(
                reconciliation["ready"] as? Bool,
                true,
                String(describing: reconciliation)
            )
            let readiness = try XCTUnwrap(runtimeResult["readiness"] as? [String: Any])
            XCTAssertEqual(
                readiness["ready"] as? Bool,
                true,
                String(describing: readiness)
            )
            let registeredContentScriptIDs = try XCTUnwrap(
                runtimeResult["registeredContentScriptIDs"] as? [String]
            )
            XCTAssertTrue(
                registeredContentScriptIDs.contains("floorp-safari-registration-sentinel")
            )
            extensionWebView.stopLoading()
            extensionWebView.navigationDelegate = nil
            withExtendedLifetime(navigation) {}
        }
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        withExtendedLifetime(retainedExtensionWebView) {}
    }

    // swiftlint:disable:next function_body_length
    func testBundledUBOLMatchedRulesRoutesThroughProductionHostInBothPrivacyRealms() async throws {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_route")
        let profile = profileFixture.profile
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        try await host.setPrivateAccess(true, identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let normalSource = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/normal")),
            isPrivate: false
        )
        let privateSource = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/private")),
            isPrivate: true
        )
        manager.selectedTab = normalSource
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        for source in [normalSource, privateSource] {
            source.webView?.frame = root.view.bounds
            source.webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let webView = source.webView {
                root.view.addSubview(webView)
            }
        }
        privateSource.webView?.isHidden = true
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        let extensionController = try XCTUnwrap(
            context.webViewConfiguration?.webExtensionController
        )
        let extensionWebView = try await makeUBOLDeveloperModePage(context: context)
        defer { extensionWebView.stopLoading() }

        try await exerciseBundledUBOLPopupRouteCloseRace(
            sourceTab: normalSource,
            host: host,
            manager: manager,
            item: item,
            presentingRoot: root
        )

        let normalRoute: Tab
        let privateRoute: Tab
        let privateReportRoute: Tab
        do {
            normalRoute = try await requestUBOLMatchedRulesRoute(
                sourceTab: normalSource,
                isPrivate: false,
                host: host,
                manager: manager,
                item: item,
                observerWebView: extensionWebView,
                presentingRoot: root
            )
            privateRoute = try await requestUBOLMatchedRulesRoute(
                sourceTab: privateSource,
                isPrivate: true,
                host: host,
                manager: manager,
                item: item,
                observerWebView: extensionWebView,
                presentingRoot: root
            )
            privateReportRoute = try await requestUBOLPrivateReportRouteAfterFocusShift(
                sourceTab: privateSource,
                normalFocusTab: normalSource,
                host: host,
                manager: manager,
                item: item,
                observerWebView: extensionWebView,
                presentingRoot: root
            )
        } catch {
            await closePresentedActionPopupForCleanup(from: root)
            throw error
        }

        XCTAssertEqual(manager.extensionCreatedTabs.map(\.isPrivate), [false, true, true])
        XCTAssertTrue(
            normalRoute.webView?.configuration.webExtensionController === extensionController
        )
        XCTAssertTrue(
            privateRoute.webView?.configuration.webExtensionController === extensionController
        )
        XCTAssertTrue(
            privateReportRoute.webView?.configuration.webExtensionController === extensionController
        )
        let normalUserContentController = try XCTUnwrap(
            normalRoute.webView?.configuration.userContentController
        )
        let privateUserContentController = try XCTUnwrap(
            privateRoute.webView?.configuration.userContentController
        )
        XCTAssertFalse(normalUserContentController === privateUserContentController)
        XCTAssertTrue(context.errors.isEmpty, context.errors.map(\.localizedDescription).joined(separator: "\n"))
        for tab in manager.tabs {
            await tab.close()
        }
    }

    func testBundledDarkReaderThemesProductionHostTabsInBothPrivacyRealms() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_content_effects")
        let profile = profileFixture.profile
        // WKWebExtensionController can keep its SQLite-backed contexts alive until
        // process exit. Retire the host without unlinking that active WebKit data.
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        try await host.setPrivateAccess(true, identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let server = try makeDNRTestServer()
        defer { server.stop() }
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let normalURL = try XCTUnwrap(
            URL(string: "http://localhost:\(server.port)/?realm=normal-darkreader")
        )
        let privateURL = try XCTUnwrap(
            URL(string: "http://localhost:\(server.port)/?realm=private-darkreader")
        )
        let normalTab = manager.seedTab(url: normalURL, isPrivate: false)
        let privateTab = manager.seedTab(url: privateURL, isPrivate: true)
        manager.selectedTab = normalTab
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        for tab in [normalTab, privateTab] {
            tab.webView?.frame = root.view.bounds
            tab.webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let webView = tab.webView {
                root.view.addSubview(webView)
            }
        }
        privateTab.webView?.isHidden = true
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let extensionController = try XCTUnwrap(
            context.webViewConfiguration?.webExtensionController
        )
        let cases = [
            FloorpProductionHostTabCase(tab: normalTab, isPrivate: false, url: normalURL),
            FloorpProductionHostTabCase(tab: privateTab, isPrivate: true, url: privateURL)
        ]
        var navigationWaiters = [FloorpWebExtensionNavigationWaiter]()
        for testCase in cases {
            manager.selectTab(testCase.tab)
            host.focus(windowUUID: manager.windowUUID, isPrivate: testCase.isPrivate)
            normalTab.webView?.isHidden = testCase.isPrivate
            privateTab.webView?.isHidden = !testCase.isPrivate
            try await loadBackgroundContent(in: context)
            let webView = try XCTUnwrap(testCase.tab.webView)
            let navigation = FloorpWebExtensionNavigationWaiter()
            navigationWaiters.append(navigation)
            try await navigation.load(testCase.url, in: webView)
            let state = try await waitForJavaScriptState(
                in: webView,
                description: "Dark Reader production-host theme in private=\(testCase.isPrivate)",
                source: """
                const styleCount = document.querySelectorAll('style.darkreader').length;
                const mode = document.documentElement.dataset.darkreaderMode || '';
                const scheme = document.documentElement.dataset.darkreaderScheme || '';
                return {
                    ready: document.readyState === 'complete' &&
                        mode === 'dynamic' && scheme === 'dark' && styleCount > 0,
                    mode,
                    scheme,
                    styleCount,
                };
                """
            )

            XCTAssertEqual(state["mode"] as? String, "dynamic")
            XCTAssertEqual(state["scheme"] as? String, "dark")
            XCTAssertGreaterThan((state["styleCount"] as? NSNumber)?.intValue ?? 0, 0)
            XCTAssertEqual(webView.configuration.websiteDataStore.isPersistent, !testCase.isPrivate)
            XCTAssertTrue(webView.configuration.webExtensionController === extensionController)
        }

        let normalUserContentController = try XCTUnwrap(
            normalTab.webView?.configuration.userContentController
        )
        let privateUserContentController = try XCTUnwrap(
            privateTab.webView?.configuration.userContentController
        )
        XCTAssertFalse(normalUserContentController === privateUserContentController)
        XCTAssertTrue(context.hasAccessToPrivateData)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        withExtendedLifetime(navigationWaiters) {}
        for tab in manager.tabs {
            await tab.close()
        }
    }

    // swiftlint:disable:next function_body_length
    func testBundledUBOLStorageRetryAndScriptConvergenceRecoverPartialFailures() async throws {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_recovery_primitives")
        let profile = profileFixture.profile
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let webView = try await makeUBOLDeveloperModePage(context: context)
        defer { webView.stopLoading() }
        let raw = try await webView.floorpCallAsyncJavaScript(
            """
            const compat = await import(browser.runtime.getURL('js/ext-compat.js'));
            const scriptingManager = await import(
                browser.runtime.getURL('js/scripting-manager.js')
            );
            const compiledFilters = await import(
                browser.runtime.getURL('js/compiled-filters.js')
            );
            const fetchHelpers = await import(browser.runtime.getURL('js/fetch.js'));

            let transientSessionAttempts = 0;
            const sessionValue = await compat.runStorageOperation('session', async () => {
                transientSessionAttempts += 1;
                if ( transientSessionAttempts === 1 ) {
                    throw new Error('An unknown error occurred');
                }
                return 'recovered';
            });
            let permanentSessionAttempts = 0;
            let permanentSessionError = '';
            try {
                await compat.runStorageOperation('session', async () => {
                    permanentSessionAttempts += 1;
                    throw new Error('permission denied');
                });
            } catch (error) {
                permanentSessionError = String(error);
            }
            let invalidEnabledRulesetReadback = '';
            try {
                await compat.readNativeEnabledRulesets({
                    getEnabledRulesets(callback) { callback(undefined); },
                }, {});
            } catch (error) {
                invalidEnabledRulesetReadback = String(error);
            }
            let enabledRulesetLastError = '';
            try {
                await compat.readNativeEnabledRulesets({
                    getEnabledRulesets(callback) { callback([]); },
                }, { lastError: { message: 'injected enabled-ruleset read failure' } });
            } catch (error) {
                enabledRulesetLastError = String(error);
            }
            const validEnabledRulesets = await compat.readNativeEnabledRulesets({
                getEnabledRulesets(callback) { callback([ 'easylist' ]); },
            }, {});

            const sentinel = {
                id: 'floorp-safari-registration-sentinel',
                matches: [ 'https://floorp.invalid/*' ],
                js: [ '/js/safari-registration-sentinel.js' ],
                persistAcrossSessions: true,
                runAt: 'document_start',
            };
            const first = {
                id: 'floorp-test-first',
                matches: [ 'https://first.example/*' ],
                js: [ '/first.js' ],
                persistAcrossSessions: true,
                runAt: 'document_start',
            };
            const second = {
                id: 'floorp-test-second',
                matches: [ 'https://second.example/*' ],
                js: [ '/second.js' ],
                persistAcrossSessions: true,
                runAt: 'document_start',
            };
            const desired = [ sentinel, first, second ];
            const clone = value => structuredClone(value);
            const sorted = values => clone(values).sort((a, b) =>
                a.id < b.id ? -1 : a.id > b.id ? 1 : 0
            );
            const makeAPI = (initial, partialMethod, permanentlyReject = false) => {
                const state = new Map(initial.map(value => [ value.id, clone(value) ]));
                const calls = { register: 0, update: 0, remove: 0 };
                let didPartiallyApply = false;
                let sentinelMutationCount = 0;
                const maybeFail = (method, values, apply) => {
                    calls[method] += 1;
                    if ( method === 'update' &&
                         values.some(value => value.id === sentinel.id) ) {
                        sentinelMutationCount += 1;
                    }
                    if ( method === 'remove' && values.includes(sentinel.id) ) {
                        sentinelMutationCount += 1;
                    }
                    if ( method === partialMethod && permanentlyReject ) {
                        throw new Error(`permanent ${method} failure`);
                    }
                    if ( method === partialMethod && didPartiallyApply === false ) {
                        didPartiallyApply = true;
                        if ( values.length !== 0 ) { apply(values[0]); }
                        throw new Error(`partial ${method} failure`);
                    }
                    values.forEach(apply);
                };
                return {
                    calls,
                    get sentinelMutationCount() { return sentinelMutationCount; },
                    getRegisteredContentScripts: async () =>
                        Array.from(state.values(), clone),
                    registerContentScripts: async values => maybeFail(
                        'register', values, value => state.set(value.id, clone(value))
                    ),
                    updateContentScripts: async values => maybeFail(
                        'update', values, value => state.set(value.id, clone(value))
                    ),
                    unregisterContentScripts: async ({ ids }) => maybeFail(
                        'remove', ids, id => state.delete(id)
                    ),
                    snapshot: () => sorted(Array.from(state.values())),
                };
            };

            const registerAPI = makeAPI([ sentinel ], 'register');
            const updateAPI = makeAPI([
                sentinel,
                { ...first, matches: [ 'https://stale.example/*' ] },
                { ...second, matches: [ 'https://stale.example/*' ] },
            ], 'update');
            const removeAPI = makeAPI([
                ...desired,
                { ...first, id: 'floorp-test-stale-first' },
                { ...second, id: 'floorp-test-stale-second' },
            ], 'remove');
            for ( const api of [ registerAPI, updateAPI, removeAPI ] ) {
                await scriptingManager.reconcileSafariContentScripts(api, desired);
            }

            const permanentAPI = makeAPI([ sentinel ], 'register', true);
            let permanentReconcileError = '';
            try {
                await scriptingManager.reconcileSafariContentScripts(permanentAPI, desired);
            } catch (error) {
                permanentReconcileError = String(error);
            }

            const oldUserScript = {
                id: 'floorp-old-user-script',
                world: 'MAIN',
                allFrames: true,
                js: [ { code: 'globalThis.floorpOld = true;' } ],
                runAt: 'document_start',
                matches: [ 'https://old.example/*' ],
            };
            const desiredUserScript = {
                ...oldUserScript,
                id: 'floorp-new-user-script',
                matches: [ 'https://new.example/*' ],
            };
            let userScriptState = [ structuredClone(oldUserScript) ];
            let userScriptRegisterAttempts = 0;
            const userScriptAPI = {
                getScripts: async () => structuredClone(userScriptState),
                unregister: async () => { userScriptState = []; },
                register: async scripts => {
                    userScriptRegisterAttempts += 1;
                    if ( userScriptRegisterAttempts === 1 ) {
                        throw new Error('injected user-script register failure');
                    }
                    userScriptState = structuredClone(scripts);
                },
            };
            let userScriptFailure = '';
            try {
                await compiledFilters.reconcileUserScripts(
                    userScriptAPI,
                    [ desiredUserScript ]
                );
            } catch (error) {
                userScriptFailure = String(error);
            }
            const userScriptRollbackExact =
                JSON.stringify(userScriptState) === JSON.stringify([ oldUserScript ]);
            await compiledFilters.reconcileUserScripts(
                userScriptAPI,
                [ desiredUserScript ]
            );
            const userScriptRetryExact =
                JSON.stringify(userScriptState) === JSON.stringify([ desiredUserScript ]);

            let failedFetchRejected = false;
            try {
                await fetchHelpers.fetchJSON('data:application/json,not-valid-json?floorp=');
            } catch {
                failedFetchRejected = true;
            }

            const expected = JSON.stringify(sorted(desired));
            return {
                sessionValue,
                transientSessionAttempts,
                permanentSessionAttempts,
                permanentSessionError,
                invalidEnabledRulesetReadback,
                enabledRulesetLastError,
                validEnabledRulesets,
                registerConverged: JSON.stringify(registerAPI.snapshot()) === expected,
                updateConverged: JSON.stringify(updateAPI.snapshot()) === expected,
                removeConverged: JSON.stringify(removeAPI.snapshot()) === expected,
                registerAttempts: registerAPI.calls.register,
                updateAttempts: updateAPI.calls.update,
                removeAttempts: removeAPI.calls.remove,
                sentinelMutationCount: registerAPI.sentinelMutationCount +
                    updateAPI.sentinelMutationCount + removeAPI.sentinelMutationCount,
                permanentReconcileAttempts: permanentAPI.calls.register,
                permanentReconcileError,
                userScriptFailure,
                userScriptRollbackExact,
                userScriptRetryExact,
                userScriptRegisterAttempts,
                failedFetchRejected,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 15_000_000_000
        ) as? [String: Any]
        let state = try XCTUnwrap(raw)
        XCTAssertEqual(state["sessionValue"] as? String, "recovered")
        XCTAssertEqual((state["transientSessionAttempts"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((state["permanentSessionAttempts"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue((state["permanentSessionError"] as? String)?.contains("permission denied") == true)
        XCTAssertTrue(
            (state["invalidEnabledRulesetReadback"] as? String)?
                .contains("Invalid enabled static DNR readback") == true
        )
        XCTAssertTrue(
            (state["enabledRulesetLastError"] as? String)?
                .contains("injected enabled-ruleset read failure") == true
        )
        XCTAssertEqual(state["validEnabledRulesets"] as? [String], ["easylist"])
        XCTAssertEqual(state["registerConverged"] as? Bool, true)
        XCTAssertEqual(state["updateConverged"] as? Bool, true)
        XCTAssertEqual(state["removeConverged"] as? Bool, true)
        XCTAssertGreaterThanOrEqual((state["registerAttempts"] as? NSNumber)?.intValue ?? 0, 2)
        XCTAssertGreaterThanOrEqual((state["updateAttempts"] as? NSNumber)?.intValue ?? 0, 2)
        XCTAssertGreaterThanOrEqual((state["removeAttempts"] as? NSNumber)?.intValue ?? 0, 2)
        XCTAssertEqual((state["sentinelMutationCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((state["permanentReconcileAttempts"] as? NSNumber)?.intValue, 3)
        XCTAssertTrue(
            (state["permanentReconcileError"] as? String)?.contains("permanent register failure") == true
        )
        XCTAssertTrue(
            (state["userScriptFailure"] as? String)?.contains("injected user-script register failure") == true
        )
        XCTAssertEqual(state["userScriptRollbackExact"] as? Bool, true)
        XCTAssertEqual(state["userScriptRetryExact"] as? Bool, true)
        XCTAssertEqual((state["userScriptRegisterAttempts"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(state["failedFetchRejected"] as? Bool, true)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    // swiftlint:disable:next function_body_length
    func testBundledUBOLReconcilesSentinellessChangedContentScripts() async throws {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_registration_reconcile")
        let profile = profileFixture.profile
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        try await host.setPrivateAccess(true, identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let setupWebView = try await makeUBOLDeveloperModePage(context: context)
        defer { setupWebView.stopLoading() }
        let setup = try await setupWebView.floorpCallAsyncJavaScript(
            """
            const modeManager = await import(browser.runtime.getURL('js/mode-manager.js'));
            const scriptingManager = await import(browser.runtime.getURL('js/scripting-manager.js'));
            const ext = await import(browser.runtime.getURL('js/ext.js'));
            const sentinelId = 'floorp-safari-registration-sentinel';
            const storageSentinelKey = '__floorpSafariStorageSentinel';
            const rawLocalKeys = browser.storage.local.getKeys
                ? await browser.storage.local.getKeys()
                : Object.keys(await browser.storage.local.get(null));
            const visibleLocalKeys = await ext.localKeys();
            const initialScripts = await browser.scripting.getRegisteredContentScripts();
            const legacyScripts = initialScripts.filter(script => script.id !== sentinelId);
            if (legacyScripts.length === 0 || initialScripts.some(script => script.id === sentinelId) === false) {
                throw new Error('Missing initial Safari sentinel/content registrations');
            }
            const invalidMatches = [ 'https://floorp.invalid/*' ];
            try {
                await browser.scripting.updateContentScripts(legacyScripts.map(script => ({
                    id: script.id,
                    matches: invalidMatches,
                })));
            } catch (error) {
                return { setupError: { stage: 'corrupt-legacy', error: String(error) } };
            }
            const corruptedScripts = await browser.scripting.getRegisteredContentScripts();
            try {
                await browser.scripting.unregisterContentScripts({ ids: [ sentinelId ] });
            } catch (error) {
                return { setupError: { stage: 'remove-sentinel', error: String(error) } };
            }
            const sentinellessScripts = await browser.scripting.getRegisteredContentScripts();
            try {
                await scriptingManager.registerContentScripts(true);
            } catch (error) {
                return { setupError: { stage: 'reconcile', error: String(error) } };
            }
            const registeredScripts = await browser.scripting.getRegisteredContentScripts();
            const registrationShape = script => JSON.stringify({
                matches: script.matches || [],
                excludeMatches: script.excludeMatches || [],
                js: script.js || [],
                allFrames: script.allFrames === true,
                runAt: script.runAt || 'document_idle',
                world: script.world || 'ISOLATED',
            });
            const initialById = new Map(initialScripts.map(script => [ script.id, script ]));
            const finalById = new Map(registeredScripts.map(script => [ script.id, script ]));
            const registrationMismatches = legacyScripts.flatMap(script => {
                const restored = finalById.get(script.id);
                const initialShape = registrationShape(initialById.get(script.id));
                const restoredShape = restored === undefined
                    ? '<missing>'
                    : registrationShape(restored);
                return initialShape === restoredShape
                    ? []
                    : [ { id: script.id, initialShape, restoredShape } ];
            });
            return {
                filteringLevel: await modeManager.getDefaultFilteringMode(),
                enabledRulesets: await browser.declarativeNetRequest.getEnabledRulesets(),
                registeredScripts: registeredScripts.map(script => script.id),
                storageSentinelPersisted: rawLocalKeys.includes(storageSentinelKey),
                storageSentinelHidden: visibleLocalKeys.includes(storageSentinelKey) === false,
                legacyScriptCount: legacyScripts.length,
                allLegacyScriptsCorrupted: legacyScripts.every(script => {
                    const corrupted = corruptedScripts.find(value => value.id === script.id);
                    return JSON.stringify(corrupted?.matches || []) === JSON.stringify(invalidMatches);
                }),
                sentinelRemovedBeforeReconcile:
                    sentinellessScripts.some(script => script.id === sentinelId) === false,
                sentinelRestoredBeforeAllUpdates:
                    registeredScripts.some(script => script.id === sentinelId),
                allLegacyScriptsRestored: registrationMismatches.length === 0,
                registrationMismatches,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 15_000_000_000
        ) as? [String: Any]
        let setupState = try XCTUnwrap(setup)
        if let setupError = setupState["setupError"] as? [String: Any] {
            XCTFail(
                "uBO registration setup failed at \(setupError["stage"] ?? "unknown"): " +
                    "\(setupError["error"] ?? "unknown")"
            )
            return
        }
        XCTAssertEqual((setupState["filteringLevel"] as? NSNumber)?.intValue, 2)
        let enabledRulesets = Set(setupState["enabledRulesets"] as? [String] ?? [])
        XCTAssertTrue(Set(["ublock-filters", "easylist", "easyprivacy"]).isSubset(of: enabledRulesets))
        let registeredScripts = Set(setupState["registeredScripts"] as? [String] ?? [])
        XCTAssertTrue(registeredScripts.contains("ublock-filters.main"))
        XCTAssertEqual(setupState["storageSentinelPersisted"] as? Bool, true)
        XCTAssertEqual(setupState["storageSentinelHidden"] as? Bool, true)
        XCTAssertGreaterThan((setupState["legacyScriptCount"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(setupState["allLegacyScriptsCorrupted"] as? Bool, true)
        XCTAssertEqual(setupState["sentinelRemovedBeforeReconcile"] as? Bool, true)
        XCTAssertEqual(setupState["sentinelRestoredBeforeAllUpdates"] as? Bool, true)
        XCTAssertEqual(
            setupState["allLegacyScriptsRestored"] as? Bool,
            true,
            String(describing: setupState["registrationMismatches"])
        )
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
    }

    // swiftlint:disable:next function_body_length
    func testBundledUBOLBlocksProductionHostTabsAndRendersDashboard() async throws {
        // This end-to-end case exercises both privacy realms and every options
        // mutation path. Its measured runtime exceeds the one-minute CI default.
        executionTimeAllowance = 480
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let profileFixture = try makeIsolatedHostProfile(prefix: "ubol_content_effects")
        let profile = profileFixture.profile
        // WKWebExtensionController can keep its SQLite-backed contexts alive until
        // process exit. Retire the host without unlinking that active WebKit data.
        defer { FloorpNativeWebExtensionHost.remove(for: profile.localName()) }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        try await host.setPrivateAccess(true, identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let server = try makeDNRTestServer()
        defer { server.stop() }
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let normalURL = try XCTUnwrap(
            URL(string: "http://localhost:\(server.port)/?realm=normal-ubol")
        )
        let privateURL = try XCTUnwrap(
            URL(string: "http://localhost:\(server.port)/?realm=private-ubol")
        )
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let extensionController = try XCTUnwrap(
            context.webViewConfiguration?.webExtensionController
        )

        let normalTab = manager.seedTab(url: normalURL, isPrivate: false)
        let privateTab = manager.seedTab(url: privateURL, isPrivate: true)
        manager.selectedTab = normalTab
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        for tab in [normalTab, privateTab] {
            tab.webView?.frame = root.view.bounds
            tab.webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let webView = tab.webView {
                root.view.addSubview(webView)
            }
        }
        privateTab.webView?.isHidden = true
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        let cases = [
            FloorpProductionHostTabCase(tab: normalTab, isPrivate: false, url: normalURL),
            FloorpProductionHostTabCase(tab: privateTab, isPrivate: true, url: privateURL)
        ]
        var navigationWaiters = [FloorpWebExtensionNavigationWaiter]()
        for testCase in cases {
            manager.selectTab(testCase.tab)
            host.focus(windowUUID: manager.windowUUID, isPrivate: testCase.isPrivate)
            normalTab.webView?.isHidden = testCase.isPrivate
            privateTab.webView?.isHidden = !testCase.isPrivate
            XCTAssertTrue(
                host.needsBackgroundReadiness(
                    beforeNavigating: testCase.tab,
                    to: testCase.url
                )
            )
            let navigationAction = MockNavigationAction(
                url: testCase.url,
                type: .linkActivated
            )
            let preparationGeneration = host.beginNavigationPreparation(for: testCase.tab)
            let didPrepare = await host.prepareBackgroundContent(
                beforeNavigating: testCase.tab,
                to: testCase.url,
                navigationAction: navigationAction,
                generation: preparationGeneration
            )
            XCTAssertTrue(didPrepare)
            XCTAssertTrue(host.consumePreparedNavigation(navigationAction))
            XCTAssertFalse(
                host.needsBackgroundReadiness(
                    beforeNavigating: testCase.tab,
                    to: testCase.url
                )
            )
            let webView = try XCTUnwrap(testCase.tab.webView)
            let navigation = FloorpWebExtensionNavigationWaiter()
            navigationWaiters.append(navigation)
            try await navigation.load(testCase.url, in: webView)
            let state: [String: Any]
            do {
                state = try await waitForUBOLPageEffects(
                    in: webView,
                    description: "uBO Lite optimal production-host effects in private=\(testCase.isPrivate)",
                    expectedCosmeticHidden: false
                )
            } catch {
                let diagnostics = context.errors
                    .map(\.localizedDescription)
                    .joined(separator: " | ")
                throw FloorpNativeWebExtensionError.unsupportedOperation(
                    "\(error.localizedDescription); context=\(diagnostics.isEmpty ? "none" : diagnostics)"
                )
            }

            XCTAssertEqual(state["controlExecuted"] as? Bool, true)
            XCTAssertEqual(state["blockedExecuted"] as? Bool, false)
            // uBO Lite intentionally reserves generic cosmetic filtering for
            // complete mode. Optimal mode still applies DNR and site-specific
            // cosmetic/scriptlet filters, but must leave this generic probe visible.
            XCTAssertEqual(state["cosmeticHidden"] as? Bool, false)
            XCTAssertEqual(webView.configuration.websiteDataStore.isPersistent, !testCase.isPrivate)
            XCTAssertTrue(webView.configuration.webExtensionController === extensionController)
        }

        manager.selectTab(normalTab)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        normalTab.webView?.isHidden = false
        privateTab.webView?.isHidden = true
        let optionsController = try await host.optionsViewController(
            identifier: item.identifier,
            sourceTab: normalTab,
            isPrivate: false
        )
        let optionsNavigation = try XCTUnwrap(
            optionsController as? UINavigationController
        )
        let optionsPage = try XCTUnwrap(
            optionsNavigation.viewControllers.first as? FloorpNativeWebExtensionPageViewController
        )
        root.present(optionsNavigation, animated: false)
        optionsPage.loadViewIfNeeded()
        let optionsWebView = try XCTUnwrap(
            optionsPage.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        // Do not let the first tracked JavaScript probe race the initial
        // navigation-policy callback. While a native callback is in flight,
        // the production page correctly refuses document replacement; probing
        // about:blank here would otherwise cancel the navigation under test.
        try await waitForDocumentCommit(
            in: optionsWebView,
            expectedOrigin: context.baseURL
        )
        let dashboard = try await waitForJavaScriptState(
            in: optionsWebView,
            description: "uBO Lite production options dashboard",
            source: """
            const buttons = Array.from(document.querySelectorAll('#dashboard-nav .tabButton'));
            const filteringLevel = self.cachedRulesetData?.defaultFilteringMode;
            return {
                ready: document.readyState === 'complete' &&
                    document.body.classList.contains('loading') === false &&
                    buttons.length === 5 && buttons.every(button => button.textContent.trim() !== '') &&
                    typeof filteringLevel === 'number',
                pane: document.body.dataset.pane || '',
                platform: document.body.dataset.platform || '',
                filteringLevel,
                buttonCount: buttons.length,
            };
            """
        )
        XCTAssertEqual(dashboard["pane"] as? String, "settings")
        XCTAssertEqual(dashboard["platform"] as? String, "safari")
        XCTAssertEqual((dashboard["filteringLevel"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((dashboard["buttonCount"] as? NSNumber)?.intValue, 5)

        let settingsOnlyClose = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const before = await browser.runtime.sendMessage({
                what: 'getEnabledRulesets',
            });
            const renderedRulesetCount = document.querySelectorAll(
                '#lists [data-role="leaf"][data-rulesetid]'
            ).length;
            const preparation = await globalThis.floorpPrepareToClose();
            const after = await browser.runtime.sendMessage({
                what: 'getEnabledRulesets',
            });
            return { before, after, renderedRulesetCount, preparation };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 90_000_000_000
        ) as? [String: Any]
        let settingsOnlyState = try XCTUnwrap(settingsOnlyClose)
        let defaultRulesets = Set(settingsOnlyState["before"] as? [String] ?? [])
        XCTAssertTrue(
            Set(["ublock-filters", "easylist", "easyprivacy"]).isSubset(of: defaultRulesets),
            "The locale/device defaults must retain every required stock ruleset"
        )
        XCTAssertEqual((settingsOnlyState["renderedRulesetCount"] as? NSNumber)?.intValue, 0)
        let settingsOnlyPreparation = try XCTUnwrap(
            settingsOnlyState["preparation"] as? [String: Any]
        )
        XCTAssertEqual(settingsOnlyPreparation["ready"] as? Bool, true)
        XCTAssertEqual(
            Set(settingsOnlyState["after"] as? [String] ?? []),
            defaultRulesets,
            "Closing Settings before Filter lists renders must not disable the stock rulesets"
        )

        let interruptedRestoreRecovery: [String: Any]?
        var interruptedSnapshot: [String: Any]?
        var interruptedRestoreOperation = "setup"
        do {
            let setup = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const snapshot = await backup.backupToObject(self.cachedRulesetData);
                const initialEnabled = await browser.runtime.sendMessage({
                    what: 'getEnabledRulesets',
                });
                const alternateEnabled = initialEnabled.includes('jpn-1')
                    ? initialEnabled.filter(id => id !== 'jpn-1')
                    : initialEnabled.concat('jpn-1');
                const documentToken = crypto.randomUUID();
                document.documentElement.dataset.floorpRestoreProbe = documentToken;
                return {
                    snapshot,
                    initialEnabled,
                    alternateEnabled,
                    documentToken,
                };
                """,
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let setupState = try XCTUnwrap(setup)
            let snapshot = try XCTUnwrap(setupState["snapshot"] as? [String: Any])
            let initialEnabled = setupState["initialEnabled"] as? [String] ?? []
            let alternateEnabled = setupState["alternateEnabled"] as? [String] ?? []
            let documentToken = try XCTUnwrap(setupState["documentToken"] as? String)
            interruptedSnapshot = snapshot

            interruptedRestoreOperation = "stage"
            let staged = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                if (
                    document.documentElement.dataset.floorpRestoreProbe !==
                    documentToken
                ) {
                    throw new Error('Options document changed before restore staging');
                }
                const reconciler = await import(
                    browser.runtime.getURL('js/floorp-reconcile.js')
                );
                const journalKey = 'floorp.settingsRestoreJournal.v1';
                const interrupted = await browser.runtime.sendMessage({
                    what: 'beginSettingsRestore',
                });
                const result = await reconciler.reconcileProtection({
                    enabledRulesets: alternateEnabled,
                });
                if (result.ready !== true) {
                    throw new Error(result.error || 'Failed to stage interrupted restore');
                }
                const whileInterrupted = await browser.storage.local.get(journalKey);
                return {
                    interruptedJournalRetained:
                        whileInterrupted[journalKey]?.id === interrupted.id,
                    stagedChanged:
                        JSON.stringify([...alternateEnabled].sort()) !==
                        JSON.stringify([...initialEnabled].sort()),
                };
                """,
                arguments: [
                    "documentToken": documentToken,
                    "initialEnabled": initialEnabled,
                    "alternateEnabled": alternateEnabled,
                ],
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let stagedState = try XCTUnwrap(staged)

            interruptedRestoreOperation = "restore"
            interruptedRestoreRecovery = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                if (
                    document.documentElement.dataset.floorpRestoreProbe !==
                    documentToken
                ) {
                    throw new Error('Options document changed before restore recovery');
                }
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const journalKey = 'floorp.settingsRestoreJournal.v1';
                await backup.restoreFromObject(snapshot);
                const finalEnabled = await browser.runtime.sendMessage({
                    what: 'getEnabledRulesets',
                });
                const finalConfig = await browser.runtime.sendMessage({
                    what: 'getOptionsPageData',
                });
                Object.assign(self.cachedRulesetData, finalConfig);
                const finalStorage = await browser.storage.local.get(journalKey);
                const readiness = await browser.runtime.sendMessage({
                    what: 'floorpReadiness',
                });
                delete document.documentElement.dataset.floorpRestoreProbe;
                return {
                    interruptedJournalRetained,
                    stagedChanged,
                    initialEnabled,
                    finalEnabled,
                    journalRemoved: finalStorage[journalKey] === undefined,
                    readiness,
                };
                """,
                arguments: [
                    "documentToken": documentToken,
                    "snapshot": snapshot,
                    "initialEnabled": initialEnabled,
                    "interruptedJournalRetained":
                        stagedState["interruptedJournalRetained"] as? Bool ?? false,
                    "stagedChanged": stagedState["stagedChanged"] as? Bool ?? false,
                ],
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
        } catch {
            let operationError = error
            if let interruptedSnapshot {
                _ = try? await optionsWebView.floorpCallAsyncJavaScript(
                    """
                    const backup = await import(
                        browser.runtime.getURL('js/backup-restore.js')
                    );
                    await backup.restoreFromObject(snapshot);
                    delete document.documentElement.dataset.floorpRestoreProbe;
                    return true;
                    """,
                    arguments: ["snapshot": interruptedSnapshot],
                    contentWorld: .page,
                    timeoutNanoseconds: 90_000_000_000
                )
            }
            throw NSError(
                domain: "FloorpInterruptedRestoreIntegration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(interruptedRestoreOperation) failed: \(operationError)",
                    NSUnderlyingErrorKey: operationError,
                ]
            )
        }
        let interruptedState = try XCTUnwrap(interruptedRestoreRecovery)
        XCTAssertEqual(interruptedState["interruptedJournalRetained"] as? Bool, true)
        XCTAssertEqual(interruptedState["stagedChanged"] as? Bool, true)
        XCTAssertEqual(
            Set(interruptedState["finalEnabled"] as? [String] ?? []),
            Set(interruptedState["initialEnabled"] as? [String] ?? [])
        )
        XCTAssertEqual(interruptedState["journalRemoved"] as? Bool, true)
        XCTAssertEqual(
            (interruptedState["readiness"] as? [String: Any])?["ready"] as? Bool,
            true
        )

        let userRuleDraftRoundTrip: [String: Any]?
        var userRuleSnapshot: [String: Any]?
        var userRuleRestoreOperation = "setup"
        do {
            let setup = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const userRuleBase = 9000000;
                const originalStorage = await browser.storage.local.get('userDnrRules');
                const originalRules = (
                    await browser.declarativeNetRequest.getDynamicRules()
                ).filter(rule => rule.id >= userRuleBase);
                const snapshot = await backup.backupToObject(self.cachedRulesetData);
                const documentToken = crypto.randomUUID();
                document.documentElement.dataset.floorpUserRuleProbe = documentToken;
                return {
                    snapshot,
                    originalStorage,
                    originalRules,
                    documentToken,
                };
                """,
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let setupState = try XCTUnwrap(setup)
            let snapshot = try XCTUnwrap(setupState["snapshot"] as? [String: Any])
            let originalStorage =
                setupState["originalStorage"] as? [String: Any] ?? [:]
            let originalRules =
                setupState["originalRules"] as? [[String: Any]] ?? []
            let documentToken = try XCTUnwrap(setupState["documentToken"] as? String)
            userRuleSnapshot = snapshot

            userRuleRestoreOperation = "inactive"
            let inactive = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                if (
                    document.documentElement.dataset.floorpUserRuleProbe !==
                    documentToken
                ) {
                    throw new Error('Options document changed before inactive user rules');
                }
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const userRuleBase = 9000000;
                const inactiveDraft = [
                    'action:',
                    '  type: block',
                    '  unfinished: true',
                ];
                await backup.restoreFromObject({
                    ...snapshot,
                    developerMode: false,
                    dnrRules: inactiveDraft,
                });
                const inactiveStorage =
                    await browser.storage.local.get('userDnrRules');
                const inactiveRules =
                    await browser.declarativeNetRequest.getDynamicRules();
                return {
                    inactiveStoredExactly:
                        inactiveStorage.userDnrRules === inactiveDraft.join('\\n'),
                    inactiveRuleCount: inactiveRules.filter(
                        rule => rule.id >= userRuleBase
                    ).length,
                };
                """,
                arguments: [
                    "documentToken": documentToken,
                    "snapshot": snapshot,
                ],
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let inactiveState = try XCTUnwrap(inactive)

            userRuleRestoreOperation = "active"
            let active = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                if (
                    document.documentElement.dataset.floorpUserRuleProbe !==
                    documentToken
                ) {
                    throw new Error('Options document changed before active user rules');
                }
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const userRuleBase = 9000000;
                const activeDraft = [
                    'action:',
                    '  type: block',
                    '  unfinished: true',
                    '---',
                    'action:',
                    '  type: block',
                    'condition:',
                    '  urlFilter: ||floorp-user-rule.invalid^',
                    '  excludedInitiatorDomains:',
                    '  excludedRequestDomains:',
                    '  excludedResourceTypes:',
                ];
                await backup.restoreFromObject({
                    ...snapshot,
                    developerMode: true,
                    dnrRules: activeDraft,
                });
                const activeStorage =
                    await browser.storage.local.get('userDnrRules');
                const activeRules = (
                    await browser.declarativeNetRequest.getDynamicRules()
                ).filter(rule => rule.id >= userRuleBase);
                return {
                    activeStoredExactly:
                        activeStorage.userDnrRules === activeDraft.join('\\n'),
                    activeRuleCount: activeRules.length,
                    activeURLFilter:
                        activeRules[0]?.condition?.urlFilter || '',
                };
                """,
                arguments: [
                    "documentToken": documentToken,
                    "snapshot": snapshot,
                ],
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let activeState = try XCTUnwrap(active)

            userRuleRestoreOperation = "final restore"
            let restored = try await optionsWebView.floorpCallAsyncJavaScript(
                """
                if (
                    document.documentElement.dataset.floorpUserRuleProbe !==
                    documentToken
                ) {
                    throw new Error('Options document changed before final user-rule restore');
                }
                const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
                const journalKey = 'floorp.settingsRestoreJournal.v1';
                const userRuleBase = 9000000;
                await backup.restoreFromObject(snapshot);
                const finalStorage = await browser.storage.local.get([
                    'userDnrRules',
                    journalKey,
                ]);
                const finalRules = (
                    await browser.declarativeNetRequest.getDynamicRules()
                ).filter(rule => rule.id >= userRuleBase);
                const finalConfig = await browser.runtime.sendMessage({
                    what: 'getOptionsPageData',
                });
                Object.assign(self.cachedRulesetData, finalConfig);
                const readiness = await browser.runtime.sendMessage({
                    what: 'floorpReadiness',
                });
                delete document.documentElement.dataset.floorpUserRuleProbe;
                return {
                    finalUserRuleTextMatches:
                        finalStorage.userDnrRules === originalStorage.userDnrRules,
                    finalRuleSetMatches:
                        JSON.stringify(finalRules) === JSON.stringify(originalRules),
                    finalHasJournal: finalStorage[journalKey] !== undefined,
                    readiness,
                };
                """,
                arguments: [
                    "documentToken": documentToken,
                    "snapshot": snapshot,
                    "originalStorage": originalStorage,
                    "originalRules": originalRules,
                ],
                contentWorld: .page,
                timeoutNanoseconds: 90_000_000_000
            ) as? [String: Any]
            let restoredState = try XCTUnwrap(restored)

            userRuleDraftRoundTrip = inactiveState
                .merging(activeState) { _, new in new }
                .merging(restoredState) { _, new in new }
        } catch {
            let operationError = error
            if let userRuleSnapshot {
                _ = try? await optionsWebView.floorpCallAsyncJavaScript(
                    """
                    const backup = await import(
                        browser.runtime.getURL('js/backup-restore.js')
                    );
                    await backup.restoreFromObject(snapshot);
                    delete document.documentElement.dataset.floorpUserRuleProbe;
                    return true;
                    """,
                    arguments: ["snapshot": userRuleSnapshot],
                    contentWorld: .page,
                    timeoutNanoseconds: 90_000_000_000
                )
            }
            throw NSError(
                domain: "FloorpUserRuleRestoreIntegration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(userRuleRestoreOperation) failed: \(operationError)",
                    NSUnderlyingErrorKey: operationError,
                ]
            )
        }
        let draftState = try XCTUnwrap(userRuleDraftRoundTrip)
        XCTAssertEqual(draftState["inactiveStoredExactly"] as? Bool, true)
        XCTAssertEqual((draftState["inactiveRuleCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(draftState["activeStoredExactly"] as? Bool, true)
        XCTAssertEqual((draftState["activeRuleCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(
            draftState["activeURLFilter"] as? String,
            "||floorp-user-rule.invalid^"
        )
        XCTAssertEqual(draftState["finalUserRuleTextMatches"] as? Bool, true)
        XCTAssertEqual(draftState["finalRuleSetMatches"] as? Bool, true)
        XCTAssertEqual(draftState["finalHasJournal"] as? Bool, false)
        XCTAssertEqual(
            (draftState["readiness"] as? [String: Any])?["ready"] as? Bool,
            true
        )

        let rollbackSideEffects = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const alarms = await import(browser.runtime.getURL('js/alarms.js'));
            const journalKey = 'floorp.settingsRestoreJournal.v1';
            const originalJobs = await browser.storage.local.get('deferredJobs');
            const beforeConfig = await browser.runtime.sendMessage({
                what: 'getOptionsPageData',
            });
            const testJob = {
                name: 'floorpRollbackAlarmProbe',
                time: Date.now() + 15 * 60 * 1000,
            };
            const readLocalUntil = async predicate => {
                const deadline = Date.now() + 2_000;
                let state;
                do {
                    state = await browser.storage.local.get([
                        'deferredJobs',
                        journalKey,
                    ]);
                    if ( predicate(state) ) { return state; }
                    await new Promise(resolve => setTimeout(resolve, 50));
                } while ( Date.now() < deadline );
                return state;
            };
            await browser.storage.local.set({ deferredJobs: [testJob] });
            await alarms.resetJobsAlarm();
            const transaction = await browser.runtime.sendMessage({
                what: 'beginSettingsRestore',
            });
            const snapshottedStorage = await readLocalUntil(state =>
                state[journalKey]?.id === transaction.id &&
                state[journalKey]?.beforeLocal?.deferredJobs?.length === 1 &&
                state[journalKey].beforeLocal.deferredJobs[0]?.name === testJob.name
            );
            await browser.runtime.sendMessage({
                what: 'setShowBlockedCount',
                state: !beforeConfig.showBlockedCount,
            });
            await browser.storage.local.remove('deferredJobs');
            await browser.alarms.clear('deferredJobs');
            const rollback = await browser.runtime.sendMessage({
                what: 'rollbackSettingsRestore',
                id: transaction.id,
            });
            const rollbackVisible = await readLocalUntil(state =>
                state[journalKey] === undefined
            );
            const verificationTransaction = await browser.runtime.sendMessage({
                what: 'beginSettingsRestore',
            });
            let verifiedStorage;
            try {
                verifiedStorage = await readLocalUntil(state =>
                    state[journalKey]?.id === verificationTransaction.id
                );
            } finally {
                await browser.runtime.sendMessage({
                    what: 'commitSettingsRestore',
                    id: verificationTransaction.id,
                });
            }
            const committedVerification = await readLocalUntil(state =>
                state[journalKey] === undefined
            );
            const restoredAlarm = await browser.alarms.get('deferredJobs');
            const restoredConfig = await browser.runtime.sendMessage({
                what: 'getOptionsPageData',
            });
            if (originalJobs.deferredJobs === undefined) {
                await browser.storage.local.remove('deferredJobs');
            } else {
                await browser.storage.local.set({
                    deferredJobs: originalJobs.deferredJobs,
                });
            }
            await alarms.resetJobsAlarm();
            Object.assign(self.cachedRulesetData, restoredConfig);
            const readiness = await browser.runtime.sendMessage({
                what: 'floorpReadiness',
            });
            return {
                rolledBack: rollback?.rolledBack === true,
                jobSnapshotted:
                    snapshottedStorage[journalKey]?.beforeLocal
                        ?.deferredJobs?.length === 1 &&
                    snapshottedStorage[journalKey].beforeLocal
                        .deferredJobs[0]?.name === testJob.name,
                jobRestored:
                    verifiedStorage[journalKey]?.beforeLocal?.deferredJobs
                        ?.filter(job =>
                            job?.name === testJob.name &&
                            job?.time === testJob.time
                        ).length === 1,
                alarmRestored: restoredAlarm?.name === 'deferredJobs',
                optionRestored:
                    restoredConfig.showBlockedCount === beforeConfig.showBlockedCount,
                journalRemoved:
                    rollbackVisible[journalKey] === undefined &&
                    committedVerification[journalKey] === undefined,
                readiness,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 60_000_000_000
        ) as? [String: Any]
        let rollbackSideEffectState = try XCTUnwrap(rollbackSideEffects)
        XCTAssertEqual(rollbackSideEffectState["rolledBack"] as? Bool, true)
        XCTAssertEqual(rollbackSideEffectState["jobSnapshotted"] as? Bool, true)
        XCTAssertEqual(rollbackSideEffectState["jobRestored"] as? Bool, true)
        XCTAssertEqual(rollbackSideEffectState["alarmRestored"] as? Bool, true)
        XCTAssertEqual(rollbackSideEffectState["optionRestored"] as? Bool, true)
        XCTAssertEqual(rollbackSideEffectState["journalRemoved"] as? Bool, true)
        XCTAssertEqual(
            (rollbackSideEffectState["readiness"] as? [String: Any])?["ready"] as? Bool,
            true
        )

        let rejectedRestore = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
            const journalKey = 'floorp.settingsRestoreJournal.v1';
            let journalMutationCount = 0;
            const journalObserver = (changes, areaName) => {
                if (
                    areaName === 'local' &&
                    Object.prototype.hasOwnProperty.call(changes, journalKey)
                ) {
                    journalMutationCount += 1;
                }
            };
            browser.storage.onChanged.addListener(journalObserver);
            let restoreError = '';
            try {
                await backup.restoreFromObject({
                    developerMode: true,
                    rulesets: [ '+jpn-1' ],
                    dnrRules: [ 'action:', '  type: block' ],
                });
            } catch (reason) {
                restoreError = reason instanceof Error ? reason.message : `${reason}`;
            } finally {
                browser.storage.onChanged.removeListener(journalObserver);
            }
            const enabledRulesets = await browser.runtime.sendMessage({
                what: 'getEnabledRulesets',
            });
            const config = await browser.runtime.sendMessage({
                what: 'getOptionsPageData',
            });
            // The public dashboard restore path refreshes this cache in both
            // success and failure cases. This low-level rollback probe calls
            // backup.restoreFromObject directly, so mirror that UI refresh
            // before testing the close handshake in isolation.
            Object.assign(self.cachedRulesetData, config);
            const readiness = await browser.runtime.sendMessage({
                what: 'floorpReadiness',
            });
            const persisted = await browser.storage.local.get([
                'rulesetConfig',
                journalKey,
            ]);
            const failedClose = await globalThis.floorpPrepareToClose();
            const retryClose = await globalThis.floorpPrepareToClose();
            return {
                restoreError,
                enabledRulesets,
                developerMode: config?.developerMode,
                persistedEnabledRulesets:
                    persisted.rulesetConfig?.config?.enabledRulesets,
                hasRestoreJournal:
                    persisted[journalKey] !== undefined,
                journalMutationCount,
                readiness,
                failedClose,
                retryClose,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 20_000_000_000
        ) as? [String: Any]
        let rejectedRestoreState = try XCTUnwrap(rejectedRestore)
        XCTAssertTrue(
            (rejectedRestoreState["restoreError"] as? String)?.contains(
                "Settings restore DNR preflight failed"
            ) == true
        )
        XCTAssertEqual(
            Set(rejectedRestoreState["enabledRulesets"] as? [String] ?? []),
            defaultRulesets,
            "A rejected restore must not mutate WebKit static rulesets"
        )
        XCTAssertEqual(
            Set(rejectedRestoreState["persistedEnabledRulesets"] as? [String] ?? []),
            defaultRulesets,
            "A rejected restore must not mutate durable ruleset intent"
        )
        XCTAssertEqual(rejectedRestoreState["developerMode"] as? Bool, false)
        XCTAssertEqual(rejectedRestoreState["hasRestoreJournal"] as? Bool, false)
        XCTAssertEqual(
            (rejectedRestoreState["journalMutationCount"] as? NSNumber)?.intValue,
            0,
            "Preflight rejection must occur before the restore journal is opened"
        )
        let rollbackReadiness = try XCTUnwrap(
            rejectedRestoreState["readiness"] as? [String: Any]
        )
        XCTAssertEqual(rollbackReadiness["ready"] as? Bool, true)
        let failedRollbackClose = try XCTUnwrap(
            rejectedRestoreState["failedClose"] as? [String: Any]
        )
        XCTAssertEqual(failedRollbackClose["ready"] as? Bool, false)
        XCTAssertTrue(
            (failedRollbackClose["error"] as? String)?.isEmpty == false,
            "The first close attempt must surface the tracked restore failure"
        )
        let retriedRollbackClose = try XCTUnwrap(
            rejectedRestoreState["retryClose"] as? [String: Any]
        )
        XCTAssertEqual(retriedRollbackClose["ready"] as? Bool, true)

        let closePreparation = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const ext = await import(browser.runtime.getURL('js/ext.js'));
            const settings = await import(browser.runtime.getURL('js/settings.js'));
            const filters = await import(browser.runtime.getURL('js/filter-manager-ui.js'));
            const backup = await import(browser.runtime.getURL('js/backup-restore.js'));
            const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

            const modeBefore = self.cachedRulesetData.defaultFilteringMode;
            const basicInput = document.querySelector(
                '.filteringModeCard input[type="radio"][value="1"]'
            );
            const delayedMode = ext.trackOptionsOperation(
                settings.onFilteringModeChange(
                    { target: basicInput },
                    async request => {
                        await delay(150);
                        return ext.sendMessage(request);
                    }
                )
            );
            const modeStarted = performance.now();
            const modeClose = await globalThis.floorpPrepareToClose();
            const modeElapsed = performance.now() - modeStarted;
            await delayedMode;
            const modeConfirmed = await ext.sendMessage({
                what: 'getDefaultFilteringMode',
            });
            await ext.sendMessage({
                what: 'setDefaultFilteringMode',
                level: modeBefore,
            });
            self.cachedRulesetData.defaultFilteringMode = modeBefore;
            document.querySelector(
                `.filteringModeCard input[type="radio"][value="${modeBefore}"]`
            ).checked = true;
            const modeRestoreClose = await globalThis.floorpPrepareToClose();

            const customHostname = 'floorp-close-custom.invalid';
            const customSelector = '.floorp-close-custom-ad';
            const customOperation = ext.trackOptionsOperation((async () => {
                await delay(150);
                await ext.sendMessage({
                    what: 'addCustomFilters',
                    hostname: customHostname,
                    selectors: [ customSelector ],
                });
            })());
            const customStarted = performance.now();
            const customClose = await globalThis.floorpPrepareToClose();
            const customElapsed = performance.now() - customStarted;
            await customOperation;
            const customConfirmed = new Map(
                await ext.sendMessage({ what: 'getAllCustomFilters' })
            ).get(customHostname)?.includes(customSelector) === true;
            await ext.sendMessage({
                what: 'removeAllCustomFilters',
                hostname: customHostname,
            });
            await globalThis.floorpPrepareToClose();

            const fileHostname = 'floorp-file-import.invalid';
            const fileSelector = '.floorp-file-import-ad';
            const fakeReader = {
                result: undefined,
                readAsText() {
                    setTimeout(() => {
                        this.result = `${fileHostname}##${fileSelector}`;
                        this.onload();
                    }, 150);
                },
            };
            const fileOperation = ext.trackOptionsOperation(
                filters.readAndImportCustomFiltersFile(
                    { name: 'delayed-custom-filters.txt' },
                    fakeReader
                )
            );
            const fileStarted = performance.now();
            const fileClose = await globalThis.floorpPrepareToClose();
            const fileElapsed = performance.now() - fileStarted;
            await fileOperation;
            const fileConfirmed = new Map(
                await ext.sendMessage({ what: 'getAllCustomFilters' })
            ).get(fileHostname)?.includes(fileSelector) === true;
            await ext.sendMessage({
                what: 'removeAllCustomFilters',
                hostname: fileHostname,
            });
            await globalThis.floorpPrepareToClose();

            const restoreSnapshot = await backup.backupToObject(self.cachedRulesetData);
            const restoreOperation = ext.trackOptionsOperation(
                settings.restoreSettingsFromObject(
                    restoreSnapshot,
                    async config => {
                        await delay(150);
                        return backup.restoreFromObject(config);
                    }
                )
            );
            const restoreStarted = performance.now();
            const restoreClose = await globalThis.floorpPrepareToClose();
            const restoreElapsed = performance.now() - restoreStarted;
            const restoreSucceeded = await restoreOperation;

            const rejected = ext.trackOptionsOperation(
                Promise.reject(new Error('injected tracked dashboard failure'))
            );
            await Promise.allSettled([ rejected ]);
            const firstFailureClose = await globalThis.floorpPrepareToClose();
            const retryClose = await globalThis.floorpPrepareToClose();

            const paneStates = [];
            for ( const button of document.querySelectorAll('#dashboard-nav .tabButton') ) {
                button.click();
                await delay(30);
                paneStates.push({
                    expected: button.dataset.pane,
                    actual: document.body.dataset.pane,
                    handshake: typeof globalThis.floorpPrepareToClose === 'function',
                });
            }
            document.querySelector(
                '#dashboard-nav .tabButton[data-pane="settings"]'
            ).click();
            document.querySelector('#runtimeError').textContent = '';
            return {
                modeReady: modeClose.ready === true,
                modeError: modeClose.error || '',
                modeElapsed,
                modeConfirmed,
                modeRestoreReady: modeRestoreClose.ready === true,
                modeRestoreError: modeRestoreClose.error || '',
                customReady: customClose.ready === true,
                customError: customClose.error || '',
                customElapsed,
                customConfirmed,
                fileReady: fileClose.ready === true,
                fileError: fileClose.error || '',
                fileElapsed,
                fileConfirmed,
                restoreReady: restoreClose.ready === true,
                restoreElapsed,
                restoreSucceeded,
                firstFailureReady: firstFailureClose.ready === true,
                firstFailureError: firstFailureClose.error || '',
                retryReady: retryClose.ready === true,
                panesReady: paneStates.every(state =>
                    state.expected === state.actual && state.handshake
                ),
                paneCount: paneStates.length,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 60_000_000_000
        ) as? [String: Any]
        let closeState = try XCTUnwrap(closePreparation)
        XCTAssertEqual(
            closeState["modeReady"] as? Bool,
            true,
            String(describing: closeState["modeError"])
        )
        XCTAssertGreaterThanOrEqual((closeState["modeElapsed"] as? NSNumber)?.doubleValue ?? 0, 100)
        XCTAssertEqual((closeState["modeConfirmed"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(
            closeState["modeRestoreReady"] as? Bool,
            true,
            String(describing: closeState["modeRestoreError"])
        )
        XCTAssertEqual(
            closeState["customReady"] as? Bool,
            true,
            String(describing: closeState["customError"])
        )
        XCTAssertGreaterThanOrEqual((closeState["customElapsed"] as? NSNumber)?.doubleValue ?? 0, 100)
        XCTAssertEqual(closeState["customConfirmed"] as? Bool, true)
        XCTAssertEqual(
            closeState["fileReady"] as? Bool,
            true,
            String(describing: closeState["fileError"])
        )
        XCTAssertGreaterThanOrEqual((closeState["fileElapsed"] as? NSNumber)?.doubleValue ?? 0, 100)
        XCTAssertEqual(closeState["fileConfirmed"] as? Bool, true)
        XCTAssertEqual(closeState["restoreReady"] as? Bool, true)
        XCTAssertGreaterThanOrEqual((closeState["restoreElapsed"] as? NSNumber)?.doubleValue ?? 0, 100)
        XCTAssertEqual(closeState["restoreSucceeded"] as? Bool, true)
        XCTAssertEqual(closeState["firstFailureReady"] as? Bool, false)
        XCTAssertTrue(
            (closeState["firstFailureError"] as? String)?.contains("injected tracked dashboard failure") == true
        )
        XCTAssertEqual(closeState["retryReady"] as? Bool, true)
        XCTAssertEqual(closeState["panesReady"] as? Bool, true)
        XCTAssertEqual((closeState["paneCount"] as? NSNumber)?.intValue, 5)

        let atomicCustomFilterMutation = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const ext = await import(browser.runtime.getURL('js/ext.js'));
            const manager = await import(browser.runtime.getURL('js/filter-manager.js'));
            const ui = await import(browser.runtime.getURL('js/filter-manager-ui.js'));
            const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
            const entries = async () => new Map(
                await ext.sendMessage({ what: 'getAllCustomFilters' })
            );
            const oldHostname = 'floorp-atomic-old.invalid';
            const newHostname = 'floorp-atomic-new.invalid';
            const selector = '.floorp-atomic-ad';
            await ext.sendMessage({
                what: 'addCustomFilters',
                hostname: oldHostname,
                selectors: [ selector ],
            });
            let registrationAttempts = 0;
            let injectedError = '';
            try {
                await manager.replaceCustomFiltersAtomically(
                    { hostname: oldHostname, selectors: [ selector ] },
                    { hostname: newHostname, selectors: [ selector ] },
                    async () => {
                        registrationAttempts += 1;
                        if ( registrationAttempts === 1 ) {
                            throw new Error('injected registration failure');
                        }
                    }
                );
            } catch (error) {
                injectedError = String(error);
            }
            const afterFailure = await entries();
            const oldRetained = afterFailure.get(oldHostname)?.includes(selector) === true;
            const newAbsent = afterFailure.has(newHostname) === false;
            await manager.replaceCustomFiltersAtomically(
                { hostname: oldHostname, selectors: [ selector ] },
                { hostname: newHostname, selectors: [ selector ] },
                async () => { registrationAttempts += 1; }
            );
            const afterRetry = await entries();
            const retryMoved = afterRetry.has(oldHostname) === false &&
                afterRetry.get(newHostname)?.includes(selector) === true;
            await ext.sendMessage({
                what: 'removeAllCustomFilters',
                hostname: newHostname,
            });

            const uiOldHostname = 'floorp-ui-old.invalid';
            const uiNewHostname = 'floorp-ui-new.invalid';
            await ext.sendMessage({
                what: 'addCustomFilters',
                hostname: uiOldHostname,
                selectors: [ selector ],
            });
            document.querySelector(
                '#dashboard-nav .tabButton[data-pane="filters"]'
            ).click();
            await delay(400);
            let hostnameTarget = document.querySelector(
                `li.hostname[data-ugly="${uiOldHostname}"] span.hostname`
            );
            if (!hostnameTarget) { throw new Error('Missing custom-filter hostname editor'); }
            hostnameTarget.textContent = uiNewHostname;
            let uiError = '';
            try {
                await ui.onHostnameChanged(
                    hostnameTarget,
                    uiOldHostname,
                    uiNewHostname,
                    async () => { throw new Error('injected rename failure'); }
                );
            } catch (error) {
                uiError = String(error);
            }
            const afterUIFailure = await entries();
            const committingCleared = document.body.classList.contains('committing') === false;
            const visibleError = document.querySelector('#runtimeError')?.textContent || '';
            const uiOldRetained = afterUIFailure.get(uiOldHostname)?.includes(selector) === true;
            hostnameTarget = document.querySelector(
                `li.hostname[data-ugly="${uiOldHostname}"] span.hostname`
            );
            hostnameTarget.textContent = uiNewHostname;
            const uiRetry = await ui.onHostnameChanged(
                hostnameTarget,
                uiOldHostname,
                uiNewHostname
            );
            const afterUIRetry = await entries();
            const uiRetryMoved = afterUIRetry.has(uiOldHostname) === false &&
                afterUIRetry.get(uiNewHostname)?.includes(selector) === true;
            await ext.sendMessage({
                what: 'removeAllCustomFilters',
                hostname: uiNewHostname,
            });
            await globalThis.floorpPrepareToClose();
            document.querySelector('#runtimeError').textContent = '';
            return {
                registrationAttempts,
                injectedError,
                oldRetained,
                newAbsent,
                retryMoved,
                uiError,
                committingCleared,
                visibleError,
                uiOldRetained,
                uiRetry,
                uiRetryMoved,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 30_000_000_000
        ) as? [String: Any]
        let customFilterState = try XCTUnwrap(atomicCustomFilterMutation)
        XCTAssertGreaterThanOrEqual(
            (customFilterState["registrationAttempts"] as? NSNumber)?.intValue ?? 0,
            3
        )
        XCTAssertTrue(
            (customFilterState["injectedError"] as? String)?.contains("injected registration failure") == true
        )
        XCTAssertEqual(customFilterState["oldRetained"] as? Bool, true)
        XCTAssertEqual(customFilterState["newAbsent"] as? Bool, true)
        XCTAssertEqual(customFilterState["retryMoved"] as? Bool, true)
        XCTAssertTrue(
            (customFilterState["uiError"] as? String)?.contains("injected rename failure") == true
        )
        XCTAssertEqual(customFilterState["committingCleared"] as? Bool, true)
        XCTAssertTrue(
            (customFilterState["visibleError"] as? String)?.contains("injected rename failure") == true
        )
        XCTAssertEqual(customFilterState["uiOldRetained"] as? Bool, true)
        XCTAssertEqual(customFilterState["uiRetry"] as? Bool, true)
        XCTAssertEqual(customFilterState["uiRetryMoved"] as? Bool, true)

        let mutationFailure = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const settings = await import(browser.runtime.getURL('js/settings.js'));
            const ext = await import(browser.runtime.getURL('js/ext.js'));
            await globalThis.floorpPrepareToClose();
            await globalThis.floorpPrepareToClose();
            const input = document.querySelector(
                '.filteringModeCard input[type="radio"][value="1"]'
            );
            const beforeLevel = self.cachedRulesetData.defaultFilteringMode;
            input.checked = true;
            let modeRequestCount = 0;
            const modeCommitted = await settings.onFilteringModeChange(
                { target: input },
                async () => {
                    modeRequestCount += 1;
                    return { error: 'injected options mutation failure' };
                }
            );
            const modeError = document.querySelector('#runtimeError')?.textContent || '';
            const selectedLevel = document.querySelector(
                '.filteringModeCard input[type="radio"]:checked'
            )?.value;

            const restoreSteps = [];
            const restoreCompleted = await settings.restoreSettingsFromObject(
                {},
                async () => {
                    restoreSteps.push('before-failure');
                    ext.assertSuccessfulMessageResponse({
                        error: 'injected restore mutation failure',
                    });
                    restoreSteps.push('after-failure');
                }
            );
            const restoreError = document.querySelector('#runtimeError')?.textContent || '';
            const busyAfterRestore = document.body.classList.contains('busy');
            const restoreFailureClose = await globalThis.floorpPrepareToClose();
            const restoreRetryClose = await globalThis.floorpPrepareToClose();
            document.querySelector('#runtimeError').textContent = '';
            return {
                modeCommitted,
                modeRequestCount,
                beforeLevel,
                afterLevel: self.cachedRulesetData.defaultFilteringMode,
                selectedLevel,
                modeError,
                restoreCompleted,
                restoreSteps,
                restoreError,
                busyAfterRestore,
                restoreFailureClose,
                restoreRetryClose,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        ) as? [String: Any]
        let failureState = try XCTUnwrap(mutationFailure)
        XCTAssertEqual(failureState["modeCommitted"] as? Bool, false)
        XCTAssertEqual((failureState["modeRequestCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(
            (failureState["afterLevel"] as? NSNumber)?.intValue,
            (failureState["beforeLevel"] as? NSNumber)?.intValue
        )
        XCTAssertEqual(failureState["selectedLevel"] as? String, "2")
        XCTAssertTrue(
            (failureState["modeError"] as? String)?.contains("injected options mutation failure") == true
        )
        XCTAssertEqual(failureState["restoreCompleted"] as? Bool, false)
        XCTAssertEqual(failureState["restoreSteps"] as? [String], ["before-failure"])
        XCTAssertTrue(
            (failureState["restoreError"] as? String)?.contains("injected restore mutation failure") == true
        )
        XCTAssertEqual(failureState["busyAfterRestore"] as? Bool, false)
        let directFailureClose = try XCTUnwrap(
            failureState["restoreFailureClose"] as? [String: Any]
        )
        XCTAssertEqual(directFailureClose["ready"] as? Bool, false)
        XCTAssertTrue(
            (directFailureClose["error"] as? String)?.contains(
                "injected restore mutation failure"
            ) == true
        )
        XCTAssertEqual(
            (failureState["restoreRetryClose"] as? [String: Any])?["ready"] as? Bool,
            true
        )

        // Exercise the same production runtime messages used by dashboard
        // settings while normal and private browsing WebViews remain loaded.
        // Switching to complete mode must settle both DNR and registered-content
        // updates before either realm is allowed to navigate again. This also
        // proves generic ad removal through Floorp's production tab adapters.
        let modeChange = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const before = await browser.runtime.sendMessage({
                what: 'getDefaultFilteringMode',
            });
            const basic = await browser.runtime.sendMessage({
                what: 'setDefaultFilteringMode',
                level: 1,
            });
            const complete = await browser.runtime.sendMessage({
                what: 'setDefaultFilteringMode',
                level: 3,
            });
            const readiness = await browser.runtime.sendMessage({
                what: 'floorpReadiness',
            });
            return { before, basic, complete, readiness };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 20_000_000_000
        ) as? [String: Any]
        let modeChangeState = try XCTUnwrap(modeChange)
        XCTAssertEqual((modeChangeState["before"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((modeChangeState["basic"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((modeChangeState["complete"] as? NSNumber)?.intValue, 3)
        let modeReadiness = try XCTUnwrap(modeChangeState["readiness"] as? [String: Any])
        XCTAssertEqual(modeReadiness["ready"] as? Bool, true)
        XCTAssertEqual(
            modeReadiness["version"] as? String,
            FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion
        )

        for testCase in cases {
            manager.selectTab(testCase.tab)
            host.focus(windowUUID: manager.windowUUID, isPrivate: testCase.isPrivate)
            normalTab.webView?.isHidden = testCase.isPrivate
            privateTab.webView?.isHidden = !testCase.isPrivate
            let refreshedURL = try XCTUnwrap(
                URL(string: testCase.url.absoluteString + "&phase=after-mode-change")
            )
            let needsReadiness = host.needsBackgroundReadiness(
                beforeNavigating: testCase.tab,
                to: refreshedURL
            )
            XCTAssertTrue(
                needsReadiness,
                "A filtering-mode mutation must invalidate both normal and private readiness"
            )
            if needsReadiness {
                let navigationAction = MockNavigationAction(
                    url: refreshedURL,
                    type: .linkActivated
                )
                let generation = host.beginNavigationPreparation(for: testCase.tab)
                let didPrepare = await host.prepareBackgroundContent(
                    beforeNavigating: testCase.tab,
                    to: refreshedURL,
                    navigationAction: navigationAction,
                    generation: generation
                )
                XCTAssertTrue(didPrepare)
                XCTAssertTrue(host.consumePreparedNavigation(navigationAction))
            }
            let webView = try XCTUnwrap(testCase.tab.webView)
            let navigation = FloorpWebExtensionNavigationWaiter()
            navigationWaiters.append(navigation)
            try await navigation.load(refreshedURL, in: webView)
            let state = try await waitForUBOLPageEffects(
                in: webView,
                description: "uBO Lite complete effects after mode update in private=\(testCase.isPrivate)",
                expectedCosmeticHidden: true
            )
            XCTAssertEqual(state["controlExecuted"] as? Bool, true)
            XCTAssertEqual(state["blockedExecuted"] as? Bool, false)
            XCTAssertEqual(state["cosmeticHidden"] as? Bool, true)
            XCTAssertEqual(webView.configuration.websiteDataStore.isPersistent, !testCase.isPrivate)
            XCTAssertTrue(webView.configuration.webExtensionController === extensionController)
        }

        let rulesetsPane = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const button = document.querySelector('#dashboard-nav .tabButton[data-pane="rulesets"]');
            if (!button) { throw new Error('Missing rulesets dashboard button'); }
            button.click();
            const section = document.querySelector('section[data-pane="rulesets"]');
            return {
                pane: document.body.dataset.pane,
                visible: section !== null && getComputedStyle(section).display !== 'none',
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        ) as? [String: Any]
        XCTAssertEqual(rulesetsPane?["pane"] as? String, "rulesets")
        XCTAssertEqual(rulesetsPane?["visible"] as? Bool, true)

        let optionsURL = try XCTUnwrap(optionsWebView.url)
        XCTAssertEqual(optionsURL.scheme, item.baseURLScheme)
        XCTAssertEqual(optionsURL.host, item.baseURLHost)
        XCTAssertEqual(optionsURL.path, "/dashboard.html")
        XCTAssertTrue(optionsWebView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(
            optionsWebView.configuration.websiteDataStore
                === normalTab.floorpNativeWebsiteDataStore
        )
        XCTAssertTrue(optionsWebView.configuration.webExtensionController === extensionController)
        XCTAssertFalse(
            optionsWebView.configuration.userContentController
                === normalTab.webView?.configuration.userContentController
        )
        XCTAssertTrue(context.hasAccessToPrivateData)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )

        let japaneseToggleState = try await waitForJavaScriptState(
            in: optionsWebView,
            description: "uBO Lite Japanese ruleset toggle",
            source: """
            const input = document.querySelector(
                '#lists [data-role="leaf"][data-rulesetid="jpn-1"] input[type="checkbox"]'
            );
            return {
                ready: input !== null &&
                    typeof globalThis.floorpPrepareToClose === 'function',
                checked: input?.checked === true,
            };
            """
        )
        let japaneseWasEnabled = japaneseToggleState["checked"] as? Bool == true
        let scheduledToggle = try await optionsWebView.floorpCallAsyncJavaScript(
            """
            const input = document.querySelector(
                '#lists [data-role="leaf"][data-rulesetid="jpn-1"] input[type="checkbox"]'
            );
            if (!input) { throw new Error('Missing Japanese ruleset checkbox'); }
            if (input.checked) {
                input.checked = false;
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }
            input.checked = true;
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return input.checked;
            """,
            contentWorld: .page,
            timeoutNanoseconds: 90_000_000_000
        ) as? Bool
        XCTAssertEqual(scheduledToggle, true)
        XCTAssertEqual(
            japaneseWasEnabled,
            defaultRulesets.contains("jpn-1"),
            "The options UI must reflect the locale-derived ruleset state"
        )

        let doneButton = try XCTUnwrap(optionsPage.navigationItem.rightBarButtonItem)
        let doneAction = try XCTUnwrap(doneButton.action)
        XCTAssertTrue(
            UIApplication.shared.sendAction(
                doneAction,
                to: doneButton.target,
                from: doneButton,
                for: nil
            )
        )
        let didCloseOptions = await waitForDismissedPresentation(from: root, attempts: 160)
        XCTAssertTrue(didCloseOptions, "Done must wait for and then close after the ruleset commit")

        manager.selectTab(normalTab)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        normalTab.webView?.isHidden = false
        privateTab.webView?.isHidden = true
        let japaneseRulesURL = try XCTUnwrap(
            URL(string: normalURL.absoluteString + "&phase=after-japanese-ruleset")
        )
        XCTAssertTrue(
            host.needsBackgroundReadiness(
                beforeNavigating: normalTab,
                to: japaneseRulesURL
            ),
            "Options close must invalidate same-realm readiness after the confirmed mutation"
        )
        let japaneseNavigationAction = MockNavigationAction(
            url: japaneseRulesURL,
            type: .linkActivated
        )
        let japanesePreparationGeneration = host.beginNavigationPreparation(for: normalTab)
        let didPrepareJapaneseRules = await host.prepareBackgroundContent(
            beforeNavigating: normalTab,
            to: japaneseRulesURL,
            navigationAction: japaneseNavigationAction,
            generation: japanesePreparationGeneration
        )
        XCTAssertTrue(didPrepareJapaneseRules)
        XCTAssertTrue(host.consumePreparedNavigation(japaneseNavigationAction))
        let japaneseNavigation = FloorpWebExtensionNavigationWaiter()
        navigationWaiters.append(japaneseNavigation)
        let normalWebView = try XCTUnwrap(normalTab.webView)
        try await japaneseNavigation.load(japaneseRulesURL, in: normalWebView)
        let japaneseEffect = try await waitForJavaScriptState(
            in: normalWebView,
            description: "Japanese ruleset effect after immediate options close",
            source: """
            const controlExecuted = window.floorpControlScriptExecuted === true;
            const japaneseBlocked = window.floorpJPNRulesetScriptExecuted === false;
            return {
                ready: document.readyState === 'complete' && controlExecuted && japaneseBlocked,
                controlExecuted,
                japaneseBlocked,
            };
            """
        )
        XCTAssertEqual(japaneseEffect["controlExecuted"] as? Bool, true)
        XCTAssertEqual(japaneseEffect["japaneseBlocked"] as? Bool, true)
        XCTAssertTrue(context.errors.isEmpty, context.errors.map(\.localizedDescription).joined(separator: "\n"))
        withExtendedLifetime(navigationWaiters) {}
        for tab in manager.tabs {
            await tab.close()
        }
    }

    func testBundledDarkReaderTabsCreateRoutesOptionsThroughProductionHost() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_tabs_create")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)

        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let source = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/darkreader")),
            isPrivate: false
        )
        manager.selectedTab = source
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let extensionConfiguration = try XCTUnwrap(context.webViewConfiguration)
        let extensionController = try XCTUnwrap(extensionConfiguration.webExtensionController)
        let extensionWebView = WKWebView(frame: .zero, configuration: extensionConfiguration)
        defer { extensionWebView.stopLoading() }
        let navigation = FloorpWebExtensionNavigationWaiter()
        try await navigation.load(
            context.baseURL.appendingPathComponent("ui/options/index.html"),
            in: extensionWebView
        )

        _ = try await extensionWebView.callAsyncJavaScript(
            """
            return await browser.tabs.create({
                active: true,
                url: browser.runtime.getURL('ui/options/index.html'),
            });
            """,
            arguments: [:],
            contentWorld: .page
        )

        let createdTab = try XCTUnwrap(manager.extensionCreatedTabs.last)
        let url = try XCTUnwrap(createdTab.webView?.url ?? createdTab.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertFalse(createdTab.isPrivate)
        XCTAssertEqual(createdTab.floorpNativeWebExtensionContextIdentifier, item.identifier)
        XCTAssertTrue(createdTab.webView?.configuration.websiteDataStore.isPersistent == true)
        XCTAssertTrue(createdTab.webView?.configuration.webExtensionController === extensionController)
        XCTAssertEqual(components.scheme, item.baseURLScheme)
        XCTAssertEqual(components.host, item.baseURLHost)
        XCTAssertEqual(components.path, "/ui/options/index.html")
        XCTAssertTrue(context.errors.isEmpty, context.errors.map(\.localizedDescription).joined(separator: "\n"))
        withExtendedLifetime(navigation) {}
    }

    // swiftlint:disable:next function_body_length
    func testBundledDarkReaderActionPopupPresentsAndBecomesInteractiveThroughProductionHost() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "darkreader_action_popup")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        defer { profileFixture.cleanup() }
        let source = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/darkreader-popup")),
            isPrivate: false
        )
        manager.selectedTab = source
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        source.webView?.frame = root.view.bounds
        source.webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let webView = source.webView {
            root.view.addSubview(webView)
        }
        window.makeKeyAndVisible()
        defer {
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        try await host.performAction(contextIdentifier: item.identifier, for: source)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: root)
        let popup = try XCTUnwrap(
            popupResult,
            "Dark Reader action popup was not presented by the production host"
        )
        XCTAssertTrue(popup.webView.configuration.websiteDataStore.isPersistent)
        var didClosePopup = false
        defer {
            if !didClosePopup {
                popup.viewController.closePopup(animated: false)
            }
        }

        var isInteractive = false
        for _ in 0..<60 {
            isInteractive = (try? await popup.webView.floorpCallAsyncJavaScript(
                """
                return document.readyState === 'complete' &&
                    Boolean(document.querySelector('.app-switch__control')) &&
                    Boolean(document.querySelector('.site-toggle'));
                """,
                contentWorld: .page,
                timeoutNanoseconds: 3_000_000_000
            ) as? Bool) == true
            if isInteractive { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(isInteractive)
        let toggleResult = try await popup.webView.floorpCallAsyncJavaScript(
            """
            const options = Array.from(document.querySelectorAll(
                '.app-switch__control .multi-switch__option'
            ));
            const selected = options.find((option) =>
                option.classList.contains('multi-switch__option--selected')
            );
            const target = options.find((option) => option !== selected);
            if (!selected || !target) {
                throw new Error('Dark Reader app switch is not interactive');
            }
            const before = selected.textContent.trim();
            const expected = target.textContent.trim();
            target.click();
            return { before, expected };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 3_000_000_000
        ) as? [String: String]
        let expectedToggleValue = try XCTUnwrap(toggleResult?["expected"])
        XCTAssertNotEqual(toggleResult?["before"], expectedToggleValue)
        var selectedToggleValue: String?
        for _ in 0..<50 {
            selectedToggleValue = try? await popup.webView.floorpCallAsyncJavaScript(
                """
                return document.querySelector(
                    '.app-switch__control .multi-switch__option--selected'
                )?.textContent.trim();
                """,
                contentWorld: .page,
                timeoutNanoseconds: 3_000_000_000
            ) as? String
            if selectedToggleValue == expectedToggleValue { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(selectedToggleValue, expectedToggleValue)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        let extensionTabCountBeforeSettings = manager.extensionCreatedTabs.count
        let routeAcknowledgementGate = FloorpClosePreparationTestGate()
        host.extensionTabCreationCompletionHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return }
            _ = await routeAcknowledgementGate.waitUntilReleased()
        }
        defer {
            routeAcknowledgementGate.mayFinish = true
            host.extensionTabCreationCompletionHookForTesting = nil
        }
        let clickedSettings = try await popup.webView.floorpCallAsyncJavaScript(
            """
            const button = document.querySelector('.settings-button-icon')?.closest('button');
            if (!button) { return false; }
            button.click();
            return true;
            """,
            contentWorld: .page,
            timeoutNanoseconds: 3_000_000_000
        ) as? Bool
        XCTAssertEqual(clickedSettings, true)
        for _ in 0..<80 where !routeAcknowledgementGate.didBegin {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(routeAcknowledgementGate.didBegin)

        popup.viewController.closePopup(animated: false)
        for _ in 0..<20 where
            !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(root.presentedViewController === popup.viewController)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "Native close must retain Dark Reader until its real tabs.create callback settles"
        )
        routeAcknowledgementGate.mayFinish = true
        host.extensionTabCreationCompletionHookForTesting = nil
        let didDismissPopup = await waitForDismissedPresentation(from: root, attempts: 340)
        for _ in 0..<120 where manager.extensionCreatedTabs.count == extensionTabCountBeforeSettings {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if didDismissPopup,
           !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView) {
            popup.webView.stopLoading()
            await Task.yield()
            await Task.yield()
        }
        didClosePopup = didDismissPopup
        XCTAssertTrue(didDismissPopup)
        XCTAssertNil(popup.viewController.presentedViewController)
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(manager.extensionCreatedTabs.count, extensionTabCountBeforeSettings + 1)
        let optionsTab = try XCTUnwrap(manager.extensionCreatedTabs.last)
        XCTAssertTrue(manager.selectedTab === optionsTab)
        let optionsURL = try XCTUnwrap(optionsTab.webView?.url ?? optionsTab.url)
        let optionsComponents = try XCTUnwrap(
            URLComponents(url: optionsURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(optionsTab.floorpNativeWebExtensionContextIdentifier, item.identifier)
        XCTAssertEqual(optionsComponents.scheme, item.baseURLScheme)
        XCTAssertEqual(optionsComponents.host, item.baseURLHost)
        XCTAssertEqual(optionsComponents.path, "/ui/options/index.html")
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        await source.close()
    }

    func testManagedActionPopupReopenWindowCloseTabSwitchRemovalAndDisableCleanup() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "managed_popup_lifecycle")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        defer { profileFixture.cleanup() }
        let firstSource = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/first")),
            isPrivate: false
        )
        let secondSource = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/second")),
            isPrivate: false
        )
        manager.selectedTab = firstSource
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        for source in [firstSource, secondSource] {
            source.webView?.frame = root.view.bounds
            source.webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let webView = source.webView {
                root.view.addSubview(webView)
            }
        }
        window.makeKeyAndVisible()
        defer {
            (root.presentedViewController
                as? FloorpNativeWebExtensionActionPopupViewController)?
                .closePopup(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        let firstAdapter = host.tabAdapter(for: firstSource)
        try await host.performAction(contextIdentifier: item.identifier, for: firstSource)
        let firstPopupResult = await waitForPresentedActionPopup(presentingRoot: root)
        let firstPopup = try XCTUnwrap(firstPopupResult)
        XCTAssertTrue(context.hasActiveUserGesture(in: firstAdapter))

        try await host.performAction(contextIdentifier: item.identifier, for: firstSource)
        let reopenedPopupResult = await waitForPresentedActionPopup(
            presentingRoot: root,
            excluding: firstPopup.viewController
        )
        let reopenedPopup = try XCTUnwrap(reopenedPopupResult)
        XCTAssertFalse(reopenedPopup.viewController === firstPopup.viewController)
        XCTAssertTrue(context.hasActiveUserGesture(in: firstAdapter))

        _ = try await reopenedPopup.webView.floorpCallAsyncJavaScript(
            "setTimeout(() => window.close(), 0); return true;",
            contentWorld: .page,
            timeoutNanoseconds: 3_000_000_000
        )
        let didSelfClose = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didSelfClose)
        XCTAssertFalse(context.hasActiveUserGesture(in: firstAdapter))

        try await host.performAction(contextIdentifier: item.identifier, for: firstSource)
        let tabSwitchPopup = await waitForPresentedActionPopup(presentingRoot: root)
        _ = try XCTUnwrap(tabSwitchPopup)
        manager.selectTab(secondSource)
        let didCloseForTabSwitch = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didCloseForTabSwitch)
        XCTAssertFalse(context.hasActiveUserGesture(in: firstAdapter))

        manager.selectTab(firstSource)
        try await host.performAction(contextIdentifier: item.identifier, for: firstSource)
        let tabRemovalPopup = await waitForPresentedActionPopup(presentingRoot: root)
        _ = try XCTUnwrap(tabRemovalPopup)
        manager.removeSeedTab(firstSource)
        let didCloseForTabRemoval = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didCloseForTabRemoval)
        XCTAssertFalse(context.hasActiveUserGesture(in: firstAdapter))
        await firstSource.close()

        let secondAdapter = host.tabAdapter(for: secondSource)
        try await host.performAction(contextIdentifier: item.identifier, for: secondSource)
        let disablePopup = await waitForPresentedActionPopup(presentingRoot: root)
        _ = try XCTUnwrap(disablePopup)
        XCTAssertTrue(context.hasActiveUserGesture(in: secondAdapter))
        try await host.setEnabled(false, identifier: item.identifier)
        let didCloseForDisable = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didCloseForDisable)
        XCTAssertFalse(context.hasActiveUserGesture(in: secondAdapter))
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        await secondSource.close()
    }

    func testBackgroundWindowTabActivationKeepsForegroundManagedPopupUntilFocusMoves() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "managed_popup_background")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let foregroundManager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: WindowUUID(),
            notifiesDelegatesOnAdd: false
        )
        let backgroundManager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: WindowUUID(),
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: foregroundManager
        )
        defer { dependencies.reset() }
        defer { profileFixture.cleanup() }
        let foregroundTab = foregroundManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/foreground")),
            isPrivate: false
        )
        let backgroundTab = backgroundManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/background")),
            isPrivate: false
        )
        foregroundManager.selectedTab = foregroundTab
        backgroundManager.selectedTab = backgroundTab
        host.register(tabManager: foregroundManager)
        host.register(tabManager: backgroundManager)
        defer {
            host.unregister(windowUUID: backgroundManager.windowUUID)
            host.unregister(windowUUID: foregroundManager.windowUUID)
        }
        host.focus(windowUUID: foregroundManager.windowUUID, isPrivate: false)

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        foregroundTab.webView?.frame = root.view.bounds
        if let webView = foregroundTab.webView {
            root.view.addSubview(webView)
        }
        window.makeKeyAndVisible()
        defer {
            (root.presentedViewController
                as? FloorpNativeWebExtensionActionPopupViewController)?
                .closePopup(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        let foregroundAdapter = host.tabAdapter(for: foregroundTab)
        try await host.performAction(contextIdentifier: item.identifier, for: foregroundTab)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: root)
        let popup = try XCTUnwrap(popupResult)
        XCTAssertTrue(context.hasActiveUserGesture(in: foregroundAdapter))

        backgroundManager.selectTab(backgroundTab)
        await Task.yield()
        XCTAssertTrue(root.presentedViewController === popup.viewController)
        XCTAssertTrue(context.hasActiveUserGesture(in: foregroundAdapter))

        host.focus(windowUUID: backgroundManager.windowUUID, isPrivate: false)
        let didCloseForFocusTransfer = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didCloseForFocusTransfer)
        XCTAssertFalse(context.hasActiveUserGesture(in: foregroundAdapter))
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        await foregroundTab.close()
        await backgroundTab.close()
    }

    // swiftlint:disable:next function_body_length
    func testManagedPopupCancellationAndKeepOpenDiscardStagedActivations() async throws {
#if DEBUG || TESTING
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let profileFixture = try makeIsolatedHostProfile(prefix: "managed_popup_keep_open")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        defer { profileFixture.cleanup() }
        let source = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/popup-source")),
            isPrivate: false
        )
        let abandonedTarget = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/abandoned-target")),
            isPrivate: false
        )
        let committedTarget = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/committed-target")),
            isPrivate: false
        )
        manager.selectedTab = source
        host.register(tabManager: manager)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        root.loadViewIfNeeded()
        source.webView?.frame = root.view.bounds
        if let webView = source.webView {
            root.view.addSubview(webView)
        }
        window.makeKeyAndVisible()
        var mayClose = false
        host.extensionSurfaceClosePreparationHookForTesting = { identifier, _ in
            identifier == item.identifier && mayClose
        }
        defer {
            mayClose = true
            host.extensionSurfaceClosePreparationHookForTesting = nil
            (root.presentedViewController
                as? FloorpNativeWebExtensionActionPopupViewController)?
                .closePopupImmediately(animated: false)
            root.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        try await host.performAction(contextIdentifier: item.identifier, for: source)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: root)
        let popup = try XCTUnwrap(popupResult)

        let createdTabCount = manager.extensionCreatedTabs.count
        manager.rejectsSingleTabRemovalForTesting = true
        let forcedRouteGate = FloorpClosePreparationTestGate()
        host.extensionTabCreationCompletionHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return }
            _ = await forcedRouteGate.waitUntilReleased()
        }
        defer {
            forcedRouteGate.mayFinish = true
            host.extensionTabCreationCompletionHookForTesting = nil
        }
        let forcedRouteTask = Task { @MainActor in
            try await popup.webView.floorpCallAsyncJavaScript(
                """
                try {
                    await browser.tabs.create({
                        active: true,
                        url: browser.runtime.getURL('/dashboard.html'),
                    });
                    return '';
                } catch (reason) {
                    return reason instanceof Error ? reason.message : `${reason}`;
                }
                """,
                contentWorld: .page,
                timeoutNanoseconds: 10_000_000_000
            ) as? String
        }
        for _ in 0..<80 where !forcedRouteGate.didBegin {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(forcedRouteGate.didBegin)
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount + 1)
        XCTAssertTrue(manager.selectedTab === source)
        XCTAssertTrue(root.presentedViewController === popup.viewController)

        manager.selectTab(abandonedTarget)
        let didForceCloseFirstPopup = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didForceCloseFirstPopup)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "A forced-retired popup must remain alive while its native callback is pending"
        )
        try await Task.sleep(nanoseconds: 2_250_000_000)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "Native callback retention must outlive the fixed two-second UIKit teardown grace"
        )
        forcedRouteGate.mayFinish = true
        host.extensionTabCreationCompletionHookForTesting = nil
        let forcedRouteError = try await forcedRouteTask.value
        XCTAssertFalse(forcedRouteError?.isEmpty ?? true)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "Callback delivery must begin a fresh teardown grace period"
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "The callback teardown grace must retain the popup for two seconds"
        )
        for _ in 0..<160 where
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView),
            "The forced-retired popup lease must end after its callback grace expires"
        )
        for _ in 0..<80 where manager.extensionCreatedTabs.count != createdTabCount {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount)
        XCTAssertTrue(manager.selectedTab === abandonedTarget)
        XCTAssertEqual(manager.rejectedSingleTabRemovalCount, 1)
        XCTAssertEqual(manager.forcedRemoveTabsCallCount, 1)
        XCTAssertFalse(manager.didAttemptToForceRemoveSelectedTab)

        // A user/system activation can win after tabs.create has staged its
        // destination but before the popup's script-close acknowledgement.
        // Cancelling that stale popup must preserve the now-current created tab
        // without even asking TabManager to remove it.
        manager.selectTab(source)
        try await host.performAction(contextIdentifier: item.identifier, for: source)
        let selectedRoutePopupResult = await waitForPresentedActionPopup(
            presentingRoot: root
        )
        let selectedRoutePopup = try XCTUnwrap(selectedRoutePopupResult)
        let selectedRouteGate = FloorpClosePreparationTestGate()
        defer {
            selectedRouteGate.mayFinish = true
            host.extensionTabCreationCompletionHookForTesting = nil
        }
        host.extensionTabCreationCompletionHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return }
            _ = await selectedRouteGate.waitUntilReleased()
        }
        let selectedRouteTask = Task { @MainActor in
            try await selectedRoutePopup.webView.floorpCallAsyncJavaScript(
                """
                try {
                    await browser.tabs.create({
                        active: true,
                        url: browser.runtime.getURL('/dashboard.html'),
                    });
                    return '';
                } catch (reason) {
                    return reason instanceof Error ? reason.message : `${reason}`;
                }
                """,
                contentWorld: .page,
                timeoutNanoseconds: 10_000_000_000
            ) as? String
        }
        for _ in 0..<80 where !selectedRouteGate.didBegin {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(selectedRouteGate.didBegin)
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount + 1)
        let externallySelectedCreatedTab = try XCTUnwrap(manager.extensionCreatedTabs.last)
        XCTAssertTrue(manager.selectedTab === source)

        manager.selectTab(externallySelectedCreatedTab)
        let didDismissSelectedRoutePopup = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didDismissSelectedRoutePopup)
        XCTAssertTrue(manager.selectedTab === externallySelectedCreatedTab)
        selectedRouteGate.mayFinish = true
        host.extensionTabCreationCompletionHookForTesting = nil
        let selectedRouteError = try await selectedRouteTask.value
        XCTAssertFalse(selectedRouteError?.isEmpty ?? true)
        await Task.yield()
        XCTAssertTrue(manager.selectedTab === externallySelectedCreatedTab)
        XCTAssertTrue(manager.tabs.contains { $0 === externallySelectedCreatedTab })
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount + 1)
        XCTAssertEqual(
            manager.rejectedSingleTabRemovalCount,
            1,
            "Rollback must not request removal after the staged-created tab becomes current"
        )
        XCTAssertEqual(manager.forcedRemoveTabsCallCount, 1)
        for _ in 0..<160 where FloorpNativeWebExtensionProcessLifetimeWebViewRegistry
            .mustPreserve(selectedRoutePopup.webView) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry
                .mustPreserve(selectedRoutePopup.webView)
        )
        selectedRoutePopup.webView.stopLoading()
        manager.removeSeedTab(externallySelectedCreatedTab)
        await externallySelectedCreatedTab.close()
        manager.rejectsSingleTabRemovalForTesting = false

        manager.selectTab(source)
        mayClose = false
        try await host.performAction(contextIdentifier: item.identifier, for: source)
        let retryPopupResult = await waitForPresentedActionPopup(presentingRoot: root)
        let retryPopup = try XCTUnwrap(retryPopupResult)
        var abandonedActivationCompleted = false
        var abandonedActivationError: (any Error)?
        host.tabAdapter(for: abandonedTarget).activate(for: context) { error in
            abandonedActivationError = error
            abandonedActivationCompleted = true
        }
        XCTAssertTrue(abandonedActivationCompleted)
        XCTAssertNil(abandonedActivationError)
        XCTAssertTrue(manager.selectedTab === source)

        retryPopup.viewController.requestCloseForTesting()
        for _ in 0..<80 where !(retryPopup.viewController.presentedViewController is UIAlertController) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(retryPopup.viewController.presentedViewController as? UIAlertController)
        XCTAssertTrue(manager.selectedTab === source)

        retryPopup.viewController.keepOpenAfterPreparationFailureForTesting()
        for _ in 0..<80 where retryPopup.viewController.presentedViewController != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await Task.yield()
        XCTAssertNil(retryPopup.viewController.presentedViewController)
        XCTAssertTrue(root.presentedViewController === retryPopup.viewController)
        XCTAssertTrue(manager.selectedTab === source)

        var committedActivationCompleted = false
        var committedActivationError: (any Error)?
        host.tabAdapter(for: committedTarget).activate(for: context) { error in
            committedActivationError = error
            committedActivationCompleted = true
        }
        XCTAssertTrue(committedActivationCompleted)
        XCTAssertNil(committedActivationError)
        XCTAssertTrue(manager.selectedTab === source)

        mayClose = true
        retryPopup.viewController.requestCloseForTesting()
        let didDismiss = await waitForDismissedPresentation(from: root)
        XCTAssertTrue(didDismiss)
        XCTAssertTrue(manager.selectedTab === committedTarget)
        XCTAssertFalse(manager.selectedTab === abandonedTarget)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        await source.close()
        await abandonedTarget.close()
        await committedTarget.close()
#else
        throw XCTSkip("The close-preparation test seam is available only in test builds")
#endif
    }

    // swiftlint:disable:next function_body_length
    func testManagedPrivatePopupOptionsFailClosedWhenFocusMovesToNormalWindow() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "managed_popup_options_focus")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        try await host.setPrivateAccess(true, identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let privateManager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: WindowUUID(),
            notifiesDelegatesOnAdd: false
        )
        let normalManager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: WindowUUID(),
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: privateManager
        )
        defer { dependencies.reset() }
        defer { profileFixture.cleanup() }
        let privateTab = privateManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/private-options")),
            isPrivate: true
        )
        let normalTab = normalManager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/normal-options")),
            isPrivate: false
        )
        privateManager.selectedTab = privateTab
        normalManager.selectedTab = normalTab
        host.register(tabManager: privateManager)
        host.register(tabManager: normalManager)
        defer {
            host.unregister(windowUUID: normalManager.windowUUID)
            host.unregister(windowUUID: privateManager.windowUUID)
        }

        let privateRoot = UIViewController()
        let privateWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        privateWindow.rootViewController = privateRoot
        privateRoot.loadViewIfNeeded()
        privateTab.webView?.frame = privateRoot.view.bounds
        if let webView = privateTab.webView {
            privateRoot.view.addSubview(webView)
        }
        let normalRoot = UIViewController()
        let normalWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        normalWindow.rootViewController = normalRoot
        normalRoot.loadViewIfNeeded()
        normalTab.webView?.frame = normalRoot.view.bounds
        if let webView = normalTab.webView {
            normalRoot.view.addSubview(webView)
        }
        privateWindow.makeKeyAndVisible()
        defer {
            privateRoot.presentedViewController?.dismiss(animated: false)
            normalRoot.presentedViewController?.dismiss(animated: false)
            privateWindow.isHidden = true
            privateWindow.rootViewController = nil
            normalWindow.isHidden = true
            normalWindow.rootViewController = nil
        }

        host.focus(windowUUID: privateManager.windowUUID, isPrivate: true)
        let privateAdapter = host.tabAdapter(for: privateTab)
        try await host.performAction(contextIdentifier: item.identifier, for: privateTab)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: privateRoot)
        let popup = try XCTUnwrap(popupResult)
        XCTAssertTrue(context.hasActiveUserGesture(in: privateAdapter))

        var optionsRequestCompleted = false
        var optionsError: (any Error)?
        host.webExtensionController(
            try XCTUnwrap(context.webViewConfiguration?.webExtensionController),
            openOptionsPageFor: context
        ) { error in
            optionsError = error
            optionsRequestCompleted = true
        }
        for _ in 0..<60 where !optionsRequestCompleted {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(optionsRequestCompleted)
        XCTAssertNil(optionsError)
        XCTAssertTrue(privateRoot.presentedViewController === popup.viewController)
        popup.viewController.requestCloseForTesting()
        var presentedOptionsNavigation: UINavigationController?
        for _ in 0..<120 {
            presentedOptionsNavigation = privateRoot.presentedViewController
                as? UINavigationController
            if presentedOptionsNavigation != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let optionsNavigation = try XCTUnwrap(presentedOptionsNavigation)
        let optionsPage = try XCTUnwrap(optionsNavigation.viewControllers.first)
        optionsPage.loadViewIfNeeded()
        let optionsWebView = try XCTUnwrap(
            optionsPage.view.subviews.first { $0 is WKWebView } as? WKWebView
        )
        XCTAssertTrue(
            optionsWebView.configuration.websiteDataStore
                === privateTab.floorpNativeWebsiteDataStore
        )
        XCTAssertFalse(optionsWebView.configuration.websiteDataStore.isPersistent)
        optionsNavigation.dismiss(animated: false)
        let didDismissPrivatePopup = await waitForDismissedPresentation(from: privateRoot)
        XCTAssertTrue(didDismissPrivatePopup)
        XCTAssertFalse(context.hasActiveUserGesture(in: privateAdapter))

        host.focus(windowUUID: privateManager.windowUUID, isPrivate: true)
        try await host.performAction(contextIdentifier: item.identifier, for: privateTab)
        let reopenedPopup = await waitForPresentedActionPopup(presentingRoot: privateRoot)
        _ = try XCTUnwrap(reopenedPopup)
        XCTAssertTrue(context.hasActiveUserGesture(in: privateAdapter))
        normalWindow.makeKeyAndVisible()
        host.focus(windowUUID: normalManager.windowUUID, isPrivate: false)
        let didCloseForFocusTransfer = await waitForDismissedPresentation(from: privateRoot)
        XCTAssertTrue(didCloseForFocusTransfer)

        optionsRequestCompleted = false
        optionsError = nil
        host.webExtensionController(
            try XCTUnwrap(context.webViewConfiguration?.webExtensionController),
            openOptionsPageFor: context
        ) { error in
            optionsError = error
            optionsRequestCompleted = true
        }
        for _ in 0..<60 where !optionsRequestCompleted {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(optionsRequestCompleted)
        XCTAssertNotNil(optionsError)
        XCTAssertNil(normalRoot.presentedViewController)
        XCTAssertFalse(context.hasActiveUserGesture(in: privateAdapter))
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        await privateTab.close()
        await normalTab.close()
    }

    func testOptionsPageExternalLinkLoadsInManagedTabBeforeDeferredDelegateNotification() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "options_external_link")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let source = manager.seedTab(
            url: try XCTUnwrap(URL(string: "https://example.com/options-source")),
            isPrivate: false
        )
        manager.selectedTab = source
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let optionsController = try await host.optionsViewController(identifier: item.identifier)
        let navigationController = try XCTUnwrap(
            optionsController as? UINavigationController
        )
        let page = try XCTUnwrap(
            navigationController.viewControllers.first as? FloorpNativeWebExtensionPageViewController
        )
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            navigationController.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        root.present(navigationController, animated: false)
        page.loadViewIfNeeded()
        let webView = try XCTUnwrap(page.view.subviews.first { $0 is WKWebView } as? WKWebView)
        for _ in 0..<60 {
            if (try? await webView.evaluateJavaScript("document.readyState === 'complete'") as? Bool) == true {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let destination = try XCTUnwrap(URL(string: "https://darkreader.org/"))
        _ = try await webView.evaluateJavaScript(
            "window.location.assign('\(destination.absoluteString)'); true;"
        )
        var createdTab: Tab?
        for _ in 0..<60 {
            if let candidate = manager.extensionCreatedTabs.last,
               (candidate.webView?.url ?? candidate.url) != nil {
                createdTab = candidate
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let tab = try XCTUnwrap(createdTab)
        XCTAssertEqual(tab.webView?.url ?? tab.url, destination)
        XCTAssertNil(tab.floorpNativeWebExtensionContextIdentifier)
    }

    func testTabsDuplicateLoadsInManagedTabBeforeDeferredDelegateNotification() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let profileFixture = try makeIsolatedHostProfile(prefix: "tabs_duplicate")
        let profile = profileFixture.profile
        defer { profileFixture.cleanup() }
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let manager = FloorpUBOLRoutingTabManager(
            profile: profile,
            host: host,
            windowUUID: .XCTestDefaultUUID,
            notifiesDelegatesOnAdd: false
        )
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(
            injectedProfile: profile,
            injectedTabManager: manager
        )
        defer { dependencies.reset() }
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/duplicate-source"))
        let source = manager.seedTab(url: sourceURL, isPrivate: false)
        manager.selectedTab = source
        host.register(tabManager: manager)
        defer { host.unregister(windowUUID: manager.windowUUID) }

        let extensionConfiguration = try XCTUnwrap(context.webViewConfiguration)
        let extensionWebView = WKWebView(frame: .zero, configuration: extensionConfiguration)
        defer { extensionWebView.stopLoading() }
        let navigation = FloorpWebExtensionNavigationWaiter()
        try await navigation.load(
            context.baseURL.appendingPathComponent("ui/options/index.html"),
            in: extensionWebView
        )
        let sourceAdapter = host.tabAdapter(for: source)
        context.userGesturePerformed(in: sourceAdapter)
        defer { context.clearUserGesture(in: sourceAdapter) }

        _ = try await extensionWebView.callAsyncJavaScript(
            """
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
            if ( tab instanceof Object === false || typeof tab.id !== 'number' ) {
                throw new Error('Missing source tab for duplicate');
            }
            return await browser.tabs.duplicate(tab.id);
            """,
            arguments: [:],
            contentWorld: .page
        )

        let duplicated = try XCTUnwrap(manager.extensionCreatedTabs.last)
        XCTAssertEqual(duplicated.webView?.url ?? duplicated.url, sourceURL)
        XCTAssertNil(duplicated.floorpNativeWebExtensionContextIdentifier)
        XCTAssertTrue(context.errors.isEmpty, context.errors.map(\.localizedDescription).joined(separator: "\n"))
        withExtendedLifetime(navigation) {}
    }

    func testFirefoxTrackingProtectionPreservesWebExtensionOwnedContentRules() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "floorp-native-owner-\(UUID().uuidString)"
        let rule = try await compileContentRuleList(
            in: store,
            identifier: identifier,
            source: """
            [{"trigger":{"url-filter":"/floorp-extension-owned\\\\.js"},"action":{"type":"block"}}]
            """
        )
        defer {
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rule)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tab = FloorpContentBlockerTestTab(webView: webView)

        ContentBlocker.shared.setupTrackingProtection(
            forTab: tab,
            isEnabled: false,
            rules: [],
            completion: nil
        )

        let server = try makeRuleOwnershipTestServer()
        defer { server.stop() }
        let navigation = FloorpWebExtensionNavigationWaiter()
        try await navigation.load(
            try XCTUnwrap(URL(string: "http://localhost:\(server.port)/")),
            in: webView
        )
        let didExecute = try await webView.callAsyncJavaScript(
            "return window.floorpExtensionOwnedRuleDidExecute === true;",
            arguments: [:],
            contentWorld: .page
        ) as? Bool

        XCTAssertEqual(didExecute, false)
    }

    func testNativeDNRBlocksAndRedirectsInManagedWebView() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extensionRoot = temporaryRoot.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionRoot, withIntermediateDirectories: true)

        let webExtension = try await makeDNRTestExtension(at: extensionRoot)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "app.floorp.dnr-acceptance.\(UUID().uuidString)"
        context.baseURL = URL(string: "webkit-extension://dnr-acceptance.floorp.internal/")!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, Date.distantFuture) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .default()
        let controller = WKWebExtensionController(configuration: configuration)
        let browsingConfiguration = WKWebViewConfiguration()
        browsingConfiguration.websiteDataStore = .default()
        browsingConfiguration.webExtensionController = controller
        let browsingWebView = WKWebView(frame: .zero, configuration: browsingConfiguration)
        let testTab = FloorpWebExtensionTestTab(webView: browsingWebView)
        let testWindow = FloorpWebExtensionTestWindow(tab: testTab)
        testTab.testWindow = testWindow
        let testDelegate = FloorpWebExtensionTestControllerDelegate(window: testWindow)
        controller.delegate = testDelegate
        controller.didOpenWindow(testWindow)
        controller.didOpenTab(testTab)
        controller.didFocusWindow(testWindow)
        controller.didActivateTab(testTab, previousActiveTab: nil)

        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension],
                resourceRoot: temporaryRoot
            )
        }
        try controller.load(context)
        let browsingNavigation = FloorpWebExtensionNavigationWaiter()
        defer {
            browsingWebView.stopLoading()
            browsingWebView.navigationDelegate = nil
            controller.didCloseTab(testTab, windowIsClosing: true)
            controller.didCloseWindow(testWindow)
            controller.delegate = nil
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [
                    webExtension,
                    browsingWebView,
                    browsingNavigation,
                    testTab,
                    testWindow,
                    testDelegate
                ],
                resourceRoot: temporaryRoot
            )
        }
        try? await Task.sleep(nanoseconds: 750_000_000)

        let server = try makeDNRTestServer()
        defer { server.stop() }
        try await browsingNavigation.load(
            try XCTUnwrap(URL(string: "http://localhost:\(server.port)/")),
            in: browsingWebView
        )
        try? await Task.sleep(nanoseconds: 750_000_000)
        let result = try await browsingWebView.callAsyncJavaScript(
            """
            return {
                controlScriptExecuted: window.floorpControlScriptExecuted === true,
                blockedScriptExecuted: window.floorpBlockedScriptExecuted === true,
                controlImageWidth: document.getElementById('control').naturalWidth,
                redirectedImageWidth: document.getElementById('redirected').naturalWidth
            };
            """,
            arguments: [:],
            contentWorld: .page
        ) as? [String: Any]
        let dnrResult = try XCTUnwrap(result)
        XCTAssertEqual(dnrResult["controlScriptExecuted"] as? Bool, true)
        XCTAssertEqual(dnrResult["blockedScriptExecuted"] as? Bool, false)
        XCTAssertEqual((dnrResult["controlImageWidth"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((dnrResult["redirectedImageWidth"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        withExtendedLifetime(testDelegate) {}
    }

    @MainActor
    private struct IsolatedHostProfile {
        let profile: MockProfile
        let rootDirectory: URL

        func cleanup() {
            FloorpNativeWebExtensionHost.remove(for: profile.localName())
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    @MainActor
    private struct HostContextFixture {
        let profile: MockProfile
        let host: FloorpNativeWebExtensionHost
        let context: WKWebExtensionContext
        let rootDirectory: URL

        func cleanup() {
            host.unregister(windowUUID: .XCTestDefaultUUID)
            FloorpNativeWebExtensionHost.remove(for: profile.localName())
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private func makeHostContextFixture(
        hasPrivateAccess: Bool
    ) async throws -> HostContextFixture {
        let profileFixture = try makeIsolatedHostProfile(prefix: "context")
        let profile = profileFixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: profile)
        try await host.installBundledExtension(
            identifier: FloorpNativeWebExtensionCatalog.darkReader.identifier
        )
        if hasPrivateAccess {
            try await host.setPrivateAccess(
                true,
                identifier: FloorpNativeWebExtensionCatalog.darkReader.identifier
            )
        }
        let context = try XCTUnwrap(
            host.installedContext(
                identifier: FloorpNativeWebExtensionCatalog.darkReader.identifier
            )
        )
        return HostContextFixture(
            profile: profile,
            host: host,
            context: context,
            rootDirectory: profileFixture.rootDirectory
        )
    }

    private func makeIsolatedHostProfile(prefix: String) throws -> IsolatedHostProfile {
        let identifier = UUID().uuidString
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-web-extension-\(identifier)", isDirectory: true)
        let profile = MockProfile(
            databasePrefix: "web_extension_\(prefix)_\(identifier.prefix(8))",
            localName: "web-extension-\(identifier)",
            fileRootPath: rootDirectory.path
        )
        return IsolatedHostProfile(profile: profile, rootDirectory: rootDirectory)
    }

    private func registryStore(
        for profile: MockProfile
    ) throws -> FloorpNativeWebExtensionRegistryStore {
        let directory = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        return FloorpNativeWebExtensionRegistryStore(
            url: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("registry-v2.json")
        )
    }

    private func loadBackgroundContent(in context: WKWebExtensionContext) async throws {
        let loaded = expectation(description: "WebExtension background content loaded")
        var backgroundError: (any Error)?
        context.loadBackgroundContent { error in
            backgroundError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 15)
        if let backgroundError {
            throw backgroundError
        }
    }

    private func waitForDocumentCommit(
        in webView: WKWebView,
        expectedOrigin: URL? = nil
    ) async throws {
        for _ in 0..<100 {
            if let expectedOrigin {
                guard let currentURL = webView.url,
                      currentURL.absoluteString != "about:blank",
                      currentURL.scheme == expectedOrigin.scheme,
                      currentURL.host == expectedOrigin.host else {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
            }
            if let ready = try? await webView.evaluateJavaScript(
                "document.readyState === 'complete'"
            ) as? Bool, ready {
                if expectedOrigin != nil {
                    // The JavaScript completion can resume just before WebKit
                    // delivers its didFinish delegate callback on MainActor.
                    // Let that real callback run before a close is requested;
                    // tests without an expected origin retain the legacy
                    // about:blank-ready behavior and timing.
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloorpNativeWebExtensionError.unsupportedOperation(
            "The test document did not finish loading"
        )
    }

    private func waitForJavaScriptState(
        in webView: WKWebView,
        description: String,
        source: String
    ) async throws -> [String: Any] {
        var lastState: [String: Any]?
        var lastError: (any Error)?
        for _ in 0..<80 {
            do {
                if let state = try await webView.floorpCallAsyncJavaScript(
                    source,
                    contentWorld: .page,
                    timeoutNanoseconds: 3_000_000_000
                ) as? [String: Any] {
                    lastState = state
                    if state["ready"] as? Bool == true {
                        return state
                    }
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FloorpNativeWebExtensionError.unsupportedOperation(
            "\(description) did not become ready; state=\(String(describing: lastState)); "
                + "error=\(lastError?.localizedDescription ?? "none")"
        )
    }

    private func waitForUBOLPageEffects(
        in webView: WKWebView,
        description: String,
        expectedCosmeticHidden: Bool
    ) async throws -> [String: Any] {
        try await waitForJavaScriptState(
            in: webView,
            description: description,
            source: """
            const ad = document.getElementById('Ad-Container');
            const style = ad ? getComputedStyle(ad) : null;
            const cosmeticHidden = style !== null && (
                style.display === 'none' || style.visibility === 'hidden' ||
                Number(style.opacity) === 0
            );
            const controlExecuted = window.floorpControlScriptExecuted === true;
            const blockedExecuted = window.floorpBundledUBOLBlockedScriptExecuted === true;
            const japaneseRulesetScriptExecuted = window.floorpJPNRulesetScriptExecuted === true;
            const expectedCosmeticHidden = \(expectedCosmeticHidden ? "true" : "false");
            return {
                ready: document.readyState === 'complete' && controlExecuted &&
                    blockedExecuted === false &&
                    cosmeticHidden === expectedCosmeticHidden,
                controlExecuted,
                blockedExecuted,
                cosmeticHidden,
                japaneseRulesetScriptExecuted,
            };
            """
        )
    }

    private func makeUBOLDeveloperModePage(
        context: WKWebExtensionContext
    ) async throws -> WKWebView {
        var lastError: (any Error)?
        for _ in 0..<3 {
            try await loadBackgroundContent(in: context)
            let template = try XCTUnwrap(context.webViewConfiguration)
            let configuration = try XCTUnwrap(
                template.copy() as? WKWebViewConfiguration
            )
            FloorpNativeWebExtensionHost.configureExtensionSurface(
                configuration,
                websiteDataStore: .default(),
                isPrivate: false
            )
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let navigation = FloorpWebExtensionNavigationWaiter()
            do {
                try await navigation.load(
                    context.baseURL.appendingPathComponent("web_accessible_resources/noop.html"),
                    in: webView
                )
                let enabled = try await webView.floorpCallAsyncJavaScript(
                    """
                    return await browser.runtime.sendMessage({
                        what: 'setDeveloperMode',
                        state: true,
                    });
                    """,
                    contentWorld: .page,
                    timeoutNanoseconds: 10_000_000_000
                ) as? Bool
                if enabled == true {
                    withExtendedLifetime(navigation) {}
                    return webView
                }
                lastError = FloorpNativeWebExtensionError.unsupportedOperation(
                    "uBO Lite did not enable Developer mode"
                )
            } catch {
                lastError = error
            }
            webView.stopLoading()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw lastError ?? FloorpNativeWebExtensionError.unsupportedOperation(
            "uBO Lite Developer mode page"
        )
    }

    private func topologyProbeState(
        in context: WKWebExtensionContext,
        generationAtLeast expectedGeneration: Int,
        createdEventTotalAtLeast expectedCreatedEventTotal: Int = 0
    ) async throws -> [String: Any] {
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = FloorpWebExtensionNavigationWaiter()
        try await navigation.load(context.baseURL.appendingPathComponent("probe.html"), in: webView)
        defer { webView.stopLoading() }

        var lastError: (any Error)?
        for _ in 0..<20 {
            do {
                if let state = try await webView.floorpCallAsyncJavaScript(
                    "return await browser.runtime.sendMessage({ what: 'snapshot' });",
                    contentWorld: .page,
                    timeoutNanoseconds: 2_000_000_000
                ) as? [String: Any],
                   (state["generation"] as? NSNumber)?.intValue ?? 0 >= expectedGeneration,
                   (state["createdEventTotal"] as? NSNumber)?.intValue ?? 0
                    >= expectedCreatedEventTotal {
                    withExtendedLifetime(navigation) {}
                    return state
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FloorpNativeWebExtensionError.unsupportedOperation(
            "topology probe did not reach generation \(expectedGeneration): "
                + (lastError?.localizedDescription ?? "no snapshot response")
        )
    }

    private static let topologyProbeArchiveBase64 = """
    UEsDBBQAAAAIAAAAJF0lxBNeqgAAAPgAAAANAAAAbWFuaWZlc3QuanNvbl2PsQrCQAyGX+XIXIridoibzg5uUkraxnp6vRzJVZTS
    d7etIOKY5Pv+JAN0GNyFNJUPEnUcwG4yCNgRWDh4ZonmxJE9ty9zFK4IMmhIa3ExLTjsnyS1U1KjCSX10SSsTOTYe5yRfDK+4bDO
    V1NdYX1vhfvQgB3gk6Zgzz+D/KZQZBBnUxOFBPaCXmlcep3TOXBxNLFgOx82LV6kK08P/VFb9L7sxesOivENUEsDBBQAAAAIAAAA
    JF2ClP5vcQEAAFoDAAANAAAAYmFja2dyb3VuZC5qc41STWvCQBD9K2lOu1QWe43EHsRbC6X1VnpY4zRZWHfTmYki6n9vNhtrrNAK
    gQ3z8ea9N2OBE9iA41mljctf0K8NgUIgbzcg5GSJfkuAivWSlHczBM2wUnq1ejLE4ACFkPl0PwA5/yquwAlNO1d0RYV3xAlxC5Hr
    rTacnOCJPeoSlPWFtqoEFu9pEWfNA9zCs7bph5z81UZt2/6qKxPdQHWVOBzG8v7hKCfx+yGH3NS9EfkV+RphY3xDN/AvgzuajXeB
    eGwPNv5q7Zz9agB3Yn+8QeAZNhMnNuocjKpGvY6FXs584zjrplhwJVed3MFqsc2bNbTbfQaiMO1iu+sYHBG4FWD3vALVrRwItpjP
    U8Wj2laa7/I8JadrqjynEoEbdJOBjVHfpc296PPh9AEH26QvEf1J5tPWhEVL1zd8io3GUl5DDImK/7blGmtl9EUVmotKAKLHMG2A
    sq/RL2EeMtkbo3FlLJPHtjdKTRgbCOf0DVBLAwQUAAAACAAAACRdqUdSVzYAAAA5AAAACgAAAHByb2JlLmh0bWyzUUzJTy6pLEhV
    yCjJzbGzyU0tSVRIzkgsKk4tsVUqLUnTtVCysynJLMlJtQsoyk9KtdGHcABQSwECFAMUAAAACAAAACRdJcQTXqoAAAD4AAAADQAA
    AAAAAAAAAAAApIEAAAAAbWFuaWZlc3QuanNvblBLAQIUAxQAAAAIAAAAJF2ClP5vcQEAAFoDAAANAAAAAAAAAAAAAACkgdUAAABi
    YWNrZ3JvdW5kLmpzUEsBAhQDFAAAAAgAAAAkXalHUlc2AAAAOQAAAAoAAAAAAAAAAAAAAKSBcQIAAHByb2JlLmh0bWxQSwUGAAAA
    AAMAAwCuAAAAzwIAAAAA
    """

    private func waitForPresentedActionPopup(
        presentingRoot: UIViewController,
        excluding excludedViewController: UIViewController? = nil
    ) async -> (viewController: FloorpNativeWebExtensionActionPopupViewController, webView: WKWebView)? {
        for _ in 0..<80 {
            if let popupViewController = presentingRoot.presentedViewController
                as? FloorpNativeWebExtensionActionPopupViewController,
               popupViewController !== excludedViewController {
                popupViewController.loadViewIfNeeded()
                let webView = popupViewController.webView
                if presentingRoot.presentedViewController === popupViewController,
                   popupViewController.presentingViewController != nil,
                   webView.url != nil,
                   !webView.isLoading {
                    XCTAssertTrue(presentingRoot.presentedViewController === popupViewController)
                    XCTAssertNotNil(webView.window)
                    return (popupViewController, webView)
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func waitForDismissedPresentation(
        from root: UIViewController,
        attempts: Int = 340
    ) async -> Bool {
        for _ in 0..<attempts {
            if root.presentedViewController == nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return root.presentedViewController == nil
    }

    // A throwing JavaScript call only starts the helper's deferred close. Await that close before
    // the test unregisters its host, with a bounded force-close fallback for failed preparation.
    private func closePresentedActionPopupForCleanup(from root: UIViewController) async {
        guard let popup = root.presentedViewController
            as? FloorpNativeWebExtensionActionPopupViewController else {
            return
        }
        let webView = popup.webView
        let didFinishPreparedClose: Bool
        if FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) {
            didFinishPreparedClose = false
        } else {
            let closeTask = Task { @MainActor in
                await popup.closePopupAfterPreparing(animated: false)
            }
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                closeTask.cancel()
            }
            didFinishPreparedClose = await closeTask.value
            timeoutTask.cancel()
            await timeoutTask.value
        }
        if !didFinishPreparedClose {
            popup.closePopupImmediately(animated: false)
        }
        let didDismiss = await waitForDismissedPresentation(from: root, attempts: 80)
        guard didDismiss,
              popup.presentingViewController == nil,
              !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
            return
        }
        webView.stopLoading()
        await Task.yield()
        await Task.yield()
    }

    private func exerciseBundledUBOLPopupRouteCloseRace(
        sourceTab: Tab,
        host: FloorpNativeWebExtensionHost,
        manager: FloorpUBOLRoutingTabManager,
        item: FloorpNativeWebExtensionCatalogItem,
        presentingRoot: UIViewController
    ) async throws {
        manager.selectTab(sourceTab)
        host.focus(windowUUID: sourceTab.windowUUID, isPrivate: sourceTab.isPrivate)
        try await host.performAction(contextIdentifier: item.identifier, for: sourceTab)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: presentingRoot)
        let popup = try XCTUnwrap(popupResult)
        let createdTabCount = manager.extensionCreatedTabs.count
        let routeAcknowledgementGate = FloorpClosePreparationTestGate()
        host.extensionTabCreationCompletionHookForTesting = { identifier, _ in
            guard identifier == item.identifier else { return }
            _ = await routeAcknowledgementGate.waitUntilReleased()
        }
        defer {
            routeAcknowledgementGate.mayFinish = true
            host.extensionTabCreationCompletionHookForTesting = nil
        }

        let didStartBundledRoute = try await popup.webView.floorpCallAsyncJavaScript(
            """
            if (typeof globalThis.floorpCompletePopupRoute !== 'function') {
                return false;
            }
            const operation = (async () => {
                const [tab] = await browser.tabs.query({
                    active: true,
                    currentWindow: true,
                });
                if (typeof tab?.id !== 'number' || typeof tab?.windowId !== 'number') {
                    throw new Error('Missing active source tab for route race');
                }
                return browser.runtime.sendMessage({
                    what: 'showMatchedRules',
                    tabId: tab.id,
                    windowId: tab.windowId,
                    incognito: tab.incognito === true,
                });
            })();
            void globalThis.floorpCompletePopupRoute(operation);
            return true;
            """,
            contentWorld: .page,
            timeoutNanoseconds: 3_000_000_000
        ) as? Bool
        XCTAssertEqual(didStartBundledRoute, true)
        for _ in 0..<80 where !routeAcknowledgementGate.didBegin {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(routeAcknowledgementGate.didBegin)
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount + 1)
        XCTAssertTrue(manager.selectedTab === sourceTab)

        popup.viewController.closePopup(animated: false)
        for _ in 0..<20 where
            !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(
            presentingRoot.presentedViewController === popup.viewController,
            "Native close must wait for the bundled popup route promise"
        )
        XCTAssertTrue(
            FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView)
        )

        routeAcknowledgementGate.mayFinish = true
        host.extensionTabCreationCompletionHookForTesting = nil
        let didDismiss = await waitForDismissedPresentation(from: presentingRoot)
        XCTAssertTrue(didDismiss)
        var routedTab: Tab?
        for _ in 0..<120 {
            if manager.extensionCreatedTabs.count == createdTabCount + 1,
               let candidate = manager.extensionCreatedTabs.last,
               (candidate.webView?.url ?? candidate.url) != nil {
                routedTab = candidate
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let tab = try XCTUnwrap(routedTab)
        let routeURL = try XCTUnwrap(tab.webView?.url ?? tab.url)
        XCTAssertTrue(manager.selectedTab === tab)
        XCTAssertEqual(routeURL.path, "/matched-rules.html")
        if !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup.webView) {
            popup.webView.stopLoading()
            await Task.yield()
            await Task.yield()
        }
        manager.removeSeedTab(tab)
        await tab.close()
        manager.selectTab(sourceTab)
        XCTAssertEqual(manager.extensionCreatedTabs.count, createdTabCount)
    }

    // swiftlint:disable:next function_body_length
    private func requestUBOLMatchedRulesRoute(
        sourceTab: Tab,
        isPrivate: Bool,
        host: FloorpNativeWebExtensionHost,
        manager: FloorpUBOLRoutingTabManager,
        item: FloorpNativeWebExtensionCatalogItem,
        observerWebView: WKWebView,
        presentingRoot: UIViewController
    ) async throws -> Tab {
        let previousCreatedTabCount = manager.extensionCreatedTabs.count
        manager.selectTab(sourceTab)
        host.focus(windowUUID: manager.windowUUID, isPrivate: isPrivate)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        for tab in manager.tabs {
            tab.webView?.isHidden = tab !== sourceTab
        }
        if let sourceWebView = sourceTab.webView {
            sourceWebView.superview?.bringSubviewToFront(sourceWebView)
        }
        let expectedSourceTabIDResult = try await observerWebView.floorpCallAsyncJavaScript(
            """
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
            return tab?.id;
            """,
            contentWorld: .page,
            timeoutNanoseconds: 3_000_000_000
        ) as? NSNumber
        let expectedSourceTabID = try XCTUnwrap(expectedSourceTabIDResult).intValue

        let sourceURL = try XCTUnwrap(sourceTab.webView?.url ?? sourceTab.url)
        let preActionNavigation = MockNavigationAction(url: sourceURL, type: .linkActivated)
        let preActionGeneration = host.beginNavigationPreparation(for: sourceTab)
        let preparedSourceNavigation = await host.prepareBackgroundContent(
            beforeNavigating: sourceTab,
            to: sourceURL,
            navigationAction: preActionNavigation,
            generation: preActionGeneration
        )
        XCTAssertTrue(preparedSourceNavigation)
        XCTAssertTrue(host.consumePreparedNavigation(preActionNavigation))
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: sourceTab, to: sourceURL))

        try await host.performAction(contextIdentifier: item.identifier, for: sourceTab)
        XCTAssertTrue(
            host.needsBackgroundReadiness(beforeNavigating: sourceTab, to: sourceURL),
            "Opening the uBO popup must invalidate an older realm-readiness cache"
        )
        let popupResult = await waitForPresentedActionPopup(presentingRoot: presentingRoot)
        let presentedPopup = try XCTUnwrap(
            popupResult,
            "uBO Lite action popup was not presented by the production host"
        )
        let popupViewController = presentedPopup.viewController
        let popup = presentedPopup.webView
        XCTAssertEqual(popup.configuration.websiteDataStore.isPersistent, !isPrivate)
        XCTAssertTrue(
            popup.configuration.websiteDataStore === sourceTab.floorpNativeWebsiteDataStore
        )
        XCTAssertFalse(
            popup.configuration.userContentController
                === sourceTab.webView?.configuration.userContentController
        )
        var didClosePopup = false
        defer {
            if !didClosePopup {
                popupViewController.closePopup(animated: false)
            }
        }

        var immediateCloseState: [String: Any]?
        for _ in 0..<60 {
            immediateCloseState = try? await popup.floorpCallAsyncJavaScript(
                """
                if ( typeof globalThis.floorpPrepareToClose !== 'function' ) {
                    return null;
                }
                return await globalThis.floorpPrepareToClose();
                """,
                contentWorld: .page,
                timeoutNanoseconds: 3_000_000_000
            ) as? [String: Any]
            if immediateCloseState != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(immediateCloseState?["ready"] as? Bool, true)
        XCTAssertEqual(immediateCloseState?["noMutation"] as? Bool, true)

        var popupState: [String: Any]?
        for _ in 0..<80 {
            popupState = try? await popup.floorpCallAsyncJavaScript(
                """
                const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
                const config = await browser.runtime.sendMessage({ what: 'getCurrentConfig' });
                const manifest = browser.runtime.getManifest();
                return {
                    ready: document.readyState === 'complete' &&
                        !document.body.classList.contains('loading'),
                    enabled: document.querySelector('#gotoMatchedRules')
                        ?.classList.contains('enabled') === true,
                    developerMode: config?.developerMode === true,
                    hasFeedbackPermission:
                        manifest.permissions?.includes('declarativeNetRequestFeedback') === true,
                    runtimeError: document.querySelector('#runtimeError')?.textContent || '',
                    tabId: tab?.id,
                    incognito: tab?.incognito === true,
                    runtimeId: browser.runtime.id,
                    runtimeURL: browser.runtime.getURL('/'),
                };
                """,
                contentWorld: .page,
                timeoutNanoseconds: 3_000_000_000
            ) as? [String: Any]
            if popupState?["ready"] as? Bool == true,
               popupState?["enabled"] as? Bool == true {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(popupState?["ready"] as? Bool, true)
        XCTAssertEqual(
            popupState?["enabled"] as? Bool,
            true,
            "uBO Matched rules state: \(String(describing: popupState))"
        )
        XCTAssertEqual(popupState?["incognito"] as? Bool, isPrivate)
        XCTAssertEqual((popupState?["tabId"] as? NSNumber)?.intValue, expectedSourceTabID)
        XCTAssertFalse((popupState?["runtimeId"] as? String)?.isEmpty ?? true)
        let runtimeURL = try XCTUnwrap(
            (popupState?["runtimeURL"] as? String).flatMap(URL.init(string:))
        )
        XCTAssertEqual(runtimeURL.scheme, item.baseURLScheme)
        XCTAssertEqual(runtimeURL.host, item.baseURLHost)

        let mutationFailure = try await popup.floorpCallAsyncJavaScript(
            """
            const popupModule = await import(browser.runtime.getURL('js/popup.js'));
            const slider = document.querySelector('.filteringModeSlider');
            const beforeLevel = Number(slider.dataset.level);
            const attemptedLevel = beforeLevel === 1 ? 2 : 1;
            let gesturePermissionRequested = false;
            let gesturePermissionOrigins = [];
            slider.dataset.levelBefore = '1';
            slider.dataset.level = '1';
            const queueBlocker = popupModule.commitFilteringMode(
                async request => {
                    if ( request.what === 'setFilteringMode' ) {
                        await new Promise(resolve => setTimeout(resolve, 150));
                        return 1;
                    }
                    return true;
                },
                undefined,
                false,
                async () => true
            );
            slider.dataset.levelBefore = '1';
            slider.dataset.level = '2';
            const gestureCommit = popupModule.commitFilteringMode(
                async () => true,
                undefined,
                false,
                origins => {
                    gesturePermissionRequested = true;
                    gesturePermissionOrigins = Array.from(origins);
                    return false;
                }
            );
            const gesturePermissionRequestedSynchronously = gesturePermissionRequested;
            const queueBlockerCommitted = await queueBlocker;
            const gestureCommitted = await gestureCommit;
            slider.dataset.levelBefore = `${beforeLevel}`;
            slider.dataset.level = `${attemptedLevel}`;
            let reloadCount = 0;
            const committed = await popupModule.commitFilteringMode(
                async () => ({ error: 'injected popup mutation failure' }),
                () => { reloadCount += 1; },
                true,
                async () => true
            );
            await new Promise(resolve => setTimeout(resolve, 500));
            const failedClose = await globalThis.floorpPrepareToClose();
            const retryClose = await globalThis.floorpPrepareToClose();
            slider.dataset.levelBefore = `${beforeLevel}`;
            slider.dataset.level = `${beforeLevel}`;
            const delayedCommit = popupModule.commitFilteringMode(
                async request => {
                    await new Promise(resolve => setTimeout(resolve, 150));
                    if ( request.what === 'setFilteringMode' ) { return beforeLevel; }
                    return true;
                },
                () => { reloadCount += 1; },
                false,
                async () => true
            );
            const delayedCloseStarted = performance.now();
            const delayedClose = await globalThis.floorpPrepareToClose();
            const delayedCloseElapsed = performance.now() - delayedCloseStarted;
            const delayedCommitted = await delayedCommit;
            return {
                gesturePermissionRequestedSynchronously,
                gesturePermissionOrigins,
                queueBlockerCommitted,
                gestureCommitted,
                committed,
                failedCloseReady: failedClose?.ready === true,
                failedCloseError: failedClose?.error || '',
                retryCloseReady: retryClose?.ready === true,
                delayedCommitted,
                delayedCloseReady: delayedClose?.ready === true,
                delayedCloseElapsed,
                beforeLevel,
                finalLevel: Number(slider.dataset.level),
                reloadCount,
                error: document.querySelector('#runtimeError')?.textContent || '',
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 20_000_000_000
        ) as? [String: Any]
        let popupFailure = try XCTUnwrap(mutationFailure)
        XCTAssertEqual(popupFailure["gesturePermissionRequestedSynchronously"] as? Bool, true)
        XCTAssertEqual(
            popupFailure["gesturePermissionOrigins"] as? [String],
            ["*://*.example.com/*"]
        )
        XCTAssertEqual(popupFailure["queueBlockerCommitted"] as? Bool, true)
        XCTAssertEqual(popupFailure["gestureCommitted"] as? Bool, false)
        XCTAssertEqual(popupFailure["committed"] as? Bool, false)
        XCTAssertEqual(popupFailure["failedCloseReady"] as? Bool, false)
        XCTAssertTrue(
            (popupFailure["failedCloseError"] as? String)?
                .contains("injected popup mutation failure") == true
        )
        XCTAssertEqual(popupFailure["retryCloseReady"] as? Bool, true)
        XCTAssertEqual(popupFailure["delayedCommitted"] as? Bool, true)
        XCTAssertEqual(popupFailure["delayedCloseReady"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(
            (popupFailure["delayedCloseElapsed"] as? NSNumber)?.doubleValue ?? 0,
            100
        )
        XCTAssertEqual(
            (popupFailure["finalLevel"] as? NSNumber)?.intValue,
            (popupFailure["beforeLevel"] as? NSNumber)?.intValue
        )
        XCTAssertEqual((popupFailure["reloadCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(popupFailure["error"] as? String, "")

#if DEBUG || TESTING
        host.setNavigationReadinessVerifiedForTesting(
            identifier: item.identifier,
            isPrivate: isPrivate
        )
        XCTAssertFalse(host.needsBackgroundReadiness(beforeNavigating: sourceTab, to: sourceURL))
#endif
        let raw = try await popup.floorpCallAsyncJavaScript(
            """
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
            if ( tab instanceof Object === false || typeof tab.id !== 'number' ) {
                throw new Error('Missing active source tab');
            }
            if ( typeof tab.windowId !== 'number' ) {
                throw new Error('Missing active source window');
            }
            if ( tab.incognito !== expectedPrivate ) {
                throw new Error(`Unexpected source-tab privacy: ${tab.incognito}`);
            }
            const response = await browser.runtime.sendMessage({
                what: 'showMatchedRules',
                tabId: tab.id,
                windowId: tab.windowId,
                incognito: tab.incognito === true,
            });
            return {
                tabId: tab.id,
                windowId: tab.windowId,
                incognito: tab.incognito === true,
                opened: response?.opened === true,
                error: response?.error,
            };
            """,
            arguments: ["expectedPrivate": isPrivate],
            contentWorld: .page,
            timeoutNanoseconds: 10_000_000_000
        ) as? [String: Any]
        let result = try XCTUnwrap(raw)
        let sourceTabID = try XCTUnwrap((result["tabId"] as? NSNumber)?.intValue)
        XCTAssertEqual(sourceTabID, expectedSourceTabID)
        XCTAssertNotNil((result["windowId"] as? NSNumber)?.intValue)
        XCTAssertEqual(result["incognito"] as? Bool, isPrivate)
        XCTAssertEqual(
            result["opened"] as? Bool,
            true,
            result["error"] as? String ?? "Matched-rules handler did not confirm tab creation"
        )
        XCTAssertTrue(presentingRoot.presentedViewController === popupViewController)
        XCTAssertTrue(manager.selectedTab === sourceTab)
        XCTAssertEqual(manager.extensionCreatedTabs.count, previousCreatedTabCount + 1)

        let rejectedSecondRoute = try await popup.floorpCallAsyncJavaScript(
            """
            try {
                await browser.tabs.create({
                    active: true,
                    url: browser.runtime.getURL('/dashboard.html'),
                });
                return '';
            } catch (reason) {
                return reason instanceof Error ? reason.message : `${reason}`;
            }
            """,
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        ) as? String
        XCTAssertFalse(rejectedSecondRoute?.isEmpty ?? true)
        XCTAssertEqual(
            manager.extensionCreatedTabs.count,
            previousCreatedTabCount + 1,
            "A rejected second popup transition must not leave a ghost tab"
        )

        // The bundled handler performs this explicit close after its route
        // acknowledgement. The direct API probe above first proves that the
        // response reaches a still-live popup callback.
        popupViewController.requestCloseForTesting()
        let didDismissPopup = await waitForDismissedPresentation(
            from: presentingRoot,
            attempts: 340
        )
        didClosePopup = didDismissPopup
        XCTAssertTrue(didDismissPopup)

        var routedTab: Tab?
        for _ in 0..<200 {
            if manager.extensionCreatedTabs.count > previousCreatedTabCount,
               let candidate = manager.extensionCreatedTabs.last,
               candidate.floorpNativeWebExtensionContextIdentifier == item.identifier,
               (candidate.webView?.url ?? candidate.url) != nil {
                routedTab = candidate
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let routingState = manager.extensionCreatedTabs.map { tab in
            let identifier = tab.floorpNativeWebExtensionContextIdentifier ?? "nil"
            let url = (tab.webView?.url ?? tab.url)?.absoluteString ?? "nil"
            return "private=\(tab.isPrivate), context=\(identifier), url=\(url)"
        }.joined(separator: "; ")
        let tab = try XCTUnwrap(
            routedTab,
            "No ready matched-rules tab. Created tabs: [\(routingState)]"
        )
        let url = try XCTUnwrap(tab.webView?.url ?? tab.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertTrue(manager.selectedTab === tab)
        XCTAssertEqual(tab.isPrivate, isPrivate)
        XCTAssertEqual(tab.floorpNativeWebExtensionContextIdentifier, item.identifier)
        XCTAssertEqual(tab.webView?.configuration.websiteDataStore.isPersistent, !isPrivate)
        XCTAssertEqual(components.scheme, item.baseURLScheme)
        XCTAssertEqual(components.host, item.baseURLHost)
        XCTAssertEqual(components.path, "/matched-rules.html")
        XCTAssertEqual(
            components.queryItems?.filter { $0.name == "tab" }.map(\.value),
            [String(sourceTabID)]
        )
        if didDismissPopup,
           !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(popup) {
            popup.stopLoading()
            await Task.yield()
            await Task.yield()
        }
        XCTAssertNil(popupViewController.presentedViewController)
        XCTAssertNil(presentingRoot.presentedViewController)
        XCTAssertTrue(
            host.needsBackgroundReadiness(beforeNavigating: sourceTab, to: sourceURL),
            "Closing the uBO popup must invalidate readiness after a possible mode mutation"
        )
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        return tab
    }

    // Regression for popup Report routing: a matching normal report tab must
    // never be reused after focus moves away from the originating private tab.
    // swiftlint:disable:next function_body_length
    private func requestUBOLPrivateReportRouteAfterFocusShift(
        sourceTab: Tab,
        normalFocusTab: Tab,
        host: FloorpNativeWebExtensionHost,
        manager: FloorpUBOLRoutingTabManager,
        item: FloorpNativeWebExtensionCatalogItem,
        observerWebView: WKWebView,
        presentingRoot: UIViewController
    ) async throws -> Tab {
        let previousCreatedTabCount = manager.extensionCreatedTabs.count
        manager.selectTab(sourceTab)
        host.focus(windowUUID: manager.windowUUID, isPrivate: true)
        for tab in manager.tabs {
            tab.webView?.isHidden = tab !== sourceTab
        }
        try await host.performAction(contextIdentifier: item.identifier, for: sourceTab)
        let popupResult = await waitForPresentedActionPopup(presentingRoot: presentingRoot)
        let presentedPopup = try XCTUnwrap(
            popupResult,
            "uBO Lite private popup was not presented for Report routing"
        )
        let popup = presentedPopup.webView
        XCTAssertFalse(popup.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(
            popup.configuration.websiteDataStore === sourceTab.floorpNativeWebsiteDataStore
        )

        let rawSource = try await popup.floorpCallAsyncJavaScript(
            """
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
            if ( tab instanceof Object === false || typeof tab.id !== 'number' ||
                 typeof tab.windowId !== 'number' || tab.incognito !== true ) {
                throw new Error('Missing private popup source identity');
            }
            const reportURL = new URL(browser.runtime.getURL('/report.html'));
            reportURL.searchParams.set('tabid', tab.id);
            reportURL.searchParams.set('url', tab.url);
            reportURL.searchParams.set('mode', 2);
            return {
                absoluteURL: reportURL.href,
                relativeURL: `${reportURL.pathname}${reportURL.search}`,
                tabId: tab.id,
                windowId: tab.windowId,
                incognito: tab.incognito,
            };
            """,
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        ) as? [String: Any]
        let source = try XCTUnwrap(rawSource)
        let sourceWindowID = try XCTUnwrap((source["windowId"] as? NSNumber)?.intValue)
        XCTAssertEqual(source["incognito"] as? Bool, true)
        let absoluteReportURL = try XCTUnwrap(
            (source["absoluteURL"] as? String).flatMap(URL.init(string:))
        )
        let relativeReportURL = try XCTUnwrap(source["relativeURL"] as? String)

        presentedPopup.viewController.closePopup(animated: false)
        let didDismissPopup = await waitForDismissedPresentation(from: presentingRoot)
        XCTAssertTrue(didDismissPopup)
        popup.stopLoading()

        let existingNormalReport = manager.seedTab(url: absoluteReportURL, isPrivate: false)
        host.announceTabIfNeeded(existingNormalReport)
        manager.selectTab(normalFocusTab)
        host.focus(windowUUID: manager.windowUUID, isPrivate: false)
        let sourceURLBeforeRouting = sourceTab.webView?.url ?? sourceTab.url

        let rawResponse = try await observerWebView.floorpCallAsyncJavaScript(
            """
            return await browser.runtime.sendMessage({
                what: 'gotoURL',
                url: relativeURL,
                windowId: sourceWindowId,
                incognito: true,
            });
            """,
            arguments: [
                "relativeURL": relativeReportURL,
                "sourceWindowId": sourceWindowID
            ],
            contentWorld: .page,
            timeoutNanoseconds: 10_000_000_000
        ) as? [String: Any]
        let response = try XCTUnwrap(rawResponse)
        XCTAssertEqual(
            response["opened"] as? Bool,
            true,
            response["error"] as? String ?? "Report handler did not confirm routing"
        )
        XCTAssertEqual(response["reused"] as? Bool, false)

        var createdReport: Tab?
        for _ in 0..<200 {
            if manager.extensionCreatedTabs.count > previousCreatedTabCount,
               let candidate = manager.extensionCreatedTabs.last,
               (candidate.webView?.url ?? candidate.url) == absoluteReportURL {
                createdReport = candidate
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let reportTab = try XCTUnwrap(createdReport, "No private Report tab was created")
        XCTAssertTrue(manager.selectedTab === reportTab)
        XCTAssertFalse(reportTab === existingNormalReport)
        XCTAssertTrue(reportTab.isPrivate)
        XCTAssertFalse(reportTab.webView?.configuration.websiteDataStore.isPersistent ?? true)
        XCTAssertTrue(
            reportTab.webView?.configuration.websiteDataStore
                === sourceTab.floorpNativeWebsiteDataStore
        )
        XCTAssertEqual(reportTab.floorpNativeWebExtensionContextIdentifier, item.identifier)
        XCTAssertEqual(existingNormalReport.isPrivate, false)
        XCTAssertEqual(existingNormalReport.webView?.url ?? existingNormalReport.url, absoluteReportURL)
        XCTAssertEqual(sourceTab.webView?.url ?? sourceTab.url, sourceURLBeforeRouting)
        return reportTab
    }

    private func makeHostTestTab(
        profile: MockProfile,
        isPrivate: Bool,
        windowUUID: WindowUUID = .XCTestDefaultUUID
    ) -> Tab {
        Tab(
            profile: profile,
            isPrivate: isPrivate,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
    }

    private func assertActiveTabBelongsToWindow(
        _ window: FloorpNativeWebExtensionWindow,
        context: WKWebExtensionContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabs = window.tabs(for: context)
        guard let activeTab = window.activeTab(for: context) else {
            XCTFail("A nonempty logical window must expose an active tab", file: file, line: line)
            return
        }
        XCTAssertFalse(tabs.isEmpty, file: file, line: line)
        XCTAssertTrue(
            tabs.contains { ($0 as AnyObject) === (activeTab as AnyObject) },
            file: file,
            line: line
        )
    }

    private func makeDNRTestExtension(at extensionRoot: URL) async throws -> WKWebExtension {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Floorp DNR Acceptance",
            "description": "Exercises native declarative network request handling.",
            "version": "1.0",
            "permissions": [
                "declarativeNetRequest",
                "declarativeNetRequestWithHostAccess"
            ],
            "host_permissions": ["<all_urls>"],
            "declarative_net_request": [
                "rule_resources": [[
                    "id": "floorp-smoke",
                    "enabled": true,
                    "path": "rules.json"
                ]]
            ],
            "web_accessible_resources": [[
                "resources": ["one.svg"],
                "matches": ["<all_urls>"]
            ]]
        ]
        let rules: [[String: Any]] = [
            [
                "id": 1,
                "priority": 1,
                "action": ["type": "block"],
                "condition": [
                    "urlFilter": "/floorp-blocked.js",
                    "resourceTypes": ["script"]
                ]
            ],
            [
                "id": 2,
                "priority": 1,
                "action": [
                    "type": "redirect",
                    "redirect": ["extensionPath": "/one.svg"]
                ],
                "condition": [
                    "urlFilter": "/floorp-redirected.svg",
                    "resourceTypes": ["image"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("rules.json"), options: .atomic)
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>".utf8)
            .write(to: extensionRoot.appendingPathComponent("one.svg"), options: .atomic)

        let webExtension = try await WKWebExtension(resourceBaseURL: extensionRoot)
        XCTAssertTrue(
            webExtension.errors.isEmpty,
            webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        return webExtension
    }

    private func compileContentRuleList(
        in store: WKContentRuleListStore,
        identifier: String,
        source: String
    ) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { rule, error in
                if let rule {
                    continuation.resume(returning: rule)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? FloorpNativeWebExtensionError.unsupportedOperation(
                                "compile content-rule ownership fixture"
                            )
                    )
                }
            }
        }
    }

    nonisolated private func makeRuleOwnershipTestServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <script>window.floorpExtensionOwnedRuleDidExecute = false;</script>
            <script src="/floorp-extension-owned.js"></script>
            """)
        }
        server.addHandler(
            forMethod: "GET",
            path: "/floorp-extension-owned.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpExtensionOwnedRuleDidExecute = true;".utf8),
                contentType: "text/javascript"
            )
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpNativeWebExtensionError.unsupportedOperation(
                "start content-rule ownership test server"
            )
        }
        return server
    }

    nonisolated private func makeDNRTestServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <meta charset="utf-8">
            <style>
            html, body { background: white; color: black; }
            #Ad-Container { display: block; width: 20px; height: 20px; }
            </style>
            <script>window.floorpControlScriptExecuted = false;</script>
            <script>window.floorpBlockedScriptExecuted = false;</script>
            <script>window.floorpBundledUBOLBlockedScriptExecuted = false;</script>
            <script>window.floorpJPNRulesetScriptExecuted = false;</script>
            <div id="Ad-Container">bundled cosmetic probe</div>
            <script src="/control.js"></script>
            <script src="/floorp-blocked.js"></script>
            <script src="/floorp-default-acceptance.ashx?adid=floorp"></script>
            <script src="/settings/ad.js"></script>
            <img id="control" src="/control.svg">
            <img id="redirected" src="/floorp-redirected.svg">
            """)
        }
        server.addHandler(
            forMethod: "GET",
            path: "/control.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpControlScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        server.addHandler(
            forMethod: "GET",
            path: "/floorp-blocked.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpBlockedScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        server.addHandler(
            forMethod: "GET",
            path: "/floorp-default-acceptance.ashx",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpBundledUBOLBlockedScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        server.addHandler(
            forMethod: "GET",
            path: "/settings/ad.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpJPNRulesetScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        let twoPixelSVG = Data(
            "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'></svg>".utf8
        )
        for path in ["/control.svg", "/floorp-redirected.svg"] {
            server.addHandler(forMethod: "GET", path: path, request: GCDWebServerRequest.self) { _ in
                GCDWebServerDataResponse(data: twoPixelSVG, contentType: "image/svg+xml")
            }
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpNativeWebExtensionError.unsupportedOperation("start DNR test server")
        }
        return server
    }

    private func makeRecord() -> FloorpNativeWebExtensionRecord {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        return FloorpNativeWebExtensionRecord(
            id: item.identifier,
            contextIdentifier: item.contextIdentifier,
            baseURLHost: item.baseURLHost,
            packageSource: .bundled,
            packageReference: item.packageReference,
            sha256: item.expectedSHA256,
            displayName: item.name,
            installedVersion: item.expectedVersion,
            grantedPermissions: [
                "alarms",
                "fontSettings",
                "scripting",
                "storage"
            ].map { FloorpNativeWebExtensionPermissionDecision(value: $0) },
            grantedMatchPatterns: [
                FloorpNativeWebExtensionPermissionDecision(value: "*://*/*")
            ],
            hasRequestedOptionalAccessToAllHosts: true,
            installedAt: fixedDate,
            updatedAt: fixedDate
        )
    }

    private func makeUBOLRecord() -> FloorpNativeWebExtensionRecord {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let requiredPermissions = [
            "activeTab",
            "alarms",
            "declarativeNetRequest",
            "declarativeNetRequestFeedback",
            "declarativeNetRequestWithHostAccess",
            "scripting",
            "storage",
            "unlimitedStorage"
        ].map { FloorpNativeWebExtensionPermissionDecision(value: $0) }
        return FloorpNativeWebExtensionRecord(
            id: item.identifier,
            contextIdentifier: item.contextIdentifier,
            baseURLHost: item.baseURLHost,
            packageSource: .bundled,
            packageReference: item.packageReference,
            sha256: item.expectedSHA256,
            displayName: item.name,
            installedVersion: item.expectedVersion,
            grantedPermissions: requiredPermissions,
            grantedMatchPatterns: [
                FloorpNativeWebExtensionPermissionDecision(value: "<all_urls>")
            ],
            installedAt: fixedDate,
            updatedAt: fixedDate
        )
    }
}

private struct FloorpProductionHostTabCase {
    let tab: Tab
    let isPrivate: Bool
    let url: URL
}

@MainActor
private final class FloorpContentBlockerTestTab: ContentBlockerTab {
    let webView: WKWebView
    let isPrivate = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    func currentURL() -> URL? {
        webView.url
    }

    func currentWebView() -> WKWebView? {
        webView
    }

    func imageContentBlockingEnabled() -> Bool {
        false
    }
}

@MainActor
private final class FloorpWebExtensionNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class FloorpWebExtensionTestControllerDelegate: NSObject,
    WKWebExtensionControllerDelegate {
    let window: FloorpWebExtensionTestWindow

    init(window: FloorpWebExtensionTestWindow) {
        self.window = window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        window
    }
}

@MainActor
private final class FloorpWebExtensionTestWindow: NSObject, WKWebExtensionWindow {
    let tab: FloorpWebExtensionTestTab

    init(tab: FloorpWebExtensionTestTab) {
        self.tab = tab
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        tab.webView.bounds
    }
}

@MainActor
private final class FloorpWebExtensionTestTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var testWindow: FloorpWebExtensionTestWindow?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        testWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        webView.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        webView.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !webView.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }
}

@MainActor
private final class FloorpUBOLRoutingTabManager: MockTabManager {
    private let profile: MockProfile
    private let host: FloorpNativeWebExtensionHost
    private let notifiesDelegatesOnAdd: Bool
    private let privateWebsiteDataStore = WKWebsiteDataStore.nonPersistent()
    private var registeredDelegates = [WeakTabManagerDelegate]()
    private(set) var extensionCreatedTabs = [Tab]()
    var rejectsSingleTabRemovalForTesting = false
    private(set) var rejectedSingleTabRemovalCount = 0
    private(set) var forcedRemoveTabsCallCount = 0
    private(set) var didAttemptToForceRemoveSelectedTab = false
    var registeredDelegateCount: Int {
        registeredDelegates.compactMap { $0.get() }.count
    }

    init(
        profile: MockProfile,
        host: FloorpNativeWebExtensionHost,
        windowUUID: WindowUUID,
        notifiesDelegatesOnAdd: Bool = true
    ) {
        self.profile = profile
        self.host = host
        self.notifiesDelegatesOnAdd = notifiesDelegatesOnAdd
        super.init(windowUUID: windowUUID)
    }

    func seedTab(url: URL, isPrivate: Bool) -> Tab {
        let tab = makeTab(isPrivate: isPrivate)
        tab.url = url
        append(tab)
        return tab
    }

    func removeSeedTab(_ tab: Tab) {
        tabs.removeAll { $0 === tab }
        normalTabs.removeAll { $0 === tab }
        privateTabs.removeAll { $0 === tab }
        extensionCreatedTabs.removeAll { $0 === tab }
        if selectedTab === tab {
            selectedTab = tabs.first
        }
        registeredDelegates.forEach {
            $0.get()?.tabManager(self, didRemoveTab: tab, isRestoring: false)
        }
    }

    override func removeTab(_ tabUUID: TabUUID, completion: @escaping (Bool) -> Void) {
        if rejectsSingleTabRemovalForTesting {
            rejectedSingleTabRemovalCount += 1
            completion(false)
            return
        }
        guard let tab = tabs.first(where: { $0.tabUUID == tabUUID }) else {
            completion(false)
            return
        }
        removeSeedTab(tab)
        completion(true)
    }

    override func removeTabs(_ tabs: [Tab]) {
        forcedRemoveTabsCallCount += 1
        for tab in tabs where self.tabs.contains(where: { $0 === tab }) {
            guard selectedTab !== tab else {
                didAttemptToForceRemoveSelectedTab = true
                continue
            }
            removeSeedTab(tab)
        }
    }

    override func addDelegate(_ delegate: TabManagerDelegate) {
        registeredDelegates.append(WeakTabManagerDelegate(value: delegate))
    }

    override func removeDelegate(_ delegate: TabManagerDelegate, completion: (() -> Void)?) {
        registeredDelegates.removeAll {
            guard let registered = $0.get() else { return true }
            return registered === delegate
        }
        completion?()
    }

    @discardableResult
    override func addTab(
        _ request: URLRequest?,
        afterTab: Tab?,
        zombie: Bool,
        isPrivate: Bool
    ) -> Tab {
        let tab = makeTab(isPrivate: isPrivate)
        tab.url = request?.url
        append(tab)
        extensionCreatedTabs.append(tab)
        if notifiesDelegatesOnAdd {
            registeredDelegates.forEach {
                $0.get()?.tabManager(
                    self,
                    didAddTab: tab,
                    placeNextToParentTab: false,
                    isRestoring: false
                )
            }
        }
        if let request {
            tab.loadRequest(request)
        }
        return tab
    }

    override func selectTab(
        _ tab: Tab?,
        previous: Tab?,
        immediatePreservation: Bool
    ) {
        let previousTab = previous ?? selectedTab
        super.selectTab(
            tab,
            previous: previous,
            immediatePreservation: immediatePreservation
        )
        guard let tab else { return }
        registeredDelegates.forEach {
            $0.get()?.tabManager(
                self,
                didSelectedTabChange: tab,
                previousTab: previousTab,
                isRestoring: false
            )
        }
    }

    private func makeTab(isPrivate: Bool) -> Tab {
        let tab = Tab(
            profile: profile,
            isPrivate: isPrivate,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? privateWebsiteDataStore : .default()
        host.attach(to: configuration)
        tab.createWebview(configuration: configuration)
        return tab
    }

    private func append(_ tab: Tab) {
        tabs.append(tab)
        if tab.isPrivate {
            privateTabs.append(tab)
        } else {
            normalTabs.append(tab)
        }
    }
}
