// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

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

        do {
            _ = try await service.sendMessage(message, to: 3, for: extensionID)
            XCTFail("Expected host access to be required")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionError, .permissionDenied("host_access"))
        }

        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await broker.grant([], requestedHosts: [match], hostAccess: .allRequestedSites, to: extensionID)
        let reply = try await service.sendMessage(message, to: 3, for: extensionID)

        XCTAssertEqual(reply, .object(["ok": .bool(true)]))
        XCTAssertEqual(host.lastSender?.extensionID, extensionID)
        XCTAssertEqual(host.lastSender?.tabID, 3)
        XCTAssertEqual(host.lastSender?.documentGeneration, 30)
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
    private(set) var lastSender: FloorpWebExtensionTabMessageSender?

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
        sender: FloorpWebExtensionTabMessageSender,
        to tab: FloorpWebExtensionTabContext
    ) async throws -> FloorpWebExtensionJSONValue? {
        lastSender = sender
        return .object(["ok": .bool(true)])
    }
}
