// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionMessageRuntimeTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "message-fixture")!

    func testRuntimeSenderAlwaysExposesOpaqueDocumentIdentityForSubframes() {
        let main = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/main")!,
            isMainFrame: true,
            isPrivate: false
        )
        let subframe = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/frame")!,
            isMainFrame: false,
            isPrivate: false
        )

        XCTAssertEqual(main.frameID, 0)
        XCTAssertEqual(subframe.frameID, -1)
        XCTAssertEqual(main.documentID.count, 64)
        XCTAssertEqual(subframe.documentID.count, 64)
        XCTAssertNotEqual(subframe.documentID, main.documentID)
        XCTAssertEqual(
            subframe.documentID,
            FloorpWebExtensionDocumentIdentity.unsupportedSubframeID(
                tabID: 41,
                documentGeneration: 9
            )
        )
    }

    func testLazyBackgroundActivatesOnFirstMessageAndReusesHandler() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        var factoryCalls = 0
        let handler = EchoBackgroundHandler()
        host.register(extensionID: extensionID) {
            factoryCalls += 1
            return handler
        }
        let sender = testSender(extensionID: extensionID)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        let first = try await host.dispatch(payload, sender: sender)
        let second = try await host.dispatch(payload, sender: sender)

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(handler.receivedSenders, [sender, sender])
        XCTAssertEqual(try first?.decode(Pong.self), Pong(accepted: true))
        XCTAssertEqual(try second?.decode(Pong.self), Pong(accepted: true))
        XCTAssertEqual(
            host.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: true, activationCount: 1, pendingMessageCount: 0)
        )

        host.suspend(extensionID: extensionID)
        _ = try await host.dispatch(payload, sender: sender)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(host.snapshot(for: extensionID).activationCount, 2)
    }

    func testStage2EventRuntimeFixtureUsesReviewedLazyNativeHandler() async throws {
        let fixtureID = FloorpWebExtensionID(rawValue: "floorp.fixture.event-runtime-mv3")!
        let host = FloorpWebExtensionLazyBackgroundHost()
        var factoryCalls = 0
        let handler = EventRuntimeFixtureHandler()
        host.register(extensionID: fixtureID) {
            factoryCalls += 1
            return handler
        }
        let sender = testSender(extensionID: fixtureID)
        let payload = try FloorpWebExtensionMessagePayload(EventRuntimePing(type: "floorp-event-runtime-ping"))

        let first = try await host.dispatch(payload, sender: sender)
        host.suspend(extensionID: fixtureID)
        let second = try await host.dispatch(payload, sender: sender)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(try first?.decode(EventRuntimeReply.self).activationCount, 1)
        XCTAssertEqual(try second?.decode(EventRuntimeReply.self).activationCount, 2)
        XCTAssertEqual(host.snapshot(for: fixtureID).activationCount, 2)
    }

    // swiftlint:disable:next function_body_length
    func testBundledMV3ModuleBackgroundExecutesLazilyAndFailsClosedAcrossGenerationReplacement() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "generic-background-profile",
            isPrivateBrowsing: false
        )
        let nativeDispatcher = PageNativeDispatcher()
        let host = FloorpWebExtensionLazyBackgroundHost()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            nativeAPIDispatcher: nativeDispatcher,
            profileKey: profileKey
        )
        let worker = Data("""
        import { packageGeneration } from "./dependency.js";
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          chrome.i18n.getUILanguage((language) => sendResponse({
            accepted: message.type === "ping",
            generation: packageGeneration,
            language,
            senderId: sender.id,
            tabId: sender.tab?.id ?? null,
            runtimeId: chrome.runtime.id,
            packageURL: chrome.runtime.getURL("dependency.js")
          }));
          return true;
        });
        """.utf8)
        let firstResources = [
            "background.js": worker,
            "dependency.js": Data("export const packageGeneration = 'generation-1';".utf8)
        ]
        let firstPackage = try makeBackgroundInstalledPackage(
            generation: "generation-1",
            resources: firstResources
        )
        let firstResolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = firstResources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }

        XCTAssertThrowsError(
            try runtime.registerPackageBackground(
                package: firstPackage,
                packageProfileKey: .init(
                    profileIdentifier: "different-profile",
                    isPrivateBrowsing: false
                ),
                resolver: firstResolver
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionBackgroundRuntimeError,
                .profileAuthorityMismatch
            )
        }
        XCTAssertFalse(host.snapshot(for: extensionID).isRegistered)
        try runtime.registerPackageBackground(
            package: firstPackage,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: firstResolver
        )
        XCTAssertEqual(
            host.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: false, activationCount: 0, pendingMessageCount: 0)
        )

        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))
        let first = try await host.dispatch(payload, sender: testSender(extensionID: extensionID))
        let firstReply = try XCTUnwrap(try first?.decode(GenericBackgroundReply.self))
        XCTAssertTrue(firstReply.accepted)
        XCTAssertEqual(firstReply.generation, "generation-1")
        XCTAssertEqual(firstReply.language, "en-US")
        XCTAssertEqual(firstReply.senderId, extensionID.rawValue)
        XCTAssertEqual(firstReply.tabId, 41)
        XCTAssertEqual(firstReply.runtimeId, extensionID.rawValue)
        XCTAssertTrue(firstReply.packageURL.hasSuffix("/dependency.js"))
        XCTAssertEqual(host.snapshot(for: extensionID).activationCount, 1)
        let firstNativeSender = try XCTUnwrap(
            nativeDispatcher.receivedSenders.first as? FloorpWebExtensionBackgroundRuntimeMessageSender
        )
        XCTAssertEqual(firstNativeSender.profileKey, profileKey)
        XCTAssertEqual(firstNativeSender.packageGeneration, "generation-1")
        XCTAssertTrue(firstNativeSender.originHost.hasPrefix("background-"))
        XCTAssertEqual(
            firstReply.packageURL,
            "floorp-extension://\(firstNativeSender.originHost)/dependency.js"
        )

        let secondResources = [
            "background.js": worker,
            "dependency.js": Data("export const packageGeneration = 'generation-2';".utf8)
        ]
        let secondPackage = try makeBackgroundInstalledPackage(
            generation: "generation-2",
            resources: secondResources
        )
        let secondResolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = secondResources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }
        try runtime.registerPackageBackground(
            package: secondPackage,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: secondResolver
        )
        XCTAssertFalse(host.snapshot(for: extensionID).isActive)

        let second = try await host.dispatch(payload, sender: testSender(extensionID: extensionID))
        XCTAssertEqual(try second?.decode(GenericBackgroundReply.self).generation, "generation-2")
        let secondNativeSender = try XCTUnwrap(
            nativeDispatcher.receivedSenders.last as? FloorpWebExtensionBackgroundRuntimeMessageSender
        )
        XCTAssertEqual(secondNativeSender.packageGeneration, "generation-2")

        runtime.unregisterPackageBackground(for: extensionID)
        XCTAssertFalse(host.snapshot(for: extensionID).isRegistered)
        do {
            _ = try await host.dispatch(payload, sender: testSender(extensionID: extensionID))
            XCTFail("Expected a disabled package background to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundUnavailable)
        }
    }

    func testBundledNonPersistentBackgroundScriptsExecuteInOrderAndReceiveAlarmWakeup() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "script-array-background-profile",
            isPrivateBrowsing: false
        )
        let host = FloorpWebExtensionLazyBackgroundHost()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            profileKey: profileKey
        )
        let resources = [
            "background/first.js": Data("""
            globalThis.scriptOrder = ['first'];
            globalThis.lastAlarm = null;
            """.utf8),
            "background/second.js": Data("""
            globalThis.scriptOrder.push('second');
            browser.alarms.onAlarm.addListener((alarm) => { globalThis.lastAlarm = alarm; });
            browser.runtime.onMessage.addListener(() => ({
              order: globalThis.scriptOrder,
              alarmName: globalThis.lastAlarm?.name ?? null,
              scheduledTime: globalThis.lastAlarm?.scheduledTime ?? null
            }));
            """.utf8)
        ]
        let package = try makeBackgroundInstalledPackage(
            generation: "script-array-generation",
            resources: resources,
            backgroundDeclaration: """
            {
              "scripts": ["background/first.js", "background/second.js"],
              "persistent": false
            }
            """
        )
        let resolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = resources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }

        try runtime.registerPackageBackground(
            package: package,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: resolver
        )
        XCTAssertFalse(host.snapshot(for: extensionID).isActive)

        let scheduledTime = Date(timeIntervalSince1970: 1_750_000_000)
        try await runtime.dispatchAlarmEvent(.init(
            extensionID: extensionID,
            alarm: .init(name: "stage3-wakeup", scheduledTime: scheduledTime, period: 120),
            deliveredAt: scheduledTime
        ))
        XCTAssertEqual(host.snapshot(for: extensionID).activationCount, 1)
        let afterAlarm = try await host.dispatch(
            FloorpWebExtensionMessagePayload(Ping(type: "ping")),
            sender: testSender(extensionID: extensionID)
        )
        let reply = try XCTUnwrap(try afterAlarm?.decode(ScriptArrayBackgroundReply.self))
        XCTAssertEqual(reply.order, ["first", "second"])
        XCTAssertEqual(reply.alarmName, "stage3-wakeup")
        XCTAssertEqual(reply.scheduledTime, scheduledTime.timeIntervalSince1970 * 1_000)
        XCTAssertEqual(host.snapshot(for: extensionID).activationCount, 1)
    }

    func testPackageBackgroundWaitsForStartupAPIAndResourceActivityBeforeFirstMessage() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "async-background-startup-profile",
            isPrivateBrowsing: false
        )
        let host = FloorpWebExtensionLazyBackgroundHost()
        let dispatcher = AsyncNativeAPIDispatchGate()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            nativeAPIDispatcher: dispatcher,
            profileKey: profileKey
        )
        let resources = [
            "background.js": Data("""
            globalThis.startupValue = null;
            browser.i18n.getUILanguage().then(() => new Promise((resolve, reject) => {
              const request = new XMLHttpRequest();
              request.open("GET", "config/startup.config", true);
              request.onload = () => resolve(request.responseText);
              request.onerror = () => reject(new Error("startup config failed"));
              request.send();
            })).then((value) => { globalThis.startupValue = value; });
            browser.runtime.onMessage.addListener(() => ({startupValue: globalThis.startupValue}));
            """.utf8),
            "config/startup.config": Data("startup-ready".utf8)
        ]
        let package = try makeBackgroundInstalledPackage(
            generation: "async-background-startup-generation",
            resources: resources
        )
        let resolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = resources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }
        try runtime.registerPackageBackground(
            package: package,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: resolver
        )

        let replyTask = Task { @MainActor in
            try await host.dispatch(
                FloorpWebExtensionMessagePayload(Ping(type: "ping")),
                sender: testSender(extensionID: extensionID)
            )
        }
        await dispatcher.waitUntilStarted()
        try await Task.sleep(nanoseconds: 200_000_000)
        dispatcher.succeed()

        let replyPayload = try await replyTask.value
        let reply = try XCTUnwrap(try replyPayload?.decode(StartupBackgroundReply.self))
        XCTAssertEqual(reply.startupValue, "startup-ready")
    }

    func testPackageBackgroundStartupRuntimeMessageDoesNotDeadlockReadiness() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "self-message-background-startup-profile",
            isPrivateBrowsing: false
        )
        let host = FloorpWebExtensionLazyBackgroundHost()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            profileKey: profileKey
        )
        let resources = [
            "background.js": Data("""
            chrome.runtime.onMessage.addListener((message) => ({type: message.type}));
            void chrome.runtime.sendMessage({type: "startup-self-message"});
            """.utf8)
        ]
        let package = try makeBackgroundInstalledPackage(
            generation: "self-message-background-startup-generation",
            resources: resources
        )
        try runtime.registerPackageBackground(
            package: package,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: .init { request in
                guard let data = resources[request.path] else {
                    throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
                }
                return data
            }
        )

        let replyPayload = try await host.dispatch(
            FloorpWebExtensionMessagePayload(Ping(type: "outer-message")),
            sender: testSender(extensionID: extensionID)
        )
        let reply = try XCTUnwrap(try replyPayload?.decode(StartupSelfMessageReply.self))
        XCTAssertEqual(reply.type, "outer-message")
    }

    func testBackgroundRegistrationIsStrictlyExtensionScoped() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let otherExtension = FloorpWebExtensionID(rawValue: "other-message-fixture")!
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        do {
            _ = try await host.dispatch(payload, sender: testSender(extensionID: otherExtension))
            XCTFail("Expected an unregistered extension to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundUnavailable)
        }
        XCTAssertFalse(host.snapshot(for: otherExtension).isRegistered)
        XCTAssertFalse(host.snapshot(for: extensionID).isActive)
    }

    func testPayloadRejectsInvalidJSONAndValuesOverQuota() throws {
        XCTAssertThrowsError(try FloorpWebExtensionMessagePayload(jsonData: Data("{".utf8)))
        XCTAssertThrowsError(
            try FloorpWebExtensionMessagePayload(
                jsonData: Data(repeating: 0x20, count: FloorpWebExtensionMessagePayload.maximumByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .payloadTooLarge)
        }
    }

    func testIsolatedWorldBridgeAuthenticatesAndUsesTrustedSenderContext() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let handler = EchoBackgroundHandler()
        host.register(extensionID: extensionID) { handler }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { url, isMainFrame, trustedTab in
                url.host == "allowed.example" && isMainFrame && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>bridge</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let pageWorldType = try await webView.callAsyncJavaScript(
            "return typeof globalThis.browser",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(pageWorldType, "undefined")

        let result = try await webView.callAsyncJavaScript(
            "return await browser.runtime.sendMessage({type: 'ping'})",
            contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        ) as? [String: Any]
        XCTAssertEqual(result?["accepted"] as? Bool, true)
        XCTAssertEqual(handler.receivedSenders.first?.extensionID, extensionID)
        XCTAssertEqual(handler.receivedSenders.first?.tabID, tab.tabID)
        XCTAssertEqual(handler.receivedSenders.first?.documentGeneration, tab.documentGeneration)
        XCTAssertEqual(handler.receivedSenders.first?.url.host, "allowed.example")
        XCTAssertEqual(handler.receivedSenders.first?.isMainFrame, true)
    }

    func testWebKitBootstrapExposesStage3PromiseAndChromeCallbackSurfaces() async throws {
        let dispatcher = BootstrapSurfaceDispatcher()
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: dispatcher)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { _, isMainFrame, trustedTab in
                isMainFrame && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>stage3 bridge</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let result = try await webView.callAsyncJavaScript(
            """
            const permission = await browser.permissions.contains({permissions: ["tabs"]});
            await browser.scripting.registerContentScripts([{
              id: "registered-from-worker",
              matches: ["https://allowed.example/*"],
              js: ["content.js"]
            }]);
            const enabledRulesets = await browser.declarativeNetRequest.getEnabledRulesets();
            const callbackError = await new Promise((resolve) => {
              chrome.scripting.executeScript({target: {tabId: 41}, func: () => true}, () => {
                resolve(chrome.runtime.lastError?.code || null);
              });
            });
            let contentGetURLRejected = false;
            try {
              chrome.runtime.getURL("package-resource.js");
            } catch (_) {
              contentGetURLRejected = true;
            }
            return {
              permission,
              enabledRulesets,
              callbackError,
              leakedLastError: chrome.runtime.lastError !== null,
              contentGetURLRejected,
              runtimeId: chrome.runtime.id,
              dynamicLimit: browser.declarativeNetRequest.MAX_NUMBER_OF_DYNAMIC_RULES
            };
            """,
            contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        ) as? [String: Any]

        XCTAssertEqual(result?["permission"] as? Bool, true)
        XCTAssertEqual(result?["enabledRulesets"] as? [String], ["base"])
        XCTAssertEqual(result?["callbackError"] as? String, "unsupported_code_execution")
        XCTAssertEqual(result?["leakedLastError"] as? Bool, false)
        XCTAssertEqual(result?["contentGetURLRejected"] as? Bool, true)
        XCTAssertEqual(result?["runtimeId"] as? String, extensionID.rawValue)
        XCTAssertEqual(result?["dynamicLimit"] as? Int, 5_000)
        XCTAssertEqual(
            dispatcher.operations,
            [
                "permissions.contains",
                "scripting.registerContentScripts",
                "declarativeNetRequest.getEnabledRulesets",
                "scripting.executeScript"
            ]
        )
        let registeredPayload = try XCTUnwrap(dispatcher.payloads["scripting.registerContentScripts"])
        let registeredObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: registeredPayload.jsonData) as? [String: Any]
        )
        XCTAssertEqual((registeredObject["scripts"] as? [[String: Any]])?.first?["id"] as? String,
                       "registered-from-worker")
    }

    func testWebKitTabsBridgePreservesJavaScriptSafeTabIdentifier() async throws {
        let tabID = 5_484_014_516_345_869
        let dispatcher = SafeTabIdentifierDispatcher(tabID: tabID)
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: dispatcher)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { _, isMainFrame, trustedTab in
                isMainFrame && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>tabs bridge</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let result = try await webView.callAsyncJavaScript(
            """
            const [queriedTab] = await browser.tabs.query({active: true});
            const roundTrippedID = JSON.parse(JSON.stringify({id: queriedTab.id})).id;
            const fetchedTab = await browser.tabs.get(roundTrippedID);
            const reply = await browser.tabs.sendMessage(roundTrippedID, {type: "ping"});
            return {
              id: queriedTab.id,
              safe: Number.isSafeInteger(queriedTab.id),
              fetchedID: fetchedTab.id,
              reply: reply.reply
            };
            """,
            contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        ) as? [String: Any]

        XCTAssertEqual(result?["id"] as? Int, tabID)
        XCTAssertEqual(result?["safe"] as? Bool, true)
        XCTAssertEqual(result?["fetchedID"] as? Int, tabID)
        XCTAssertEqual(result?["reply"] as? String, "ok")
        XCTAssertEqual(dispatcher.receivedTabIDs, [tabID, tabID])
    }

    func testDocumentAuthorizationRunsBeforeLazyBackgroundActivation() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { _, _, _ in false }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>denied</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        do {
            _ = try await webView.callAsyncJavaScript(
                "return await browser.runtime.sendMessage({type: 'ping'})",
                contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
            )
            XCTFail("Expected the document authorization gate to reject the message")
        } catch {
            XCTAssertFalse(host.snapshot(for: extensionID).isActive)
        }
    }

    func testReconcileTabBridgesRetractsBridgeWhenNextNavigationHasNoEligibleScript() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { url, isMainFrame, trustedTab in
                url.host == "allowed.example" && isMainFrame && trustedTab == tab
            }
        )
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)

        // This represents a subsequent navigation whose URL no longer has a
        // grant-qualified isolated script.  The native handler and bootstrap
        // must both disappear before WebKit begins that document.
        runtime.reconcileTabBridges(
            on: configuration.userContentController,
            retaining: []
        )
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>unmatched</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)
        let bridgeType = try await webView.callAsyncJavaScript(
            "return typeof globalThis.browser",
            contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        ) as? String
        XCTAssertEqual(bridgeType, "undefined")
        XCTAssertFalse(host.snapshot(for: extensionID).isActive)
    }

    func testExtensionPageBridgeDispatchesNativeAPIWithPageSenderAndRevokesOnDisable() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "page-bridge-profile",
            isPrivateBrowsing: false
        )
        let nativeDispatcher = PageNativeDispatcher()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            nativeAPIDispatcher: nativeDispatcher,
            profileKey: profileKey
        )
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "page-bridge-generation",
            resourcePaths: ["popup/index.html"]
        )
        let page = try FloorpWebExtensionPageViewController(
            surface: .actionPopup,
            package: package,
            entryPoint: .init("popup/index.html"),
            resolver: .init { _ in Data("<html><body>Extension page</body></html>".utf8) },
            messageRuntime: runtime,
            openExternal: { _ in }
        )
        page.loadViewIfNeeded()
        try await waitForLoad(page.webView)
        XCTAssertEqual(page.webView.url?.scheme, FloorpWebExtensionPageNavigationPolicy.resourceScheme)
        let originHost = try XCTUnwrap(page.webView.url?.host)

        let language = try await page.webView.callAsyncJavaScript(
            "return await browser.i18n.getUILanguage()",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(language, "en-US")
        let sender = try XCTUnwrap(nativeDispatcher.receivedSenders.first as? FloorpWebExtensionPageRuntimeMessageSender)
        XCTAssertEqual(sender.extensionID, extensionID)
        XCTAssertEqual(sender.profileKey, profileKey)
        XCTAssertEqual(sender.packageGeneration, package.generation)
        XCTAssertEqual(sender.originHost, originHost)
        XCTAssertEqual(sender.surface, .actionPopup)
        XCTAssertEqual(sender.transportURL, page.webView.url)

        runtime.removeExtension(extensionID)
        XCTAssertTrue(page.webView.configuration.userContentController.userScripts.isEmpty)
        page.webView.reload()
        try await waitForLoad(page.webView)
        let bridgeType = try await page.webView.callAsyncJavaScript(
            "return typeof globalThis.browser",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(bridgeType, "undefined")
        XCTAssertEqual(nativeDispatcher.receivedSenders.count, 1)
    }

    func testExtensionPageMessageNormalizesSenderPathForBackgroundAndFalseListenerDoesNotConsumeIt() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "page-to-background-profile",
            isPrivateBrowsing: false
        )
        let host = FloorpWebExtensionLazyBackgroundHost()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            profileKey: profileKey
        )
        let resources = [
            "background.js": Data("""
            chrome.runtime.onMessage.addListener(() => false);
            chrome.runtime.onMessage.addListener((message, sender) => ({
              handledBy: "second-listener",
              senderURL: sender.url,
              expectedURL: chrome.runtime.getURL("/ui/popup/index.html"),
              backgroundTransportURL: chrome.runtime.getURL("/")
            }));
            """.utf8),
            "ui/popup/index.html": Data("<html><body>Popup bridge</body></html>".utf8),
            "assets/runtime.config": Data("transport-resource-ready".utf8)
        ]
        let installedPackage = try makeBackgroundInstalledPackage(
            generation: "page-to-background-generation",
            resources: resources
        )
        let resolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = resources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }
        try runtime.registerPackageBackground(
            package: installedPackage,
            packageProfileKey: .init(
                profileIdentifier: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ),
            resolver: resolver
        )
        let pagePackage = try FloorpWebExtensionPagePackageGeneration(
            installedPackage: installedPackage
        )
        let page = try FloorpWebExtensionPageViewController(
            surface: .actionPopup,
            package: pagePackage,
            entryPoint: .init("ui/popup/index.html"),
            resolver: resolver,
            messageRuntime: runtime,
            openExternal: { _ in }
        )
        page.loadViewIfNeeded()
        try await waitForLoad(page.webView)

        let result = try await page.webView.callAsyncJavaScript(
            """
            const resourceURL = chrome.runtime.getURL("/assets/runtime.config");
            const resourceText = await new Promise((resolve, reject) => {
              const request = new XMLHttpRequest();
              request.open("GET", resourceURL, true);
              request.onload = () => resolve(request.responseText);
              request.onerror = () => reject(new Error("Package XHR failed"));
              request.send();
            });
            return {
              reply: await browser.runtime.sendMessage({type: "popup-data"}),
              resourceURL,
              resourceText
            };
            """,
            contentWorld: .page
        ) as? [String: Any]
        let reply = result?["reply"] as? [String: Any]
        let pageTransportHost = try XCTUnwrap(page.webView.url?.host)
        let backgroundTransportURL = try XCTUnwrap(reply?["backgroundTransportURL"] as? String)
        let expectedSenderURL = try XCTUnwrap(
            URL(string: backgroundTransportURL)?.appendingPathComponent("ui/popup/index.html")
        )

        XCTAssertEqual(reply?["handledBy"] as? String, "second-listener")
        XCTAssertEqual(reply?["senderURL"] as? String, expectedSenderURL.absoluteString)
        XCTAssertEqual(reply?["expectedURL"] as? String, expectedSenderURL.absoluteString)
        XCTAssertEqual(result?["resourceText"] as? String, "transport-resource-ready")
        XCTAssertEqual(
            result?["resourceURL"] as? String,
            "floorp-extension://\(pageTransportHost)/assets/runtime.config"
        )
        XCTAssertTrue(pageTransportHost.hasPrefix("page-"))
        XCTAssertTrue(URL(string: backgroundTransportURL)?.host?.hasPrefix("background-") == true)
        XCTAssertNotEqual(URL(string: backgroundTransportURL)?.host, pageTransportHost)
    }

    func testRuntimeTearDownInvalidatesBackgroundRegistrations() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        do {
            _ = try await host.dispatch(payload, sender: testSender(extensionID: extensionID))
        } catch {
            XCTFail("Expected the registered background to receive messages before tearDown: \(error)")
        }
        XCTAssertTrue(host.snapshot(for: extensionID).isRegistered)

        runtime.tearDown()

        XCTAssertFalse(host.snapshot(for: extensionID).isRegistered)
        let senderAfterTearDown = testSender(extensionID: extensionID)
        do {
            _ = try await host.dispatch(payload, sender: senderAfterTearDown)
            XCTFail("Expected dispatch after tearDown to throw")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundUnavailable)
        }
    }

    func testRuntimeTearDownSuppressesInFlightBackgroundReplies() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let gate = AsyncReplyGate()
        host.register(extensionID: extensionID) { gate }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))
        let sender = testSender(extensionID: extensionID)

        let inFlight = Task {
            _ = try await host.dispatch(payload, sender: sender)
        }
        await gate.waitUntilStarted()

        runtime.tearDown()
        await gate.release()

        do {
            try await inFlight.value
            XCTFail("Expected in-flight dispatch to throw after tearDown")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundReplaced)
        }
    }

    func testMemoryPressureReleaseRecreatesBackgroundAndSuppressesInFlightReply() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let gate = AsyncReplyGate()
        var factoryCalls = 0
        host.register(extensionID: extensionID) {
            factoryCalls += 1
            return factoryCalls == 1 ? gate : EchoBackgroundHandler()
        }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))
        let sender = testSender(extensionID: extensionID)

        let inFlight = Task {
            try await host.dispatch(payload, sender: sender)
        }
        await gate.waitUntilStarted()

        runtime.releaseBackgroundResources()

        XCTAssertEqual(
            host.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: false, activationCount: 1, pendingMessageCount: 0)
        )

        let replacementReply = try await host.dispatch(payload, sender: sender)
        XCTAssertEqual(try replacementReply?.decode(Pong.self), Pong(accepted: true))
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(
            host.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: true, activationCount: 2, pendingMessageCount: 0)
        )

        await gate.release()
        do {
            _ = try await inFlight.value
            XCTFail("Expected the pre-memory-pressure reply to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundReplaced)
        }
    }

    func testDetachedBridgeSuppressesInFlightDirectNativeAPIReply() async throws {
        let dispatcher = AsyncNativeAPIDispatchGate()
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: dispatcher)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { _, isMainFrame, trustedTab in
                isMainFrame && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>in-flight native API</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let inFlight = Task {
            try await directNativeAPIResult(in: webView)
        }
        await dispatcher.waitUntilStarted()

        runtime.removeBridge(
            for: extensionID,
            from: configuration.userContentController
        )
        dispatcher.succeed()

        let reply = try await inFlight.value
        XCTAssertEqual(reply.status, "rejected")
        XCTAssertEqual(reply.code, "document_not_authorized")
    }

    func testReattachedBridgeRejectsRequestCapturedBeforeExecutionWithoutNativeDispatch() async throws {
        let scheduler = SuspendedBridgeRequestScheduler()
        let dispatcher = PageNativeDispatcher()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            nativeAPIDispatcher: dispatcher,
            scheduleBridgeRequest: scheduler.schedule
        )
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        let authorizeDocument: FloorpWebExtensionMessageRuntime.DocumentAuthorization = { _, isMainFrame, trustedTab in
            isMainFrame && trustedTab == tab
        }
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: authorizeDocument
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>pre-start reattach</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let staleRequest = Task {
            try await directNativeAPIResult(in: webView)
        }
        await scheduler.waitUntilScheduled()

        // The receipt token belongs to the first session. Replace that session
        // before its scheduled operation begins, using the same controller so
        // generation alone and controller-presence checks cannot be confused
        // with authorization for the new attachment.
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: authorizeDocument
        )
        await scheduler.runScheduledRequest()

        let reply = try await staleRequest.value
        XCTAssertEqual(reply.status, "rejected")
        XCTAssertEqual(reply.code, "document_not_authorized")
        XCTAssertTrue(dispatcher.receivedSenders.isEmpty)
    }

    func testMemoryPressureInvalidatesInFlightAlarmAndReleasesHandlerResource() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        var resource: VolatileBackgroundResource? = VolatileBackgroundResource()
        weak var releasedResource = resource
        let firstHandler = AsyncAlarmResourceGate(resource: try XCTUnwrap(resource))
        resource = nil
        let replacementHandler = AlarmRecordingHandler()
        var factoryCalls = 0
        host.register(extensionID: extensionID) {
            factoryCalls += 1
            return factoryCalls == 1 ? firstHandler : replacementHandler
        }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let beforeWarning = FloorpWebExtensionAlarmEvent(
            extensionID: extensionID,
            alarm: .init(name: "before-warning", scheduledTime: .distantPast),
            deliveredAt: .distantPast
        )
        let inFlight = Task { @MainActor in
            try await host.dispatchAlarm(beforeWarning)
        }
        let failSafe = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            firstHandler.forceFinish()
        }
        defer {
            failSafe.cancel()
            firstHandler.forceFinish()
        }
        await firstHandler.waitUntilStarted()

        runtime.releaseBackgroundResources()

        XCTAssertEqual(firstHandler.invalidationCount, 1)
        XCTAssertNil(releasedResource)
        do {
            try await inFlight.value
            XCTFail("Expected the pre-memory-pressure alarm to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundReplaced)
        }

        let afterWarning = FloorpWebExtensionAlarmEvent(
            extensionID: extensionID,
            alarm: .init(name: "after-warning", scheduledTime: .distantPast),
            deliveredAt: .distantPast
        )
        try await host.dispatchAlarm(afterWarning)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(replacementHandler.events.map(\.alarm.name), ["after-warning"])
    }

    func testMemoryPressureInvalidatesInFlightWKAlarmAndDropsHiddenWebView() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "hidden-webview-release-profile",
            isPrivateBrowsing: false
        )
        let host = FloorpWebExtensionLazyBackgroundHost()
        let dispatcher = AsyncNativeAPIDispatchGate()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: host,
            nativeAPIDispatcher: dispatcher,
            profileKey: profileKey
        )
        let resources = [
            "background.js": Data("""
            browser.alarms.onAlarm.addListener(async () => {
              await browser.i18n.getUILanguage();
            });
            """.utf8)
        ]
        let package = try makeBackgroundInstalledPackage(
            generation: "hidden-webview-release-generation",
            resources: resources
        )
        let background = try FloorpWebExtensionBackgroundPackageGeneration(
            installedPackage: package
        )
        let resolver = FloorpWebExtensionPageResourceResolver { request in
            guard let data = resources[request.path] else {
                throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
            }
            return data
        }
        weak var activatedHandler: FloorpWebExtensionWKBackgroundEventHandler?
        weak var hiddenWebView: WKWebView?
        host.register(extensionID: extensionID) {
            let handler = try FloorpWebExtensionWKBackgroundEventHandler(
                profileKey: profileKey,
                background: background,
                resolver: resolver,
                messageRuntime: runtime
            )
            activatedHandler = handler
            hiddenWebView = handler.webView
            return handler
        }

        let event = FloorpWebExtensionAlarmEvent(
            extensionID: extensionID,
            alarm: .init(name: "in-flight-webkit-alarm", scheduledTime: .distantPast),
            deliveredAt: .distantPast
        )
        let inFlight = Task { @MainActor in
            try await runtime.dispatchAlarmEvent(event)
        }
        let failSafe = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            dispatcher.fail()
        }
        defer {
            failSafe.cancel()
            dispatcher.fail()
        }
        await dispatcher.waitUntilStarted()
        XCTAssertNotNil(activatedHandler)
        XCTAssertNotNil(hiddenWebView)

        runtime.releaseBackgroundResources()

        XCTAssertNil(activatedHandler?.webView)
        do {
            try await inFlight.value
            XCTFail("Expected the in-flight WebKit alarm to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundReplaced)
        }

        dispatcher.succeed()
        for _ in 0..<100 where hiddenWebView != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(hiddenWebView)
    }

    private func testTab() -> FloorpWebExtensionTabContext {
        FloorpWebExtensionTabContext(
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/bridge")!,
            isPrivate: false
        )
    }

    private func directNativeAPIResult(in webView: WKWebView) async throws -> DirectNativeAPIResult {
        let rawReply = try await webView.callAsyncJavaScript(
            """
            try {
              const language = await browser.i18n.getUILanguage();
              return { status: "resolved", language };
            } catch (error) {
              return { status: "rejected", code: error.code || null };
            }
            """,
            contentWorld: .world(
                name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID)
            )
        ) as? [String: Any]
        return DirectNativeAPIResult(
            status: rawReply?["status"] as? String,
            code: rawReply?["code"] as? String
        )
    }

    private func testSender(
        extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionRuntimeMessageSender {
        FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/bridge")!,
            isMainFrame: true,
            isPrivate: false
        )
    }

    private func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<250 {
            if !webView.isLoading, webView.url != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the bridge test document")
    }

    private func makeBackgroundInstalledPackage(
        generation: String,
        resources: [String: Data],
        backgroundDeclaration: String = """
        {
          "service_worker": "background.js",
          "type": "module"
        }
        """
    ) throws -> FloorpWebExtensionInstalledPackage {
        let rawManifest = Data("""
        {
          "manifest_version": 3,
          "name": "Generic Background Fixture",
          "version": "1.0.0",
          "permissions": ["alarms"],
          "background": \(backgroundDeclaration)
        }
        """.utf8)
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: resources.map {
            .init(path: $0.key, isRegularFile: true, byteSize: $0.value.count)
        })
        let fixture = try FloorpWebExtensionFixture(
            extensionID: extensionID,
            sourceRepository: try XCTUnwrap(URL(string: "https://example.com/generic-background")),
            sourceCommit: String(repeating: "b", count: 40),
            version: "1.0.0",
            packageSHA256: String(repeating: "1", count: 64),
            license: "MPL-2.0",
            supportedOSFloor: "iOS 15"
        )
        return .init(
            extensionID: extensionID,
            generation: generation,
            name: "Generic Background Fixture",
            version: "1.0.0",
            fixture: fixture,
            packageSHA256: String(repeating: "1", count: 64),
            installedAt: .distantPast,
            rawManifest: rawManifest,
            preflight: try FloorpWebExtensionManifest.preflight(
                manifestData: rawManifest,
                packageInventory: inventory
            ),
            resourcePaths: Set(resources.keys),
            isEnabled: true,
            grants: .init(apiPermissions: [.alarms])
        )
    }
}

