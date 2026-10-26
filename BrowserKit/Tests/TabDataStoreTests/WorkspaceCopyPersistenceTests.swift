// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import TabDataStore

private final class CopyReceiptFileManager: TabFileManager, @unchecked Sendable {
    enum Failure: Error { case writeFailed }
    var files = [URL: Data]()
    var failWrites = false
    var receiptToOmitOnWrite: UUID?
    var didWrite: (@Sendable (WindowData, URL) -> Void)?
    let primary = URL(fileURLWithPath: "/copy-tests/primary")
    let backup = URL(fileURLWithPath: "/copy-tests/backup")

    func tabSessionDataDirectory() -> URL? { nil }
    func windowDataDirectory(isBackup: Bool) -> URL? { isBackup ? backup : primary }
    func contentsOfDirectory(at path: URL) -> [URL] { Array(files.keys) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { files[destinationURL] = files[sourceURL] }
    func removeAllFilesAt(directory: URL) { files = files.filter { $0.key.deletingLastPathComponent() != directory } }
    func fileExists(atPath pathURL: URL) -> Bool { files[pathURL] != nil || pathURL == primary || pathURL == backup }
    func createDirectoryAtPath(path: URL) { }
    func getWindowDataFromPath(path: URL) throws -> WindowData? {
        guard let data = files[path] else { return nil }
        return try JSONDecoder().decode(WindowData.self, from: data)
    }
    func writeWindowData(windowData: WindowData, to url: URL) throws {
        if failWrites { throw Failure.writeFailed }
        let receipts = windowData.workspaceCopyReceipts?.filter { $0 != receiptToOmitOnWrite }
        let saved = WindowData(id: windowData.id,
                               activeTabId: windowData.activeTabId,
                               tabData: windowData.tabData,
                               workspaceCopyReceipts: receipts,
                               workspaceCopyReceiptInventoryUncertain: windowData.workspaceCopyReceiptInventoryUncertain)
        files[url] = try JSONEncoder().encode(saved)
        didWrite?(saved, url)
    }
    func removeFileAt(path: URL) { files.removeValue(forKey: path) }
}

final class WorkspaceCopyPersistenceTests: XCTestCase, @unchecked Sendable {
    func testDeferredSaveKeepsOtherWindowsDurableCopyAndBackupAssociations() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files, throttleTime: 100 * NSEC_PER_MSEC)
        let firstWindowID = UUID()
        let copyWindowID = UUID()
        let originalID = UUID()
        let latestID = UUID()
        let copiedID = UUID()
        let firstPath = files.primary.appendingPathComponent("window-\(firstWindowID.uuidString)")
        let firstBackup = files.backup.appendingPathComponent("window-\(firstWindowID.uuidString)")
        let copyBackup = files.backup.appendingPathComponent("window-\(copyWindowID.uuidString)")
        await store.saveWindowData(window: window(firstWindowID, tabID: originalID), forced: true)
        let delayedWrite = expectation(description: "Deferred first-window save completed")
        files.didWrite = { _, path in
            if path == firstPath { delayedWrite.fulfill() }
        }

        await store.saveWindowData(window: window(firstWindowID, tabID: latestID), forced: false)
        try await store.saveWindowDataDurably(window: window(copyWindowID, tabID: copiedID),
                                              workspaceCopyReceipt: copiedID)
        await fulfillment(of: [delayedWrite], timeout: 2)

