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
    case duplicateNoteID(source: FloorpNotesSyncSource, id: FloorpNoteID)
    case invalidRemotePayload
    case invalidApplicationServicesBoundary
    case unsupportedRemoteFields([String])
    case missingRemoteIDsAfterInitialSync
    case conflictIDExhausted(FloorpNoteID)
    case tooManyNotes(Int)
    case recordTooLarge(actualBytes: Int, maximumBytes: Int)
}

/// The four remote states exposed by the Floorp Application Services prefs
/// engine. They deliberately remain distinct until the merge policy sees
/// them: a missing aggregate record resets the merge base, while a present
/// aggregate whose Notes value is absent or null represents an empty remote
/// Notes value without resetting the account association.
enum FloorpNotesSyncRemoteNotes: Equatable, Sendable {
    case recordMissing
    case notesKeyMissing
    case notesNull
    case notesString(Data)
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
    let remoteNotes: FloorpNotesSyncRemoteNotes
    let revision: String?
    /// Maximum byte length of the Notes string after it is encoded as an
    /// outer JSON string value, including the two surrounding quote bytes.
    /// This exactly matches Application Services' escaping-aware budget.
    let maximumEncodedNotesValueBytes: Int
}

/// Local DTO mirroring the generated UniFFI enum. Keeping it in Client avoids
/// linking an unreleased XCFramework while still making the boundary contract
/// executable. The eventual generated-type adapter must be a mechanical,
/// exhaustive conversion to this enum.
enum FloorpNotesApplicationServicesRemoteNotes: Equatable, Sendable {
    case recordMissing
    case notesKeyMissing
    case notesNull
    case notesString(value: String)
}

/// Local DTO mirroring `FloorpPrefsSyncPrepareInput` from the pinned Floorp
/// Application Services source contract.
struct FloorpNotesApplicationServicesPrepareInput: Equatable, Sendable {
    let remoteNotes: FloorpNotesApplicationServicesRemoteNotes
    let remoteRecordModifiedMillis: Int64?
    let collectionModifiedMillis: Int64
    let maximumNotesValueBytes: UInt64
}

enum FloorpNotesApplicationServicesAdapter {
    static let transportContractVersion = "floorp-prefs-sync-v1"

    static func remoteRecord(
        from input: FloorpNotesApplicationServicesPrepareInput
    ) throws -> FloorpNotesSyncRemoteRecord {
        guard let maximumBytes = Int(exactly: input.maximumNotesValueBytes) else {
            throw FloorpNotesSyncError.invalidApplicationServicesBoundary
        }

        let revision = input.remoteRecordModifiedMillis.map(String.init)
        let remoteNotes: FloorpNotesSyncRemoteNotes
        switch input.remoteNotes {
        case .recordMissing:
            guard revision == nil else {
                throw FloorpNotesSyncError.invalidApplicationServicesBoundary
            }
            remoteNotes = .recordMissing
        case .notesKeyMissing:
            guard revision != nil else {
                throw FloorpNotesSyncError.invalidApplicationServicesBoundary
            }
            remoteNotes = .notesKeyMissing
        case .notesNull:
            guard revision != nil else {
                throw FloorpNotesSyncError.invalidApplicationServicesBoundary
            }
            remoteNotes = .notesNull
        case .notesString(let value):
            guard revision != nil else {
                throw FloorpNotesSyncError.invalidApplicationServicesBoundary
            }
            remoteNotes = .notesString(Data(value.utf8))
        }

        return FloorpNotesSyncRemoteRecord(
            remoteNotes: remoteNotes,
            revision: revision,
            maximumEncodedNotesValueBytes: maximumBytes
        )
    }
}

struct FloorpNotesSyncReleaseEvidence: Equatable, Sendable {
    let fixtureContractVersion: String
    let fixtureSHA256: String
    let currentDesktopContractVersion: String?
    let coordinatedDesktopMigrationVersion: String?
    let linkedApplicationServicesContractVersion: String?
}

