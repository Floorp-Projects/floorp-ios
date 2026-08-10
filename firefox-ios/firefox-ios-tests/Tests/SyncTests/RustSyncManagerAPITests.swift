// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import MozillaAppServices
import XCTest

@testable import Sync

final class RustSyncManagerAPITests: XCTestCase {
    func testCheckedDisconnectSuccessReplacesComponent() {
        let initialComponent = FakeSyncManagerComponent()
        let replacementComponent = FakeSyncManagerComponent()
        let factory = FakeSyncManagerComponentFactory(
            components: [initialComponent, replacementComponent]
        )
        let results = LockedRecorder<RustSyncManagerAPI.CheckedDisconnectResult>()
        let api = makeAPI(factory: factory)

        api.disconnectChecked { result in
            results.record(result)
        }
        api.disconnect()

        XCTAssertEqual(results.values, [.success])
        XCTAssertEqual(factory.invocationCount, 2)
        XCTAssertEqual(initialComponent.checkedDisconnectCallCount, 1)
        XCTAssertEqual(initialComponent.disconnectCallCount, 0)
        XCTAssertEqual(replacementComponent.disconnectCallCount, 1)
    }

    func testCheckedDisconnectFailureRetainsComponentForRetry() {
        let initialComponent = FakeSyncManagerComponent(checkedDisconnectFailures: [true, false])
        let replacementComponent = FakeSyncManagerComponent()
        let factory = FakeSyncManagerComponentFactory(
            components: [initialComponent, replacementComponent]
        )
        let results = LockedRecorder<RustSyncManagerAPI.CheckedDisconnectResult>()
        let api = makeAPI(factory: factory)

        api.disconnectChecked { result in
            results.record(result)
        }

        XCTAssertEqual(results.values, [.failure])
        XCTAssertEqual(factory.invocationCount, 1)

        api.disconnectChecked { result in
            results.record(result)
        }
        api.disconnect()

        XCTAssertEqual(results.values, [.failure, .success])
        XCTAssertEqual(factory.invocationCount, 2)
        XCTAssertEqual(initialComponent.checkedDisconnectCallCount, 2)
        XCTAssertEqual(initialComponent.disconnectCallCount, 0)
        XCTAssertEqual(replacementComponent.disconnectCallCount, 1)
    }

    func testCheckedDisconnectCompletionResolvesExactlyOnce() {
        let components = (0..<3).map { _ in FakeSyncManagerComponent() }
        let factory = FakeSyncManagerComponentFactory(components: components)
        let results = LockedRecorder<RustSyncManagerAPI.CheckedDisconnectResult>()
        let api = makeAPI(factory: factory, queueExecutionCount: 2)

        api.disconnectChecked { result in
            results.record(result)
        }

        XCTAssertEqual(results.values, [.success])
    }

    func testSyncThrowCompletesWithSyntheticOtherError() {
        let component = FakeSyncManagerComponent(syncShouldThrow: true)
        let factory = FakeSyncManagerComponentFactory(components: [component])
        let results = LockedRecorder<SyncResult>()
        let api = makeAPI(factory: factory)

        api.sync(params: makeSyncParams()) { result in
            results.record(result)
        }

        XCTAssertEqual(results.values.count, 1)
        XCTAssertEqual(results.values.first?.status, .otherError)
        XCTAssertEqual(results.values.first?.successful, [])
        XCTAssertEqual(results.values.first?.failures, ["syncmanager": "ffi-error"])
    }

    func testStaleLifecycleIsRejectedInsideComponentLockBeforeSync() {
        let component = FakeSyncManagerComponent()
        let factory = FakeSyncManagerComponentFactory(components: [component])
        let results = LockedRecorder<SyncResult>()
        let api = makeAPI(factory: factory)

        api.sync(params: makeSyncParams(), shouldStart: { false }) { result in
            results.record(result)
        }

        XCTAssertEqual(component.syncCallCount, 0)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertEqual(results.values.first?.failures, ["syncmanager": "cancelled"])
    }

