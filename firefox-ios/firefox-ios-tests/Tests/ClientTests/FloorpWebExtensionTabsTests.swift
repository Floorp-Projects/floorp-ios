// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Common
import TestKit
import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionTabsTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.tabs")!

    func testQueryRedactsSensitiveFieldsUntilTabsOrHostAccessIsGranted() async throws {
        let host = TabsHost(tabs: [tab(id: 7, url: "https://allowed.example/page", title: "Allowed", active: true)])
        let broker = FloorpWebExtensionPermissionBroker()
        let service = try FloorpWebExtensionTabsService(
            profileIdentifier: "normal",
            isPrivateBrowsing: false,
            host: host,
            permissionBroker: broker
        )

        let redacted = try await service.query(.active, for: extensionID)
        XCTAssertEqual(redacted, [.init(id: 7, active: true, isPrivate: false, url: nil, title: nil)])

        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await broker.grant([], requestedHosts: [match], hostAccess: .allRequestedSites, to: extensionID)

        let visible = try await service.query(.current, for: extensionID)
        XCTAssertEqual(visible.first?.url?.host, "allowed.example")
        XCTAssertEqual(visible.first?.title, "Allowed")
    }

    func testTabMutationsRequireTabsPermissionAndRejectUnsafeNavigation() async throws {
        let host = TabsHost(tabs: [tab(id: 1, url: "https://start.example/", title: "Start", active: true)])
        let broker = FloorpWebExtensionPermissionBroker()
        let service = try FloorpWebExtensionTabsService(
            profileIdentifier: "normal",
            isPrivateBrowsing: false,
            host: host,
            permissionBroker: broker
        )
        let nextURL = try XCTUnwrap(URL(string: "https://next.example/"))

        do {
            _ = try await service.create(url: nextURL, for: extensionID)
            XCTFail("Expected tabs permission to be required")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionError, .permissionDenied(FloorpWebExtensionAPIGrant.tabs.rawValue))
        }

        await broker.grant([.tabs], requestedHosts: [], hostAccess: .denied, to: extensionID)
        let created = try await service.create(url: nextURL, for: extensionID)
        XCTAssertEqual(created.url?.host, "next.example")

        let javascriptURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        do {
            _ = try await service.update(created.id, url: javascriptURL, for: extensionID)
            XCTFail("Expected unsafe URL scheme to be rejected")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionTabsError, .unsafeNavigationScheme)
        }

        let updated = try await service.update(
            created.id,
            url: try XCTUnwrap(URL(string: "https://updated.example/")),
            for: extensionID
        )
        XCTAssertEqual(updated.url?.host, "updated.example")
        let reloaded = try await service.reload(updated.id, for: extensionID)
        XCTAssertEqual(reloaded.id, updated.id)
    }

    func testSendMessageRequiresHostAccessAndUsesStableDocumentSender() async throws {
        let host = TabsHost(tabs: [tab(id: 3, url: "https://allowed.example/frame", title: nil, active: true)])
        let broker = FloorpWebExtensionPermissionBroker()
        let service = try FloorpWebExtensionTabsService(
            profileIdentifier: "normal",
            isPrivateBrowsing: false,
            host: host,
            permissionBroker: broker
        )
        let message: FloorpWebExtensionJSONValue = .object(["type": .string("ping")])
        let sourceSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 99,
            documentGeneration: 7,
            url: try XCTUnwrap(URL(string: "https://source.example/page")),
            isMainFrame: true,
            isPrivate: false
        )

        do {
            _ = try await service.sendMessage(
                message,
                to: 3,
                for: extensionID,
                sender: sourceSender
            )
            XCTFail("Expected host access to be required")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionError, .permissionDenied("host_access"))
        }

        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await broker.grant([], requestedHosts: [match], hostAccess: .allRequestedSites, to: extensionID)
        let reply = try await service.sendMessage(
            message,
            to: 3,
            for: extensionID,
            sender: sourceSender
        )

        XCTAssertEqual(reply, .object(["ok": .bool(true)]))
        let deliveredSender = try XCTUnwrap(host.lastSender as? FloorpWebExtensionRuntimeMessageSender)
        XCTAssertEqual(deliveredSender.extensionID, extensionID)
        XCTAssertEqual(deliveredSender.tabID, sourceSender.tabID)
        XCTAssertEqual(deliveredSender.documentGeneration, sourceSender.documentGeneration)
    }

    func testPrivateTabsRequireExplicitPrivateAccessAndHostInvariantsAreClosed() async throws {
        let privateHost = TabsHost(
            profileIdentifier: "private",
            isPrivateBrowsing: true,
            tabs: [tab(id: 8, url: "https://private.example/", title: "Private", active: true, isPrivate: true)]
        )
        let broker = FloorpWebExtensionPermissionBroker()
        let privateService = try FloorpWebExtensionTabsService(
            profileIdentifier: "private",
            isPrivateBrowsing: true,
            host: privateHost,
            permissionBroker: broker
        )
        let url = try XCTUnwrap(URL(string: "https://private.example/new"))
        await broker.grant([.tabs], requestedHosts: [], hostAccess: .denied, to: extensionID)

        do {
            _ = try await privateService.create(url: url, for: extensionID)
            XCTFail("Expected private browsing to require explicit enablement")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionTabsError, .privateBrowsingDenied)
        }

        await broker.grant(
            [.tabs],
            requestedHosts: [],
            hostAccess: .denied,
            privateBrowsingEnabled: true,
            to: extensionID
        )
        let created = try await privateService.create(url: url, for: extensionID)
        XCTAssertEqual(created.url, url)
        let privateTab = try await privateService.get(8, for: extensionID)
        XCTAssertEqual(privateTab.title, "Private")

        let brokenHost = TabsHost(tabs: [
            tab(id: 1, url: "https://one.example/", title: nil, active: true),
            tab(id: 1, url: "https://two.example/", title: nil, active: false)
        ])
        let brokenService = try FloorpWebExtensionTabsService(
            profileIdentifier: "normal",
            isPrivateBrowsing: false,
            host: brokenHost,
            permissionBroker: broker
        )
        do {
            _ = try await brokenService.query(.active, for: extensionID)
            XCTFail("Expected duplicate host tab IDs to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionTabsError, .hostTabInvariantViolation)
        }
    }

    @MainActor
    func testProfileTabsHostUsesLiveWindowManagersAndMessageBridge() async throws {
        let extensionID = self.extensionID
        // `MockProfile` deliberately has a stable local name.  The production
        // host filters by exactly that name, so use it here rather than a
        // synthetic profile identifier which could never own these test tabs.
        let profileIdentifier = "mockaccount"
        let profile = MockProfile(databasePrefix: "tabs-live-\(UUID().uuidString)")
        // `MockProfile.shutdown()` force-closes these stores during
        // deallocation. Open every store it touches while this test still owns
        // its unique prefix so teardown does not lazily create and race their
        // backing files after the tabs have been released.
        _ = profile.database
        _ = profile.logins
        _ = profile.places
        _ = profile.tabs
        let manager = LiveTabsManagerStub(windowUUID: .XCTestDefaultUUID, profile: profile)
        let windowManager = TabsWindowManagerStub(tabManagers: [manager])
        let javaScriptEvaluator = TabsJavaScriptEvaluator()
        let liveHost = FloorpWebExtensionProfileTabsHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            windowManager: windowManager,
            javaScriptEvaluator: javaScriptEvaluator.evaluate
        )
        let broker = FloorpWebExtensionPermissionBroker()
        let hostPattern = try FloorpWebExtensionMatchPattern("<all_urls>")
        await broker.grant([.tabs], requestedHosts: [hostPattern], hostAccess: .allRequestedSites, to: extensionID)
        let service = try FloorpWebExtensionTabsService(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            host: liveHost,
            permissionBroker: broker
        )

        let originalURL = try XCTUnwrap(URL(string: "https://start.example/path"))
        let originalTab = MockTab(
            profile: profile,
            windowUUID: manager.windowUUID
        )
        let originalWebView = MockTabWebView(
            frame: .zero,
            configuration: .init(),
            windowUUID: manager.windowUUID,
            certStore: profile.certStore
        )
        originalWebView.mockTitle = "Start"
        originalTab.webView = originalWebView
        originalTab.loadRequest(URLRequest(url: originalURL))
        manager.tabs = [originalTab]
        manager.selectedTab = originalTab
        var createdTabForCleanup: Tab?
        defer {
            originalTab.close()
            createdTabForCleanup?.close()
            manager.tabs.removeAll()
            manager.selectedTab = nil
        }

        let queried = try await service.query(.active, for: extensionID)
        XCTAssertEqual(queried.first?.url?.host, "start.example")
        XCTAssertEqual(queried.first?.title, "Start")

        let createdURL = try XCTUnwrap(URL(string: "https://created.example/new"))
        let created: FloorpWebExtensionTab
        do {
            created = try await service.create(url: createdURL, for: extensionID)
        } catch {
            return XCTFail("Creating a live tab failed: \(error)")
        }
        XCTAssertEqual(created.url?.host, "created.example")
        XCTAssertEqual(manager.tabs.count, 2)

        let sourceSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: originalTab.floorpWebExtensionTabID,
            documentGeneration: try XCTUnwrap(originalTab.floorpWebExtensionActiveDocumentContext?.documentGeneration),
            url: originalURL,
            isMainFrame: true,
            isPrivate: false
        )

        let reply: FloorpWebExtensionJSONValue?
        do {
            reply = try await service.sendMessage(
                .object(["type": .string("ping")]),
                to: created.id,
                for: extensionID,
                sender: sourceSender
            )
        } catch {
            return XCTFail("Delivering a live tab message failed: \(error)")
        }
        XCTAssertEqual(reply, .object(["reply": .string("ok")]))
        XCTAssertTrue(javaScriptEvaluator.scripts.contains { $0.contains("__floorpWebExtensionDeliverTabsMessage") })

        let updated: FloorpWebExtensionTab
        do {
            updated = try await service.update(
                created.id,
                url: try XCTUnwrap(URL(string: "https://updated.example/next")),
                for: extensionID
            )
        } catch {
            return XCTFail("Updating a live tab failed: \(error)")
        }
        XCTAssertEqual(updated.url?.host, "updated.example")

        let reloaded: FloorpWebExtensionTab
        do {
            reloaded = try await service.reload(updated.id, for: extensionID)
        } catch {
            return XCTFail("Reloading a live tab failed: \(error)")
        }
        XCTAssertEqual(reloaded.id, updated.id)

        guard let liveCreatedTab = manager.tabs.first(where: { $0.floorpWebExtensionTabID == created.id }) else {
            return XCTFail("created tab not found")
        }
        createdTabForCleanup = liveCreatedTab
        let liveCreatedWebView = MockTabWebView(
            frame: .zero,
            configuration: .init(),
            windowUUID: manager.windowUUID,
            certStore: profile.certStore
        )
        liveCreatedTab.webView = liveCreatedWebView
        let updatedURL = try XCTUnwrap(updated.url)
        liveCreatedTab.loadRequest(URLRequest(url: updatedURL))
        liveCreatedTab.prepareFloorpWebExtensionPolicy(for: liveCreatedWebView, navigationURL: updatedURL)

        // A tab may navigate after the API service snapshots it but before
        // JavaScript is delivered.  The host must reject that stale generation
        // instead of retargeting the message to the new document.
        let staleContext = try XCTUnwrap(liveCreatedTab.floorpWebExtensionActiveDocumentContext)
        let staleURL = try XCTUnwrap(URL(string: "https://stale.example/after-update"))
        liveCreatedTab.loadRequest(URLRequest(url: staleURL))
        liveCreatedTab.prepareFloorpWebExtensionPolicy(for: liveCreatedWebView, navigationURL: staleURL)
        let staleSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: staleContext.tabID,
            documentGeneration: staleContext.documentGeneration,
            url: staleContext.url,
            isMainFrame: true,
            isPrivate: staleContext.isPrivate
        )
        do {
            _ = try await liveHost.deliverMessage(
                .object(["type": .string("stale")]),
                sender: staleSender,
                to: staleContext
            )
            XCTFail("Expected stale tab document delivery to be rejected")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionTabsError, .hostTabInvariantViolation)
        }
    }

    private func tab(
        id: Int,
        url: String,
        title: String?,
        active: Bool,
        isPrivate: Bool = false
    ) -> FloorpWebExtensionHostTab {
        FloorpWebExtensionHostTab(
            context: .init(
                tabID: id,
                documentGeneration: UInt64(id * 10),
                url: URL(string: url)!,
                isPrivate: isPrivate
            ),
            title: title,
            isActive: active
        )
    }
}