        let first = await store.fetchWindowData(uuid: firstWindowID)
        let copied = await store.fetchWindowData(uuid: copyWindowID)
        let backup = try files.getWindowDataFromPath(path: firstBackup)
        XCTAssertEqual(first?.id, firstWindowID)
        XCTAssertEqual(first?.tabData.map(\.id), [latestID])
        XCTAssertNil(first?.workspaceCopyReceipts)
        XCTAssertEqual(backup?.id, firstWindowID)
        XCTAssertEqual(backup?.tabData.map(\.id), [originalID])
        XCTAssertFalse(files.fileExists(atPath: copyBackup))
        XCTAssertEqual(copied?.id, copyWindowID)
        XCTAssertEqual(copied?.tabData.map(\.id), [copiedID])
        XCTAssertEqual(copied?.workspaceCopyReceipts, [copiedID])
    }

    func testDeferredSavesTrackLatestSnapshotIndependentlyForEveryWindow() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files, throttleTime: 100 * NSEC_PER_MSEC)
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let latestID = UUID()
        let secondID = UUID()
        let writes = expectation(description: "Both windows have a scheduled save")
        writes.expectedFulfillmentCount = 2
        files.didWrite = { _, _ in writes.fulfill() }
        await store.saveWindowData(window: window(firstWindowID, tabID: UUID()), forced: false)
        await store.saveWindowData(window: window(secondWindowID, tabID: secondID), forced: false)
        await store.saveWindowData(window: window(firstWindowID, tabID: latestID), forced: false)
        await fulfillment(of: [writes], timeout: 2)
        let first = await store.fetchWindowData(uuid: firstWindowID)
        let second = await store.fetchWindowData(uuid: secondWindowID)
        XCTAssertEqual(first?.id, firstWindowID)
        XCTAssertEqual(first?.tabData.map(\.id), [latestID])
        XCTAssertEqual(second?.id, secondWindowID)
        XCTAssertEqual(second?.tabData.map(\.id), [secondID])
    }

    func testBatchCommitsEveryNormalTabAndReceiptTogetherAcrossRestart() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let ids = [UUID(), UUID()]
        try await store.saveWindowDataDurably(window: window(windowID, tabIDs: ids), workspaceCopyReceipts: Set(ids))
        let restarted = DefaultTabDataStore(fileManager: files)
        let saved = await restarted.fetchWindowData(uuid: windowID)
        let receipts = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertEqual(saved?.tabData.map(\.id), ids)
        XCTAssertEqual(Set(saved?.workspaceCopyReceipts ?? []), Set(ids))
        XCTAssertEqual(receipts, Set(ids))
    }

    func testBatchRejectsMissingPrivateOrEmptyReceiptIDsBeforeWriting() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let normalID = UUID()
        let privateID = UUID()
        let normal = window(windowID, tabID: normalID)
        let privateTab = TabData(id: privateID,
                                 title: "Private",
                                 siteUrl: "https://example.com/",
                                 faviconURL: nil,
                                 isPrivate: true,
                                 lastUsedTime: Date(),
                                 createdAtTime: Date(),
                                 temporaryDocumentSession: [:])
        let candidate = WindowData(id: windowID, activeTabId: normalID, tabData: normal.tabData + [privateTab])
        for receipts in [Set<UUID>(), [normalID, UUID()], [normalID, privateID]] {
            do {
                try await store.saveWindowDataDurably(window: candidate, workspaceCopyReceipts: receipts)
                XCTFail("Every receipt must refer to a normal tab in the committed batch")
            } catch WorkspaceCopyPersistenceError.verificationFailed { }
        }
        XCTAssertTrue(files.files.isEmpty)
    }

    func testFailedBatchWriteAcknowledgesNoReceiptsAndRetriesEntireBatch() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let ids = [UUID(), UUID()]
        files.failWrites = true
        do {
            try await store.saveWindowDataDurably(window: window(windowID, tabIDs: ids), workspaceCopyReceipts: Set(ids))
            XCTFail("Expected batch write failure")
        } catch CopyReceiptFileManager.Failure.writeFailed { }
        let failedReceipts = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertTrue(failedReceipts.isEmpty)
        files.failWrites = false
        try await store.saveWindowDataDurably(window: window(windowID, tabIDs: ids), workspaceCopyReceipts: Set(ids))
        let receipts = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertEqual(receipts, Set(ids))
    }

    func testBatchRequiresReadbackOfEveryReceipt() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let ids = [UUID(), UUID()]
        files.receiptToOmitOnWrite = ids[1]
        do {
            try await store.saveWindowDataDurably(window: window(windowID, tabIDs: ids), workspaceCopyReceipts: Set(ids))
            XCTFail("A partially verified receipt inventory cannot acknowledge the batch")
        } catch WorkspaceCopyPersistenceError.verificationFailed { }
        let receipts = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertEqual(receipts, [ids[0]])
    }

    func testSuccessfulBatchPreservesEarlierFailedCopyReceiptEvenAfterItsTabCloses() async throws {
        for closeBeforeBatch in [true, false] {
            let files = CopyReceiptFileManager()
            let store = DefaultTabDataStore(fileManager: files)
            let windowID = UUID()
            let firstID = UUID()
            let secondID = UUID()
            let first = WindowData(id: windowID,
                                   activeTabId: firstID,
                                   tabData: window(windowID, tabID: firstID).tabData,
                                   workspaceCopyReceipts: [firstID])
            files.failWrites = true
            do {
                try await store.saveWindowDataDurably(window: first, workspaceCopyReceipt: firstID)
                XCTFail("Expected first copy save to fail")
            } catch CopyReceiptFileManager.Failure.writeFailed { }

            files.failWrites = false
            let ids = closeBeforeBatch ? [secondID] : [firstID, secondID]
            let second = WindowData(id: windowID,
                                    activeTabId: secondID,
                                    tabData: window(windowID, tabIDs: ids).tabData,
                                    workspaceCopyReceipts: [firstID])
            try await store.saveWindowDataDurably(window: second, workspaceCopyReceipts: [secondID])
            let closed = WindowData(id: windowID,
                                    activeTabId: secondID,
                                    tabData: window(windowID, tabID: secondID).tabData,
                                    workspaceCopyReceipts: [firstID, secondID])
            await store.saveWindowData(window: closed, forced: true)
            let restarted = DefaultTabDataStore(fileManager: files)
            let receipts = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
            let saved = await restarted.fetchWindowData(uuid: windowID)
            XCTAssertEqual(receipts, [firstID, secondID])
            XCTAssertEqual(saved?.tabData.map(\.id), [secondID])
        }
    }

    func testReceiptAndNormalTabCommitTogetherAndReceiptSurvivesClosingAndRestart() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let localID = UUID()
        try await store.saveWindowDataDurably(window: window(windowID, tabID: localID), workspaceCopyReceipt: localID)
        let saved = await store.fetchWindowData(uuid: windowID)
        XCTAssertEqual(saved?.tabData.first?.id, localID)
        XCTAssertEqual(saved?.workspaceCopyReceipts, [localID])

        let closedWindow = WindowData(id: windowID, activeTabId: UUID(), tabData: [], workspaceCopyReceipts: [localID])
        await store.saveWindowData(window: closedWindow, forced: true)
        let restarted = DefaultTabDataStore(fileManager: files)
        let receipts = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertEqual(receipts, [localID])
        let closed = await restarted.fetchWindowData(uuid: windowID)
        XCTAssertTrue(closed?.tabData.isEmpty == true)
    }

    func testOlderDeferredSaveCannotRemoveADurablyCopiedTab() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let localID = UUID()
        let stale = window(windowID, tabID: nil)
        try await store.saveWindowDataDurably(window: window(windowID, tabID: localID), workspaceCopyReceipt: localID)
        await store.saveWindowData(window: stale, forced: true)
        let saved = await store.fetchWindowData(uuid: windowID)
        XCTAssertEqual(saved?.tabData.map(\.id), [localID])
        XCTAssertEqual(saved?.workspaceCopyReceipts, [localID])
    }

    func testOlderDurableSnapshotCannotOverwriteANewerCopy() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let committedID = UUID()
        let staleID = UUID()
        try await store.saveWindowDataDurably(window: window(windowID, tabID: committedID),
                                              workspaceCopyReceipt: committedID)
        do {
            try await store.saveWindowDataDurably(window: window(windowID, tabID: staleID),
                                                  workspaceCopyReceipt: staleID)
            XCTFail("Expected stale snapshot rejection")
        } catch WorkspaceCopyPersistenceError.verificationFailed { }
        let saved = await store.fetchWindowData(uuid: windowID)
        XCTAssertEqual(saved?.tabData.map(\.id), [committedID])
        XCTAssertEqual(saved?.workspaceCopyReceipts, [committedID])
    }

    func testFailedOrdinarySaveCannotPolluteCommittedCopyReceipts() async throws {
        let files = CopyReceiptFileManager()
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let localID = UUID()
        await store.saveWindowData(window: window(windowID, tabID: nil), forced: true)
        files.failWrites = true
        let candidate = WindowData(id: windowID,
                                   activeTabId: localID,
                                   tabData: window(windowID, tabID: localID).tabData,
                                   workspaceCopyReceipts: [localID])
        do {
            try await store.saveWindowDataDurably(window: candidate, workspaceCopyReceipt: localID)
            XCTFail("Expected durable save to fail")
        } catch CopyReceiptFileManager.Failure.writeFailed { }
        await store.saveWindowData(window: candidate, forced: true)
        let receipts = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertFalse(receipts.contains(localID))
        let saved = await store.fetchWindowData(uuid: windowID)
        XCTAssertFalse(saved?.tabData.contains { $0.id == localID } == true)
        files.failWrites = false
        await store.saveWindowData(window: candidate, forced: true)
        let verified = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertTrue(verified.contains(localID))
    }

    func testFailedWriteCannotAcknowledgeACopy() async throws {
        let files = CopyReceiptFileManager()
        files.failWrites = true
        let store = DefaultTabDataStore(fileManager: files)
        let windowID = UUID()
        let localID = UUID()
        do {
            try await store.saveWindowDataDurably(window: window(windowID, tabID: localID), workspaceCopyReceipt: localID)
            XCTFail("Expected failed save")
        } catch CopyReceiptFileManager.Failure.writeFailed { }
        let receipts = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertTrue(receipts.isEmpty)
        files.failWrites = false
        try await store.saveWindowDataDurably(window: window(windowID, tabID: localID), workspaceCopyReceipt: localID)
        let saved = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
        XCTAssertEqual(saved, [localID])
    }

    func testCorruptPrimaryDoesNotUseAnOlderBackupToRepeatCopies() async throws {
        let files = CopyReceiptFileManager()
        let windowID = UUID()
        let primary = files.primary.appendingPathComponent("window-\(windowID.uuidString)")
        let backup = files.backup.appendingPathComponent("window-\(windowID.uuidString)")
        files.files[primary] = Data("corrupt".utf8)
        files.files[backup] = try JSONEncoder().encode(window(windowID, tabID: nil))
        let store = DefaultTabDataStore(fileManager: files)
        do {
            _ = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
            XCTFail("Unknown save results must fail closed")
        } catch { }
        files.files.removeValue(forKey: primary)
        do {
            _ = try await store.fetchWorkspaceCopyReceipts(windowID: windowID)
            XCTFail("Backup alone cannot prove whether a copy was committed")
        } catch WorkspaceCopyPersistenceError.receiptInventoryUncertain { }
    }

    func testFallbackThenOrdinarySaveCannotHideUnknownCopyReceiptsAcrossRestart() async throws {
        for corruptPrimary in [true, false] {
            let files = CopyReceiptFileManager()
            let windowID = UUID()
            let knownID = UUID()
            let primary = files.primary.appendingPathComponent("window-\(windowID.uuidString)")
            let backup = files.backup.appendingPathComponent("window-\(windowID.uuidString)")
            let backupData = window(windowID, tabID: knownID)
            let oldWindow = WindowData(id: windowID,
                                       activeTabId: knownID,
                                       tabData: backupData.tabData,
                                       workspaceCopyReceipts: [knownID])
            files.files[backup] = try JSONEncoder().encode(oldWindow)
            if corruptPrimary { files.files[primary] = Data("corrupt".utf8) }
            let restoring = DefaultTabDataStore(fileManager: files)
            let restored = await restoring.fetchWindowData(uuid: windowID)
            XCTAssertEqual(restored?.tabData.first?.id, knownID)
            await restoring.saveWindowData(window: backupData, forced: true)

            let restarted = DefaultTabDataStore(fileManager: files)
            do {
                _ = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
                XCTFail("Replacing a corrupt/missing primary from backup cannot authorize pending copy replay")
            } catch WorkspaceCopyPersistenceError.receiptInventoryUncertain { }
            let marked = await restarted.fetchWindowData(uuid: windowID)
            XCTAssertEqual(marked?.workspaceCopyReceiptInventoryUncertain, true)

            // The caller first discards every pending operation for this window.
            try await restarted.resolveWorkspaceCopyReceiptUncertainty(windowID: windowID)
            let known = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
            XCTAssertEqual(known, [knownID])
            let resolved = await restarted.fetchWindowData(uuid: windowID)
            XCTAssertEqual(resolved?.tabData.map(\.id), [knownID])
            XCTAssertNil(resolved?.workspaceCopyReceiptInventoryUncertain)

            let freshID = UUID()
            let freshTab = window(windowID, tabID: freshID).tabData
            let fresh = WindowData(id: windowID,
                                   activeTabId: knownID,
                                   tabData: oldWindow.tabData + freshTab,
                                   workspaceCopyReceipts: [knownID])
            try await restarted.saveWindowDataDurably(window: fresh, workspaceCopyReceipt: freshID)
            let saved = await restarted.fetchWindowData(uuid: windowID)
            XCTAssertEqual(saved?.tabData.map(\.id), [knownID, freshID])
        }
    }

    func testMissingPrimaryAndBackupRemainUncertainAfterEmptyRestoreSave() async throws {
        let files = CopyReceiptFileManager()
        let windowID = UUID()
        let restoring = DefaultTabDataStore(fileManager: files)
        let restored = await restoring.fetchWindowData(uuid: windowID)
        XCTAssertNil(restored)
        await restoring.saveWindowData(window: window(windowID, tabID: nil), forced: true)
        let restarted = DefaultTabDataStore(fileManager: files)
        do {
            _ = try await restarted.fetchWorkspaceCopyReceipts(windowID: windowID)
            XCTFail("Missing inventory must not become a known empty receipt list")
        } catch WorkspaceCopyPersistenceError.receiptInventoryUncertain { }
    }

    func testExplicitResolutionPreservesLatestPendingBrowserTabs() async throws {
        let files = CopyReceiptFileManager()
        let windowID = UUID()
        let firstID = UUID()
        let newestID = UUID()
        let store = DefaultTabDataStore(fileManager: files, throttleTime: 60 * NSEC_PER_SEC)
        _ = await store.fetchWindowData(uuid: windowID)
        await store.saveWindowData(window: window(windowID, tabID: firstID), forced: true)
        let newest = WindowData(id: windowID,
                                activeTabId: newestID,
                                tabData: window(windowID, tabIDs: [firstID, newestID]).tabData)
        await store.saveWindowData(window: newest, forced: false)
        await store.saveWindowData(window: window(UUID(), tabID: UUID()), forced: false)
        try await store.resolveWorkspaceCopyReceiptUncertainty(windowID: windowID)
        let saved = await store.fetchWindowData(uuid: windowID)
        XCTAssertEqual(saved?.tabData.map(\.id), [firstID, newestID])
        XCTAssertNil(saved?.workspaceCopyReceiptInventoryUncertain)
    }

    func testExistingWindowWithoutReceiptsStillDecodes() throws {
        let original = window(UUID(), tabID: UUID())
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "workspaceCopyReceipts")
        let decoded = try JSONDecoder().decode(WindowData.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.workspaceCopyReceipts)
    }

    private func window(_ windowID: UUID, tabID: UUID?) -> WindowData {
        window(windowID, tabIDs: tabID.map { [$0] } ?? [])
    }

    private func window(_ windowID: UUID, tabIDs: [UUID]) -> WindowData {
        let tabs = tabIDs.map {
            TabData(id: $0,
                    title: "Copied page",
                    siteUrl: "https://example.com/",
                    faviconURL: nil,
                    isPrivate: false,
                    lastUsedTime: Date(),
                    createdAtTime: Date(),
                    temporaryDocumentSession: [:])
        }
        return WindowData(id: windowID, activeTabId: tabIDs.first ?? UUID(), tabData: tabs)
    }
}
