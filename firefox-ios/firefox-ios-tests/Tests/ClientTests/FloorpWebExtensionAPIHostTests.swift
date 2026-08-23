// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionAPIHostTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "api-host-fixture")!

    func testAuthenticatedNativeSubsetIsPermissionAndProfileScoped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = [
            "_locales/en/messages.json": #"{"greeting":{"message":"Hello $1"}}"#
        ]
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-host-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en-US"]
        ) { _, source in
            resources[source.path]
        }
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.storage, .alarms],
                requestedHosts: [],
                normalHostAccess: .denied
            ),
            defaultLocale: "en"
        )
        let sender = testSender()

        _ = try await host.dispatch(
            operation: "storage.local.set",
            payload: try payload(["items": ["theme": "dark", "count": 2]]),
            sender: sender
        )
        let storedPayload = try await host.dispatch(
            operation: "storage.local.get",
            payload: try payload(["keys": ["theme", "count"]]),
            sender: sender
        )
        let stored = try XCTUnwrap(storedPayload)
        XCTAssertEqual(
            try stored.decode([String: FloorpWebExtensionJSONValue].self),
            ["theme": .string("dark"), "count": .number(2)]
        )

        let localizedPayload = try await host.dispatch(
            operation: "i18n.getMessage",
            payload: try payload(["name": "greeting", "substitutions": ["Floorp"]]),
            sender: sender
        )
        let localized = try XCTUnwrap(localizedPayload)
        XCTAssertEqual(try localized.decode(ValueResponse.self).value, "Hello Floorp")

        _ = try await host.dispatch(
            operation: "alarms.create",
            payload: try payload([
                "name": "refresh",
                "delayInMinutes": 1,
                "periodInMinutes": 1
            ]),
            sender: sender
        )
        let alarmNames = await host.alarms.alarms(for: extensionID).map(\.name)
        XCTAssertEqual(alarmNames, ["refresh"])

        _ = try await host.dispatch(
            operation: "action.setTitle",
            payload: try payload(["value": "Fixture action"]),
            sender: sender
        )
        let actionTitle = await host.actions.state(for: extensionID).title
        XCTAssertEqual(actionTitle, "Fixture action")

        let privateSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: sender.tabID,
            documentGeneration: sender.documentGeneration,
            url: sender.url,
            isMainFrame: true,
            isPrivate: true
        )
        do {
            _ = try await host.dispatch(
                operation: "storage.local.get",
                payload: try payload(["keys": NSNull()]),
                sender: privateSender
            )
            XCTFail("Expected cross-profile API use to fail")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
    }

    func testDeactivateClearsStoresAndRevokesEveryOperation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-cleanup-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage, .alarms]),
            defaultLocale: "en"
        )
        let sender = testSender()
        _ = try await host.dispatch(
            operation: "storage.session.set",
            payload: try payload(["items": ["token": "ephemeral"]]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "action.setBadgeText",
            payload: try payload(["value": "4"]),
            sender: sender
        )

        await host.deactivate(extensionID)

        let localValues = try await host.storage.values(for: extensionID, in: .local)
        let sessionValues = try await host.storage.values(for: extensionID, in: .session)
        let alarms = await host.alarms.alarms(for: extensionID)
        let action = await host.actions.state(for: extensionID)
        XCTAssertTrue(localValues.isEmpty)
        XCTAssertTrue(sessionValues.isEmpty)
        XCTAssertTrue(alarms.isEmpty)
        XCTAssertEqual(action, .init())
        do {
            _ = try await host.dispatch(
                operation: "i18n.getUILanguage",
                payload: try payload([String: String]()),
                sender: sender
            )
            XCTFail("Expected a deactivated package to lose its bridge capabilities")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
    }

    func testTabsSendMessageForwardsAuthenticatedSourceSender() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = FloorpWebExtensionTabContext(
            tabID: 12,
            documentGeneration: 3,
            url: try XCTUnwrap(URL(string: "https://target.example/document")),
            isPrivate: false
        )
        let tabsHost = APIHostTabsHost(
            profileIdentifier: "api-host-tabs-profile",
            tab: target
        )
        let permissionBroker = FloorpWebExtensionPermissionBroker()
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-host-tabs-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: FloorpWebExtensionAlarmEventHost(),
            permissionBroker: permissionBroker,
            tabsHost: tabsHost
        )
        let hostPattern = try FloorpWebExtensionMatchPattern("https://target.example/*")
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.tabs],
                requestedHosts: [hostPattern],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en"
        )
        let sourceSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 73,
            documentGeneration: 8,
            url: try XCTUnwrap(URL(string: "https://source.example/frame")),
            isMainFrame: false,
            isPrivate: false
        )

        _ = try await host.dispatch(
            operation: "tabs.sendMessage",
            payload: try payload([
                "tabId": target.tabID,
                "message": ["kind": "ping"],
                "options": [:]
            ]),
            sender: sourceSender
        )

        let deliveredSender = try XCTUnwrap(tabsHost.lastSender as? FloorpWebExtensionRuntimeMessageSender)
        XCTAssertEqual(deliveredSender, sourceSender)
    }

    func testWebKitBootstrapUsesNativeStorageAndI18nThroughIsolatedWorld() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-webkit-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"]
        ) { _, source in
            source.path == "_locales/en/messages.json"
                ? #"{"hello":{"message":"Hello"}}"#
                : nil
        }
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage]),
            defaultLocale: "en"
        )
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: host)
        let configuration = WKWebViewConfiguration()
        let tab = FloorpWebExtensionTabContext(
            tabID: 73,
            documentGeneration: 2,
            url: URL(string: "https://allowed.example/api")!,
            isPrivate: false
        )
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { url, _, trustedTab in
                url.host == "allowed.example" && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>api</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)
        let contentWorld = WKContentWorld.world(
            name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID)
        )

        let result = try await webView.callAsyncJavaScript(
            """
            await browser.storage.local.set({enabled: true});
            const values = await browser.storage.local.get("enabled");
            const message = await browser.i18n.getMessage("hello");
            return {enabled: values.enabled, message};
            """,
            contentWorld: contentWorld
        ) as? [String: Any]

        XCTAssertEqual(result?["enabled"] as? Bool, true)
        XCTAssertEqual(result?["message"] as? String, "Hello")
        let pageWorldStorage = try await webView.callAsyncJavaScript(
            "return globalThis.browser?.storage",
            contentWorld: .page
        )
        XCTAssertNil(pageWorldStorage)
    }

    func testRuntimeMetadataURLAndReloadStayBoundToActivePackageGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = APIHostStage3Recorder()
        let rawManifest = Data(#"{"manifest_version":3,"name":"Runtime Fixture","version":"1.0"}"#.utf8)
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-runtime-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: .init(),
            runtimeReloader: { extensionID in
                recorder.reloadedExtensionIDs.append(extensionID)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(),
            defaultLocale: "en",
            rawManifest: rawManifest,
            packageGeneration: "generation-1",
            resourcePaths: ["manifest.json", "images/icon.png"]
        )
        let sender = FloorpWebExtensionPageRuntimeMessageSender(
            extensionID: extensionID,
            profileKey: host.profileKey,
            packageGeneration: "generation-1",
            originHost: "page-runtime-fixture",
            surface: .options
        )

        let optionalIDPayload = try await host.dispatch(
            operation: "runtime.id",
            payload: try payload([String: String]()),
            sender: sender
        )
        let idPayload = try XCTUnwrap(optionalIDPayload)
        XCTAssertEqual(try idPayload.decode(ValueResponse.self).value, extensionID.rawValue)

        let optionalManifestPayload = try await host.dispatch(
            operation: "runtime.getManifest",
            payload: try payload([String: String]()),
            sender: sender
        )
        let manifestPayload = try XCTUnwrap(optionalManifestPayload)
        XCTAssertEqual(
            try manifestPayload.decode(RuntimeManifestResponse.self),
            .init(manifest_version: 3, name: "Runtime Fixture", version: "1.0")
        )

        let optionalURLPayload = try await host.dispatch(
            operation: "runtime.getURL",
            payload: try payload(["path": "images/icon.png"]),
            sender: sender
        )
        let urlPayload = try XCTUnwrap(optionalURLPayload)
        XCTAssertEqual(
            try urlPayload.decode(ValueResponse.self).value,
            "floorp-extension://page-runtime-fixture/images/icon.png"
        )
        _ = try await host.dispatch(
            operation: "runtime.reload",
            payload: try payload([String: String]()),
            sender: sender
        )
        XCTAssertEqual(recorder.reloadedExtensionIDs, [extensionID])

        do {
            _ = try await host.dispatch(
                operation: "runtime.getURL",
                payload: try payload(["path": "images/icon.png"]),
                sender: testSender()
            )
            XCTFail("A web tab has no package scheme authority")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unsupportedOperation)
        }
    }

    func testPermissionsRequestNeedsTrustedConsentAndPersistsBeforeExposure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = APIHostStage3Recorder()
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let broker = FloorpWebExtensionPermissionBroker()
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-permissions-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: broker,
            permissionRequestAuthorizer: { request in
                recorder.permissionRequests.append(request)
                return true
            },
            permissionMutationHandler: { snapshot, _ in
                recorder.persistedPermissions.append(snapshot)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.storage],
                requestedHosts: [allowedHost],
                normalHostAccess: .denied
            ),
            defaultLocale: "en",
            declaredPermissions: [.storage, .scripting],
            declaredHosts: [allowedHost]
        )

        let requestPayload = try payload([
            "permissions": ["scripting"],
            "origins": ["https://allowed.example/*"]
        ])
        let optionalGranted = try await host.dispatch(
            operation: "permissions.request",
            payload: requestPayload,
            sender: testSender()
        )
        let granted = try XCTUnwrap(optionalGranted)
        XCTAssertTrue(try granted.decode(BoolValueResponse.self).value)
        XCTAssertEqual(recorder.permissionRequests.count, 1)
        XCTAssertEqual(recorder.persistedPermissions.count, 1)

        let optionalContains = try await host.dispatch(
            operation: "permissions.contains",
            payload: requestPayload,
            sender: testSender()
        )
        let contains = try XCTUnwrap(optionalContains)
        XCTAssertTrue(try contains.decode(BoolValueResponse.self).value)

        let optionalRemoved = try await host.dispatch(
            operation: "permissions.remove",
            payload: requestPayload,
            sender: testSender()
        )
        let removed = try XCTUnwrap(optionalRemoved)
        XCTAssertTrue(try removed.decode(BoolValueResponse.self).value)
        XCTAssertEqual(recorder.persistedPermissions.count, 2)

        let failClosedHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-permissions-fail-closed",
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("fail-closed", isDirectory: true),
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await failClosedHost.activate(
            extensionID: extensionID,
            grants: .init(
                requestedHosts: [allowedHost],
                normalHostAccess: .denied
            ),
            defaultLocale: "en",
            declaredPermissions: [.scripting],
            declaredHosts: [allowedHost]
        )
        do {
            _ = try await failClosedHost.dispatch(
                operation: "permissions.request",
                payload: requestPayload,
                sender: testSender()
            )
            XCTFail("Permission expansion without a trusted consent presenter must fail")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .permissionDenied)
        }
    }

    func testStage3ScriptingAndDNRSurfaceUsesCoordinatorTransactions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "api-stage3-\(UUID().uuidString)"
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: APIHostRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: { _, source in
                guard source.path == "registered.js" else {
                    throw FloorpWebExtensionError.unsupported("missing fixture resource")
                }
                return "globalThis.registeredFixture = true;"
            }
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await coordinator.grantPermissions(
            [.scripting, .declarativeNetRequest],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        let configuredDNR = try await checkedStage("configure DNR") {
            try await coordinator.configureDNR(for: self.extensionID)
        }
        XCTAssertTrue(configuredDNR)
        let tab = FloorpWebExtensionTabContext(
            tabID: 301,
            documentGeneration: 8,
            url: URL(string: "https://allowed.example/stage3")!,
            isPrivate: false
        )
        let webView = WKWebView(frame: .zero, configuration: .init())
        webView.loadHTMLString("<html><head></head><body>stage3</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, source in
                source.path == "fixture.css" ? ".fixture { display: none; }" : nil
            },
            alarmEvents: .init(),
            permissionBroker: .init(),
            liveScriptingTargetResolver: { tabID in
                guard tabID == tab.tabID else { throw FloorpWebExtensionTabsError.tabNotFound(tabID) }
                return .init(tab: tab, webView: webView)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.scripting, .declarativeNetRequest],
                requestedHosts: [allowedHost],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en",
            declaredPermissions: [.scripting, .declarativeNetRequest],
            declaredHosts: [allowedHost],
            resourcePaths: ["registered.js", "fixture.css"]
        )

        _ = try await checkedStage("register content script") {
            try await host.dispatch(
                operation: "scripting.registerContentScripts",
                payload: try self.payload(["scripts": [[
                    "id": "runtime-script",
                    "matches": ["https://allowed.example/*"],
                    "js": ["registered.js"],
                    "persistAcrossSessions": false
                ]]]),
                sender: self.testSender()
            )
        }
        let optionalRegisteredPayload = try await checkedStage("get registered content scripts") {
            try await host.dispatch(
                operation: "scripting.getRegisteredContentScripts",
                payload: try self.payload(["filter": ["ids": ["runtime-script"]]]),
                sender: self.testSender()
            )
        }
        let registeredPayload = try XCTUnwrap(optionalRegisteredPayload)
        let registered = try registeredPayload.decode([RegisteredScriptView].self)
        XCTAssertEqual(registered.map(\.id), ["runtime-script"])
        XCTAssertEqual(registered.first?.js, ["registered.js"])

        let optionalInsertedPayload = try await checkedStage("insert CSS") {
            try await host.dispatch(
                operation: "scripting.insertCSS",
                payload: try self.payload([
                    "target": ["tabId": tab.tabID, "frameIds": [0]],
                    "files": ["fixture.css"]
                ]),
                sender: self.testSender()
            )
        }
        let insertedPayload = try XCTUnwrap(optionalInsertedPayload)
        let handles = try insertedPayload.decode(CSSHandlesView.self).handles
        XCTAssertEqual(handles.count, 1)
        _ = try await checkedStage("remove CSS") {
            try await host.dispatch(
                operation: "scripting.removeCSS",
                payload: try self.payload([
                    "target": ["tabId": tab.tabID, "frameIds": [0]],
                    "handles": handles
                ]),
                sender: self.testSender()
            )
        }

        _ = try await checkedStage("update dynamic DNR") {
            try await host.dispatch(
                operation: "declarativeNetRequest.updateDynamicRules",
                payload: try self.payload([
                    "addRules": [[
                        "id": 91,
                        "priority": 1,
                        "action": ["type": "block"],
                        "condition": ["urlFilter": "tracker.example"]
                    ]],
                    "removeRuleIds": []
                ]),
                sender: self.testSender()
            )
        }
        let optionalDynamicPayload = try await checkedStage("get dynamic DNR") {
            try await host.dispatch(
                operation: "declarativeNetRequest.getDynamicRules",
                payload: try self.payload([String: String]()),
                sender: self.testSender()
            )
        }
        let dynamicPayload = try XCTUnwrap(optionalDynamicPayload)
        XCTAssertEqual(try dynamicPayload.decode([DNRRuleView].self).map(\.id), [91])

        let optionalRegexPayload = try await checkedStage("check DNR regex") {
            try await host.dispatch(
                operation: "declarativeNetRequest.isRegexSupported",
                payload: try self.payload(["regex": "tracker\\.example"]),
                sender: self.testSender()
            )
        }
        let regexPayload = try XCTUnwrap(optionalRegexPayload)
        XCTAssertTrue(try regexPayload.decode(RegexSupportView.self).isSupported)
        let optionalLimitsPayload = try await checkedStage("get DNR limits") {
            try await host.dispatch(
                operation: "declarativeNetRequest.getLimits",
                payload: try self.payload([String: String]()),
                sender: self.testSender()
            )
        }
        let limitsPayload = try XCTUnwrap(optionalLimitsPayload)
        XCTAssertEqual(
            try limitsPayload.decode(FloorpWebExtensionDNRLimits.self).maxDynamicRules,
            FloorpWebExtensionDNRLimits().maxDynamicRules
        )

        do {
            _ = try await host.dispatch(
                operation: "scripting.executeScript",
                payload: try payload(["func": "() => 1"]),
                sender: testSender()
            )
            XCTFail("Arbitrary function/code execution must remain unavailable")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unsupportedCodeExecution)
        }
    }

    func testForegroundAlarmDrainIsProfileScopedAndRegistryRemovalTearsDownHost() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let profileIdentifier = "api-alarm-lifecycle-\(UUID().uuidString)"
        let recorder = AlarmEventRecorder()
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: FloorpWebExtensionAlarmEventHost(),
            permissionBroker: FloorpWebExtensionPermissionBroker(),
            alarmEventHandler: { event in
                recorder.events.append(event)
            },
            now: { now }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.alarms]),
            defaultLocale: "en"
        )
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: host)
        FloorpWebExtensionAPIHostRegistry.install(host, messageRuntime: runtime)

        _ = try await host.dispatch(
            operation: "alarms.create",
            payload: try payload(["name": "foreground", "delayInMinutes": 0]),
            sender: testSender()
        )

        await FloorpBootstrapper.drainDueWebExtensionAlarms(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: true,
            now: now
        )
        XCTAssertTrue(recorder.events.isEmpty)
        let alarmBeforeNormalDrain = await host.alarms.alarm(named: "foreground", for: extensionID)
        XCTAssertNotNil(alarmBeforeNormalDrain)

        await FloorpBootstrapper.drainDueWebExtensionAlarms(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            now: now
        )
        XCTAssertEqual(recorder.events.map(\.alarm.name), ["foreground"])
        let alarmAfterNormalDrain = await host.alarms.alarm(named: "foreground", for: extensionID)
        XCTAssertNil(alarmAfterNormalDrain)

        await host.deactivate(extensionID)
        await host.alarmEvents.dispatch([.init(
            extensionID: extensionID,
            alarm: .init(name: "after-deactivate", scheduledTime: now),
            deliveredAt: now
        )])
        XCTAssertEqual(
            recorder.events.map(\.alarm.name),
            ["foreground"],
            "deactivation must remove the reviewed alarm-delivery hook"
        )

        await FloorpWebExtensionAPIHostRegistry.removeHost(for: host.profileKey)
        XCTAssertNil(FloorpWebExtensionAPIHostRegistry.host(
            for: profileIdentifier,
            isPrivateBrowsing: false
        ))
    }

    private func payload(_ object: Any) throws -> FloorpWebExtensionMessagePayload {
        try .init(jsonData: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }

    private func testSender() -> FloorpWebExtensionRuntimeMessageSender {
        .init(
            extensionID: extensionID,
            tabID: 73,
            documentGeneration: 2,
            url: URL(string: "https://allowed.example/api")!,
            isMainFrame: true,
            isPrivate: false
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-api-host-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            if !webView.isLoading, webView.url != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the API bridge document")
    }

    private func checkedStage<T>(
        _ stage: String,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            XCTFail("\(stage) failed: \(error)")
            throw error
        }
    }
}