    func testLockedPreparationRemovesNotesWithoutCancellingStandardEngines() {
        let component = FakeSyncManagerComponent()
        let factory = FakeSyncManagerComponentFactory(components: [component])
        let results = LockedRecorder<SyncResult>()
        let api = makeAPI(factory: factory)

        api.sync(
            params: makeSyncParams(engines: ["bookmarks", "prefs"]),
            prepareParams: { params in
                var standardOnly = params
                standardOnly.engines = .some(engines: ["bookmarks"])
                return standardOnly
            }
        ) { result in
            results.record(result)
        }

        XCTAssertEqual(component.syncCallCount, 1)
        XCTAssertEqual(
            component.lastSyncEngineSelection,
            .some(engines: ["bookmarks"])
        )
        XCTAssertEqual(results.values.first?.status, .ok)
    }

    func testSynchronizedOperationWaitsForInFlightComponentSync() {
        let syncStarted = DispatchSemaphore(value: 0)
        let allowSyncToFinish = DispatchSemaphore(value: 0)
        let syncFinished = DispatchSemaphore(value: 0)
        let synchronizedOperationFinished = DispatchSemaphore(value: 0)
        let component = FakeSyncManagerComponent(
            syncStarted: syncStarted,
            allowSyncToFinish: allowSyncToFinish
        )
        let factory = FakeSyncManagerComponentFactory(components: [component])
        let api = RustSyncManagerAPI(
            dispatchQueue: DispatchQueue.global(qos: .userInitiated),
            componentFactory: factory.make
        )

        api.sync(params: makeSyncParams(engines: ["bookmarks", "prefs"])) { _ in
            syncFinished.signal()
        }
        XCTAssertEqual(syncStarted.wait(timeout: .now() + 1), .success)

        api.synchronizeComponentState {
            synchronizedOperationFinished.signal()
        }
        XCTAssertEqual(
            synchronizedOperationFinished.wait(timeout: .now() + 0.1),
            .timedOut
        )

        allowSyncToFinish.signal()
        XCTAssertEqual(syncFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            synchronizedOperationFinished.wait(timeout: .now() + 1),
            .success
        )
    }

