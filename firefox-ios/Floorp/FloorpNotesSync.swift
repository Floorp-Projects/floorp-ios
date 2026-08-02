// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation

enum FloorpNotesSyncSource: String, Codable, Equatable, Sendable {
    case base
    case local
    case remote
}

enum FloorpNotesSyncError: Error, Equatable, Sendable {
    case emptyAccountID
    case unsupportedBaseSchema(Int)
    case baseAccountMismatch(expected: String, actual: String)
    case invalidRecordLimit(Int)
    case invalidNoteID(source: FloorpNotesSyncSource, index: Int)
    case duplicateNoteID(source: FloorpNotesSyncSource, id: String)
    case invalidRemotePayload
    case unsupportedRemoteFields([String])
    case missingRemoteIDsAfterInitialSync
    case conflictIDExhausted(String)
    case tooManyNotes(Int)
    case recordTooLarge(actualBytes: Int, maximumBytes: Int)
}

struct FloorpNotesSyncBaseState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountID: String
    let notes: [FloorpNote]

    init(accountID: String, notes: [FloorpNote]) {
        schemaVersion = Self.currentSchemaVersion
        self.accountID = accountID
        self.notes = notes
    }

    init(schemaVersion: Int, accountID: String, notes: [FloorpNote]) {
        self.schemaVersion = schemaVersion
        self.accountID = accountID
        self.notes = notes
    }
}

struct FloorpNotesSyncRemoteRecord: Equatable, Sendable {
    /// Exact decrypted Notes preference bytes supplied by the Sync engine.
    /// Keeping the original bytes makes size and forward-schema checks real.
    let payloadData: Data?
    let revision: String?
    /// Usable decrypted payload budget after the engine accounts for record
    /// framing and encryption overhead.
    let maximumPayloadBytes: Int
}

struct FloorpNotesSyncUploadReceipt: Equatable, Sendable {
    let revision: String
}

/// This boundary is implemented by a supported Sync engine. It intentionally
/// receives neither OAuth credentials nor encryption keys.
protocol FloorpNotesSyncTransport: Sendable {
    /// A missing server record is represented by nil payload bytes and a nil
    /// revision so it cannot be confused with a remote bulk deletion.
    func fetchNotesRecord(accountID: String) async throws -> FloorpNotesSyncRemoteRecord

    func uploadNotesRecord(
        _ payloadData: Data,
        accountID: String,
        expectedRevision: String?
    ) async throws -> FloorpNotesSyncUploadReceipt
}

struct FloorpNotesSyncConflict: Equatable, Sendable {
    let originalNoteID: String
    let conflictCopyID: String
}

struct FloorpNotesSyncMergeResult: Equatable, Sendable {
    let notes: [FloorpNote]
    let conflicts: [FloorpNotesSyncConflict]
}

struct FloorpNotesSyncPlan: Equatable, Sendable {
    let accountID: String
    let remoteRevision: String?
    let mergedNotes: [FloorpNote]
    let uploadPayloadData: Data?
    let requiresUpload: Bool
    let nextBaseState: FloorpNotesSyncBaseState
    let conflicts: [FloorpNotesSyncConflict]
}

struct FloorpNotesSyncCommitCandidate: Equatable, Sendable {
    let accountID: String
    let expectedLocalRevision: UInt64
    let notes: [FloorpNote]
    let baseState: FloorpNotesSyncBaseState
}

struct FloorpNotesSyncPreparedCommit: Equatable, Sendable {
    let candidate: FloorpNotesSyncCommitCandidate
    /// Store-owned opaque proof that this exact candidate passed preflight.
    let storeToken: Data
}

struct FloorpNotesSyncCommit: Equatable, Sendable {
    let prepared: FloorpNotesSyncPreparedCommit
    let confirmedRemoteRevision: String?
    let didUpload: Bool
}

struct FloorpNotesSyncRunResult: Equatable, Sendable {
    let remoteRevision: String?
    let didUpload: Bool
}

/// `prepareSuccessfulSync` must compare the expected local revision and fully
/// serialize/validate the candidate Notes archive and base without mutating
/// either. `commitSuccessfulSync` must authenticate the store token, compare
/// the revision again, then persist both atomically. A stale revision fails
/// without changing either value.
protocol FloorpNotesSyncCommitStore: Sendable {
    func prepareSuccessfulSync(
        _ candidate: FloorpNotesSyncCommitCandidate
    ) async throws -> FloorpNotesSyncPreparedCommit

