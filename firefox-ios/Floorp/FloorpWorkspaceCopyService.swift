// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct FloorpWorkspaceCopyItem: Codable, Equatable, Sendable {
    let url: String
    let title: String
}

struct FloorpWorkspaceCopyEntry: Equatable, Sendable {
    let item: FloorpWorkspaceCopyItem
    let localID: UUID
}

struct FloorpWorkspaceCopyProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    var isComplete: Bool { completed == total }
}

struct FloorpWorkspacePendingCopy: Equatable, Sendable {
    let operationID: UUID
    let progress: FloorpWorkspaceCopyProgress
}

enum FloorpWorkspaceCopyError: Error {
    case invalidItems
    case operationNotFound
    case cancelled
    case alreadyRunning
    case destinationUnavailable
    case wrongDestination
    case persistenceUnavailable
    case invalidJournal
}

@MainActor
protocol FloorpWorkspaceCopyDestination: AnyObject {
    var windowID: UUID { get }
    var isAvailable: Bool { get }
    var preferredBatchSize: Int { get }
    func savedReceiptIDs() async throws -> Set<UUID>
    func persist(item: FloorpWorkspaceCopyItem, localID: UUID) async throws
    func persistBatch(entries: [FloorpWorkspaceCopyEntry]) async throws
    func select(localID: UUID)
    func discardUncertainCopyInventory() async throws
}

extension FloorpWorkspaceCopyDestination {
    var preferredBatchSize: Int { 1 }

    func persistBatch(entries: [FloorpWorkspaceCopyEntry]) async throws {
        for entry in entries { try await persist(item: entry.item, localID: entry.localID) }
    }

    func discardUncertainCopyInventory() async throws {}
}

@MainActor
final class FloorpWorkspaceCopyService {
    private struct Operation: Codable {
        enum Status: String, Codable { case pending, completed, cancelled }
        let id: UUID
        let windowID: UUID
        var generation: String?
        var items: [FloorpWorkspaceCopyItem]?
        let localIDs: [UUID]
        var savedIDs: Set<UUID>
        var status: Status

        var progress: FloorpWorkspaceCopyProgress {
            FloorpWorkspaceCopyProgress(completed: savedIDs.count, total: localIDs.count)
        }

        mutating func finish(_ status: Status) {
            self.status = status
            generation = nil
            items = nil
        }
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        var operations: [Operation]
    }

    private let journalURL: URL
    private var running = Set<UUID>()
    private var runningWindows = Set<UUID>()
    private var activeJournal: Journal?

    init(journalURL: URL) {
        self.journalURL = journalURL
    }

    func start(items: [FloorpWorkspaceCopyItem],
               generation: String,
               destination: FloorpWorkspaceCopyDestination,
               operationID: UUID = UUID()) throws -> UUID {
        guard destination.isAvailable else { throw FloorpWorkspaceCopyError.destinationUnavailable }
        guard !generation.isEmpty, !items.isEmpty, items.allSatisfy(Self.isValid) else {
            throw FloorpWorkspaceCopyError.invalidItems
        }
        var journal = try load()
        if let existing = journal.operations.first(where: { $0.id == operationID }) {
            guard existing.windowID == destination.windowID else { throw FloorpWorkspaceCopyError.wrongDestination }
            guard existing.status == .pending, existing.generation == generation else {
                throw FloorpWorkspaceCopyError.cancelled
            }
            return operationID
        }
        let operation = Operation(id: operationID,
                                  windowID: destination.windowID,
                                  generation: generation,
                                  items: items,
                                  localIDs: items.map { _ in UUID() },
                                  savedIDs: [],
                                  status: .pending)
        journal.operations.append(operation)
        try save(journal)
        return operation.id
    }

    func pendingOperation(generation: String,
                          destination: FloorpWorkspaceCopyDestination) throws -> FloorpWorkspacePendingCopy? {
        try invalidatePendingOperations(exceptGeneration: generation)
        return try load().operations.first(where: {
            $0.status == .pending && $0.generation == generation && $0.windowID == destination.windowID
        }).map { FloorpWorkspacePendingCopy(operationID: $0.id, progress: $0.progress) }
    }