/// Network Notes Sync is release-gated independently of build-time feature
/// flags. Production Desktop does not yet implement this deterministic merge
/// contract, and the custom Application Services binary is not yet linked, so
/// the evidence bundled by this branch intentionally evaluates to false.
enum FloorpNotesSyncReleaseGate {
    static let mergeContractVersion = "floorp-notes-merge-v1"
    static let mergeFixtureSHA256 = "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd"
    static let observedProductionDesktopCommit = "410c211c202012631159d1bce1f3ab208305d2b7"

    static let currentRuntimeEvidence = FloorpNotesSyncReleaseEvidence(
        fixtureContractVersion: mergeContractVersion,
        fixtureSHA256: mergeFixtureSHA256,
        currentDesktopContractVersion: nil,
        coordinatedDesktopMigrationVersion: nil,
        linkedApplicationServicesContractVersion: nil
    )

    static func allowsNetworkSync(_ evidence: FloorpNotesSyncReleaseEvidence) -> Bool {
        guard evidence.fixtureContractVersion == mergeContractVersion,
              evidence.fixtureSHA256 == mergeFixtureSHA256,
              evidence.linkedApplicationServicesContractVersion
                == FloorpNotesApplicationServicesAdapter.transportContractVersion else {
            return false
        }
        return evidence.currentDesktopContractVersion == mergeContractVersion
            || evidence.coordinatedDesktopMigrationVersion == mergeContractVersion
    }

    static var isNetworkSyncEnabled: Bool {
        allowsNetworkSync(currentRuntimeEvidence)
    }
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
    let originalNoteID: FloorpNoteID
    let conflictCopyID: FloorpNoteID
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

private enum FloorpNotesSyncWire {
    static func stringsAreEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func stringArraysAreEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { stringsAreEqual($0.0, $0.1) }
    }

