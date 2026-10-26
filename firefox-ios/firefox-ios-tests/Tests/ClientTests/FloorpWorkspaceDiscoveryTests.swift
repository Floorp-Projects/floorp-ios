// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import MozillaAppServices
import XCTest
@testable import Client

final class FloorpWorkspaceDiscoveryTests: XCTestCase {
    func testSnapshotPreservesDuplicateURLsAndOriginalIDs() throws {
        let json = """
        {"schemaVersion":1,"accountUid":"account-a","revision":4,"globalSyncId":"global",
         "collectionSyncId":"collection","engineVersion":1,"status":"ready","lastReceivedMillis":1000,
         "workspaces":[{"id":"ABC","name":"Work","icon":"unknown-icon","tabs":[
           {"id":"abc","url":"https://example.com/","title":"First","pinned":true,"position":0},
           {"id":"AbC","url":"https://example.com/","title":"Second","pinned":false,"position":1}]}]}
        """
        let snapshot = try JSONDecoder().decode(FloorpWorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.hasConfirmedSnapshot)
        XCTAssertEqual(snapshot.lastReceivedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.workspaces.first?.icon, "unknown-icon")
        XCTAssertEqual(snapshot.workspaces.first?.tabs.map(\.id), ["abc", "AbC"])
        XCTAssertEqual(snapshot.workspaces.first?.tabs.map(\.title), ["First", "Second"])
    }

    func testContentRevisionDoesNotChangeCopyAssociationButResetDoes() {
        let original = makeSnapshot(revision: 1)
        XCTAssertTrue(original.hasSameAssociation(as: makeSnapshot(revision: 9)))
        XCTAssertFalse(original.hasSameAssociation(as: makeSnapshot(collection: "new-collection")))
        XCTAssertFalse(original.hasSameAssociation(as: makeSnapshot(account: "account-b")))
        XCTAssertFalse(makeSnapshot(status: "unsupportedVersion", version: 2).hasConfirmedSnapshot)
        XCTAssertFalse(makeSnapshot(status: "unpublished", version: nil).hasConfirmedSnapshot)
    }

    func testLargeUnsupportedEngineVersionDecodesAsIneligible() throws {
        let json = """
        {"schemaVersion":1,"accountUid":"account-a","revision":5,"globalSyncId":"global",
         "collectionSyncId":"collection","engineVersion":4294967296,"status":"unsupportedVersion",
         "lastReceivedMillis":null,"workspaces":[]}
        """
        let snapshot = try JSONDecoder().decode(FloorpWorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.engineVersion, 4_294_967_296)
        XCTAssertFalse(snapshot.hasConfirmedSnapshot)
    }

