// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Darwin
import Foundation
@preconcurrency import GCDWebServers
import WebKit
import XCTest
@testable import Client

/// Records the Stage 3 scopes that can be measured truthfully in one hosted
/// Simulator XCTest process. The attached JSON is intentionally record-only:
/// its validated limitations prevent empty-store compilation, localhost page
/// loading, and Client-host memory from being promoted to release evidence.
final class FloorpWebExtensionStage3SimulatorPerformanceTests: XCTestCase, @unchecked Sendable {
    private let fixtureIdentifier = "demanding-mv3"
    private let extensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.demanding-mv3")!
    private let staticRuleSetIdentifier = "large-static"
    private let measuredSampleCount = 7
    private let nativeWarmupSampleCount = 1
    private let webKitWarmupSampleCount = 1
    private let pageWarmupPairCount = 2
    private let memoryPhaseSampleCount = 3
    private let memorySamplingIntervalMilliseconds = 50

    @MainActor
    // swiftlint:disable:next function_body_length
    func testRecordsDemandingFixtureSimulatorPerformanceScopes() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This record is deliberately limited to an iOS Simulator host.")
        #endif

        let clock = try ContinuousMachClock()
        let sourceAttestation = try sourceAttestation()
        let fixtureDirectory = try checkedInFixtureDirectory(named: fixtureIdentifier)
        let metadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(at: fixtureDirectory)
        // Measure the hosted-process memory scope before constructing any WebKit
        // compiler/page-load objects retained by the later phases of this test.
        let memory = try await measureMemoryReleaseAndRecovery(
            fixtureDirectory: fixtureDirectory,
            clock: clock
        )
        let ruleData = try Data(contentsOf: fixtureDirectory.appendingPathComponent("rules/static.json"))
        let rules = try materializeStaticRules(from: ruleData)
        XCTAssertEqual(rules.count, 5_000)
        XCTAssertEqual(rules.map(\.id), Array(1...5_000))

        for _ in 0..<nativeWarmupSampleCount {
            _ = try await timedNativeTransform(rules: rules, clock: clock)
        }
        let native = try await measureNativeCompilation(rules: rules, clock: clock)
        let finalCompilation = native.compilation
        try verifyCompilation(finalCompilation)

        for _ in 0..<webKitWarmupSampleCount {
            _ = try await measureWebKitCompilationSample(
                index: 0,
                encodedRuleList: finalCompilation.webKitContentRuleJSON,
                clock: clock
            )
        }
        let webKitSamples = try await measureWebKitCompilation(
            encodedRuleList: finalCompilation.webKitContentRuleJSON,
            clock: clock
        )
        let pagePhase = try await measurePageLoadPhase(
            encodedRuleList: finalCompilation.webKitContentRuleJSON,
            clock: clock
        )

        let fixture = try FloorpWebExtensionPerformanceFixtureEvidence(
            identifier: fixtureIdentifier,
            version: metadata.fixture.version,
            packageSHA256: metadata.fixture.packageSHA256,
            integrityVerified: true,
            staticRuleCount: rules.count,
            dynamicRuleCount: 0,
            sessionRuleCount: 0,
            totalRuleCount: rules.count,
            enabledRuleCount: finalCompilation.compiledRules.count,
            transformedRuleCount: finalCompilation.report.transformedRuleCount,
            rejectedRuleCount: finalCompilation.report.rejectedRuleCount
        )
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(fixture)
        try verifySourceAttestationUnchanged(sourceAttestation)