    func commitSuccessfulSync(_ commit: FloorpNotesSyncCommit) async throws
}

enum FloorpNotesSyncRunner {
    @discardableResult
    static func run(
        accountID: String,
        baseState: FloorpNotesSyncBaseState?,
        localSnapshot: FloorpNotesSnapshot,
        transport: any FloorpNotesSyncTransport,
        commitStore: any FloorpNotesSyncCommitStore,
        now: Int64 = FloorpNotesStore.currentTimeInMilliseconds()
    ) async throws -> FloorpNotesSyncRunResult {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw FloorpNotesSyncError.emptyAccountID
        }
        if let baseState {
            guard baseState.schemaVersion == FloorpNotesSyncBaseState.currentSchemaVersion else {
                throw FloorpNotesSyncError.unsupportedBaseSchema(baseState.schemaVersion)
            }
            guard baseState.accountID == trimmedAccountID else {
                throw FloorpNotesSyncError.baseAccountMismatch(
                    expected: trimmedAccountID,
                    actual: baseState.accountID
                )
            }
        }

        let remoteRecord = try await transport.fetchNotesRecord(accountID: trimmedAccountID)
        try Task.checkCancellation()
        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: trimmedAccountID,
            baseState: baseState,
            localNotes: localSnapshot.notes,
            remoteRecord: remoteRecord,
            now: now
        )
        let prepared = try await commitStore.prepareSuccessfulSync(
            FloorpNotesSyncCommitCandidate(
                accountID: plan.accountID,
                expectedLocalRevision: localSnapshot.revision,
                notes: plan.mergedNotes,
                baseState: plan.nextBaseState
            )
        )
        try Task.checkCancellation()

        let result: FloorpNotesSyncRunResult
        if plan.requiresUpload {
            guard let uploadPayloadData = plan.uploadPayloadData else {
                assertionFailure("An upload plan must contain payload bytes")
                throw FloorpNotesSyncError.invalidRemotePayload
            }
            let receipt = try await transport.uploadNotesRecord(
                uploadPayloadData,
                accountID: plan.accountID,
                expectedRevision: plan.remoteRevision
            )
            result = FloorpNotesSyncRunResult(
                remoteRevision: receipt.revision,
                didUpload: true
            )
        } else {
            result = FloorpNotesSyncRunResult(
                remoteRevision: plan.remoteRevision,
                didUpload: false
            )
        }
        try Task.checkCancellation()

        try await commitStore.commitSuccessfulSync(
            FloorpNotesSyncCommit(
                prepared: prepared,
                confirmedRemoteRevision: result.remoteRevision,
                didUpload: result.didUpload
            )
        )
        return result
    }
}

enum FloorpNotesSyncPlanner {
    static func makePlan(
        accountID: String,
        baseState: FloorpNotesSyncBaseState?,
        localNotes: [FloorpNote],
        remoteRecord: FloorpNotesSyncRemoteRecord,
        now: Int64 = FloorpNotesStore.currentTimeInMilliseconds()
    ) throws -> FloorpNotesSyncPlan {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw FloorpNotesSyncError.emptyAccountID
        }

        if let baseState {
            guard baseState.schemaVersion == FloorpNotesSyncBaseState.currentSchemaVersion else {
                throw FloorpNotesSyncError.unsupportedBaseSchema(baseState.schemaVersion)
            }
            guard baseState.accountID == trimmedAccountID else {
                throw FloorpNotesSyncError.baseAccountMismatch(
                    expected: trimmedAccountID,
                    actual: baseState.accountID
                )
            }
        }

        let maximumPayloadBytes = remoteRecord.maximumPayloadBytes
        guard maximumPayloadBytes > 0 else {
            throw FloorpNotesSyncError.invalidRecordLimit(maximumPayloadBytes)
        }