    func resume(operationID: UUID,
                generation: String,
                destination: FloorpWorkspaceCopyDestination,
                isGenerationValid: () -> Bool,
                progress: (FloorpWorkspaceCopyProgress) -> Void = { _ in }) async throws -> FloorpWorkspaceCopyProgress {
        if running.isEmpty { activeJournal = nil }
        guard !runningWindows.contains(destination.windowID), running.insert(operationID).inserted else {
            throw FloorpWorkspaceCopyError.alreadyRunning
        }
        runningWindows.insert(destination.windowID)
        defer {
            running.remove(operationID)
            runningWindows.remove(destination.windowID)
            if running.isEmpty { activeJournal = nil }
        }
        var operation = try find(operationID)
        guard operation.windowID == destination.windowID else { throw FloorpWorkspaceCopyError.wrongDestination }
        if operation.status == .completed { return operation.progress }
        guard operation.status == .pending else { throw FloorpWorkspaceCopyError.cancelled }
        guard operation.generation == generation, isGenerationValid() else {
            try cancel(operationID: operationID)
            throw FloorpWorkspaceCopyError.cancelled
        }
        guard let items = operation.items, items.count == operation.localIDs.count else {
            throw FloorpWorkspaceCopyError.invalidJournal
        }
        progress(operation.progress)
        let entries = zip(items, operation.localIDs).compactMap { item, localID in
            operation.savedIDs.contains(localID) ? nil : FloorpWorkspaceCopyEntry(item: item, localID: localID)
        }
        let batchSize = min(max(destination.preferredBatchSize, 1), 32)
        for offset in stride(from: 0, to: entries.count, by: batchSize) {
            let chunk = Array(entries[offset..<min(offset + batchSize, entries.count)])
            try validate(operationID: operationID,
                         generation: generation,
                         destination: destination,
                         isGenerationValid: isGenerationValid)
            let receipts = try await destination.savedReceiptIDs()
            try validate(operationID: operationID,
                         generation: generation,
                         destination: destination,
                         isGenerationValid: isGenerationValid)
            let unfinished = chunk.filter { !receipts.contains($0.localID) }
            if !unfinished.isEmpty {
                if batchSize == 1, let entry = unfinished.first {
                    try await destination.persist(item: entry.item, localID: entry.localID)
                } else {
                    try await destination.persistBatch(entries: unfinished)
                }
            }
            // Persistence receipts outlive the tab. A crash before this journal update
            // must not recreate a successfully copied tab that the user later closed.
            try acknowledge(operationID: operationID, localIDs: chunk.map(\.localID))
            operation = try find(operationID)
            progress(operation.progress)
            await Task.yield()
        }
        try validate(operationID: operationID,
                     generation: generation,
                     destination: destination,
                     isGenerationValid: isGenerationValid)
        try complete(operationID: operationID)
        if let first = operation.localIDs.first { destination.select(localID: first) }
        return operation.progress
    }

    func cancelPendingOperations() throws {
        do {
            try invalidatePendingOperations(exceptGeneration: nil)
        } catch {
            try save(Journal(schemaVersion: 1, operations: []))
        }
    }

    func cancelPendingOperations(windowID: UUID) throws {
        var journal = try load()
        for index in journal.operations.indices where journal.operations[index].status == .pending &&
            journal.operations[index].windowID == windowID {
            journal.operations[index].finish(.cancelled)
        }
        try save(journal)
    }

    func invalidatePendingOperations(exceptGeneration generation: String?) throws {
        var journal = try load()
        var changed = false
        for index in journal.operations.indices where journal.operations[index].status == .pending &&
            journal.operations[index].generation != generation {
            journal.operations[index].finish(.cancelled)
            changed = true
        }
        if changed { try save(journal) }
    }

    func cancel(operationID: UUID) throws {
        try update(operationID) { operation in
            if operation.status == .pending { operation.finish(.cancelled) }
        }
    }

    private func validate(operationID: UUID,
                          generation: String,
                          destination: FloorpWorkspaceCopyDestination,
                          isGenerationValid: () -> Bool) throws {
        let operation = try find(operationID)
        guard operation.status == .pending else { throw FloorpWorkspaceCopyError.cancelled }
        guard operation.generation == generation, isGenerationValid(), !Task.isCancelled else {
            try cancel(operationID: operationID)
            throw FloorpWorkspaceCopyError.cancelled
        }
        guard destination.isAvailable else { throw FloorpWorkspaceCopyError.destinationUnavailable }
    }

    private func acknowledge(operationID: UUID, localIDs: [UUID]) throws {
        try update(operationID) { operation in
            guard Set(localIDs).isSubset(of: Set(operation.localIDs)) else {
                throw FloorpWorkspaceCopyError.invalidJournal
            }
            operation.savedIDs.formUnion(localIDs)
        }
    }