        let record = try FloorpWebExtensionStage3SimulatorPerformanceRecord(
            runIdentifier: "stage3-simulator-\(UUID().uuidString.lowercased())",
            associatedSourceRevision: sourceAttestation.revision,
            sourceAttestedRevision: sourceAttestation.revision,
            sourceWorktreeState: sourceAttestation.worktreeState,
            recordedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            environment: currentEnvironment(),
            fixture: fixture,
            measurementProtocol: .init(
                clock: "mach_continuous_time",
                clockNumerator: clock.numerator,
                clockDenominator: clock.denominator,
                nativeState: "fresh-store-transform-from-prevalidated-retained-rules-no-native-cache",
                webKitEmptyState: "empty-profile-scoped-store-compile",
                webKitPrimedState: "same-store-fresh-identifier-compile-after-untimed-prime",
                pagePairing: "alternating-baseline-enabled-identical-local-page",
                memoryMetric: "task_vm_info.phys_footprint",
                memoryScope: "Client-hosted-XCTest-process-only",
                memoryReleaseAction: "direct-bootstrapper-release-hook",
                nativeWarmupSampleCount: nativeWarmupSampleCount,
                webKitWarmupSampleCount: webKitWarmupSampleCount,
                pageWarmupPairCount: pageWarmupPairCount,
                measuredSampleCount: measuredSampleCount,
                pagePairCount: measuredSampleCount,
                memorySamplingIntervalMilliseconds: memorySamplingIntervalMilliseconds
            ),
            nativeTransformation: .init(
                samples: native.samples,
                outputRuleCount: finalCompilation.compiledRules.count
            ),
            webKitCompilation: .init(
                samples: webKitSamples,
                outputRuleCount: finalCompilation.compiledRules.count
            ),
            pageLoad: pagePhase.evidence,
            memory: memory,
            functionalChecks: [
                try .init(
                    identifier: "demanding-fixture-integrity",
                    passed: true,
                    detail: "Pinned fixture SHA and 5000-rule compiler invariants verified."
                ),
                try .init(
                    identifier: "webkit-dnr-local-resource-block",
                    passed: pagePhase.dnrFunctionalCheckPassed,
                    detail: "A localhost image URL containing load0041.fixture.test was blocked before reaching the server."
                ),
                try .init(
                    identifier: "package-background-release-recovery",
                    passed: memory.priorBackgroundReleased && memory.postRecoveryReplyPassed,
                    // swiftlint:disable:next line_length
                    detail: "The package-backed hidden WebView was released and a second activation answered the fixture ping."
                )
            ]
        )

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-stage3-performance-tests", isDirectory: true)
            .appendingPathComponent(record.runIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let recordURL = outputDirectory.appendingPathComponent("simulator-performance-record.json")
        let encoded = try FloorpWebExtensionStage3SimulatorPerformanceRecordVerifier.encode(record)
        try encoded.write(to: recordURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        let decoded = try FloorpWebExtensionStage3SimulatorPerformanceRecordVerifier.decode(
            Data(contentsOf: recordURL)
        )
        XCTAssertEqual(decoded, record)

        let attachment = XCTAttachment(contentsOfFile: recordURL)
        attachment.name = "Stage 3 demanding-mv3 simulator performance record (record-only)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FLOORP_STAGE3_SIMULATOR_PERFORMANCE_RECORD=\(recordURL.path)")
    }

    private func measureNativeCompilation(
        rules: [FloorpWebExtensionDNRRule],
        clock: ContinuousMachClock
    ) async throws -> (
        samples: [FloorpWebExtensionStage3SimulatorPerformanceRecord.DurationSample],
        compilation: FloorpWebExtensionDNRCompilation
    ) {
        var samples = [FloorpWebExtensionStage3SimulatorPerformanceRecord.DurationSample]()
        var finalCompilation: FloorpWebExtensionDNRCompilation?
        for index in 0..<measuredSampleCount {
            let measured = try await timedNativeTransform(rules: rules, clock: clock)
            try verifyCompilation(measured.compilation)
            samples.append(.init(
                index: index,
                startTicks: measured.span.startTicks,
                endTicks: measured.span.endTicks,
                milliseconds: measured.span.milliseconds
            ))
            finalCompilation = measured.compilation
        }
        return (samples, try XCTUnwrap(finalCompilation))
    }