        let normalizedRemote = try normalizedRemoteNotes(
            record: remoteRecord,
            accountID: trimmedAccountID,
            now: now,
            maximumPayloadBytes: maximumPayloadBytes
        )
        if baseState != nil,
           let payload = normalizedRemote.payload,
           payload.ids == nil,
           !payload.titles.isEmpty {
            throw FloorpNotesSyncError.missingRemoteIDsAfterInitialSync
        }
        // A nil revision is the transport's explicit missing/reset record
        // signal, not a remote request to delete every local note. Drop the
        // old base so retained local data is uploaded as a fresh first sync.
        let effectiveBase = normalizedRemote.payload == nil ? [] : (baseState?.notes ?? [])
        let mergeResult = try FloorpNotesSyncMerger.merge(
            base: effectiveBase,
            local: localNotes,
            remote: normalizedRemote.notes
        )
        let requiresUpload = normalizedRemote.payload.map {
            FloorpNotesDesktopPayload(notes: mergeResult.notes) != $0
        } ?? !mergeResult.notes.isEmpty
        let payloadData = requiresUpload
            ? try encodedPayload(
                notes: mergeResult.notes,
                maximumPayloadBytes: maximumPayloadBytes
            )
            : nil

        return FloorpNotesSyncPlan(
            accountID: trimmedAccountID,
            remoteRevision: remoteRecord.revision,
            mergedNotes: mergeResult.notes,
            uploadPayloadData: payloadData,
            requiresUpload: requiresUpload,
            nextBaseState: FloorpNotesSyncBaseState(
                accountID: trimmedAccountID,
                notes: mergeResult.notes
            ),
            conflicts: mergeResult.conflicts
        )
    }

    static func encodedPayload(
        notes: [FloorpNote],
        maximumPayloadBytes: Int
    ) throws -> Data {
        guard maximumPayloadBytes > 0 else {
            throw FloorpNotesSyncError.invalidRecordLimit(maximumPayloadBytes)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FloorpNotesDesktopPayload(notes: notes))
        guard data.count <= maximumPayloadBytes else {
            throw FloorpNotesSyncError.recordTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumPayloadBytes
            )
        }
        return data
    }

    private struct NormalizedRemoteRecord {
        let payload: FloorpNotesDesktopPayload?
        let notes: [FloorpNote]
    }

    private static func normalizedRemoteNotes(
        record: FloorpNotesSyncRemoteRecord,
        accountID: String,
        now: Int64,
        maximumPayloadBytes: Int
    ) throws -> NormalizedRemoteRecord {
        guard let payloadData = record.payloadData else {
            guard record.revision == nil else {
                throw FloorpNotesSyncError.invalidRemotePayload
            }
            return NormalizedRemoteRecord(payload: nil, notes: [])
        }
        guard record.revision != nil else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        guard payloadData.count <= maximumPayloadBytes else {
            throw FloorpNotesSyncError.recordTooLarge(
                actualBytes: payloadData.count,
                maximumBytes: maximumPayloadBytes
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payloadData)
        } catch {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        guard let dictionary = object as? [String: Any] else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        let supportedFields: Set<String> = [
            "ids", "titles", "contents", "createdAts", "updatedAts",
        ]
        let unsupportedFields = dictionary.keys.filter { !supportedFields.contains($0) }.sorted()
        guard unsupportedFields.isEmpty else {
            throw FloorpNotesSyncError.unsupportedRemoteFields(unsupportedFields)
        }

        let payload: FloorpNotesDesktopPayload
        do {
            payload = try JSONDecoder().decode(FloorpNotesDesktopPayload.self, from: payloadData)
        } catch {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        let ids = try validatedExplicitRemoteIDs(payload)

        let payloadDigest = SHA256.hash(data: payloadData).hexString
        let count = payload.titles.count
        guard count <= FloorpNotesStore.maximumNoteCount else {
            throw FloorpNotesSyncError.tooManyNotes(count)
        }

        var notes = [FloorpNote]()
        notes.reserveCapacity(count)
        for index in 0..<count {
            let id: String
            if let ids {
                id = ids[index]
            } else {
                let digest = deterministicDigest(
                    strings: [accountID, record.revision ?? "", payloadDigest, String(index)]
                )
                id = "floorp-sync-legacy-\(digest)"
            }
            let createdAt = validTimestamp(payload.createdAts, at: index) ?? now
            let updatedAt = max(
                validTimestamp(payload.updatedAts, at: index) ?? createdAt,
                createdAt
            )
            notes.append(
                FloorpNote(
                    id: id,
                    title: payload.titles[index],
                    content: value(payload.contents, at: index) ?? "",
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    contentFormat: .automatic
                )
            )
        }
        return NormalizedRemoteRecord(payload: payload, notes: notes)
    }

    private static func validatedExplicitRemoteIDs(
        _ payload: FloorpNotesDesktopPayload
    ) throws -> [String]? {
        guard let ids = payload.ids else { return nil }
        guard ids.count == payload.titles.count else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }

        var seen = Set<String>()
        var validated = [String]()
        validated.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloorpNotesSyncError.invalidNoteID(source: .remote, index: index)
            }
            guard seen.insert(id).inserted else {
                throw FloorpNotesSyncError.duplicateNoteID(source: .remote, id: id)
            }
            validated.append(id)
        }
        return validated
    }

    private static func value<T>(_ values: [T], at index: Int) -> T? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func validTimestamp(_ values: [Int64]?, at index: Int) -> Int64? {
        guard let value = values.flatMap({ value($0, at: index) }), value > 0 else {
            return nil
        }
        return value
    }

    private static func deterministicDigest(strings: [String]) -> String {
        var data = Data()
        for string in strings {
            append(string, to: &data)
        }
        return SHA256.hash(data: data).hexString
    }

    fileprivate static func append(_ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

enum FloorpNotesSyncMerger {
    private struct IndexedNotes {
        let order: [String]
        let byID: [String: FloorpNote]
    }

    private struct ConflictResolution {
        let winner: FloorpNote
        let loser: FloorpNote
    }

    private struct AvailableConflictCopy {
        let note: FloorpNote
        let shouldInsert: Bool
    }

    static func merge(
        base: [FloorpNote],
        local: [FloorpNote],
        remote: [FloorpNote]
    ) throws -> FloorpNotesSyncMergeResult {
        let baseIndex = try indexed(base, source: .base)
        let localIndex = try indexed(local, source: .local)
        let remoteIndex = try indexed(remote, source: .remote)

        var existingIDs = Set(baseIndex.order + localIndex.order + remoteIndex.order)
        let originalIDs = stableUnion(baseIndex.order, localIndex.order, remoteIndex.order)
        let resolutionsByID = Dictionary(uniqueKeysWithValues: originalIDs.map { id in
            (
                id,
                resolve(
                    base: baseIndex.byID[id],
                    local: localIndex.byID[id],
                    remote: remoteIndex.byID[id]
                )
            )
        })
        var mergedByID = [String: FloorpNote]()
        var generatedConflictCopies = [String: FloorpNote]()
        var conflictIDByOriginal = [String: String]()
        var conflicts = [FloorpNotesSyncConflict]()

        for id in originalIDs {
            guard let resolution = resolutionsByID[id] else { continue }
            switch resolution {
            case .none:
                continue
            case .note(let note):
                mergedByID[id] = note
            case .conflict(let resolution):
                mergedByID[id] = resolution.winner
                let conflictCopy = try availableConflictCopy(
                    originalID: id,
                    resolution: resolution,
                    existingIDs: &existingIDs,
                    originalResolutions: resolutionsByID,
                    generatedConflictCopies: generatedConflictCopies
                )
                let conflictID = conflictCopy.note.id
                conflictIDByOriginal[id] = conflictID
                conflicts.append(
                    FloorpNotesSyncConflict(
                        originalNoteID: id,
                        conflictCopyID: conflictID
                    )
                )
                if conflictCopy.shouldInsert {
                    mergedByID[conflictID] = conflictCopy.note
                    generatedConflictCopies[conflictID] = conflictCopy.note
                }
            }
        }

        guard mergedByID.count <= FloorpNotesStore.maximumNoteCount else {
            throw FloorpNotesSyncError.tooManyNotes(mergedByID.count)
        }

        let availableIDs = Set(mergedByID.keys)
        let localOrderChanged = orderChanged(
            candidate: localIndex.order,
            base: baseIndex.order,
            availableIDs: availableIDs
        )
        let remoteOrderChanged = orderChanged(
            candidate: remoteIndex.order,
            base: baseIndex.order,
            availableIDs: availableIDs
        )
        let primaryOrder = !localOrderChanged && remoteOrderChanged
            ? remoteIndex.order
            : localIndex.order
        let secondaryOrder = !localOrderChanged && remoteOrderChanged
            ? localIndex.order
            : remoteIndex.order

        var orderedIDs = [String]()
        var appendedIDs = Set<String>()
        appendOrder(
            primaryOrder,
            availableIDs: availableIDs,
            conflictIDByOriginal: conflictIDByOriginal,
            orderedIDs: &orderedIDs,
            appendedIDs: &appendedIDs
        )
        appendOrder(
            secondaryOrder,
            availableIDs: availableIDs,
            conflictIDByOriginal: conflictIDByOriginal,
            orderedIDs: &orderedIDs,
            appendedIDs: &appendedIDs
        )
        appendOrder(
            baseIndex.order,
            availableIDs: availableIDs,
            conflictIDByOriginal: conflictIDByOriginal,
            orderedIDs: &orderedIDs,
            appendedIDs: &appendedIDs
        )
        for id in availableIDs.sorted() where appendedIDs.insert(id).inserted {
            orderedIDs.append(id)
        }

        return FloorpNotesSyncMergeResult(
            notes: orderedIDs.compactMap { mergedByID[$0] },
            conflicts: conflicts.sorted { lhs, rhs in
                if lhs.originalNoteID == rhs.originalNoteID {
                    return lhs.conflictCopyID < rhs.conflictCopyID
                }
                return lhs.originalNoteID < rhs.originalNoteID
            }
        )
    }

    private enum Resolution {
        case none
        case note(FloorpNote)
        case conflict(ConflictResolution)
    }

    private static func resolve(
        base: FloorpNote?,
        local: FloorpNote?,
        remote: FloorpNote?
    ) -> Resolution {
        guard let base else {
            switch (local, remote) {
            case (nil, nil):
                return .none
            case (.some(let note), nil), (nil, .some(let note)):
                return .note(note)
            case (.some(let local), .some(let remote)):
                return resolveConcurrent(local: local, remote: remote)
            }
        }

        switch (local, remote) {
        case (nil, nil):
            return .none
        case (nil, .some(let remote)):
            return sameUserContent(remote, base) ? .none : .note(remote)
        case (.some(let local), nil):
            return sameUserContent(local, base) ? .none : .note(local)
        case (.some(let local), .some(let remote)):
            let localChanged = !sameUserContent(local, base)
            let remoteChanged = !sameUserContent(remote, base)
            switch (localChanged, remoteChanged) {
            case (false, false):
                return .note(coalesced(local: local, remote: remote))
            case (true, false):
                return .note(local)
            case (false, true):
                return .note(remote)
            case (true, true):
                return resolveConcurrent(local: local, remote: remote)
            }
        }
    }

    private static func resolveConcurrent(
        local: FloorpNote,
        remote: FloorpNote
    ) -> Resolution {
        if sameUserContent(local, remote) {
            return .note(coalesced(local: local, remote: remote))
        }

        let winner: FloorpNote
        let loser: FloorpNote
        if precedes(local, remote) {
            winner = remote
            loser = local
        } else {
            winner = local
            loser = remote
        }
        return .conflict(ConflictResolution(winner: winner, loser: loser))
    }

    private static func coalesced(local: FloorpNote, remote: FloorpNote) -> FloorpNote {
        FloorpNote(
            id: local.id,
            title: local.title,
            content: local.content,
            createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            contentFormat: local.contentFormat
        )
    }

    private static func sameUserContent(_ lhs: FloorpNote, _ rhs: FloorpNote) -> Bool {
        lhs.title == rhs.title && lhs.content == rhs.content
    }

    private static func precedes(_ lhs: FloorpNote, _ rhs: FloorpNote) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return canonicalData(for: lhs).lexicographicallyPrecedes(canonicalData(for: rhs))
    }

    private static func availableConflictCopy(
        originalID: String,
        resolution: ConflictResolution,
        existingIDs: inout Set<String>,
        originalResolutions: [String: Resolution],
        generatedConflictCopies: [String: FloorpNote]
    ) throws -> AvailableConflictCopy {
        for probe in 0...FloorpNotesStore.maximumNoteCount {
            let candidate = FloorpNote(
                id: conflictCopyID(
                    originalID: originalID,
                    losingNote: resolution.loser,
                    probe: probe
                ),
                title: "\(resolution.loser.title) (Conflict)",
                content: resolution.loser.content,
                createdAt: resolution.loser.createdAt,
                updatedAt: max(
                    resolution.winner.updatedAt,
                    resolution.loser.updatedAt
                ),
                contentFormat: resolution.loser.contentFormat
            )

            if !existingIDs.contains(candidate.id) {
                existingIDs.insert(candidate.id)
                return AvailableConflictCopy(note: candidate, shouldInsert: true)
            }

            if let generated = generatedConflictCopies[candidate.id],
               sameWireNote(generated, candidate) {
                return AvailableConflictCopy(note: generated, shouldInsert: false)
            }

            if case .note(let existing) = originalResolutions[candidate.id],
               sameWireNote(existing, candidate) {
                return AvailableConflictCopy(note: existing, shouldInsert: false)
            }
        }
        throw FloorpNotesSyncError.conflictIDExhausted(originalID)
    }

    private static func sameWireNote(_ lhs: FloorpNote, _ rhs: FloorpNote) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.content == rhs.content
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }

    private static func conflictCopyID(
        originalID: String,
        losingNote: FloorpNote,
        probe: Int
    ) -> String {
        var data = Data()
        FloorpNotesSyncPlanner.append(originalID, to: &data)
        data.append(canonicalData(for: losingNote))
        if probe > 0 {
            FloorpNotesSyncPlanner.append(String(probe), to: &data)
        }
        return "floorp-sync-conflict-\(SHA256.hash(data: data).hexString)"
    }

    private static func canonicalData(for note: FloorpNote) -> Data {
        var data = Data()
        // Only fields represented by the desktop parallel-array payload
        // participate so iOS and Desktop derive identical winners and IDs.
        for string in [note.id, note.title, note.content] {
            FloorpNotesSyncPlanner.append(string, to: &data)
        }
        var createdAt = note.createdAt.bigEndian
        var updatedAt = note.updatedAt.bigEndian
        withUnsafeBytes(of: &createdAt) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &updatedAt) { data.append(contentsOf: $0) }
        return data
    }

    private static func indexed(
        _ notes: [FloorpNote],
        source: FloorpNotesSyncSource
    ) throws -> IndexedNotes {
        var byID = [String: FloorpNote]()
        var order = [String]()
        order.reserveCapacity(notes.count)
        for (index, note) in notes.enumerated() {
            guard !note.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloorpNotesSyncError.invalidNoteID(source: source, index: index)
            }
            guard byID[note.id] == nil else {
                throw FloorpNotesSyncError.duplicateNoteID(source: source, id: note.id)
            }
            byID[note.id] = note
            order.append(note.id)
        }
        return IndexedNotes(order: order, byID: byID)
    }

    private static func stableUnion(_ orders: [String]...) -> [String] {
        var ids = [String]()
        var seen = Set<String>()
        for order in orders {
            for id in order where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private static func orderChanged(
        candidate: [String],
        base: [String],
        availableIDs: Set<String>
    ) -> Bool {
        let baseIDs = Set(base)
        let candidateBaseOrder = candidate.filter {
            baseIDs.contains($0) && availableIDs.contains($0)
        }
        let candidateBaseIDs = Set(candidateBaseOrder)
        let comparableBaseOrder = base.filter {
            candidateBaseIDs.contains($0) && availableIDs.contains($0)
        }
        return candidateBaseOrder != comparableBaseOrder
    }

    private static func appendOrder(
        _ source: [String],
        availableIDs: Set<String>,
        conflictIDByOriginal: [String: String],
        orderedIDs: inout [String],
        appendedIDs: inout Set<String>
    ) {
        for id in source where availableIDs.contains(id) {
            if appendedIDs.insert(id).inserted {
                orderedIDs.append(id)
            }
            guard let conflictID = conflictIDByOriginal[id],
                  availableIDs.contains(conflictID),
                  appendedIDs.insert(conflictID).inserted else { continue }
            orderedIDs.append(conflictID)
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