    func testProviderRejectsCompletionFromBeforeAccountSwitch() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let oldGeneration = try fixture.provider.prepare(accountID: "account-a")
        let generation = try fixture.provider.prepare(accountID: "account-b")
        let eventCount = fixture.events.values.count
        fixture.provider.didFinishSync(successful: true, status: .ok, generation: oldGeneration)
        XCTAssertEqual(fixture.events.values.count, eventCount)
        fixture.provider.didFinishSync(successful: true, status: .ok, generation: generation)
        guard case .finished(let snapshot, true, .ok, let receivedGeneration) = fixture.events.values.last else {
            return XCTFail("Expected current-account completion")
        }
        XCTAssertEqual(receivedGeneration, generation)
        XCTAssertEqual(snapshot?.accountUid, "account-b")
        XCTAssertEqual(fixture.store.boundAccounts, ["account-a", "account-b"])
    }

    func testSuspensionDurablyFencesOldCacheAndCompletionAcrossRestart() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let generation = try fixture.provider.prepare(accountID: "account-a")
        fixture.provider.suspend()
        XCTAssertEqual(fixture.store.invalidateCount, 1)
        XCTAssertNil(fixture.provider.snapshotForCopyValidation())
        let count = fixture.events.values.count
        fixture.provider.didFinishSync(successful: true, status: .ok, generation: generation)
        XCTAssertEqual(fixture.events.values.count, count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
        let restarted = FloorpWorkspaceSyncEngineProvider(
            store: fixture.store,
            invalidationURL: fixture.marker,
            event: { _ in }
        )
        _ = try restarted.prepare(accountID: "account-a")
        XCTAssertEqual(fixture.store.invalidateCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    func testUnchangedAccountRetainsRegisteredStoreAndDoesNotWipeCache() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertEqual(try fixture.provider.prepare(accountID: "account-a"),
                       try fixture.provider.prepare(accountID: "account-a"))
        XCTAssertEqual(fixture.store.registrationCount, 1)
        XCTAssertEqual(fixture.store.invalidateCount, 0)
    }

    func testLiveCopyEligibilitySeesBackendWithdrawalBeforeSyncCompletion() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.provider.prepare(accountID: "account-a")
        let original = try XCTUnwrap(fixture.provider.snapshotForCopyValidation())
        XCTAssertTrue(original.hasConfirmedSnapshot)
        fixture.store.status = "unsupportedVersion"
        let live = try XCTUnwrap(fixture.provider.snapshotForCopyValidation())
        XCTAssertFalse(live.hasConfirmedSnapshot)
        XCTAssertEqual(live.status, "unsupportedVersion")
    }

    func testLiveCopyEligibilityAllowsOrdinaryRevisionButRejectsAssociationChange() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.provider.prepare(accountID: "account-a")
        let original = try XCTUnwrap(fixture.provider.snapshotForCopyValidation())
        fixture.store.snapshotRevision = 999
        let refreshed = try XCTUnwrap(fixture.provider.snapshotForCopyValidation())
        XCTAssertTrue(refreshed.hasConfirmedSnapshot)
        XCTAssertTrue(original.hasSameAssociation(as: refreshed))
        fixture.store.collectionID = "reset-collection"
        let reset = try XCTUnwrap(fixture.provider.snapshotForCopyValidation())
        XCTAssertFalse(original.hasSameAssociation(as: reset))
    }

    func testLiveCopyEligibilityFailsClosedOnStoreReadError() throws {
        let fixture = try makeProvider()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.provider.prepare(accountID: "account-a")
        fixture.store.snapshotError = true
        XCTAssertNil(fixture.provider.snapshotForCopyValidation())
    }

    func testExplicitCorruptCacheRecoveryRemovesCacheAndItsJournals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["received.json", "received.pending", "received.invalidated", "other-file"] {
            try Data("invalid".utf8).write(to: directory.appendingPathComponent(name))
        }
        try FloorpWorkspaceCacheRecovery.removeUnusableCache(at: directory.appendingPathComponent("received.json"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["other-file"])
    }

    private struct Fixture {
        let provider: FloorpWorkspaceSyncEngineProvider
        let store: WorkspaceStore
        let events: Events
        let directory: URL
        let marker: URL
    }

    private func makeProvider() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("invalidated")
        let events = Events()
        let store = WorkspaceStore()
        let provider = FloorpWorkspaceSyncEngineProvider(store: store, invalidationURL: marker) {
            events.append($0)
        }
        return Fixture(provider: provider, store: store, events: events, directory: directory, marker: marker)
    }

    private func makeSnapshot(
        account: String = "account-a",
        collection: String = "collection",
        revision: UInt64 = 1,
        status: String = "ready",
        version: UInt64? = 1
    ) -> FloorpWorkspaceSnapshot {
        FloorpWorkspaceSnapshot(
            schemaVersion: 1,
            accountUid: account,
            revision: revision,
            globalSyncId: "global",
            collectionSyncId: collection,
            engineVersion: version,
            status: status,
            lastReceivedMillis: 1000,
            workspaces: []
        )
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FloorpWorkspaceProviderEvent] = []
    var values: [FloorpWorkspaceProviderEvent] { lock.withLock { events } }
    func append(_ event: FloorpWorkspaceProviderEvent) { lock.withLock { events.append(event) } }
}

private final class WorkspaceStore: FloorpWorkspaceStoreProtocol {
    private var account: String?
    var status = "ready"
    var collectionID = "collection"
    var snapshotRevision: UInt64 = 1
    var snapshotError = false
    private(set) var boundAccounts: [String] = []
    private(set) var invalidateCount = 0
    private(set) var registrationCount = 0

    func bindAccount(uid: String) throws {
        account = uid
        boundAccounts.append(uid)
    }

    func invalidate() throws { invalidateCount += 1; account = nil }
    func registerWithSyncManager() { registrationCount += 1 }

    func copyEligibilityJson() throws -> String { try snapshotJson() }

    func snapshotJson() throws -> String {
        if snapshotError { throw CocoaError(.fileReadUnknown) }
        let snapshot = FloorpWorkspaceSnapshot(
            schemaVersion: 1,
            accountUid: account,
            revision: snapshotRevision,
            globalSyncId: "global",
            collectionSyncId: collectionID,
            engineVersion: 1,
            status: status,
            lastReceivedMillis: 1000,
            workspaces: []
        )
        return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    }
}