    private func timedNativeTransform(
        rules: [FloorpWebExtensionDNRRule],
        clock: ContinuousMachClock
    ) async throws -> (compilation: FloorpWebExtensionDNRCompilation, span: MachSpan) {
        let started = clock.now()
        let store = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(identifier: staticRuleSetIdentifier, rules: rules)],
            enabledStaticRuleSetIDs: [staticRuleSetIdentifier]
        )
        let finished = clock.now()
        return (await store.currentCompilation(), try clock.span(from: started, to: finished))
    }

    @MainActor
    private func measureWebKitCompilation(
        encodedRuleList: String,
        clock: ContinuousMachClock
    ) async throws -> [FloorpWebExtensionStage3SimulatorPerformanceRecord.TimedSample] {
        var samples = [FloorpWebExtensionStage3SimulatorPerformanceRecord.TimedSample]()
        for index in 0..<measuredSampleCount {
            samples.append(try await measureWebKitCompilationSample(
                index: index,
                encodedRuleList: encodedRuleList,
                clock: clock
            ))
        }
        return samples
    }

    @MainActor
    private func measureWebKitCompilationSample(
        index: Int,
        encodedRuleList: String,
        clock: ContinuousMachClock
    ) async throws -> FloorpWebExtensionStage3SimulatorPerformanceRecord.TimedSample {
        try await withVerifiedTemporaryDirectory(prefix: "floorp-stage3-webkit-compile") { directory in
            let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
            let empty = try await compileRuleList(
                in: store,
                identifier: "stage3-empty-\(index)-\(UUID().uuidString.lowercased())",
                encodedRuleList: encodedRuleList,
                clock: clock
            )
            _ = try await compileRuleList(
                in: store,
                identifier: "stage3-prime-\(index)-\(UUID().uuidString.lowercased())",
                encodedRuleList: encodedRuleList,
                clock: clock
            )
            let primed = try await compileRuleList(
                in: store,
                identifier: "stage3-primed-\(index)-\(UUID().uuidString.lowercased())",
                encodedRuleList: encodedRuleList,
                clock: clock
            )
            return .init(
                index: index,
                emptyStartTicks: empty.span.startTicks,
                emptyEndTicks: empty.span.endTicks,
                emptyMilliseconds: empty.span.milliseconds,
                primedStartTicks: primed.span.startTicks,
                primedEndTicks: primed.span.endTicks,
                primedMilliseconds: primed.span.milliseconds
            )
        }
    }

    @MainActor
    private func measurePageLoadPhase(
        encodedRuleList: String,
        clock: ContinuousMachClock
    ) async throws -> (
        evidence: FloorpWebExtensionStage3SimulatorPerformanceRecord.PageLoadEvidence,
        dnrFunctionalCheckPassed: Bool
    ) {
        // swiftlint:disable:next closure_body_length
        try await withVerifiedTemporaryDirectory(prefix: "floorp-stage3-page-rule-store") { directory in
            let retainedRuleStore = try XCTUnwrap(WKContentRuleListStore(url: directory))
            let retainedRuleListResult = try await compileRuleList(
                in: retainedRuleStore,
                identifier: "stage3-page-policy-\(UUID().uuidString.lowercased())",
                encodedRuleList: encodedRuleList,
                clock: clock
            )
            let server = try Stage3PerformanceServer()
            defer { server.stop() }
            let processPool = WKProcessPool()
            let websiteDataStore = WKWebsiteDataStore.nonPersistent()

            // Two alternating untimed pairs give both configurations the same
            // number of pre-measurement navigations and first/second positions.
            let warmupRuleLists: [WKContentRuleList?] = [
                nil, retainedRuleListResult.ruleList,
                retainedRuleListResult.ruleList, nil,
            ]
            for ruleList in warmupRuleLists {
                _ = try await measurePageLoad(
                    url: server.pageURL,
                    enabledRuleList: ruleList,
                    processPool: processPool,
                    websiteDataStore: websiteDataStore,
                    clock: clock
                )
            }
            let evidence = try await measurePairedPageLoads(
                server: server,
                ruleList: retainedRuleListResult.ruleList,
                processPool: processPool,
                websiteDataStore: websiteDataStore,
                clock: clock
            )
            let dnrFunctionalCheckPassed = try await verifyDemandingRuleListBlocksLocalResource(
                server: server,
                ruleList: retainedRuleListResult.ruleList,
                processPool: processPool,
                websiteDataStore: websiteDataStore,
                clock: clock
            )
            return (evidence, dnrFunctionalCheckPassed)
        }
    }

    @MainActor
    private func compileRuleList(
        in store: WKContentRuleListStore,
        identifier: String,
        encodedRuleList: String,
        clock: ContinuousMachClock
    ) async throws -> (ruleList: WKContentRuleList, span: MachSpan) {
        try await withCheckedThrowingContinuation { continuation in
            let started = clock.now()
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRuleList
            ) { ruleList, error in
                let finished = clock.now()
                do {
                    let span = try clock.span(from: started, to: finished)
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let ruleList {
                        continuation.resume(returning: (ruleList, span))
                    } else {
                        continuation.resume(throwing: performanceError("WebKit returned no compiled rule list."))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func measurePairedPageLoads(
        server: Stage3PerformanceServer,
        ruleList: WKContentRuleList,
        processPool: WKProcessPool,
        websiteDataStore: WKWebsiteDataStore,
        clock: ContinuousMachClock
    ) async throws -> FloorpWebExtensionStage3SimulatorPerformanceRecord.PageLoadEvidence {
        var pairs = [FloorpWebExtensionStage3SimulatorPerformanceRecord.PagePair]()
        for index in 0..<measuredSampleCount {
            let order: FloorpWebExtensionStage3SimulatorPerformanceRecord.PagePairOrder =
                index.isMultiple(of: 2) ? .baselineThenEnabled : .enabledThenBaseline
            let baseline: MachSpan
            let enabled: MachSpan
            switch order {
            case .baselineThenEnabled:
                baseline = try await measurePageLoad(
                    url: server.pageURL,
                    enabledRuleList: nil,
                    processPool: processPool,
                    websiteDataStore: websiteDataStore,
                    clock: clock
                )
                enabled = try await measurePageLoad(
                    url: server.pageURL,
                    enabledRuleList: ruleList,
                    processPool: processPool,
                    websiteDataStore: websiteDataStore,
                    clock: clock
                )
            case .enabledThenBaseline:
                enabled = try await measurePageLoad(
                    url: server.pageURL,
                    enabledRuleList: ruleList,
                    processPool: processPool,
                    websiteDataStore: websiteDataStore,
                    clock: clock
                )
                baseline = try await measurePageLoad(
                    url: server.pageURL,
                    enabledRuleList: nil,
                    processPool: processPool,
                    websiteDataStore: websiteDataStore,
                    clock: clock
                )
            }
            pairs.append(.init(
                index: index,
                order: order,
                baselineStartTicks: baseline.startTicks,
                baselineEndTicks: baseline.endTicks,
                baselineMilliseconds: baseline.milliseconds,
                enabledStartTicks: enabled.startTicks,
                enabledEndTicks: enabled.endTicks,
                enabledMilliseconds: enabled.milliseconds,
                signedDeltaMilliseconds: enabled.milliseconds - baseline.milliseconds
            ))
        }
        return .init(
            pairs: pairs,
            signedMeanDeltaMilliseconds: pairs.map(\.signedDeltaMilliseconds).reduce(0, +) / Double(pairs.count)
        )
    }

    @MainActor
    private func measurePageLoad(
        url: URL,
        enabledRuleList: WKContentRuleList?,
        processPool: WKProcessPool,
        websiteDataStore: WKWebsiteDataStore,
        clock: ContinuousMachClock
    ) async throws -> MachSpan {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = websiteDataStore
        if let enabledRuleList {
            configuration.userContentController.add(enabledRuleList)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = TimedNavigationDelegate(clock: clock)
        webView.navigationDelegate = navigation
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return try await navigation.measureLoad(of: request, in: webView)
    }

    @MainActor
    private func verifyDemandingRuleListBlocksLocalResource(
        server: Stage3PerformanceServer,
        ruleList: WKContentRuleList,
        processPool: WKProcessPool,
        websiteDataStore: WKWebsiteDataStore,
        clock: ContinuousMachClock
    ) async throws -> Bool {
        _ = try await measurePageLoad(
            url: server.functionalPageURL,
            enabledRuleList: nil,
            processPool: processPool,
            websiteDataStore: websiteDataStore,
            clock: clock
        )
        guard server.blockCandidateRequestCount == 1 else {
            throw performanceError(
                "The baseline functional page did not reach the local image resource exactly once."
            )
        }
        _ = try await measurePageLoad(
            url: server.functionalPageURL,
            enabledRuleList: ruleList,
            processPool: processPool,
            websiteDataStore: websiteDataStore,
            clock: clock
        )
        guard server.blockCandidateRequestCount == 1 else {
            throw performanceError(
                "The enabled demanding rule list did not block before the local server received the second image request."
            )
        }
        return true
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    private func measureMemoryReleaseAndRecovery(
        fixtureDirectory: URL,
        clock: ContinuousMachClock
    ) async throws -> FloorpWebExtensionStage3SimulatorPerformanceRecord.MemoryEvidence {
        let profileIdentifier = "stage3-performance-\(UUID().uuidString.lowercased())"
        let directory = temporaryDirectory(prefix: "floorp-stage3-memory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("packages", isDirectory: true)
        )
        let package = try await store.installBundledPackage(
            at: fixtureDirectory,
            expectedExtensionID: extensionID
        )
        let apiHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("api", isDirectory: true),
            preferredLocales: ["en-US"],
            packageResourceLoader: { _, _ in nil }
        )
        await apiHost.activate(package)
        let backgroundHost = FloorpWebExtensionLazyBackgroundHost()
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false
        )
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: backgroundHost,
            nativeAPIDispatcher: apiHost,
            profileKey: profileKey
        )
        let background = try FloorpWebExtensionBackgroundPackageGeneration(installedPackage: package)
        let resolver = store.makePageResourceResolver()
        var factoryCalls: UInt64 = 0
        weak var firstWebView: WKWebView?
        backgroundHost.register(extensionID: extensionID) {
            let handler = try FloorpWebExtensionWKBackgroundEventHandler(
                profileKey: profileKey,
                background: background,
                resolver: resolver,
                messageRuntime: runtime
            )
            factoryCalls &+= 1
            if factoryCalls == 1 {
                firstWebView = handler.webView
            }
            return handler
        }
        FloorpWebExtensionAPIHostRegistry.install(apiHost, messageRuntime: runtime)

        let samplingTask = Task { () -> [Int64] in
            var samples = [Int64]()
            while !Task.isCancelled,
                  samples.count < FloorpWebExtensionStage3SimulatorPerformanceRecord.maximumMemorySampleCount {
                if let footprint = try? Self.residentFootprintBytes() {
                    samples.append(footprint)
                }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(memorySamplingIntervalMilliseconds) * 1_000_000
                    )
                } catch {
                    break
                }
            }
            return samples
        }

        do {
            let baseline = try await settledFootprintSamples()
            let firstReplyPayload = try await backgroundHost.dispatch(
                try FloorpWebExtensionMessagePayload(FixturePing(
                    type: "floorp-fixture-ping",
                    documentGeneration: 1
                )),
                sender: fixtureSender(documentGeneration: 1)
            )
            let firstReply = try XCTUnwrap(firstReplyPayload).decode(FixtureReply.self)
            guard firstReply.accepted, firstReply.key == "1:1", factoryCalls == 1 else {
                throw performanceError("The first package-backed fixture ping did not complete as expected.")
            }
            guard firstWebView != nil else {
                throw performanceError("The first package-backed hidden WebView was never observed alive.")
            }
            let backgroundObservedBeforeRelease = true
            let fixture = try await settledFootprintSamples()

            FloorpBootstrapper.releaseWebExtensionBackgroundResources(
                profileIdentifier: profileIdentifier
            )
            for _ in 0..<200 where firstWebView != nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let priorBackgroundReleased = firstWebView == nil
            XCTAssertTrue(priorBackgroundReleased)
            XCTAssertEqual(
                backgroundHost.snapshot(for: extensionID),
                .init(isRegistered: true, isActive: false, activationCount: 1, pendingMessageCount: 0)
            )
            let postRelease = try await settledFootprintSamples()

            let recoveryStarted = clock.now()
            let replacementReplyPayload = try await backgroundHost.dispatch(
                try FloorpWebExtensionMessagePayload(FixturePing(
                    type: "floorp-fixture-ping",
                    documentGeneration: 2
                )),
                sender: fixtureSender(documentGeneration: 2)
            )
            let recoveryFinished = clock.now()
            let replacementReply = try XCTUnwrap(replacementReplyPayload).decode(FixtureReply.self)
            let postRecoveryReplyPassed = replacementReply.accepted && replacementReply.key == "1:2"
            guard postRecoveryReplyPassed, factoryCalls == 2 else {
                throw performanceError("The replacement package background did not answer the fixture ping.")
            }
            let postRecovery = try await settledFootprintSamples()

            samplingTask.cancel()
            let periodic = await samplingTask.value
            let allSamples = baseline + fixture + postRelease + postRecovery + periodic
            let peak = try XCTUnwrap(allSamples.max())
            let recoverySpan = try clock.span(from: recoveryStarted, to: recoveryFinished)
            await FloorpWebExtensionAPIHostRegistry.removeHost(for: profileKey)
            return .init(
                processName: ProcessInfo.processInfo.processName,
                processIdentifier: getpid(),
                baselineSamplesBytes: baseline,
                fixtureSamplesBytes: fixture,
                postReleaseSamplesBytes: postRelease,
                postRecoverySamplesBytes: postRecovery,
                periodicSamplesBytes: periodic,
                peakObservedBytes: peak,
                recoveryStartTicks: recoverySpan.startTicks,
                recoveryEndTicks: recoverySpan.endTicks,
                recoveryMilliseconds: recoverySpan.milliseconds,
                backgroundObservedBeforeRelease: backgroundObservedBeforeRelease,
                priorBackgroundReleased: priorBackgroundReleased,
                replacementActivationCount: factoryCalls,
                postRecoveryReplyPassed: postRecoveryReplyPassed
            )
        } catch {
            samplingTask.cancel()
            _ = await samplingTask.value
            await FloorpWebExtensionAPIHostRegistry.removeHost(for: profileKey)
            throw error
        }
    }

    private func settledFootprintSamples() async throws -> [Int64] {
        var samples = [Int64]()
        for index in 0..<memoryPhaseSampleCount {
            samples.append(try Self.residentFootprintBytes())
            if index + 1 < memoryPhaseSampleCount {
                try await Task.sleep(
                    nanoseconds: UInt64(memorySamplingIntervalMilliseconds) * 1_000_000
                )
            }
        }
        return samples
    }

    private func fixtureSender(documentGeneration: UInt64) -> FloorpWebExtensionRuntimeMessageSender {
        .init(
            extensionID: extensionID,
            tabID: 1,
            documentGeneration: documentGeneration,
            url: URL(string: "https://page.fixture.test/performance")!,
            isMainFrame: true,
            isPrivate: false
        )
    }

    private static func residentFootprintBytes() throws -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, info.phys_footprint > 0 else {
            throw performanceError("Unable to sample task_vm_info.phys_footprint.")
        }
        return Int64(info.phys_footprint)
    }

    private func verifyCompilation(_ compilation: FloorpWebExtensionDNRCompilation) throws {
        guard compilation.compiledRules.count == 5_000,
              compilation.report.acceptedRuleCount == 0,
              compilation.report.transformedRuleCount == 5_000,
              compilation.report.rejectedRuleCount == 0,
              !compilation.report.hasRejections else {
            throw performanceError("The demanding fixture compiler invariants failed.")
        }
    }

    private func checkedInFixtureDirectory(named fixtureName: String) throws -> URL {
        let fileManager = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let fixturePath = "firefox-ios/Floorp/WebExtensions/Fixtures/\(fixtureName)"
        for startingDirectory in [workingDirectory, sourceDirectory] {
            var directory = startingDirectory.standardizedFileURL
            while true {
                let candidate = directory.appendingPathComponent(fixturePath, isDirectory: true)
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }
        throw performanceError("The checked-in demanding fixture was not found.")
    }

    private func materializeStaticRules(from data: Data) throws -> [FloorpWebExtensionDNRRule] {
        let rawRules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let supportedConditionKeys: Set<String> = ["urlFilter", "resourceTypes"]
        return try rawRules.map { rawRule in
            let id = try XCTUnwrap(rawRule["id"] as? Int)
            let priority = rawRule["priority"] as? Int ?? 1
            let action = try XCTUnwrap(rawRule["action"] as? [String: Any])
            let actionType = try XCTUnwrap(
                FloorpWebExtensionDNRActionType(rawValue: try XCTUnwrap(action["type"] as? String))
            )
            let condition = try XCTUnwrap(rawRule["condition"] as? [String: Any])
            guard Set(condition.keys).isSubset(of: supportedConditionKeys) else {
                throw performanceError("The demanding fixture contains an unsupported condition key.")
            }
            let resourceTypes = try (condition["resourceTypes"] as? [String] ?? []).map {
                try XCTUnwrap(FloorpWebExtensionDNRResourceType(rawValue: $0))
            }
            return .init(
                id: id,
                priority: priority,
                action: .init(type: actionType),
                condition: .init(
                    urlFilter: condition["urlFilter"] as? String,
                    resourceTypes: resourceTypes
                )
            )
        }
    }

    private func sourceAttestation() throws -> SourceAttestation {
        let environment = ProcessInfo.processInfo.environment
        let revision = try validatedSourceRevision(
            environment["FLOORP_STAGE3_SOURCE_REVISION"] ?? ""
        )
        let attestedRevision = try validatedSourceRevision(
            environment["FLOORP_STAGE3_CLEAN_WORKTREE_ATTESTED_REVISION"] ?? ""
        )
        guard environment["FLOORP_STAGE3_WORKTREE_STATE"] == "clean",
              attestedRevision == revision,
              try repositoryHeadRevision() == revision else {
            throw performanceError(
                "A host-generated clean-worktree attestation for the exact repository HEAD is required."
            )
        }
        return .init(revision: revision, worktreeState: "clean")
    }

    private func verifySourceAttestationUnchanged(_ attestation: SourceAttestation) throws {
        let finalAttestation = try sourceAttestation()
        guard finalAttestation == attestation else {
            throw performanceError("The source attestation changed while measurements were running.")
        }
    }

    private func repositoryHeadRevision() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while true {
            let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
            let headURL = gitDirectory.appendingPathComponent("HEAD")
            if fileManager.fileExists(atPath: headURL.path) {
                let head = try String(contentsOf: headURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if head.hasPrefix("ref: ") {
                    let reference = String(head.dropFirst("ref: ".count))
                    let looseReferenceURL = gitDirectory.appendingPathComponent(reference)
                    if fileManager.fileExists(atPath: looseReferenceURL.path) {
                        return try validatedSourceRevision(
                            String(contentsOf: looseReferenceURL, encoding: .utf8)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    let packedReferences = try String(
                        contentsOf: gitDirectory.appendingPathComponent("packed-refs"),
                        encoding: .utf8
                    )
                    for line in packedReferences.split(separator: "\n") where !line.hasPrefix("#") {
                        let fields = line.split(separator: " ", maxSplits: 1)
                        if fields.count == 2, fields[1] == Substring(reference) {
                            return try validatedSourceRevision(String(fields[0]))
                        }
                    }
                    throw performanceError("The repository HEAD reference could not be resolved.")
                }
                return try validatedSourceRevision(head)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        throw performanceError("The repository HEAD could not be located.")
    }

    private func validatedSourceRevision(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 40,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw performanceError("The repository HEAD revision is invalid.")
        }
        return normalized
    }

    private func currentEnvironment() -> FloorpWebExtensionStage3SimulatorPerformanceRecord.Environment {
        var system = utsname()
        uname(&system)
        let architecture = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let environment = ProcessInfo.processInfo.environment
        return .init(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemBuild: Self.systemString(named: "kern.osversion") ?? "unavailable",
            modelIdentifier: environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unavailable",
            deviceIdentifier: environment["SIMULATOR_UDID"] ?? "unavailable",
            architecture: architecture,
            isSimulator: true
        )
    }

    private static func systemString(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func withVerifiedTemporaryDirectory<T>(
        prefix: String,
        operation: (URL) async throws -> T
    ) async throws -> T {
        let directory = temporaryDirectory(prefix: prefix)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: T
        do {
            result = try await operation(directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        try fileManager.removeItem(at: directory)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw performanceError("A temporary WebKit rule-list store survived verified cleanup.")
        }
        return result
    }
}

private struct SourceAttestation: Equatable {
    let revision: String
    let worktreeState: String
}

private struct FixturePing: Codable {
    let type: String
    let documentGeneration: UInt64
}

private struct FixtureReply: Codable {
    let accepted: Bool
    let key: String
}

private struct MachSpan: Sendable {
    let startTicks: UInt64
    let endTicks: UInt64
    let milliseconds: Double
}

private struct ContinuousMachClock: Sendable {
    let numerator: UInt32
    let denominator: UInt32

    init() throws {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            throw performanceError("Unable to read the monotonic clock timebase.")
        }
        numerator = timebase.numer
        denominator = timebase.denom
    }

    func now() -> UInt64 {
        mach_continuous_time()
    }

    func span(from start: UInt64, to end: UInt64) throws -> MachSpan {
        guard end >= start else { throw performanceError("The monotonic clock moved backwards.") }
        let nanoseconds = Double(end - start) * Double(numerator) / Double(denominator)
        let milliseconds = nanoseconds / 1_000_000
        guard milliseconds.isFinite, milliseconds > 0 else {
            throw performanceError("The measured duration was invalid.")
        }
        return .init(startTicks: start, endTicks: end, milliseconds: milliseconds)
    }
}

@MainActor
private final class TimedNavigationDelegate: NSObject, WKNavigationDelegate {
    private let clock: ContinuousMachClock
    private var started: UInt64?
    private var continuation: CheckedContinuation<MachSpan, Error>?

    init(clock: ContinuousMachClock) {
        self.clock = clock
    }

    func measureLoad(of request: URLRequest, in webView: WKWebView) async throws -> MachSpan {
        guard continuation == nil else {
            throw performanceError("A timed navigation is already active.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = clock.now()
            webView.load(request)
        }
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(clock.now()))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<UInt64, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        guard let started else {
            continuation.resume(throwing: performanceError("A timed navigation had no start tick."))
            return
        }
        self.started = nil
        switch result {
        case .success(let finished):
            do {
                continuation.resume(returning: try clock.span(from: started, to: finished))
            } catch {
                continuation.resume(throwing: error)
            }
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class Stage3PerformanceServer: @unchecked Sendable {
    private let server = GCDWebServer()
    private let lock = NSLock()
    private var candidateRequests = 0

    init() throws {
        server.addHandler(
            forMethod: "GET",
            path: "/stage3-performance/page",
            request: GCDWebServerRequest.self
        ) { _ in
            let response = GCDWebServerDataResponse(html: Self.pageHTML)!
            response.setValue("no-store", forAdditionalHeader: "Cache-Control")
            return response
        }
        server.addHandler(
            forMethod: "GET",
            path: "/stage3-performance/functional",
            request: GCDWebServerRequest.self
        ) { _ in
            let response = GCDWebServerDataResponse(html: """
            <!doctype html><html><body>
            <img src="/stage3-performance/load0041.fixture.test.gif" alt="functional-check">
            </body></html>
            """)!
            response.setValue("no-store", forAdditionalHeader: "Cache-Control")
            return response
        }
        server.addHandler(
            forMethod: "GET",
            path: "/stage3-performance/load0041.fixture.test.gif",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            self?.lock.lock()
            self?.candidateRequests += 1
            self?.lock.unlock()
            return GCDWebServerDataResponse(
                data: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!,
                contentType: "image/gif"
            )
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw performanceError("Unable to start the deterministic local performance server.")
        }
    }

    var pageURL: URL {
        URL(string: "http://localhost:\(server.port)/stage3-performance/page")!
    }

    var functionalPageURL: URL {
        URL(string: "http://localhost:\(server.port)/stage3-performance/functional")!
    }

    var blockCandidateRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return candidateRequests
    }

    func stop() {
        server.stop()
    }

    private static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Stage 3 performance</title></head>
    <body><main id="fixture">Identical deterministic local page bytes.</main></body></html>
    """
}

private func performanceError(_ message: String) -> NSError {
    NSError(
        domain: "FloorpWebExtensionStage3SimulatorPerformanceTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