@MainActor
private final class TabsHost: FloorpWebExtensionTabsHostAdapting {
    let profileIdentifier: String
    let isPrivateBrowsing: Bool
    private var tabs: [FloorpWebExtensionHostTab]
    private var nextID = 100
    private(set) var lastSender: (any FloorpWebExtensionMessageSender)?

    init(profileIdentifier: String = "normal", isPrivateBrowsing: Bool = false, tabs: [FloorpWebExtensionHostTab]) {
        self.profileIdentifier = profileIdentifier
        self.isPrivateBrowsing = isPrivateBrowsing
        self.tabs = tabs
    }

    func tabsSnapshot() -> [FloorpWebExtensionHostTab] {
        tabs
    }

    func createTab(url: URL, makeActive: Bool) throws -> FloorpWebExtensionHostTab {
        if makeActive {
            tabs = tabs.map { .init(context: $0.context, title: $0.title, isActive: false) }
        }
        let tab = FloorpWebExtensionHostTab(
            context: .init(tabID: nextID, documentGeneration: UInt64(nextID * 10), url: url, isPrivate: isPrivateBrowsing),
            title: nil,
            isActive: makeActive
        )
        nextID += 1
        tabs.append(tab)
        return tab
    }

    func updateTab(id: Int, url: URL) throws -> FloorpWebExtensionHostTab {
        guard let index = tabs.firstIndex(where: { $0.context.tabID == id }) else {
            throw FloorpWebExtensionTabsError.tabNotFound(id)
        }
        let previous = tabs[index]
        let updated = FloorpWebExtensionHostTab(
            context: .init(
                tabID: previous.context.tabID,
                documentGeneration: previous.context.documentGeneration + 1,
                url: url,
                isPrivate: previous.context.isPrivate
            ),
            title: previous.title,
            isActive: previous.isActive
        )
        tabs[index] = updated
        return updated
    }