private struct ValueResponse: Decodable {
    let value: String
}

private struct BoolValueResponse: Decodable {
    let value: Bool
}

private struct RuntimeManifestResponse: Decodable, Equatable {
    let manifest_version: Int
    let name: String
    let version: String
}

private struct RegisteredScriptView: Decodable {
    let id: String
    let js: [String]
}

private struct CSSHandlesView: Decodable {
    let handles: [String]
}

private struct RegexSupportView: Decodable {
    let isSupported: Bool
}

private struct DNRRuleView: Decodable {
    let id: Int
}

@MainActor
private final class APIHostStage3Recorder {
    var reloadedExtensionIDs = [FloorpWebExtensionID]()
    var permissionRequests = [FloorpWebExtensionPermissionRequest]()
    var persistedPermissions = [FloorpWebExtensionPermissionSnapshot]()
}

@MainActor
private final class AlarmEventRecorder {
    var events = [FloorpWebExtensionAlarmEvent]()
}

@MainActor
private final class APIHostTabsHost: FloorpWebExtensionTabsHostAdapting {
    let profileIdentifier: String
    let isPrivateBrowsing = false
    private let tab: FloorpWebExtensionTabContext
    private(set) var lastSender: (any FloorpWebExtensionMessageSender)?

    init(profileIdentifier: String, tab: FloorpWebExtensionTabContext) {
        self.profileIdentifier = profileIdentifier
        self.tab = tab
    }

    func tabsSnapshot() -> [FloorpWebExtensionHostTab] {
        [.init(context: tab, title: "Target", isActive: true)]
    }

    func createTab(url: URL, makeActive: Bool) throws -> FloorpWebExtensionHostTab {
        throw FloorpWebExtensionTabsError.hostUnavailable
    }

    func updateTab(id: Int, url: URL) throws -> FloorpWebExtensionHostTab {
        throw FloorpWebExtensionTabsError.hostUnavailable
    }

    func reloadTab(id: Int) throws -> FloorpWebExtensionHostTab {
        throw FloorpWebExtensionTabsError.hostUnavailable
    }

    func deliverMessage(
        _ message: FloorpWebExtensionJSONValue,
        sender: any FloorpWebExtensionMessageSender,
        to tab: FloorpWebExtensionTabContext
    ) async throws -> FloorpWebExtensionJSONValue? {
        guard tab == self.tab else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        lastSender = sender
        return .object(["delivered": .bool(true)])
    }
}

@MainActor
private final class APIHostRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    enum Failure: Error { case compilation }

    private let store: WKContentRuleListStore

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-api-host-rule-lists", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)!
    }

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedContentRuleList
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: Failure.compilation)
                }
            }
        }
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}