    static func optionalStringArraysAreEqual(
        _ lhs: [String]?,
        _ rhs: [String]?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return stringArraysAreEqual(lhs, rhs)
        default:
            return false
        }
    }

    static func payloadsAreEqual(
        _ lhs: FloorpNotesDesktopPayload,
        _ rhs: FloorpNotesDesktopPayload
    ) -> Bool {
        optionalStringArraysAreEqual(lhs.ids, rhs.ids)
            && stringArraysAreEqual(lhs.titles, rhs.titles)
            && stringArraysAreEqual(lhs.contents, rhs.contents)
            && lhs.createdAts == rhs.createdAts
            && lhs.updatedAts == rhs.updatedAts
    }
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

        let maximumEncodedNotesValueBytes = remoteRecord.maximumEncodedNotesValueBytes
        guard maximumEncodedNotesValueBytes > 0 else {
            throw FloorpNotesSyncError.invalidRecordLimit(maximumEncodedNotesValueBytes)
        }

        let normalizedRemote = try normalizedRemoteNotes(
            record: remoteRecord,
            accountID: trimmedAccountID,
            now: now,
            maximumEncodedNotesValueBytes: maximumEncodedNotesValueBytes
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
            !FloorpNotesSyncWire.payloadsAreEqual(
                FloorpNotesDesktopPayload(notes: mergeResult.notes),
                $0
            )
        } ?? !mergeResult.notes.isEmpty
        let payloadData = requiresUpload
            ? try encodedPayload(
                notes: mergeResult.notes,
                maximumEncodedNotesValueBytes: maximumEncodedNotesValueBytes
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
        maximumEncodedNotesValueBytes: Int
    ) throws -> Data {
        guard maximumEncodedNotesValueBytes > 0 else {
            throw FloorpNotesSyncError.invalidRecordLimit(maximumEncodedNotesValueBytes)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FloorpNotesDesktopPayload(notes: notes))
        let encodedValueBytes = try encodedNotesValueByteCount(payloadData: data)
        guard encodedValueBytes <= maximumEncodedNotesValueBytes else {
            throw FloorpNotesSyncError.recordTooLarge(
                actualBytes: encodedValueBytes,
                maximumBytes: maximumEncodedNotesValueBytes
            )
        }
        return data
    }

    static func encodedNotesValueByteCount(payloadData: Data) throws -> Int {
        guard let value = String(data: payloadData, encoding: .utf8) else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        // Match serde_json's compact string serializer used by the Rust
        // engine instead of relying on Foundation's encoder implementation.
        // Quotes/backslashes and JSON control escapes grow to two bytes;
        // remaining U+0000...U+001F scalars use `\u00XX`; all other scalars
        // stay as their original UTF-8 bytes (including `/` and U+2028/2029).
        var count = 2
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                count += 2
            case 0x00...0x1F:
                count += 6
            default:
                count += scalar.utf8.count
            }
        }
        return count
    }

    private struct NormalizedRemoteRecord {
        let payload: FloorpNotesDesktopPayload?
        let notes: [FloorpNote]
    }

    private static func normalizedRemoteNotes(
        record: FloorpNotesSyncRemoteRecord,
        accountID: String,
        now: Int64,
        maximumEncodedNotesValueBytes: Int
    ) throws -> NormalizedRemoteRecord {
        let payloadData: Data
        switch record.remoteNotes {
        case .recordMissing:
            guard record.revision == nil else {
                throw FloorpNotesSyncError.invalidRemotePayload
            }
            return NormalizedRemoteRecord(payload: nil, notes: [])
        case .notesKeyMissing, .notesNull:
            guard record.revision != nil else {
                throw FloorpNotesSyncError.invalidRemotePayload
            }
            return NormalizedRemoteRecord(
                payload: FloorpNotesDesktopPayload(notes: []),
                notes: []
            )
        case .notesString(let value):
            payloadData = value
        }
        guard record.revision != nil else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }
        let encodedValueBytes = try encodedNotesValueByteCount(payloadData: payloadData)
        guard encodedValueBytes <= maximumEncodedNotesValueBytes else {
            throw FloorpNotesSyncError.recordTooLarge(
                actualBytes: encodedValueBytes,
                maximumBytes: maximumEncodedNotesValueBytes
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
            let id: FloorpNoteID
            if let ids {
                id = ids[index]
            } else {
                let digest = deterministicDigest(
                    strings: [accountID, record.revision ?? "", payloadDigest, String(index)]
                )
                id = FloorpNoteID("floorp-sync-legacy-\(digest)")
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
    ) throws -> [FloorpNoteID]? {
        guard let ids = payload.ids else { return nil }
        guard ids.count == payload.titles.count else {
            throw FloorpNotesSyncError.invalidRemotePayload
        }

        var seen = Set<FloorpNoteID>()
        var validated = [FloorpNoteID]()
        validated.reserveCapacity(ids.count)
        for (index, rawID) in ids.enumerated() {
            guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloorpNotesSyncError.invalidNoteID(source: .remote, index: index)
            }
            let id = FloorpNoteID(rawID)
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
        let order: [FloorpNoteID]
        let byID: [FloorpNoteID: FloorpNote]
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
        var mergedByID = [FloorpNoteID: FloorpNote]()
        var generatedConflictCopies = [FloorpNoteID: FloorpNote]()
        var conflictIDByOriginal = [FloorpNoteID: FloorpNoteID]()
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
                    losingNote: resolution.loser,
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

        var orderedIDs = [FloorpNoteID]()
        var appendedIDs = Set<FloorpNoteID>()
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
        FloorpNotesSyncWire.stringsAreEqual(lhs.title, rhs.title)
            && FloorpNotesSyncWire.stringsAreEqual(lhs.content, rhs.content)
    }

    private static func precedes(_ lhs: FloorpNote, _ rhs: FloorpNote) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return canonicalData(for: lhs).lexicographicallyPrecedes(canonicalData(for: rhs))
    }

    private static func availableConflictCopy(
        losingNote: FloorpNote,
        existingIDs: inout Set<FloorpNoteID>,
        originalResolutions: [FloorpNoteID: Resolution],
        generatedConflictCopies: [FloorpNoteID: FloorpNote]
    ) throws -> AvailableConflictCopy {
        for probe in 0...FloorpNotesStore.maximumNoteCount {
            let candidate = FloorpNote(
                id: conflictCopyID(
                    losingNote: losingNote,
                    probe: probe
                ),
                title: losingNote.title.isEmpty ? "(Conflict)" : "\(losingNote.title) (Conflict)",
                content: losingNote.content,
                createdAt: losingNote.createdAt,
                updatedAt: losingNote.updatedAt,
                contentFormat: losingNote.contentFormat
            )

            if !existingIDs.contains(candidate.id) {
                existingIDs.insert(candidate.id)
                return AvailableConflictCopy(note: candidate, shouldInsert: true)
            }

            if let generated = generatedConflictCopies[candidate.id],
               sameWireNote(generated, candidate) {
                return AvailableConflictCopy(note: generated, shouldInsert: false)
            }

            if let originalResolution = originalResolutions[candidate.id] {
                let existing: FloorpNote?
                switch originalResolution {
                case .note(let note):
                    existing = note
                case .conflict(let resolution):
                    existing = resolution.winner
                case .none:
                    existing = nil
                }
                if let existing, sameWireNote(existing, candidate) {
                    return AvailableConflictCopy(note: existing, shouldInsert: false)
                }
            }
        }
        throw FloorpNotesSyncError.conflictIDExhausted(losingNote.id)
    }

    private static func sameWireNote(_ lhs: FloorpNote, _ rhs: FloorpNote) -> Bool {
        lhs.id == rhs.id
            && FloorpNotesSyncWire.stringsAreEqual(lhs.title, rhs.title)
            && FloorpNotesSyncWire.stringsAreEqual(lhs.content, rhs.content)
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }

    private static func conflictCopyID(
        losingNote: FloorpNote,
        probe: Int
    ) -> FloorpNoteID {
        var data = Data()
        // Preserve the pre-v1 candidate-ID layout while making its dependency
        // explicit: both this prefix and the canonical bytes come from the
        // losing note, never from the winner or the current merge clock.
        FloorpNotesSyncPlanner.append(losingNote.id.rawValue, to: &data)
        data.append(canonicalData(for: losingNote))
        if probe > 0 {
            FloorpNotesSyncPlanner.append(String(probe), to: &data)
        }
        return FloorpNoteID("floorp-sync-conflict-\(SHA256.hash(data: data).hexString)")
    }

    private static func canonicalData(for note: FloorpNote) -> Data {
        var data = Data()
        // Only fields represented by the desktop parallel-array payload
        // participate so iOS and Desktop derive identical winners and IDs.
        for string in [note.id.rawValue, note.title, note.content] {
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
        var byID = [FloorpNoteID: FloorpNote]()
        var order = [FloorpNoteID]()
        order.reserveCapacity(notes.count)
        for (index, note) in notes.enumerated() {
            guard !note.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    private static func stableUnion(_ orders: [FloorpNoteID]...) -> [FloorpNoteID] {
        var ids = [FloorpNoteID]()
        var seen = Set<FloorpNoteID>()
        for order in orders {
            for id in order where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private static func orderChanged(
        candidate: [FloorpNoteID],
        base: [FloorpNoteID],
        availableIDs: Set<FloorpNoteID>
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
        _ source: [FloorpNoteID],
        availableIDs: Set<FloorpNoteID>,
        conflictIDByOriginal: [FloorpNoteID: FloorpNoteID],
        orderedIDs: inout [FloorpNoteID],
        appendedIDs: inout Set<FloorpNoteID>
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