    func reloadTab(id: Int) throws -> FloorpWebExtensionHostTab {
        guard let tab = tabs.first(where: { $0.context.tabID == id }) else {
            throw FloorpWebExtensionTabsError.tabNotFound(id)
        }
        return tab
    }

    func deliverMessage(
        _ message: FloorpWebExtensionJSONValue,
        sender: any FloorpWebExtensionMessageSender,
        to tab: FloorpWebExtensionTabContext
    ) async throws -> FloorpWebExtensionJSONValue? {
        lastSender = sender
        return .object(["ok": .bool(true)])
    }
}

@MainActor
private final class LiveTabsManagerStub: MockTabManager {
    private let profile: Profile
    private let documentLogger = DocumentLogger(logger: MockLogger())

    init(windowUUID: WindowUUID, profile: Profile) {
        self.profile = profile
        super.init(windowUUID: windowUUID)
    }

    override func addTab(_ request: URLRequest?, afterTab: Tab?, zombie: Bool, isPrivate: Bool) -> Tab {
        let tab = MockTab(
            profile: profile,
            isPrivate: isPrivate,
            windowUUID: windowUUID,
            documentLogger: documentLogger
        )
        let webView = MockTabWebView(
            frame: .zero,
            configuration: .init(),
            windowUUID: windowUUID,
            certStore: profile.certStore
        )
        tab.webView = webView
        if let request {
            tab.loadRequest(request)
            webView.loadedURL = request.url
        }
        tabs.append(tab)
        selectedTab = tab
        return tab
    }

