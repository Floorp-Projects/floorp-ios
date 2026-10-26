// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
#if canImport(Client)
@testable import Client
#endif

@MainActor
private final class WorkspaceCopyDestinationMock: FloorpWorkspaceCopyDestination {
    let windowID: UUID
    var isAvailable = true
    var preferredBatchSize = 1
    var receipts = Set<UUID>()
    var created = [(UUID, FloorpWorkspaceCopyItem)]()
    var batches = [[FloorpWorkspaceCopyEntry]]()
    var selected: UUID?
    var beforePersist: (() throws -> Void)?
    var beforePersistAsync: (() async -> Void)?
    var afterPersist: (() throws -> Void)?
    var afterReceiptRead: (() -> Void)?

    init(windowID: UUID = UUID()) { self.windowID = windowID }

    func savedReceiptIDs() async throws -> Set<UUID> {
        afterReceiptRead?()
        return receipts
    }

    func persist(item: FloorpWorkspaceCopyItem, localID: UUID) async throws {
        try beforePersist?()
        await beforePersistAsync?()
        created.append((localID, item))
        receipts.insert(localID)
        try afterPersist?()
    }

    func persistBatch(entries: [FloorpWorkspaceCopyEntry]) async throws {
        batches.append(entries)
        for entry in entries { try await persist(item: entry.item, localID: entry.localID) }
    }

    func select(localID: UUID) { selected = localID }
}

final class FloorpWorkspaceCopyTests: XCTestCase {
    private enum Failure: Error { case simulatedCrash, saveFailed }