@MainActor
private final class EchoBackgroundHandler: FloorpWebExtensionBackgroundEventHandling {
    private(set) var receivedSenders = [FloorpWebExtensionRuntimeMessageSender]()

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = try message.decode(Ping.self)
        guard let tabSender = sender as? FloorpWebExtensionRuntimeMessageSender else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        receivedSenders.append(tabSender)
        return try FloorpWebExtensionMessagePayload(Pong(accepted: true))
    }
}

@MainActor
private final class PageNativeDispatcher: FloorpWebExtensionNativeAPIDispatching {
    private(set) var receivedSenders = [any FloorpWebExtensionMessageSender]()

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard operation == "i18n.getUILanguage" else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        receivedSenders.append(sender)
        return try .init(jsonData: Data(#"{"value":"en-US"}"#.utf8))
    }
}

@MainActor
private final class BootstrapSurfaceDispatcher: FloorpWebExtensionNativeAPIDispatching {
    private(set) var operations = [String]()
    private(set) var payloads = [String: FloorpWebExtensionMessagePayload]()

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        operations.append(operation)
        payloads[operation] = payload
        switch operation {
        case "permissions.contains":
            return try .init(jsonData: Data(#"{"value":true}"#.utf8))
        case "scripting.registerContentScripts":
            return try .init(jsonData: Data(#"{}"#.utf8))
        case "declarativeNetRequest.getEnabledRulesets":
            return try .init(jsonData: Data(#"{"values":["base"]}"#.utf8))
        case "scripting.executeScript":
            throw FloorpWebExtensionMessageError.unsupportedCodeExecution
        default:
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
    }
}

@MainActor
private final class SafeTabIdentifierDispatcher: FloorpWebExtensionNativeAPIDispatching {
    let tabID: Int
    private(set) var receivedTabIDs = [Int]()

    init(tabID: Int) {
        self.tabID = tabID
    }

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = sender
        let tab = """
        {"id":\(tabID),"active":true,"isPrivate":false,"url":"https://allowed.example/bridge","title":"Safe"}
        """
        switch operation {
        case "tabs.query":
            return try .init(jsonData: Data("[\(tab)]".utf8))
        case "tabs.get", "tabs.sendMessage":
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload.jsonData) as? [String: Any]
            )
            receivedTabIDs.append(try XCTUnwrap(object["tabId"] as? Int))
            if operation == "tabs.get" {
                return try .init(jsonData: Data(tab.utf8))
            }
            return try .init(jsonData: Data(#"{"reply":"ok"}"#.utf8))
        default:
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
    }
}

@MainActor
private final class AsyncReplyGate: FloorpWebExtensionBackgroundEventHandling {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() async {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = try message.decode(Ping.self)
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try FloorpWebExtensionMessagePayload(Pong(accepted: true))
    }
}

@MainActor
private final class AsyncNativeAPIDispatchGate: FloorpWebExtensionNativeAPIDispatching {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var replyContinuation: CheckedContinuation<FloorpWebExtensionMessagePayload?, Error>?
    private var didStart = false

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func succeed() {
        // swiftlint:disable:next force_try
        let payload = try! FloorpWebExtensionMessagePayload(
            jsonData: Data(#"{"value":"en-US"}"#.utf8)
        )
        replyContinuation?.resume(returning: payload)
        replyContinuation = nil
    }

    func fail() {
        replyContinuation?.resume(throwing: FloorpWebExtensionMessageError.handlerFailed)
        replyContinuation = nil
    }

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard operation == "i18n.getUILanguage" else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            replyContinuation = continuation
        }
    }
}

@MainActor
private final class SuspendedBridgeRequestScheduler {
    typealias Operation = @MainActor @Sendable () async -> Void

    private var scheduledContinuation: CheckedContinuation<Void, Never>?
    private var pendingOperation: Operation?
    private var didSchedule = false

    func schedule(_ operation: @escaping Operation) {
        precondition(pendingOperation == nil, "Only one bridge request may be suspended at a time")
        pendingOperation = operation
        didSchedule = true
        scheduledContinuation?.resume()
        scheduledContinuation = nil
    }

    func waitUntilScheduled() async {
        if didSchedule { return }
        await withCheckedContinuation { continuation in
            scheduledContinuation = continuation
        }
    }

    func runScheduledRequest() async {
        let operation = pendingOperation
        pendingOperation = nil
        await operation?()
    }
}

private final class VolatileBackgroundResource {}

@MainActor
private final class AsyncAlarmResourceGate: FloorpWebExtensionBackgroundEventHandling {
    private var resource: VolatileBackgroundResource?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var alarmContinuation: CheckedContinuation<Void, Error>?
    private var didStart = false
    private(set) var invalidationCount = 0

    init(resource: VolatileBackgroundResource) {
        self.resource = resource
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        throw FloorpWebExtensionMessageError.unsupportedOperation
    }

    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        try await withCheckedThrowingContinuation { continuation in
            alarmContinuation = continuation
        }
    }

    func invalidateBackgroundResources() {
        invalidationCount += 1
        resource = nil
        alarmContinuation?.resume(throwing: FloorpWebExtensionMessageError.backgroundReplaced)
        alarmContinuation = nil
    }

    func forceFinish() {
        alarmContinuation?.resume(throwing: FloorpWebExtensionMessageError.handlerFailed)
        alarmContinuation = nil
    }
}

@MainActor
private final class AlarmRecordingHandler: FloorpWebExtensionBackgroundEventHandling {
    private(set) var events = [FloorpWebExtensionAlarmEvent]()

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        throw FloorpWebExtensionMessageError.unsupportedOperation
    }

    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        events.append(event)
    }
}

private struct Ping: Codable, Equatable {
    let type: String
}

private struct Pong: Codable, Equatable {
    let accepted: Bool
}

private struct DirectNativeAPIResult: Equatable, Sendable {
    let status: String?
    let code: String?
}

private struct GenericBackgroundReply: Codable, Equatable {
    let accepted: Bool
    let generation: String
    let language: String
    let senderId: String
    let tabId: Int
    let runtimeId: String
    let packageURL: String
}

private struct ScriptArrayBackgroundReply: Codable, Equatable {
    let order: [String]
    let alarmName: String?
    let scheduledTime: Double?
}

private struct StartupBackgroundReply: Codable, Equatable {
    let startupValue: String?
}

private struct StartupSelfMessageReply: Codable, Equatable {
    let type: String
}

private struct EventRuntimePing: Codable, Equatable {
    let type: String
}

private struct EventRuntimeReply: Codable, Equatable {
    let accepted: Bool
    let activationCount: Int
}

@MainActor
private final class EventRuntimeFixtureHandler: FloorpWebExtensionBackgroundEventHandling {
    private var activationCount = 0

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        let ping = try message.decode(EventRuntimePing.self)
        guard ping.type == "floorp-event-runtime-ping" else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        activationCount += 1
        return try FloorpWebExtensionMessagePayload(EventRuntimeReply(
            accepted: true,
            activationCount: activationCount
        ))
    }
}