    func testReportSyncTelemetry() {
        let api = RustSyncManagerAPI()
        let expectation = expectation(description: "Completed telemetry reporting")
        let expected = "The operation couldn’t be completed. (MozillaAppServices.TelemetryJSONError error 0.)"
        let invalidSyncResult = SyncResult(status: ServiceStatus.ok,
                                           successful: [],
                                           failures: [:],
                                           persistedState: "",
                                           declined: nil,
                                           nextSyncAllowedAt: nil,
                                           telemetryJson: "{\"version\": \"invalidVersion\"}")
        api.reportSyncTelemetry(syncResult: invalidSyncResult) { description in
            XCTAssertEqual(description, expected)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    private func makeAPI(
        factory: FakeSyncManagerComponentFactory,
        queueExecutionCount: Int = 1
    ) -> RustSyncManagerAPI {
        RustSyncManagerAPI(
            dispatchQueue: ImmediateTestDispatchQueue(executionCount: queueExecutionCount),
            componentFactory: factory.make
        )
    }

    private func makeSyncParams(engines: [String] = []) -> SyncParams {
        SyncParams(
            reason: .user,
            engines: .some(engines: engines),
            enabledChanges: [:],
            localEncryptionKeys: [:],
            authInfo: SyncAuthInfo(
                kid: "test-kid",
                fxaAccessToken: "test-token",
                syncKey: "test-key",
                tokenserverUrl: "https://example.invalid"
            ),
            persistedState: nil,
            deviceSettings: DeviceSettings(
                fxaDeviceId: "test-device",
                name: "test-device",
                kind: .mobile
            )
        )
    }
}

private enum FakeSyncManagerComponentError: Error {
    case expected
}

private final class FakeSyncManagerComponent: RustSyncManagerComponentProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var checkedDisconnectFailures: [Bool]
    private let syncShouldThrow: Bool
    private let syncStarted: DispatchSemaphore?
    private let allowSyncToFinish: DispatchSemaphore?
    private var checkedDisconnectCalls = 0
    private var disconnectCalls = 0
    private var syncCalls = 0
    private var lastSyncEngines: SyncEngineSelection?

    init(
        checkedDisconnectFailures: [Bool] = [],
        syncShouldThrow: Bool = false,
        syncStarted: DispatchSemaphore? = nil,
        allowSyncToFinish: DispatchSemaphore? = nil
    ) {
        self.checkedDisconnectFailures = checkedDisconnectFailures
        self.syncShouldThrow = syncShouldThrow
        self.syncStarted = syncStarted
        self.allowSyncToFinish = allowSyncToFinish
    }

    var checkedDisconnectCallCount: Int {
        withLock { checkedDisconnectCalls }
    }

    var disconnectCallCount: Int {
        withLock { disconnectCalls }
    }

    var syncCallCount: Int {
        withLock { syncCalls }
    }

    var lastSyncEngineSelection: SyncEngineSelection? {
        withLock { lastSyncEngines }
    }

    func disconnect() {
        withLock {
            disconnectCalls += 1
        }
    }

    func disconnectChecked() throws {
        let shouldThrow = withLock {
            checkedDisconnectCalls += 1
            guard !checkedDisconnectFailures.isEmpty else { return false }
            return checkedDisconnectFailures.removeFirst()
        }
        if shouldThrow {
            throw FakeSyncManagerComponentError.expected
        }
    }

    func sync(params: SyncParams) throws -> SyncResult {
        withLock {
            syncCalls += 1
            lastSyncEngines = params.engines
        }
        syncStarted?.signal()
        allowSyncToFinish?.wait()
        if syncShouldThrow {
            throw FakeSyncManagerComponentError.expected
        }
        return SyncResult(
            status: .ok,
            successful: [],
            failures: [:],
            persistedState: "",
            declined: nil,
            nextSyncAllowedAt: nil,
            telemetryJson: nil
        )
    }

    func getAvailableEngines() -> [String] {
        []
    }

    private func withLock<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}

private final class FakeSyncManagerComponentFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let components: [FakeSyncManagerComponent]
    private var nextComponentIndex = 0

    init(components: [FakeSyncManagerComponent]) {
        precondition(!components.isEmpty)
        self.components = components
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextComponentIndex
    }

    func make() -> any RustSyncManagerComponentProtocol {
        lock.lock()
        defer { lock.unlock() }
        precondition(nextComponentIndex < components.count)
        let component = components[nextComponentIndex]
        nextComponentIndex += 1
        return component
    }
}

private final class LockedRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues = [Value]()

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: Value) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private final class ImmediateTestDispatchQueue: DispatchQueueInterface, @unchecked Sendable {
    private let executionCount: Int

    init(executionCount: Int) {
        self.executionCount = executionCount
    }

    func async(
        group: DispatchGroup?,
        qos: DispatchQoS,
        flags: DispatchWorkItemFlags,
        execute work: @escaping @Sendable @convention(block) () -> Void
    ) {
        (0..<executionCount).forEach { _ in work() }
    }

    func asyncAfter(deadline: DispatchTime, execute workItem: DispatchWorkItem) {
        workItem.perform()
    }

    func asyncAfter(
        deadline: DispatchTime,
        qos: DispatchQoS,
        flags: DispatchWorkItemFlags,
        execute work: @escaping @Sendable @convention(block) () -> Void
    ) {
        work()
    }

    func ensureMainThread(
        execute work: @escaping @MainActor @convention(block) () -> Void
    ) {
        MainActor.assumeIsolated {
            work()
        }
    }
}