    @MainActor
    func testPreservesOrderAndDuplicateURLsAndSeparatesExplicitCopies() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        let items = [item("one"), item("two"), item("one")]
        let operation = try service.start(items: items, generation: "owner", destination: destination)
        let result = try await service.resume(operationID: operation,
                                              generation: "owner",
                                              destination: destination,
                                              isGenerationValid: { true })
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(destination.created.map(\.1), items)
        XCTAssertEqual(Set(destination.created.map(\.0)).count, 3)
        XCTAssertEqual(destination.selected, destination.created.first?.0)
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.count, 3)
        let next = try service.start(items: items, generation: "owner", destination: destination)
        XCTAssertNotEqual(next, operation)
        _ = try await service.resume(operationID: next,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.count, 6)
        XCTAssertEqual(Set(destination.created.map(\.0)).count, 6)
    }

    @MainActor
    func testBatchesPreserveOrderDuplicateURLsAndFirstSelection() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        destination.preferredBatchSize = 32
        let items = (0..<70).map {
            FloorpWorkspaceCopyItem(url: "https://example.com/\($0 % 3)", title: "Tab \($0)")
        }
        let operation = try service.start(items: items, generation: "owner", destination: destination)
        var progress = [Int]()
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true },
                                     progress: { progress.append($0.completed) })
        XCTAssertEqual(destination.batches.map(\.count), [32, 32, 6])
        XCTAssertEqual(destination.created.map(\.1), items)
        XCTAssertEqual(Set(destination.created.map(\.0)).count, 70)
        XCTAssertEqual(destination.receipts.count, 70)
        XCTAssertEqual(destination.selected, destination.created.first?.0)
        XCTAssertEqual(progress, [0, 32, 64, 70])
    }

    @MainActor
    func testUnknownPartialOrCompleteBatchResultDoesNotRecreateClosedCopies() async throws {
        for persistedCount in [10, 32] {
            let (directory, url) = location()
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = FloorpWorkspaceCopyService(journalURL: url)
            let destination = WorkspaceCopyDestinationMock()
            destination.preferredBatchSize = 32
            let items = (0..<35).map {
                FloorpWorkspaceCopyItem(url: "https://example.com/\($0 % 3)", title: "Tab \($0)")
            }
            let operation = try service.start(items: items, generation: "owner", destination: destination)
            destination.afterPersist = {
                if destination.created.count == persistedCount { throw Failure.simulatedCrash }
            }
            do {
                _ = try await service.resume(operationID: operation,
                                             generation: "owner",
                                             destination: destination,
                                             isGenerationValid: { true })
                XCTFail("Expected an unknown batch result")
            } catch Failure.simulatedCrash { }
            let pending = try service.pendingOperation(generation: "owner", destination: destination)
            XCTAssertEqual(pending?.progress.completed, 0)
            let planned = try XCTUnwrap(destination.batches.first)
            let closedID = destination.created.removeFirst().0
            destination.afterPersist = nil
            let restarted = FloorpWorkspaceCopyService(journalURL: url)
            _ = try await restarted.resume(operationID: operation,
                                           generation: "owner",
                                           destination: destination,
                                           isGenerationValid: { true })
            XCTAssertEqual(destination.created.map(\.1), Array(items.dropFirst()))
            XCTAssertEqual(destination.created.count, 34)
            XCTAssertFalse(destination.created.contains { $0.0 == closedID })
            XCTAssertEqual(destination.receipts.count, 35)
            if persistedCount == 10 {
                XCTAssertEqual(destination.batches[1].map(\.localID), Array(planned.dropFirst(10)).map(\.localID))
            }
        }
    }

    @MainActor
    func testGenerationChangeBetweenChunksKeepsOnlyAlreadySavedCopies() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        destination.preferredBatchSize = 32
        let operation = try service.start(items: (0..<70).map { item("tab-\($0)") },
                                          generation: "owner",
                                          destination: destination)
        var valid = true
        destination.afterPersist = {
            if destination.created.count == 32 { valid = false }
        }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { valid })
            XCTFail("Expected cancellation between chunks")
        } catch FloorpWorkspaceCopyError.cancelled { }
        XCTAssertEqual(destination.created.count, 32)
        XCTAssertEqual(destination.batches.map(\.count), [32])
        XCTAssertNil(destination.selected)
        XCTAssertNil(try service.pendingOperation(generation: "owner", destination: destination))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("https://example.com/"))
    }

    @MainActor
    func testSceneLossBetweenChunksPausesAndResumesTheOriginalOperation() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        destination.preferredBatchSize = 32
        let items = (0..<70).map { item("tab-\($0)") }
        let operation = try service.start(items: items, generation: "owner", destination: destination)
        destination.afterPersist = {
            if destination.created.count == 32 { destination.isAvailable = false }
        }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected scene loss to pause the operation")
        } catch FloorpWorkspaceCopyError.destinationUnavailable { }
        XCTAssertEqual(try service.pendingOperation(generation: "owner", destination: destination)?.progress.completed, 32)
        destination.afterPersist = nil
        destination.isAvailable = true
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), items)
        XCTAssertEqual(destination.batches.map(\.count), [32, 32, 6])
        XCTAssertEqual(Set(destination.created.map(\.0)).count, 70)
    }

    @MainActor
    func testStableOperationIDKeepsTheOriginalSnapshot() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        let operation = UUID()
        _ = try service.start(items: [item("original")],
                              generation: "owner",
                              destination: destination,
                              operationID: operation)
        _ = try service.start(items: [item("changed")],
                              generation: "owner",
                              destination: destination,
                              operationID: operation)
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), [item("original")])
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("original"))
        XCTAssertFalse(data.contains("owner"))
    }

    @MainActor
    func testCrashAfterDurableSaveDoesNotRecreateAClosedCopy() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let firstService = FloorpWorkspaceCopyService(journalURL: url)
        let operation = try firstService.start(items: [item("one"), item("two")],
                                               generation: "owner",
                                               destination: destination)
        destination.afterPersist = { throw Failure.simulatedCrash }
        do {
            _ = try await firstService.resume(operationID: operation,
                                              generation: "owner",
                                              destination: destination,
                                              isGenerationValid: { true })
            XCTFail("Expected interrupted copy")
        } catch Failure.simulatedCrash { }
        let closedID = try XCTUnwrap(destination.created.first?.0)
        destination.created.removeAll()
        destination.afterPersist = nil
        let restarted = FloorpWorkspaceCopyService(journalURL: url)
        let pending = try XCTUnwrap(restarted.pendingOperation(generation: "owner", destination: destination))
        XCTAssertEqual(pending.operationID, operation)
        XCTAssertEqual(pending.progress.completed, 0)
        _ = try await restarted.resume(operationID: operation,
                                       generation: "owner",
                                       destination: destination,
                                       isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), [item("two")])
        XCTAssertFalse(destination.created.contains { $0.0 == closedID })
        XCTAssertEqual(destination.receipts.count, 2)
    }

    @MainActor
    func testPartialSaveFailureResumesOnlyUnfinishedItems() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let operation = try service.start(items: [item("one"), item("two")],
                                          generation: "owner",
                                          destination: destination)
        destination.beforePersist = {
            if !destination.created.isEmpty { throw Failure.saveFailed }
        }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected save failure")
        } catch Failure.saveFailed { }
        XCTAssertEqual(try service.pendingOperation(generation: "owner", destination: destination)?.progress.completed, 1)
        destination.beforePersist = nil
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), [item("one"), item("two")])
    }

    @MainActor
    func testGenerationChangeCancelsAndScrubsPendingSources() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let operation = try service.start(items: [item("secret-page")],
                                          generation: "account-sensitive-token",
                                          destination: destination)
        var valid = true
        destination.afterReceiptRead = { valid = false }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "account-sensitive-token",
                                         destination: destination,
                                         isGenerationValid: { valid })
            XCTFail("Expected cancellation")
        } catch FloorpWorkspaceCopyError.cancelled { }
        XCTAssertTrue(destination.created.isEmpty)
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("secret-page"))
        XCTAssertFalse(data.contains("account-sensitive-token"))
    }

    @MainActor
    func testSceneLossPausesAndDoesNotFallBackToAnotherWindow() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let otherWindow = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let operation = try service.start(items: [item("one"), item("two")],
                                          generation: "owner",
                                          destination: destination)
        destination.afterPersist = { destination.isAvailable = false }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected pause")
        } catch FloorpWorkspaceCopyError.destinationUnavailable { }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: otherWindow,
                                         isGenerationValid: { true })
            XCTFail("Expected refusal to change windows")
        } catch FloorpWorkspaceCopyError.wrongDestination { }
        XCTAssertTrue(otherWindow.created.isEmpty)
        destination.isAvailable = true
        destination.afterPersist = nil
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), [item("one"), item("two")])
    }

    @MainActor
    func testSceneLostDuringReceiptReadDoesNotInsertATab() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        let operation = try service.start(items: [item("one")], generation: "owner", destination: destination)
        destination.afterReceiptRead = { destination.isAvailable = false }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected unavailable destination")
        } catch FloorpWorkspaceCopyError.destinationUnavailable { }
        XCTAssertTrue(destination.created.isEmpty)
    }

    @MainActor
    func testConcurrentOperationsInTheSameWindowDoNotInterleave() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        let first = try service.start(items: [item("one")], generation: "owner", destination: destination)
        let second = try service.start(items: [item("two")], generation: "owner", destination: destination)
        var continuation: CheckedContinuation<Void, Never>?
        destination.beforePersistAsync = {
            await withCheckedContinuation { continuation = $0 }
        }
        let firstTask = Task {
            try await service.resume(operationID: first,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        }
        while continuation == nil { await Task.yield() }
        do {
            _ = try await service.resume(operationID: second,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected serialization of writes to one window")
        } catch FloorpWorkspaceCopyError.alreadyRunning { }
        continuation?.resume()
        _ = try await firstTask.value
        XCTAssertEqual(destination.created.map(\.1), [item("one")])
    }

    @MainActor
    func testLaterResumeRevalidatesDiskAfterAnActiveRunFinishes() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let destination = WorkspaceCopyDestinationMock()
        let operation = try service.start(items: [item("one")], generation: "owner", destination: destination)
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        try Data("corrupt journal after run".utf8).write(to: url, options: .atomic)
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("A later resume must validate the persisted journal again")
        } catch { }
        try service.cancelPendingOperations()
        XCTAssertNil(try service.pendingOperation(generation: "owner", destination: destination))
        XCTAssertEqual(destination.created.count, 1)
    }

    @MainActor
    func testStartingAndCancellingDuringAnActiveRunPreservesOtherWindowOperations() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let firstWindow = WorkspaceCopyDestinationMock()
        let secondWindow = WorkspaceCopyDestinationMock()
        let first = try service.start(items: [item("cancelled-source")], generation: "owner", destination: firstWindow)
        var continuation: CheckedContinuation<Void, Never>?
        firstWindow.beforePersistAsync = {
            await withCheckedContinuation { continuation = $0 }
        }
        let firstTask = Task {
            try await service.resume(operationID: first,
                                     generation: "owner",
                                     destination: firstWindow,
                                     isGenerationValid: { true })
        }
        while continuation == nil { await Task.yield() }
        let second = try service.start(items: [item("retained-source")], generation: "owner", destination: secondWindow)
        try service.cancelPendingOperations(windowID: firstWindow.windowID)
        continuation?.resume()
        do {
            _ = try await firstTask.value
            XCTFail("Expected the first window's operation to remain cancelled")
        } catch FloorpWorkspaceCopyError.cancelled { }
        let pending = try service.pendingOperation(generation: "owner", destination: secondWindow)
        XCTAssertEqual(pending?.operationID, second)
        let journal = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(journal.contains("cancelled-source"))
        XCTAssertTrue(journal.contains("retained-source"))
        _ = try await service.resume(operationID: second,
                                     generation: "owner",
                                     destination: secondWindow,
                                     isGenerationValid: { true })
        XCTAssertEqual(firstWindow.created.count, 1)
        XCTAssertEqual(secondWindow.created.map(\.1), [item("retained-source")])
    }

    @MainActor
    func testCancellationKeepsSavedCopiesAndForbidsRetry() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let operation = try service.start(items: [item("one"), item("two")],
                                          generation: "owner",
                                          destination: destination)
        destination.afterPersist = { try service.cancelPendingOperations() }
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Expected cancellation")
        } catch FloorpWorkspaceCopyError.cancelled { }
        XCTAssertEqual(destination.created.map(\.1), [item("one")])
        XCTAssertNil(try service.pendingOperation(generation: "owner", destination: destination))
        do {
            _ = try await service.resume(operationID: operation,
                                         generation: "owner",
                                         destination: destination,
                                         isGenerationValid: { true })
            XCTFail("Cancelled operation must remain cancelled")
        } catch FloorpWorkspaceCopyError.cancelled { }
        XCTAssertEqual(destination.created.count, 1)
    }

    @MainActor
    func testRejectsPrivateAndUnsafeDestinationsAndCorruptJournal() throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        for invalid in ["file:///tmp/file", "about:blank", "https://user:pass@example.com", "javascript:alert(1)"] {
            XCTAssertThrowsError(try service.start(items: [.init(url: invalid, title: "")],
                                                   generation: "owner",
                                                   destination: destination))
        }
        destination.isAvailable = false
        XCTAssertThrowsError(try service.start(items: [item("one")], generation: "owner", destination: destination))
        destination.isAvailable = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try service.start(items: [item("one")], generation: "owner", destination: destination))
        XCTAssertTrue(destination.created.isEmpty)
    }

    @MainActor
    func testExplicitCancellationScrubsACorruptJournal() throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupt source URL https://example.com/private".utf8).write(to: url)
        let service = FloorpWorkspaceCopyService(journalURL: url)
        try service.cancelPendingOperations()
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("private"))
        let destination = WorkspaceCopyDestinationMock()
        XCTAssertNoThrow(try service.start(items: [item("fresh")], generation: "new-owner", destination: destination))
    }

    @MainActor
    func testCanonicalNavigationURLMayExceedTheRawWireCharacterLimit() async throws {
        let (directory, url) = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = WorkspaceCopyDestinationMock()
        let service = FloorpWorkspaceCopyService(journalURL: url)
        let navigation = "https://example.com/" + String(repeating: "%E3%81%82", count: 1200)
        let value = FloorpWorkspaceCopyItem(url: navigation, title: "Expanded URL")
        let operation = try service.start(items: [value], generation: "owner", destination: destination)
        _ = try await service.resume(operationID: operation,
                                     generation: "owner",
                                     destination: destination,
                                     isGenerationValid: { true })
        XCTAssertEqual(destination.created.map(\.1), [value])
    }

    private func item(_ title: String) -> FloorpWorkspaceCopyItem {
        FloorpWorkspaceCopyItem(url: "https://example.com/\(title)", title: title)
    }

    private func location() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, directory.appendingPathComponent("operations.json"))
    }
}