    override func selectTab(_ tab: Tab?, previous: Tab?, immediatePreservation: Bool) {
        selectedTab = tab
        super.selectTab(tab, previous: previous, immediatePreservation: immediatePreservation)
    }
}

private final class TabsWindowManagerStub: WindowManager {
    private let tabManagers: [TabManager]

    init(tabManagers: [TabManager]) {
        self.tabManagers = tabManagers
    }

    var windows: [WindowUUID: AppWindowInfo] {
        Dictionary(uniqueKeysWithValues: tabManagers.map { manager in
            (manager.windowUUID, AppWindowInfo(tabManager: manager, sceneCoordinator: nil))
        })
    }

    func newBrowserWindowConfigured(_ windowInfo: AppWindowInfo, uuid: WindowUUID) {}
    func tabManager(for windowUUID: WindowUUID) -> TabManager { tabManagers.first! }
    func allWindowTabManagers() -> [TabManager] { tabManagers }
    func allWindowUUIDs(includingReserved: Bool) -> [WindowUUID] { Array(windows.keys) }
    func windowWillClose(uuid: WindowUUID) {}
    func reserveNextAvailableWindowUUID(isIpad: Bool) -> ReservedWindowUUID { .init(uuid: .XCTestDefaultUUID, isNew: false) }
    func postWindowEvent(event: WindowEvent, windowUUID: WindowUUID) {}
    func performMultiWindowAction(_ action: MultiWindowAction) {}
    func window(for tab: TabUUID) -> WindowUUID? { nil }
    func windowExists(uuid: WindowUUID) -> Bool { windows[uuid] != nil }
}

@MainActor
private final class TabsJavaScriptEvaluator {
    private(set) var scripts = [String]()

    func evaluate(
        _ webView: WKWebView,
        script: String,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        _ = webView
        _ = contentWorld
        scripts.append(script)
        return "{\"reply\":\"ok\"}"
    }
}