    private func complete(operationID: UUID) throws {
        try update(operationID) { operation in
            guard operation.status == .pending, operation.progress.isComplete else {
                throw FloorpWorkspaceCopyError.cancelled
            }
            operation.finish(.completed)
        }
    }

    private func update(_ id: UUID, mutation: (inout Operation) throws -> Void) throws {
        var journal = try load()
        guard let index = journal.operations.firstIndex(where: { $0.id == id }) else {
            throw FloorpWorkspaceCopyError.operationNotFound
        }
        try mutation(&journal.operations[index])
        try save(journal)
    }

    private func find(_ id: UUID) throws -> Operation {
        guard let operation = try load().operations.first(where: { $0.id == id }) else {
            throw FloorpWorkspaceCopyError.operationNotFound
        }
        return operation
    }

    private func load() throws -> Journal {
        if !running.isEmpty, let activeJournal { return activeJournal }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            let journal = Journal(schemaVersion: 1, operations: [])
            if !running.isEmpty { activeJournal = journal }
            return journal
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.schemaVersion == 1,
              Set(journal.operations.map(\.id)).count == journal.operations.count,
              journal.operations.allSatisfy({ operation in
                !operation.localIDs.isEmpty && Set(operation.localIDs).count == operation.localIDs.count &&
                    operation.savedIDs.isSubset(of: Set(operation.localIDs)) &&
                    (operation.status != .pending || (operation.items?.count == operation.localIDs.count &&
                                                        operation.items?.allSatisfy(Self.isValid) == true &&
                                                        operation.generation?.isEmpty == false))
              }) else {
            throw FloorpWorkspaceCopyError.invalidJournal
        }
        if !running.isEmpty { activeJournal = journal }
        return journal
    }

    private func save(_ journal: Journal) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(journal)
        try encoded.write(to: journalURL, options: .atomic)
        guard try Data(contentsOf: journalURL) == encoded else { throw FloorpWorkspaceCopyError.invalidJournal }
        activeJournal = running.isEmpty ? nil : journal
    }

    private static func isValid(_ item: FloorpWorkspaceCopyItem) -> Bool {
        guard item.url.utf8.count <= 64 * 1024, item.title.utf16.count <= 1024,
              let components = URLComponents(string: item.url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.url != nil else { return false }
        return true
    }
}

#if canImport(UIKit)
extension FloorpWorkspaceCopyService {
    static let shared = FloorpWorkspaceCopyService(
        journalURL: URL.applicationSupportDirectory
            .appendingPathComponent("FloorpWorkspaceCopies/profile.profile/operations.json")
    )
}

@MainActor
final class FloorpWorkspaceTabCopyDestination: FloorpWorkspaceCopyDestination {
    private weak var tabManager: (any TabManager)?
    private let availability: () -> Bool
    let windowID: UUID

    init(tabManager: any TabManager, isAvailable: @escaping () -> Bool) {
        self.tabManager = tabManager
        self.windowID = tabManager.windowUUID
        self.availability = isAvailable
    }

    var isAvailable: Bool {
        guard let tabManager else { return false }
        return availability() && tabManager.tabRestoreHasFinished && !tabManager.isRestoringTabs
    }

    var preferredBatchSize: Int { 32 }

    func savedReceiptIDs() async throws -> Set<UUID> {
        guard isAvailable, let tabManager else { throw FloorpWorkspaceCopyError.destinationUnavailable }
        return try await tabManager.workspaceCopyReceiptIDs()
    }

    func persist(item: FloorpWorkspaceCopyItem, localID: UUID) async throws {
        guard isAvailable, let tabManager else { throw FloorpWorkspaceCopyError.destinationUnavailable }
        try await tabManager.persistWorkspaceCopy(item: item, localID: localID)
    }

    func persistBatch(entries: [FloorpWorkspaceCopyEntry]) async throws {
        guard isAvailable, let tabManager else { throw FloorpWorkspaceCopyError.destinationUnavailable }
        try await tabManager.persistWorkspaceCopies(entries: entries)
    }

    func select(localID: UUID) {
        guard isAvailable, let tabManager,
              let first = tabManager.getTabForUUID(uuid: localID.uuidString), !first.isPrivate else { return }
        tabManager.selectTab(first)
    }

    func discardUncertainCopyInventory() async throws {
        guard isAvailable, let tabManager else { throw FloorpWorkspaceCopyError.destinationUnavailable }
        try await tabManager.resolveWorkspaceCopyReceiptUncertainty()
    }
}
#endif
