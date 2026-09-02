// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

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

    func testSuspendPreservesStoresAndPurgeClearsEveryStore() async throws {
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
            operation: "storage.local.set",
            payload: try payload(["items": ["durable": "kept"]]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "storage.session.set",
            payload: try payload(["items": ["token": "ephemeral"]]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "alarms.create",
            payload: try payload(["name": "kept", "delayInMinutes": 5]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "action.setBadgeText",
            payload: try payload(["value": "4"]),
            sender: sender
        )

        await host.suspend(extensionID)

        let localValues = try await host.storage.values(for: extensionID, in: .local)
        let sessionValues = try await host.storage.values(for: extensionID, in: .session)
        let alarms = await host.alarms.alarms(for: extensionID)
        let action = await host.actions.state(for: extensionID)
        XCTAssertEqual(localValues["durable"], .string("kept"))
        XCTAssertEqual(sessionValues["token"], .string("ephemeral"))
        XCTAssertEqual(alarms.map(\.name), ["kept"])
        XCTAssertEqual(action.badgeText, "4")
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

        try await host.purge(extensionID)
        let purgedLocal = try await host.storage.values(for: extensionID, in: .local)
        let purgedSession = try await host.storage.values(for: extensionID, in: .session)
        let purgedAlarms = await host.alarms.alarms(for: extensionID)
        let purgedAction = await host.actions.state(for: extensionID)
        XCTAssertTrue(purgedLocal.isEmpty)
        XCTAssertTrue(purgedSession.isEmpty)
        XCTAssertTrue(purgedAlarms.isEmpty)
        XCTAssertEqual(purgedAction, .init())
    }

    func testPurgeSurfacesDurableStoreFailureAndCanBeRetried() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-cleanup-failure-profile",
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
            operation: "storage.local.set",
            payload: try payload(["items": ["durable": "value"]]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "alarms.create",
            payload: try payload(["name": "retry", "delayInMinutes": 5]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "action.setBadgeText",
            payload: try payload(["value": "1"]),
            sender: sender
        )

        // Replace the alarm registry file with a directory so its atomic
        // persistence fails deterministically after storage cleanup. The
        // host must surface the error and keep the remaining stores retryable.
        let alarmsRegistryURL = directory
            .appendingPathComponent("alarms", isDirectory: true)
            .appendingPathComponent("alarms-v1.json", isDirectory: false)
        try FileManager.default.removeItem(at: alarmsRegistryURL)
        try FileManager.default.createDirectory(at: alarmsRegistryURL, withIntermediateDirectories: false)

        do {
            try await host.purge(self.extensionID)
            XCTFail("Expected alarm persistence failure")
        } catch {
            // The concrete Cocoa error is platform-owned; propagation is the
            // contract under test.
        }
        let localAfterFailure = try await host.storage.values(for: extensionID, in: .local)
        let alarmsAfterFailure = await host.alarms.alarms(for: extensionID)
        let actionAfterFailure = await host.actions.state(for: extensionID)
        XCTAssertTrue(localAfterFailure.isEmpty)
        XCTAssertEqual(alarmsAfterFailure.map(\.name), ["retry"])
        XCTAssertEqual(actionAfterFailure.badgeText, "1")
        do {
            _ = try await host.dispatch(
                operation: "i18n.getUILanguage",
                payload: try self.payload([String: String]()),
                sender: sender
            )
            XCTFail("Expected purge failure to leave the API host suspended")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }

        try FileManager.default.removeItem(at: alarmsRegistryURL)
        try await host.purge(extensionID)
        let alarmsAfterRetry = await host.alarms.alarms(for: extensionID)
        let actionAfterRetry = await host.actions.state(for: extensionID)
        XCTAssertTrue(alarmsAfterRetry.isEmpty)
        XCTAssertEqual(actionAfterRetry, .init())
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
                "options": [
                    "frameId": 0,
                    "documentId": FloorpWebExtensionDocumentIdentity.mainFrameID(for: target)
                ]
            ]),
            sender: sourceSender
        )

        let deliveredSender = try XCTUnwrap(tabsHost.lastSender as? FloorpWebExtensionRuntimeMessageSender)
        XCTAssertEqual(deliveredSender, sourceSender)

        do {
            _ = try await host.dispatch(
                operation: "tabs.sendMessage",
                payload: try payload([
                    "tabId": target.tabID,
                    "message": ["kind": "stale"],
                    "options": ["documentId": "stale-document"]
                ]),
                sender: sourceSender
            )
            XCTFail("Expected a stale document target to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionTabsError, .messageDeliveryFailed)
        }
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
            defaultLocale: "en",
            rawManifest: Data(#"{"manifest_version":3,"name":"WebKit Fixture","version":"1.0"}"#.utf8),
            packageGeneration: "webkit-bootstrap",
            resourcePaths: ["icons/darkreader.png"]
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
            await browser.storage.sync.set({theme: "dark"});
            const sync = await new Promise((resolve) => {
              chrome.storage.sync.get({theme: "light", firstRun: true}, resolve);
            });
            const message = chrome.i18n.getMessage("hello");
            const language = await new Promise((resolve) => chrome.i18n.getUILanguage(resolve));
            const manifest = chrome.runtime.getManifest();
            await chrome.action.setIcon({path: {16: "icons/darkreader.png", 64: "icons/darkreader.png"}});
            return {
              enabled: values.enabled,
              syncTheme: sync.theme,
              syncFirstRun: sync.firstRun,
              message,
              language,
              manifestName: manifest.name
            };
            """,
            contentWorld: contentWorld
        ) as? [String: Any]

        XCTAssertEqual(result?["enabled"] as? Bool, true)
        XCTAssertEqual(result?["syncTheme"] as? String, "dark")
        XCTAssertEqual(result?["syncFirstRun"] as? Bool, true)
        XCTAssertEqual(result?["message"] as? String, "Hello")
        XCTAssertEqual(result?["language"] as? String, "en")
        XCTAssertEqual(result?["manifestName"] as? String, "WebKit Fixture")
        let action = await host.actions.state(for: extensionID)
        XCTAssertEqual(action.icon?.path, "icons/darkreader.png")
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
        let staleSender = FloorpWebExtensionPageRuntimeMessageSender(
            extensionID: extensionID,
            profileKey: host.profileKey,
            packageGeneration: "generation-stale",
            originHost: "page-runtime-fixture",
            surface: .options
        )
        do {
            _ = try await host.dispatch(
                operation: "runtime.getManifest",
                payload: try payload([String: String]()),
                sender: staleSender
            )
            XCTFail("A stale package generation must lose every API operation")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
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

    func testBackgroundRuntimeFetchStreamsLargeAuthorizedResponse() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedURL = try XCTUnwrap(URL(string: "https://styles.example/site.css"))
        let expectedBody = Data((0..<70_000).map { UInt8($0 % 251) })
        let hostPattern = try FloorpWebExtensionMatchPattern("https://styles.example/*")
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-runtime-fetch-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: .init(),
            networkFetchTransport: { url in
                guard url == requestedURL else {
                    throw FloorpWebExtensionMessageError.handlerFailed
                }
                return .init(
                    url: url,
                    statusCode: 200,
                    headers: [
                        "Content-Type": "text/css; charset=utf-8",
                        "Set-Cookie": "must-not-cross-the-bridge=true"
                    ],
                    body: expectedBody
                )
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                requestedHosts: [hostPattern],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en",
            packageGeneration: "network-fetch-generation"
        )
        let sender = FloorpWebExtensionBackgroundRuntimeMessageSender(
            extensionID: extensionID,
            profileKey: host.profileKey,
            packageGeneration: "network-fetch-generation",
            originHost: "network-fetch-fixture"
        )

        let initialPayload = try await host.dispatch(
            operation: "runtime.fetch",
            payload: try payload(["url": requestedURL.absoluteString, "method": "GET"]),
            sender: sender
        )
        let initial = try XCTUnwrap(initialPayload).decode(RuntimeFetchResponseView.self)
        XCTAssertEqual(initial.status, 200)
        XCTAssertEqual(initial.headers["Content-Type"], "text/css; charset=utf-8")
        XCTAssertNil(initial.headers["Set-Cookie"])
        XCTAssertFalse(initial.done)

        var reconstructedBody = try XCTUnwrap(Data(base64Encoded: initial.bodyBase64))
        let fetchID = try XCTUnwrap(initial.fetchId)
        var done = initial.done
        while !done {
            let chunkPayload = try await host.dispatch(
                operation: "runtime.fetch.read",
                payload: try payload(["fetchId": fetchID]),
                sender: sender
            )
            let chunk = try XCTUnwrap(chunkPayload).decode(RuntimeFetchChunkResponseView.self)
            reconstructedBody.append(try XCTUnwrap(Data(base64Encoded: chunk.bodyBase64)))
            done = chunk.done
        }
        XCTAssertEqual(reconstructedBody, expectedBody)

        do {
            _ = try await host.dispatch(
                operation: "runtime.fetch",
                payload: try payload(["url": requestedURL.absoluteString, "method": "GET"]),
                sender: testSender()
            )
            XCTFail("A tab content script must not own native network authority")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unsupportedOperation)
        }

        do {
            _ = try await host.dispatch(
                operation: "runtime.fetch",
                payload: try payload([
                    "url": "https://unauthorized.example/site.css",
                    "method": "GET"
                ]),
                sender: sender
            )
            XCTFail("Background fetch must remain within durable host access")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .permissionDenied)
        }
    }

    func testPermissionsRequestNeedsTrustedConsentAndPersistsBeforeExposure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = APIHostStage3Recorder()
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let declaredWildcardHost = try FloorpWebExtensionMatchPattern("https://*.example/*")
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
            permissionMutationHandler: { snapshot, _, _ in
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
            declaredPermissions: [.storage],
            optionalPermissions: [.scripting],
            optionalHosts: [declaredWildcardHost]
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
        XCTAssertEqual(recorder.permissionRequests.first?.origins, [allowedHost])
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

    func testPermissionConsentCannotCrossPackageGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorizationGate = APIHostPermissionAuthorizationGate()
        let recorder = APIHostStage3Recorder()
        let broker = FloorpWebExtensionPermissionBroker()
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-permissions-generation-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: broker,
            permissionRequestAuthorizer: { request in
                await authorizationGate.authorize(request)
            },
            permissionMutationHandler: { snapshot, _, _ in
                recorder.persistedPermissions.append(snapshot)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage]),
            defaultLocale: "en",
            declaredPermissions: [.storage],
            optionalPermissions: [.scripting],
            packageGeneration: "permission-generation-one"
        )
        let staleSender = FloorpWebExtensionPageRuntimeMessageSender(
            extensionID: extensionID,
            profileKey: host.profileKey,
            packageGeneration: "permission-generation-one",
            originHost: "permission-generation-origin",
            surface: .options
        )
        let pendingRequest = Task { @MainActor in
            do {
                return try await host.dispatch(
                    operation: "permissions.request",
                    payload: try self.payload(["permissions": ["scripting"]]),
                    sender: staleSender
                )
            } catch {
                authorizationGate.recordDispatchFailure(error)
                throw error
            }
        }

        try await waitForPermissionAuthorization(
            authorizationGate,
            pendingRequest: pendingRequest
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage]),
            defaultLocale: "en",
            declaredPermissions: [.storage],
            optionalPermissions: [.scripting],
            packageGeneration: "permission-generation-two"
        )
        authorizationGate.resolve(true)

        do {
            _ = try await pendingRequest.value
            XCTFail("Consent from a stale package generation must not mutate the replacement package")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
        XCTAssertTrue(recorder.persistedPermissions.isEmpty)
        let current = await broker.snapshot(for: extensionID)
        XCTAssertEqual(current.apiPermissions, [.storage])
    }

    // swiftlint:disable:next function_body_length
    func testPermissionConsentCannotCrossContentDocumentGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "api-permissions-document-\(UUID().uuidString)"
        let authorizationGate = APIHostPermissionAuthorizationGate()
        let recorder = APIHostStage3Recorder()
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: APIHostRuleListCompiler()),
            scriptResourceLoader: { _, source in
                guard source.path == "content.js" else {
                    throw FloorpWebExtensionError.unsupported("missing content script")
                }
                return "globalThis.floorpPermissionFixture = true;"
            }
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        await coordinator.grantPermissions(
            [.storage, .scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        try await coordinator.registerScripts(
            [
                .init(
                    id: "permission-document",
                    matches: [allowedHost],
                    javaScript: [try .init("content.js")],
                    runAt: .documentStart
                )
            ],
            for: extensionID
        )
        let initialTab = FloorpWebExtensionTabContext(
            tabID: 407,
            documentGeneration: 1,
            url: URL(string: "https://allowed.example/first")!,
            isPrivate: false
        )
        let targetBox = APIHostLiveTargetBox(tab: initialTab)
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: .init(),
            permissionRequestAuthorizer: { request in
                await authorizationGate.authorize(request)
            },
            permissionMutationHandler: { snapshot, _, _ in
                recorder.persistedPermissions.append(snapshot)
            },
            liveScriptingTargetResolver: { tabID in
                guard tabID == targetBox.tab.tabID else {
                    throw FloorpWebExtensionTabsError.tabNotFound(tabID)
                }
                return .init(tab: targetBox.tab, webView: targetBox.webView)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.storage],
                requestedHosts: [allowedHost],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en",
            declaredPermissions: [.storage],
            declaredHosts: [allowedHost],
            optionalPermissions: [.scripting],
            packageGeneration: "permission-document-generation"
        )
        let sender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: initialTab.tabID,
            documentGeneration: initialTab.documentGeneration,
            url: initialTab.url,
            isMainFrame: true,
            isPrivate: false
        )
        let pendingRequest = Task { @MainActor in
            do {
                return try await host.dispatch(
                    operation: "permissions.request",
                    payload: try self.payload(["permissions": ["scripting"]]),
                    sender: sender
                )
            } catch {
                authorizationGate.recordDispatchFailure(error)
                throw error
            }
        }

        try await waitForPermissionAuthorization(
            authorizationGate,
            pendingRequest: pendingRequest
        )
        targetBox.tab = .init(
            tabID: initialTab.tabID,
            documentGeneration: initialTab.documentGeneration + 1,
            url: URL(string: "https://allowed.example/replaced")!,
            isPrivate: false
        )
        authorizationGate.resolve(true)

        do {
            _ = try await pendingRequest.value
            XCTFail("Consent from a replaced content document must not be persisted")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
        XCTAssertTrue(recorder.persistedPermissions.isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testCSSMutationRevalidatesDocumentGenerationBeforeCommittingHandleOrDOM() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "api-css-document-\(UUID().uuidString)"
        let mutationGate = APIHostDynamicCSSMutationGate()
        let cssRegistry = FloorpWebExtensionCSSRegistry(nextHandleSuffix: { "stale-document" })
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: APIHostRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: { _, _ in
                throw FloorpWebExtensionError.unsupported("unused CSS fixture resource")
            },
            cssRegistry: cssRegistry,
            beforeDynamicCSSMutation: {
                await mutationGate.checkpoint()
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
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        let initialTab = FloorpWebExtensionTabContext(
            tabID: 408,
            documentGeneration: 17,
            url: URL(string: "https://allowed.example/same-url")!,
            isPrivate: false
        )
        let targetBox = APIHostLiveTargetBox(tab: initialTab)
        targetBox.webView.loadHTMLString(
            "<html><head></head><body>css generation</body></html>",
            baseURL: initialTab.url
        )
        try await waitForLoad(targetBox.webView)

        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil },
            alarmEvents: .init(),
            permissionBroker: .init(),
            liveScriptingTargetResolver: { tabID in
                guard tabID == targetBox.tab.tabID else {
                    throw FloorpWebExtensionTabsError.tabNotFound(tabID)
                }
                return .init(tab: targetBox.tab, webView: targetBox.webView)
            }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.scripting],
                requestedHosts: [allowedHost],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en",
            declaredPermissions: [.scripting],
            declaredHosts: [allowedHost]
        )
        let sender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: initialTab.tabID,
            documentGeneration: initialTab.documentGeneration,
            url: initialTab.url,
            isMainFrame: true,
            isPrivate: false
        )
        let requestPayload = try payload([
            "target": ["tabId": initialTab.tabID, "frameIds": [0]],
            "css": ".must-not-cross-generation { display: none; }"
        ])
        let pendingInsertion = Task { @MainActor in
            try await host.dispatch(
                operation: "scripting.insertCSS",
                payload: requestPayload,
                sender: sender
            )
        }

        await mutationGate.waitUntilReached()
        targetBox.tab = .init(
            tabID: initialTab.tabID,
            documentGeneration: initialTab.documentGeneration + 1,
            url: initialTab.url,
            isPrivate: false
        )
        mutationGate.resume()

        do {
            _ = try await pendingInsertion.value
            XCTFail("CSS authorized for an earlier document generation must fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
        XCTAssertTrue(cssRegistry.activeInsertions(for: extensionID).isEmpty)
        let styleCount = try await targetBox.webView.callAsyncJavaScript(
            "return document.querySelectorAll('style[data-floorp-webextension-css]').length;",
            contentWorld: .page
        ) as? Int
        XCTAssertEqual(styleCount, 0)

        // A rejected insertion must leave neither coordinator quota nor API
        // host tracking behind. Restoring the original generation permits a
        // clean insert/remove round trip using the same deterministic handle.
        targetBox.tab = initialTab
        _ = try await host.dispatch(
            operation: "scripting.insertCSS",
            payload: requestPayload,
            sender: sender
        )
        XCTAssertEqual(cssRegistry.activeInsertions(for: extensionID).count, 1)
        _ = try await host.dispatch(
            operation: "scripting.removeCSS",
            payload: requestPayload,
            sender: sender
        )
        XCTAssertTrue(cssRegistry.activeInsertions(for: extensionID).isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testStage3ScriptingAndDNRSurfaceUsesCoordinatorTransactions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "api-stage3-\(UUID().uuidString)"
        let bridgeAuthorizationSource = try FloorpWebExtensionScriptSource("registered.js")
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
        // A content script only receives the native bridge after a matching
        // isolated-world script has been materialized for the document. Model
        // that production precondition before exercising scripting.* APIs.
        try await coordinator.restoreManifestScripts(
            [.init(
                id: "bridge-authorization",
                matches: [allowedHost],
                javaScript: [bridgeAuthorizationSource]
            )],
            for: extensionID
        )
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
                switch source.path {
                case "fixture.css":
                    return ".fixture { display: none; }"
                case "registered.js":
                    return "globalThis.dynamicPackageFileExecuted = true; return true;"
                default:
                    return nil
                }
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
        let sender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: tab.tabID,
            documentGeneration: tab.documentGeneration,
            url: tab.url,
            isMainFrame: true,
            isPrivate: tab.isPrivate
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
                sender: sender
            )
        }
        let optionalRegisteredPayload = try await checkedStage("get registered content scripts") {
            try await host.dispatch(
                operation: "scripting.getRegisteredContentScripts",
                payload: try self.payload(["filter": ["ids": ["runtime-script"]]]),
                sender: sender
            )
        }
        let registeredPayload = try XCTUnwrap(optionalRegisteredPayload)
        let registered = try registeredPayload.decode([RegisteredScriptView].self)
        XCTAssertEqual(registered.map(\.id), ["runtime-script"])
        XCTAssertEqual(registered.first?.js, ["registered.js"])
        XCTAssertFalse(registered.first?.persistAcrossSessions ?? true)

        let optionalExecutionPayload = try await checkedStage("execute package file") {
            try await host.dispatch(
                operation: "scripting.executeScript",
                payload: try self.payload([
                    "target": ["tabId": tab.tabID, "frameIds": [0]],
                    "files": ["registered.js"],
                    "world": "ISOLATED"
                ]),
                sender: sender
            )
        }
        let executionPayload = try XCTUnwrap(optionalExecutionPayload)
        XCTAssertEqual(
            try executionPayload.decode([ScriptInjectionResultView].self).map(\.frameId),
            [0]
        )
        XCTAssertEqual(
            try executionPayload.decode([ScriptInjectionResultView].self).first?.result,
            true
        )

        let optionalInsertedPayload = try await checkedStage("insert CSS") {
            try await host.dispatch(
                operation: "scripting.insertCSS",
                payload: try self.payload([
                    "target": ["tabId": tab.tabID, "frameIds": [0]],
                    "files": ["fixture.css"]
                ]),
                sender: sender
            )
        }
        XCTAssertNotNil(optionalInsertedPayload)
        _ = try await checkedStage("remove CSS") {
            try await host.dispatch(
                operation: "scripting.removeCSS",
                payload: try self.payload([
                    "target": ["tabId": tab.tabID, "frameIds": [0]],
                    "files": ["fixture.css"]
                ]),
                sender: sender
            )
        }

        do {
            _ = try await host.dispatch(
                operation: "scripting.registerContentScripts",
                payload: try payload(["scripts": [[
                    "id": "implicit-persistence",
                    "matches": ["https://allowed.example/*"],
                    "js": ["registered.js"]
                ]]]),
                sender: sender
            )
            XCTFail("Default persistence must not silently become memory-only without a package store")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionError,
                .unsupported("persistent registered content scripts require a package store")
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
                sender: sender
            )
        }
        let optionalDynamicPayload = try await checkedStage("get dynamic DNR") {
            try await host.dispatch(
                operation: "declarativeNetRequest.getDynamicRules",
                payload: try self.payload([String: String]()),
                sender: sender
            )
        }
        let dynamicPayload = try XCTUnwrap(optionalDynamicPayload)
        XCTAssertEqual(try dynamicPayload.decode([DNRRuleView].self).map(\.id), [91])

        _ = try await checkedStage("ignore nonexistent DNR removal") {
            try await host.dispatch(
                operation: "declarativeNetRequest.updateDynamicRules",
                payload: try self.payload(["removeRuleIds": [999_999]]),
                sender: sender
            )
        }
        do {
            _ = try await host.dispatch(
                operation: "declarativeNetRequest.updateDynamicRules",
                payload: try payload(["addRules": [[
                    "id": 92,
                    "action": ["type": "block"],
                    "condition": [
                        "urlFilter": "over-block.example",
                        "excludedRequestMethods": ["get"]
                    ]
                ]]]),
                sender: sender
            )
            XCTFail("Unsupported DNR condition keys must fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .malformedEnvelope)
        }

        let optionalRegexPayload = try await checkedStage("check DNR regex") {
            try await host.dispatch(
                operation: "declarativeNetRequest.isRegexSupported",
                payload: try self.payload(["regex": "tracker\\.example"]),
                sender: sender
            )
        }
        let regexPayload = try XCTUnwrap(optionalRegexPayload)
        XCTAssertTrue(try regexPayload.decode(RegexSupportView.self).isSupported)
        let optionalCapturingPayload = try await checkedStage("reject unsupported DNR capturing") {
            try await host.dispatch(
                operation: "declarativeNetRequest.isRegexSupported",
                payload: try self.payload([
                    "regex": "(tracker)\\.example",
                    "requireCapturing": true
                ]),
                sender: sender
            )
        }
        let capturingPayload = try XCTUnwrap(optionalCapturingPayload)
        XCTAssertFalse(try capturingPayload.decode(RegexSupportView.self).isSupported)
        let optionalLimitsPayload = try await checkedStage("get DNR limits") {
            try await host.dispatch(
                operation: "declarativeNetRequest.getLimits",
                payload: try self.payload([String: String]()),
                sender: sender
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
                sender: sender
            )
            XCTFail("Arbitrary function/code execution must remain unavailable")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unsupportedCodeExecution)
        }
    }

    func testCuratedCatalogProfileRejectsMutableDNRAPIs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-curated-dnr-\(UUID().uuidString)",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.declarativeNetRequest]),
            defaultLocale: "en",
            declaredPermissions: [.declarativeNetRequest],
            allowsMutableDNR: false
        )
        let sender = testSender()

        for operation in [
            "declarativeNetRequest.getDynamicRules",
            "declarativeNetRequest.updateDynamicRules",
            "declarativeNetRequest.getSessionRules",
            "declarativeNetRequest.updateSessionRules"
        ] {
            do {
                _ = try await host.dispatch(
                    operation: operation,
                    payload: try payload([String: String]()),
                    sender: sender
                )
                XCTFail("\(operation) must be unavailable to a curated catalog package")
            } catch {
                XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unsupportedOperation)
            }
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

    // swiftlint:disable:next function_body_length
    func testMemoryPressureReleasesBothBackgroundsAndPreservesAPIHostState() async throws {
        let normalDirectory = temporaryDirectory()
        let privateDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: normalDirectory)
            try? FileManager.default.removeItem(at: privateDirectory)
        }
        let profileIdentifier = "api-memory-pressure-\(UUID().uuidString)"
        let normalHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: normalDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        let privateHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: true,
            directory: privateDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await normalHost.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage, .alarms]),
            defaultLocale: "en"
        )
        await privateHost.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.alarms]),
            defaultLocale: "en"
        )

        let normalRuntime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: normalHost)
        let privateRuntime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: privateHost)
        let normalRecorder = AlarmEventRecorder()
        let privateRecorder = AlarmEventRecorder()
        var normalFactoryCalls = 0
        var privateFactoryCalls = 0
        normalRuntime.backgroundHost.register(extensionID: extensionID) {
            normalFactoryCalls += 1
            return APIHostAlarmBackgroundHandler(recorder: normalRecorder)
        }
        privateRuntime.backgroundHost.register(extensionID: extensionID) {
            privateFactoryCalls += 1
            return APIHostAlarmBackgroundHandler(recorder: privateRecorder)
        }
        FloorpWebExtensionAPIHostRegistry.install(normalHost, messageRuntime: normalRuntime)
        FloorpWebExtensionAPIHostRegistry.install(privateHost, messageRuntime: privateRuntime)

        let now = Date(timeIntervalSinceReferenceDate: 70_000)
        try await normalRuntime.dispatchAlarmEvent(.init(
            extensionID: extensionID,
            alarm: .init(name: "before-warning", scheduledTime: now),
            deliveredAt: now
        ))
        try await privateRuntime.dispatchAlarmEvent(.init(
            extensionID: extensionID,
            alarm: .init(name: "before-warning", scheduledTime: now),
            deliveredAt: now
        ))
        _ = try await normalHost.dispatch(
            operation: "storage.local.set",
            payload: try payload(["items": ["durable": "kept"]]),
            sender: testSender()
        )
        _ = try await normalHost.dispatch(
            operation: "alarms.create",
            payload: try payload(["name": "kept", "delayInMinutes": 5]),
            sender: testSender()
        )
        _ = try await normalHost.dispatch(
            operation: "action.setBadgeText",
            payload: try payload(["value": "7"]),
            sender: testSender()
        )

        FloorpBootstrapper.releaseWebExtensionBackgroundResources(
            profileIdentifier: profileIdentifier
        )

        XCTAssertTrue(FloorpWebExtensionAPIHostRegistry.host(
            for: profileIdentifier,
            isPrivateBrowsing: false
        ) === normalHost)
        XCTAssertTrue(FloorpWebExtensionAPIHostRegistry.host(
            for: profileIdentifier,
            isPrivateBrowsing: true
        ) === privateHost)
        XCTAssertEqual(
            normalRuntime.backgroundHost.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: false, activationCount: 1, pendingMessageCount: 0)
        )
        XCTAssertEqual(
            privateRuntime.backgroundHost.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: false, activationCount: 1, pendingMessageCount: 0)
        )
        let localValues = try await normalHost.storage.values(for: extensionID, in: .local)
        let alarms = await normalHost.alarms.alarms(for: extensionID)
        let action = await normalHost.actions.state(for: extensionID)
        XCTAssertEqual(
            localValues["durable"],
            .string("kept")
        )
        XCTAssertEqual(alarms.map(\.name), ["kept"])
        XCTAssertEqual(action.badgeText, "7")

        try await normalRuntime.dispatchAlarmEvent(.init(
            extensionID: extensionID,
            alarm: .init(name: "after-warning", scheduledTime: now),
            deliveredAt: now
        ))
        try await privateRuntime.dispatchAlarmEvent(.init(
            extensionID: extensionID,
            alarm: .init(name: "after-warning", scheduledTime: now),
            deliveredAt: now
        ))
        XCTAssertEqual(normalFactoryCalls, 2)
        XCTAssertEqual(privateFactoryCalls, 2)
        XCTAssertEqual(normalRecorder.events.map(\.alarm.name), ["before-warning", "after-warning"])
        XCTAssertEqual(privateRecorder.events.map(\.alarm.name), ["before-warning", "after-warning"])

        await FloorpWebExtensionAPIHostRegistry.removeHost(for: normalHost.profileKey)
        await FloorpWebExtensionAPIHostRegistry.removeHost(for: privateHost.profileKey)
    }

    // swiftlint:disable:next function_body_length
    func testScriptingAPICannotObserveOrMutateManifestContentScripts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "api-manifest-script-isolation-\(UUID().uuidString)"
        let manifestSource = try FloorpWebExtensionScriptSource("manifest.js")
        let dynamicSource = try FloorpWebExtensionScriptSource("dynamic.js")
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: APIHostRuleListCompiler()),
            scriptResourceLoader: { _, source in
                switch source.path {
                case manifestSource.path:
                    return "globalThis.manifestScriptRan = true;"
                case dynamicSource.path:
                    return "globalThis.dynamicScriptRan = true;"
                default:
                    throw FloorpWebExtensionError.unsupported("missing test resource")
                }
            }
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        try await coordinator.restoreManifestScripts(
            [.init(
                id: "manifest.content-script.0",
                matches: [allowedHost],
                javaScript: [manifestSource]
            )],
            for: extensionID
        )

        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.scripting],
                requestedHosts: [allowedHost],
                normalHostAccess: .allRequestedSites
            ),
            defaultLocale: "en",
            declaredPermissions: [.scripting],
            declaredHosts: [allowedHost],
            resourcePaths: [manifestSource.path, dynamicSource.path]
        )

        let sender = testSender()
        _ = try await host.dispatch(
            operation: "scripting.registerContentScripts",
            payload: try payload(["scripts": [[
                // Deliberately reuse the package-owned generated ID. The API
                // namespace must remain independent from manifest ownership.
                "id": "manifest.content-script.0",
                "matches": [allowedHost.original],
                "js": [dynamicSource.path],
                "persistAcrossSessions": false
            ]]]),
            sender: sender
        )

        let optionalDynamicPayload = try await host.dispatch(
            operation: "scripting.getRegisteredContentScripts",
            payload: try payload([:]),
            sender: sender
        )
        let dynamicPayload = try XCTUnwrap(optionalDynamicPayload)
        let dynamicScripts = try dynamicPayload.decode([RegisteredScriptView].self)
        XCTAssertEqual(dynamicScripts.map(\.id), ["manifest.content-script.0"])
        XCTAssertEqual(dynamicScripts.first?.js, [dynamicSource.path])

        _ = try await host.dispatch(
            operation: "scripting.unregisterContentScripts",
            payload: try payload([:]),
            sender: sender
        )
        let optionalAfterUnregisterPayload = try await host.dispatch(
            operation: "scripting.getRegisteredContentScripts",
            payload: try payload([:]),
            sender: sender
        )
        let afterUnregisterPayload = try XCTUnwrap(optionalAfterUnregisterPayload)
        XCTAssertTrue(try afterUnregisterPayload.decode([RegisteredScriptView].self).isEmpty)

        do {
            _ = try await host.dispatch(
                operation: "scripting.updateContentScripts",
                payload: try payload(["scripts": [[
                    "id": "manifest.content-script.0",
                    "allFrames": true
                ]]]),
                sender: sender
            )
            XCTFail("Manifest-owned scripts must not be mutable through scripting.*")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionError,
                .invalidScriptID("manifest.content-script.0")
            )
        }

        let tab = FloorpWebExtensionTabContext(
            tabID: sender.tabID,
            documentGeneration: sender.documentGeneration,
            url: sender.url,
            isPrivate: sender.isPrivate
        )
        let policies = coordinator.preNavigationPolicies(for: tab)
        XCTAssertEqual(policies.count, 1)
        XCTAssertEqual(policies.first?.scriptPolicies.map { $0.source }, [
            "globalThis.manifestScriptRan = true;"
        ])
    }

    // swiftlint:disable:next function_body_length
    func testPersistentScriptFinalWriteWinsBeforePreconstructedReplacementIsPublished() async throws {
        let storeDirectory = temporaryDirectory()
        let apiDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: apiDirectory)
        }
        let extensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.demanding-mv3")!
        let profileIdentifier = "api-script-generation-race-\(UUID().uuidString)"
        let persister = APIHostPausedRegistryPersister()
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: storeDirectory,
            registryPersister: { data, url in
                try persister.persist(data, to: url)
            }
        )
        let hosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let installed = try await store.installBundledPackage(
            at: try checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: .init(
                apiPermissions: [.scripting],
                requestedHosts: hosts,
                normalHostAccess: .allRequestedSites
            )
        )
        let firstManager = FloorpWebExtensionLivePackageManager(store: store) { _, _, _ in }
        try FloorpWebExtensionPackageStoreRegistry.install(store, manager: firstManager)
        defer {
            FloorpWebExtensionPackageStoreRegistry.removeStore(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        // Snapshot the durable file before the old request starts writing.
        // Publishing this preconstructed store must still serialize with and
        // stabilize the later tentative write.
        let replacementStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: storeDirectory
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: APIHostRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: apiDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: store.makeI18nResourceLoader()
        )
        await host.activate(installed)
        let sender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 404,
            documentGeneration: 1,
            url: URL(string: "https://www.fixture.test/page")!,
            isMainFrame: true,
            isPrivate: false
        )

        persister.pauseNextWrite()
        let pending = Task { @MainActor in
            try await host.dispatch(
                operation: "scripting.registerContentScripts",
                payload: try self.payload(["scripts": [[
                    "id": "stale-persistent",
                    "matches": ["https://*.fixture.test/*"],
                    "js": ["content/document-start.js"]
                ]]]),
                sender: sender
            )
        }
        await persister.waitUntilWriteIsPaused()

        let replacementManager = FloorpWebExtensionLivePackageManager(
            store: replacementStore
        ) { _, _, _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            persister.resumeWrite()
        }
        XCTAssertThrowsError(try FloorpWebExtensionPackageStoreRegistry.install(
            replacementStore,
            manager: replacementManager
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .stalePackageComposition
            )
        }

        _ = try await pending.value
        let liveScripts = await coordinator.registeredScripts(for: extensionID)
        XCTAssertEqual(liveScripts.map(\.id), ["stale-persistent"])
        XCTAssertTrue(FloorpWebExtensionPackageStoreRegistry.store(
            for: profileIdentifier,
            isPrivateBrowsing: false
        ) === store)
        let activePackageRecord = await store.installedPackage(for: extensionID)
        let activePackage = try XCTUnwrap(activePackageRecord)
        try await store.updatePersistentRegisteredScripts(
            activePackage.registeredPersistentScripts,
            for: extensionID,
            expectedGeneration: activePackage.generation,
            expectedCurrentScripts: activePackage.registeredPersistentScripts
        )
        let replacementPackageRecord = await replacementStore.installedPackage(for: extensionID)
        let replacementPackage = try XCTUnwrap(replacementPackageRecord)
        XCTAssertTrue(replacementPackage.registeredPersistentScripts.isEmpty)
        let reopenedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: storeDirectory
        )
        let reopenedPackageRecord = await reopenedStore.installedPackage(for: extensionID)
        let reopenedPackage = try XCTUnwrap(reopenedPackageRecord)
        XCTAssertEqual(reopenedPackage.registeredPersistentScripts.map(\.id), ["stale-persistent"])
    }

    private func payload(_ object: Any) throws -> FloorpWebExtensionMessagePayload {
        try .init(jsonData: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }

    private func waitForPermissionAuthorization(
        _ gate: APIHostPermissionAuthorizationGate,
        pendingRequest: Task<FloorpWebExtensionMessagePayload?, Error>
    ) async throws {
        do {
            try await gate.waitUntilRequested()
        } catch {
            // A failed pre-consent sender check or a timeout must not leave
            // the unstructured request task able to enter a continuation
            // after this test has already returned.
            gate.abort()
            pendingRequest.cancel()
            _ = await pendingRequest.result
            throw error
        }
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

    private func checkedInDemandingMV3FixtureDirectory() throws -> URL {
        let fileManager = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let fixturePath = "firefox-ios/Floorp/WebExtensions/Fixtures/demanding-mv3"
        for startingDirectory in [workingDirectory, sourceDirectory] {
            var searchDirectory = startingDirectory.standardizedFileURL
            while true {
                let candidate = searchDirectory.appendingPathComponent(fixturePath, isDirectory: true)
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                let parent = searchDirectory.deletingLastPathComponent()
                guard parent.path != searchDirectory.path else { break }
                searchDirectory = parent
            }
        }
        throw NSError(
            domain: "FloorpWebExtensionAPIHostTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The demanding MV3 fixture was not found."]
        )
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

private struct RuntimeFetchResponseView: Decodable {
    let status: Int
    let headers: [String: String]
    let bodyBase64: String
    let fetchId: String?
    let done: Bool
}

private struct RuntimeFetchChunkResponseView: Decodable {
    let bodyBase64: String
    let done: Bool
}

private struct RegisteredScriptView: Decodable {
    let id: String
    let js: [String]
    let persistAcrossSessions: Bool
}

private struct ScriptInjectionResultView: Decodable {
    let frameId: Int
    let result: Bool?
}

private struct RegexSupportView: Decodable {
    let isSupported: Bool
}

private struct DNRRuleView: Decodable {
    let id: Int
}

private final class APIHostPausedRegistryPersister: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private var pausesNextWrite = false
    private var writeIsPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    func pauseNextWrite() {
        lock.lock()
        pausesNextWrite = true
        lock.unlock()
    }

    func waitUntilWriteIsPaused() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if writeIsPaused {
                lock.unlock()
                continuation.resume()
            } else {
                pauseWaiter = continuation
                lock.unlock()
            }
        }
    }

    func resumeWrite() {
        resumeSemaphore.signal()
    }

    func persist(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldPause = pausesNextWrite
        pausesNextWrite = false
        if shouldPause {
            writeIsPaused = true
        }
        let waiter = shouldPause ? pauseWaiter : nil
        if shouldPause {
            pauseWaiter = nil
        }
        lock.unlock()

        if shouldPause {
            waiter?.resume()
            resumeSemaphore.wait()
        }
        try data.write(to: url, options: [.atomic])
    }
}

@MainActor
private final class APIHostStage3Recorder {
    var reloadedExtensionIDs = [FloorpWebExtensionID]()
    var permissionRequests = [FloorpWebExtensionPermissionRequest]()
    var persistedPermissions = [FloorpWebExtensionPermissionSnapshot]()
}

@MainActor
private final class APIHostPermissionAuthorizationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var dispatchFailure: Error?
    private var isAborted = false

    func authorize(_ request: FloorpWebExtensionPermissionRequest) async -> Bool {
        _ = request
        guard !isAborted else { return false }
        return await withCheckedContinuation { continuation in
            guard !isAborted else {
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
        }
    }

    func waitUntilRequested(timeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while continuation == nil {
            if let dispatchFailure {
                throw dispatchFailure
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw APIHostPermissionAuthorizationGateError.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func recordDispatchFailure(_ error: Error) {
        dispatchFailure = error
    }

    func abort() {
        isAborted = true
        continuation?.resume(returning: false)
        continuation = nil
    }

    func resolve(_ authorized: Bool) {
        continuation?.resume(returning: authorized)
        continuation = nil
    }
}

private enum APIHostPermissionAuthorizationGateError: Error {
    case timedOut
}

@MainActor
private final class APIHostDynamicCSSMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasReached = false
    private var isOpen = false

    func checkpoint() async {
        guard !isOpen else { return }
        hasReached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReached() async {
        while !hasReached {
            await Task.yield()
        }
    }

    func resume() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class APIHostLiveTargetBox {
    var tab: FloorpWebExtensionTabContext
    let webView = WKWebView(frame: .zero, configuration: .init())

    init(tab: FloorpWebExtensionTabContext) {
        self.tab = tab
    }
}

@MainActor
private final class AlarmEventRecorder {
    var events = [FloorpWebExtensionAlarmEvent]()
}

@MainActor
private final class APIHostAlarmBackgroundHandler: FloorpWebExtensionBackgroundEventHandling {
    private let recorder: AlarmEventRecorder

    init(recorder: AlarmEventRecorder) {
        self.recorder = recorder
    }

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        throw FloorpWebExtensionMessageError.unsupportedOperation
    }

    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        recorder.events.append(event)
    }
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
        // swiftlint:disable:next force_try
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
