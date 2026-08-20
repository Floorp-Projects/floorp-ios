// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import CoreFoundation
import Foundation
import MozillaAppServices

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

enum FloorpNotesSyncUIStatus: Equatable, Sendable {
    case localOnly
    case syncEnabled
}

final class FloorpNotesSyncStatusCenter: @unchecked Sendable {
    static let shared = FloorpNotesSyncStatusCenter()

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var storedStatus: FloorpNotesSyncUIStatus

    init(
        status: FloorpNotesSyncUIStatus = .localOnly,
        notificationCenter: NotificationCenter = .default
    ) {
        storedStatus = status
        self.notificationCenter = notificationCenter
    }

    var status: FloorpNotesSyncUIStatus {
        lock.withLock { storedStatus }
    }

    func setStatus(_ status: FloorpNotesSyncUIStatus) {
        let changed = lock.withLock {
            guard storedStatus != status else { return false }
            storedStatus = status
            return true
        }
        guard changed else { return }
        let post = { [notificationCenter, self] in
            notificationCenter.post(name: .FloorpNotesSyncStatusDidChange, object: self)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
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

    static func remoteRecord(
        from input: FloorpPrefsSyncPrepareInput
    ) throws -> FloorpNotesSyncRemoteRecord {
        let remoteNotes: FloorpNotesApplicationServicesRemoteNotes
        switch input.remoteNotes {
        case .recordMissing:
            remoteNotes = .recordMissing
        case .notesKeyMissing:
            remoteNotes = .notesKeyMissing
        case .notesNull:
            remoteNotes = .notesNull
        case .notesString(let value):
            remoteNotes = .notesString(value: value)
        }
        return try remoteRecord(
            from: FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: remoteNotes,
                remoteRecordModifiedMillis: input.remoteRecordModifiedMillis,
                collectionModifiedMillis: input.collectionModifiedMillis,
                maximumNotesValueBytes: input.maximumNotesValueBytes
            )
        )
    }
}

/// Synchronous adapter required by the Floorp prefs Sync engine. It never
/// waits on a Swift actor; both UI callers and these callbacks share the same
/// locked persistence core.
final class FloorpNotesPrefsSyncDelegate: FloorpPrefsSyncDelegate, @unchecked Sendable {
    private struct PendingTransaction: Sendable {
        let generation: UInt64
        let persistence: FloorpNotesPreparedPersistence
    }

    private let accountID: String
    private let persistenceCore: FloorpNotesPersistenceCore
    private let now: @Sendable () -> Int64
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var pendingTransactions = [Data: PendingTransaction]()
    private var pendingStateCommit: PendingTransaction?
    private var checkedDisconnectInProgress = false
    private var pendingAssociationResetState: FloorpNotesApplicationServicesState?

    init(
        accountID: String,
        notesStore: FloorpNotesStore = .shared,
        now: @escaping @Sendable () -> Int64 = FloorpNotesStore.currentTimeInMilliseconds
    ) {
        self.accountID = accountID
        persistenceCore = notesStore.syncPersistenceCore
        self.now = now
    }

    var initialSyncState: FloorpPrefsSyncState? {
        guard let context = try? persistenceCore.syncContext(accountID: accountID),
              let state = context.applicationServicesState else {
            return nil
        }
        return Self.generatedState(from: state)
    }

    func prepare(input: FloorpPrefsSyncPrepareInput) throws -> FloorpPrefsSyncPlan {
        let remoteRecord: FloorpNotesSyncRemoteRecord
        do {
            remoteRecord = try FloorpNotesApplicationServicesAdapter.remoteRecord(from: input)
        } catch {
            throw Self.applicationServicesError(from: error)
        }

        let capturedGeneration = withStateLock {
            pendingTransactions.removeAll()
            pendingStateCommit = nil
            return generation
        }
        let persistence: FloorpNotesPreparedPersistence
        do {
            persistence = try persistenceCore.prepareSyncPersistence(
                accountID: accountID,
                remoteRecord: remoteRecord,
                now: now()
            )
        } catch {
            throw Self.applicationServicesError(from: error)
        }

        let token = Data(UUID().uuidString.utf8)
        let wasRegistered = withStateLock {
            guard generation == capturedGeneration else { return false }
            pendingTransactions[token] = PendingTransaction(
                generation: capturedGeneration,
                persistence: persistence
            )
            return true
        }
        guard wasRegistered else { throw FloorpPrefsSyncError.UnexpectedSyncState }

        if persistence.plan.requiresUpload {
            guard let payload = persistence.plan.uploadPayloadData,
                  let notesValue = String(data: payload, encoding: .utf8) else {
                invalidate()
                throw FloorpPrefsSyncError.InvalidPreparation
            }
            return .upload(transactionToken: token, notesValue: notesValue)
        }
        return .noUpload(transactionToken: token)
    }

    func syncFinished(finish: FloorpPrefsSyncFinish) throws {
        guard finish.serverModifiedMillis >= 0 else {
            throw FloorpPrefsSyncError.InvalidIncomingRecord
        }
        guard let pending = withStateLock({ pendingTransactions.removeValue(forKey: finish.transactionToken) }),
              pending.generation == withStateLock({ generation }) else {
            throw FloorpPrefsSyncError.UnexpectedSyncState
        }
        if pending.persistence.plan.requiresUpload && !finish.didUpload {
            throw FloorpPrefsSyncError.UploadNotConfirmed
        }
        let didStage = withStateLock {
            guard generation == pending.generation else { return false }
            pendingStateCommit = pending
            return true
        }
        guard didStage else { throw FloorpPrefsSyncError.UnexpectedSyncState }
    }

    func syncStateChanged(state: FloorpPrefsSyncState) throws {
        do {
            try withStateLock {
                guard let pendingStateCommit,
                      pendingStateCommit.generation == generation else {
                    throw FloorpPrefsSyncError.UnexpectedSyncState
                }
                self.pendingStateCommit = nil
                try persistenceCore.commitSyncPersistence(
                    pendingStateCommit.persistence,
                    applicationServicesState: Self.persistedState(from: state)
                )
            }
        } catch let error as FloorpPrefsSyncError {
            throw error
        } catch {
            throw Self.applicationServicesError(from: error)
        }
    }

    func associationReset(state: FloorpPrefsSyncState) throws {
        invalidateTransactions()
        let persistedState = Self.persistedState(from: state)
        let didStage = try withStateLock {
            guard checkedDisconnectInProgress else { return false }
            try persistenceCore.stagePendingSyncAssociationReset(
                accountID: accountID,
                state: persistedState
            )
            pendingAssociationResetState = persistedState
            return true
        }
        if didStage { return }
        do {
            try persistenceCore.resetSyncAssociation(
                accountID: accountID,
                state: persistedState
            )
        } catch {
            throw Self.applicationServicesError(from: error)
        }
    }

    func beginCheckedDisconnect() {
        invalidate()
        withStateLock {
            checkedDisconnectInProgress = true
        }
    }

    func finalizeCheckedDisconnect() throws {
        do {
            try withStateLock {
                guard checkedDisconnectInProgress,
                      let pendingAssociationResetState else {
                    throw FloorpPrefsSyncError.UnexpectedSyncState
                }
                try persistenceCore.finalizePendingSyncAssociationReset(
                    accountID: accountID,
                    state: pendingAssociationResetState
                )
                checkedDisconnectInProgress = false
                self.pendingAssociationResetState = nil
            }
        } catch let error as FloorpPrefsSyncError {
            throw error
        } catch {
            throw Self.applicationServicesError(from: error)
        }
    }

    func cancelCheckedDisconnect() throws {
        try withStateLock {
            try persistenceCore.cancelPendingSyncAssociationReset(
                accountID: accountID
            )
            checkedDisconnectInProgress = false
            pendingAssociationResetState = nil
        }
    }

    func invalidate() {
        invalidateTransactions()
        withStateLock {
            checkedDisconnectInProgress = false
            pendingAssociationResetState = nil
        }
    }

    private func invalidateTransactions() {
        withStateLock {
            generation = generation == UInt64.max ? 0 : generation + 1
            pendingTransactions.removeAll()
            pendingStateCommit = nil
        }
    }

    private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private static func persistedState(
        from state: FloorpPrefsSyncState
    ) -> FloorpNotesApplicationServicesState {
        FloorpNotesApplicationServicesState(
            globalSyncID: state.globalSyncId,
            collectionSyncID: state.collectionSyncId,
            lastModifiedMillis: state.lastModifiedMillis
        )
    }

    private static func generatedState(
        from state: FloorpNotesApplicationServicesState
    ) -> FloorpPrefsSyncState {
        FloorpPrefsSyncState(
            globalSyncId: state.globalSyncID,
            collectionSyncId: state.collectionSyncID,
            lastModifiedMillis: state.lastModifiedMillis
        )
    }

    private static func applicationServicesError(from error: Error) -> FloorpPrefsSyncError {
        if let error = error as? FloorpNotesPersistenceError {
            switch error {
            case .staleRevision:
                return .UnexpectedSyncState
            case .emptyAccountID, .accountMismatch, .invalidApplicationServicesState:
                return .DelegateRejected
            }
        }
        if let error = error as? FloorpNotesSyncError {
            switch error {
            case .recordTooLarge:
                return .PayloadTooLarge
            case .invalidApplicationServicesBoundary, .invalidRemotePayload,
                    .unsupportedRemoteFields, .missingRemoteIDsAfterInitialSync:
                return .InvalidIncomingRecord
            default:
                return .DelegateRejected
            }
        }
        return .DelegateRejected
    }
}

/// Client-target bridge injected into the Providers sync manager. Keeping the
/// generated store here avoids making app extensions depend on Floorp Notes.
final class FloorpNotesSyncEngineProvider: FloorpNotesSyncEngineProviding, @unchecked Sendable {
    private let notesStore: FloorpNotesStore
    private let networkSyncEnabled: @Sendable () -> Bool
    private let statusCenter: FloorpNotesSyncStatusCenter
    private let makeApplicationServicesStore: @Sendable (
        FloorpPrefsSyncDelegate,
        FloorpPrefsSyncState?
    ) throws -> FloorpPrefsSyncStore
    private let lock = NSRecursiveLock()
    private var accountID: String?
    private var delegate: FloorpNotesPrefsSyncDelegate?
    private var applicationServicesStore: FloorpPrefsSyncStore?
    private(set) var registrationCount = 0

    init(
        notesStore: FloorpNotesStore = .shared,
        networkSyncEnabled: @escaping @Sendable () -> Bool = {
            FloorpNotesSyncReleaseGate.isNetworkSyncEnabled
        },
        statusCenter: FloorpNotesSyncStatusCenter = .shared,
        makeApplicationServicesStore: @escaping @Sendable (
            FloorpPrefsSyncDelegate,
            FloorpPrefsSyncState?
        ) throws -> FloorpPrefsSyncStore = { delegate, initialState in
            try FloorpPrefsSyncStore(
                delegate: delegate,
                initialState: initialState
            )
        }
    ) {
        self.notesStore = notesStore
        self.networkSyncEnabled = networkSyncEnabled
        self.statusCenter = statusCenter
        self.makeApplicationServicesStore = makeApplicationServicesStore
    }

    func resumePendingDisconnectCleanup() throws {
        let didResume = try lock.withLock {
            guard try notesStore.syncPersistenceCore
                .hasPendingSyncAssociationReset() else {
                return false
            }
            invalidateLocked()
            return try notesStore.syncPersistenceCore
                .resumePendingSyncAssociationReset()
        }
        if didResume {
            statusCenter.setStatus(.localOnly)
        }
    }

    func allowsSync(accountID: String) -> Bool {
        guard networkSyncEnabled(),
              (try? notesStore.syncAccountAvailability(accountID: accountID)) == .available else {
            statusCenter.setStatus(.localOnly)
            return false
        }
        return true
    }

    func register(accountID: String) throws {
        guard allowsSync(accountID: accountID) else {
            throw FloorpNotesPersistenceError.accountMismatch
        }
        try lock.withLock {
            try registerLocked(accountID: accountID)
            statusCenter.setStatus(.syncEnabled)
        }
    }

    func prepareForDisconnect(
        accountID: String?
    ) throws -> FloorpNotesSyncAccountAvailability {
        guard let accountID else {
            throw FloorpNotesPersistenceError.emptyAccountID
        }
        let availability = try notesStore.syncAccountAvailability(accountID: accountID)
        guard availability == .available else {
            invalidate()
            return .accountMismatch
        }
        try lock.withLock {
            try registerLocked(accountID: accountID)
            delegate?.beginCheckedDisconnect()
        }
        return .available
    }

    func finalizeDisconnect() throws {
        try lock.withLock {
            guard let delegate else { throw FloorpPrefsSyncError.UnexpectedSyncState }
            try delegate.finalizeCheckedDisconnect()
        }
    }

    @discardableResult
    func cancelDisconnect() -> Bool {
        let didRestore = lock.withLock { () -> Bool in
            guard let accountID else { return false }
            do {
                try delegate?.cancelCheckedDisconnect()
            } catch {
                invalidateLocked()
                return false
            }
            invalidateLocked()
            do {
                try registerLocked(accountID: accountID)
                return true
            } catch {
                invalidateLocked()
                return false
            }
        }
        statusCenter.setStatus(
            didRestore && networkSyncEnabled() ? .syncEnabled : .localOnly
        )
        return didRestore
    }

    func invalidate() {
        lock.withLock { invalidateLocked() }
        statusCenter.setStatus(.localOnly)
    }

    private func invalidateLocked() {
        delegate?.invalidate()
        applicationServicesStore = nil
        delegate = nil
        accountID = nil
    }

    private func registerLocked(accountID: String) throws {
        try notesStore.claimSyncOwnership(accountID: accountID)
        if self.accountID == accountID, applicationServicesStore != nil {
            return
        }
        invalidateLocked()
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: accountID,
            notesStore: notesStore
        )
        let store = try makeApplicationServicesStore(
            delegate,
            delegate.initialSyncState
        )
        store.registerWithSyncManager()
        self.accountID = accountID
        self.delegate = delegate
        applicationServicesStore = store
        registrationCount += 1
    }

    var retainsRegisteredStore: Bool {
        lock.withLock { applicationServicesStore != nil }
    }

    var registeredSyncState: FloorpPrefsSyncState? {
        lock.withLock { applicationServicesStore?.syncState() }
    }
}

struct FloorpNotesSyncReleaseEvidence: Equatable, Sendable {
    let fixtureContractVersion: String
    let fixtureSHA256: String
    let currentDesktopContractVersion: String?
    let coordinatedDesktopMigrationVersion: String?
    let linkedApplicationServicesContractVersion: String?
}

struct FloorpNotesSyncCompiledConfiguration {
    let buildMode: Any?
    let sourceSHA: String?
    let buildNumber: String?
    let requested: Any?
    let effective: Any?
    let registrationAllowed: Any?
    let engineRequestsAllowed: Any?
    let uiExposureAllowed: Any?
    let endpointAuthority: String?
    let wireProtocol: String?
    let endpointMatrixSHA256: String?
    let evidenceDigest: String?
    let evidenceResourceSHA256: String?
}

/// Network Notes Sync is release-gated independently of build-time feature
/// flags. Ordinary checked-in FloorpRelease settings are false. An enabled
/// build must bind every runtime surface to one validated, byte-identical
/// evidence resource produced outside the clean source worktree.
enum FloorpNotesSyncReleaseGate {
    private enum BuildMode: String {
        case productionQA = "production-qa"
        case releaseEnabled = "release-enabled"
    }

    static let mergeContractVersion = "floorp-notes-merge-v1"
    static let mergeFixtureSHA256 = "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd"
    static let observedProductionDesktopCommit = "410c211c202012631159d1bce1f3ab208305d2b7"
    private static let releaseDesktopCommit = "fc244eed70248796fa92ff5821c6046ecd576e7e"
    private static let releaseRuntimeCommit = "3bf9399564e59be32f92dcc1b044094881b4fb6a"
    private static let releaseRuntimeTree = "533f9fdca9bdccb7f3d2a13842be7e2375160ae5"
    private static let releaseApplicationServicesCommit = "b6d29804c391a573ecc0db6c1c4491b3e07a6693"
    private static let releaseApplicationServicesTree = "8bfa4a27d5b807b613d577ee49198617aab0e117"
    private static let releaseApplicationServicesTag = "floorp-ios-155.20260731050244.4"
    private static let mergeCaseSetSHA256 = "c19ec1a3229b0d09aa424498471941409bc77505862e8aa278aadb3396032802"
    private static let endpointPolicySHA256 = "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca"
    private static let recordID = "e2VjODAzMGY3LWMyMGEtNDY0Zi05YjBlLTEzYTNhOWU5NzM4NH0"
    private static let notesPrefName = "floorp.browser.note.memos"
    private static let controlPrefName = "services.sync.prefs.sync.floorp.browser.note.memos"
    private static let applicationServicesArtifacts = [
        "focus_xcframework_sha256": "d996835e76b7b66e516c4b7ddf6c401d815a1ce60466fbbdca73edd2f2ff2b0a",
        "mozilla_xcframework_sha256": "579b00cd5823a94101145a4deef7df44e1eeb3929cbe849f53a0f6d008e6f268",
        "release_manifest_sha256": "387beac1bb8d4b204b9c8ebdc3797ea75e2466c507ec944b2b5188fea2d6b0dd",
        "sha256sums_sha256": "32db0711e7b5cf6d088ef95b290941be9ba22cfceeadfc35978fa97d05506b8c",
        "swift_components_sha256": "e9cdae3cbcd19c68d6a1eed78917862f2a6420e2b74fb52e6669f0d641f31433",
    ]
    private static let fxaHosts = [
        "accounts.firefox.com",
        "api.accounts.firefox.com",
        "oauth.accounts.firefox.com",
        "profile.accounts.firefox.com",
        "static.accounts.firefox.com",
    ]
    private static let syncHosts = [
        "event-sync.services.mozilla.com",
        "sync.services.mozilla.com",
        "token.services.mozilla.com",
    ]
    static let evidenceResourceName = "FloorpNotesSyncReleaseEvidence"
    static let rescopedProductionQACapabilityVersion = "todo20-production-sync-integrity-v1"
    private static let rescopedContractSHA256 = "e935ab08c60cd7fcdbe66699764cd2805410f90bb0e3651d97b2c65c58f98764"
    private static let rescopedIntegrityMatrixSHA256 = "53828225b7ae183212df954e7076e577879a74acac73e5cbaf50389d7dd0df45"
    static let buildAllowsKey = "MozAllowFloorpNotesSync"
    static let buildModeKey = "MozFloorpNotesSyncBuildMode"
    static let sourceSHAKey = "MozFloorpNotesSyncSourceSHA"
    static let buildNumberKey = "MozFloorpNotesSyncBuildNumber"
    static let requestedKey = "MozFloorpNotesSyncRequested"
    static let registrationAllowedKey = "MozFloorpNotesSyncRegistrationAllowed"
    static let engineRequestsAllowedKey = "MozFloorpNotesSyncEngineRequestsAllowed"
    static let uiExposureAllowedKey = "MozFloorpNotesSyncUIExposureAllowed"
    static let endpointAuthorityKey = "MozFloorpNotesSyncEndpointAuthority"
    static let wireProtocolKey = "MozFloorpNotesSyncProtocol"
    static let endpointMatrixSHA256Key = "MozFloorpNotesSyncEndpointMatrixSHA256"
    static let evidenceDigestKey = "MozFloorpNotesSyncEvidenceDigest"
    static let evidenceResourceSHA256Key = "MozFloorpNotesSyncEvidenceResourceSHA256"

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
        #if DEBUG || TESTING
        false
        #else
        guard let evidenceURL = Bundle.main.url(
            forResource: evidenceResourceName,
            withExtension: "json"
        ),
              let evidenceData = try? Data(contentsOf: evidenceURL) else {
            return false
        }
        let configuration = FloorpNotesSyncCompiledConfiguration(
            buildMode: Bundle.main.object(forInfoDictionaryKey: buildModeKey),
            sourceSHA: Bundle.main.object(forInfoDictionaryKey: sourceSHAKey) as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: buildNumberKey) as? String,
            requested: Bundle.main.object(forInfoDictionaryKey: requestedKey),
            effective: Bundle.main.object(forInfoDictionaryKey: buildAllowsKey),
            registrationAllowed: Bundle.main.object(forInfoDictionaryKey: registrationAllowedKey),
            engineRequestsAllowed: Bundle.main.object(forInfoDictionaryKey: engineRequestsAllowedKey),
            uiExposureAllowed: Bundle.main.object(forInfoDictionaryKey: uiExposureAllowedKey),
            endpointAuthority: Bundle.main.object(forInfoDictionaryKey: endpointAuthorityKey) as? String,
            wireProtocol: Bundle.main.object(forInfoDictionaryKey: wireProtocolKey) as? String,
            endpointMatrixSHA256:
                Bundle.main.object(forInfoDictionaryKey: endpointMatrixSHA256Key) as? String,
            evidenceDigest: Bundle.main.object(forInfoDictionaryKey: evidenceDigestKey) as? String,
            evidenceResourceSHA256:
                Bundle.main.object(forInfoDictionaryKey: evidenceResourceSHA256Key) as? String
        )
        return allowsCompiledEvidence(configuration, evidenceData: evidenceData)
        #endif
    }

    // The legacy G1-G5 path remains byte-for-byte fail-closed beside the
    // smaller Todo 20 production-QA capability path.
    // swiftlint:disable:next function_body_length
    static func allowsCompiledEvidence(
        _ configuration: FloorpNotesSyncCompiledConfiguration,
        evidenceData: Data?,
        now: Date = Date()
    ) -> Bool {
        guard let modeValue = configuration.buildMode as? String,
              let mode = BuildMode(rawValue: modeValue),
              let sourceSHA = configuration.sourceSHA,
              isLowercaseHex(sourceSHA, count: 40),
              let buildNumber = configuration.buildNumber,
              isNonempty(buildNumber),
              isEnabled(configuration.requested),
              isEnabled(configuration.effective),
              isEnabled(configuration.registrationAllowed),
              isEnabled(configuration.engineRequestsAllowed),
              isEnabled(configuration.uiExposureAllowed),
              configuration.endpointAuthority == "production",
              configuration.wireProtocol == "sync15",
              let endpointMatrixSHA256 = configuration.endpointMatrixSHA256,
              endpointMatrixSHA256 == endpointPolicySHA256,
              let evidenceDigest = configuration.evidenceDigest,
              isLowercaseHex(evidenceDigest, count: 64),
              let evidenceResourceSHA256 = configuration.evidenceResourceSHA256,
              isLowercaseHex(evidenceResourceSHA256, count: 64),
              let evidenceData,
              SHA256.hash(data: evidenceData).hexString == evidenceResourceSHA256,
              let root = try? JSONSerialization.jsonObject(with: evidenceData) as? [String: Any],
              canonicalJSONData(root) == evidenceData,
              isJSONInteger(root["schema_version"], equalTo: 1),
              root["build_contract_mode"] as? String == mode.rawValue else {
            return false
        }

        if mode == .productionQA,
           root["todo20_contract_version"] != nil {
            return allowsRescopedProductionQACapability(
                root,
                sourceSHA: sourceSHA,
                buildNumber: buildNumber,
                endpointMatrixSHA256: endpointMatrixSHA256,
                evidenceDigest: evidenceDigest,
                evidenceResourceSHA256: evidenceResourceSHA256
            )
        }

        guard let releaseInputs = root["release_inputs"] as? [String: Any],
              compiledReleaseInputsAreBound(
                releaseInputs,
                sourceSHA: sourceSHA,
                buildNumber: buildNumber,
                endpointMatrixSHA256: endpointMatrixSHA256
              ),
              let gates = root["gates"] as? [String: Any] else {
            return false
        }

        let requiredGateNames: [String]
        let allowedGateSets: [Set<String>]
        let digestKey: String
        let rootKeys: Set<String>
        switch mode {
        case .productionQA:
            requiredGateNames = ["g1", "g2", "g3", "g4"]
            allowedGateSets = [Set(requiredGateNames)]
            digestKey = "g1_g4_digest_sha256"
            rootKeys = [
                "schema_version", "build_contract_mode", "release_inputs", "gates",
                digestKey, "same_release_key_sha256",
            ]
        case .releaseEnabled:
            requiredGateNames = ["g1", "g2", "g3", "g4", "g5"]
            // G6 signatures are validated out-of-process against repository
            // trust anchors. The app embeds only the exact G1-G5 capability
            // record and rejects any unverified G6 object at runtime.
            allowedGateSets = [Set(requiredGateNames)]
            digestKey = "g1_g5_digest_sha256"
            rootKeys = [
                "schema_version", "build_contract_mode", "release_inputs", "gates",
                digestKey, "same_release_key_sha256",
            ]
        }
        guard hasExactKeys(root, rootKeys),
              allowedGateSets.contains(Set(gates.keys)),
              root[digestKey] as? String == evidenceDigest,
              validateGates(
                gates,
                requiredGateNames: requiredGateNames,
                releaseInputs: releaseInputs,
                now: now
              ),
              digest(
                [
                    "gates": Dictionary(uniqueKeysWithValues: requiredGateNames.compactMap { name in
                        gates[name].map { (name, $0) }
                    }),
                    "release_inputs": releaseInputs,
                ]
              ) == evidenceDigest,
              let sameReleaseKey = root["same_release_key_sha256"] as? String,
              isLowercaseHex(sameReleaseKey, count: 64) else {
            return false
        }
        let gateDigests: [String: String] = Dictionary(
            uniqueKeysWithValues: gates.compactMap { name, value -> (String, String)? in
            guard let gate = value as? [String: Any],
                  let artifact = gate["artifact"] as? [String: Any],
                  let artifactDigest = artifact["sha256"] as? String else {
                return nil
            }
            return (name, artifactDigest)
            }
        )
        guard gateDigests.count == gates.count,
              Set(gateDigests.values).count == gateDigests.count else {
            return false
        }
        return digest(
            [
                "gate_artifact_digests": gateDigests,
                "release_inputs": releaseInputs,
            ]
        ) == sameReleaseKey
    }

    private static func allowsRescopedProductionQACapability(
        _ root: [String: Any],
        sourceSHA: String,
        buildNumber: String,
        endpointMatrixSHA256: String,
        evidenceDigest: String,
        evidenceResourceSHA256: String
    ) -> Bool {
        guard hasExactKeys(
                root,
                [
                    "accounts", "build_contract_mode", "clients", "contract_sha256",
                    "desktop", "endpoint", "integrity_matrix_sha256", "public_release",
                    "ios_build_number", "schema_version", "self_attestation", "source",
                    "todo20_contract_version",
                ]
              ),
              root["todo20_contract_version"] as? String == rescopedProductionQACapabilityVersion,
              isJSONInteger(root["accounts"], equalTo: 2),
              root["clients"] as? [String] == ["desktop", "mobile"],
              root["ios_build_number"] as? String == buildNumber,
              root["public_release"] as? Bool == false,
              root["contract_sha256"] as? String == rescopedContractSHA256,
              root["integrity_matrix_sha256"] as? String == rescopedIntegrityMatrixSHA256,
              evidenceDigest == evidenceResourceSHA256,
              let source = root["source"] as? [String: Any],
              hasExactKeys(
                source,
                [
                    "event", "head_sha", "job_name", "repository", "workflow_path",
                    "workflow_run_attempt", "workflow_run_id",
                ]
              ),
              source["event"] as? String == "workflow_dispatch",
              source["head_sha"] as? String == sourceSHA,
              source["job_name"] as? String == "notes-sync-production-qa",
              source["repository"] as? String == "Floorp-Projects/floorp-ios",
              source["workflow_path"] as? String
                == ".github/workflows/floorp-notes-sync-production-qa.yml",
              isJSONInteger(source["workflow_run_attempt"], greaterThan: 0),
              isJSONInteger(source["workflow_run_id"], greaterThan: 0),
              let desktop = root["desktop"] as? [String: Any],
              hasExactKeys(desktop, ["repository", "source_sha"]),
              desktop["repository"] as? String == "Floorp-Projects/Floorp",
              isLowercaseHex(desktop["source_sha"] as? String ?? "", count: 40),
              let endpoint = root["endpoint"] as? [String: Any],
              hasExactKeys(
                endpoint,
                [
                    "endpoint_policy_sha256", "fxa_configuration", "fxa_hosts",
                    "sync_hosts", "wire_protocol",
                ]
              ),
              endpoint["endpoint_policy_sha256"] as? String == endpointMatrixSHA256,
              endpoint["fxa_configuration"] as? String == "FxAConfig.Server.release",
              endpoint["fxa_hosts"] as? [String] == fxaHosts,
              endpoint["sync_hosts"] as? [String] == syncHosts,
              endpoint["wire_protocol"] as? String == "sync15",
              let attestation = root["self_attestation"] as? [String: Any],
              hasExactKeys(attestation, ["approved", "environment", "operator_id", "roles"]),
              attestation["approved"] as? Bool == true,
              attestation["environment"] as? String == "floorp-notes-sync-production-qa",
              isNonempty(attestation["operator_id"] as? String),
              attestation["roles"] as? [String] == ["owner", "operations", "executor"] else {
            return false
        }

        return true
    }

    private static func compiledReleaseInputsAreBound(
        _ inputs: [String: Any],
        sourceSHA: String,
        buildNumber: String,
        endpointMatrixSHA256: String
    ) -> Bool {
        guard hasExactKeys(
                inputs,
                ["ios", "desktop", "runtime", "application_services", "contract", "environment"]
              ),
              let ios = inputs["ios"] as? [String: Any],
              hasExactKeys(ios, ["repository", "source_sha", "build_number", "configuration"]),
              ios["repository"] as? String == "Floorp-Projects/floorp-ios",
              ios["source_sha"] as? String == sourceSHA,
              ios["build_number"] as? String == buildNumber,
              ios["configuration"] as? String == "FloorpRelease",
              let desktop = inputs["desktop"] as? [String: Any],
              hasExactKeys(desktop, ["repository", "source_sha", "build_number"]),
              desktop["repository"] as? String == "Floorp-Projects/Floorp",
              desktop["source_sha"] as? String == releaseDesktopCommit,
              let desktopBuildNumber = desktop["build_number"] as? String,
              isNonempty(desktopBuildNumber),
              let runtime = inputs["runtime"] as? [String: Any],
              hasExactKeys(runtime, ["repository", "source_sha", "tree_sha"]),
              runtime["repository"] as? String == "Floorp-Projects/Floorp-Runtime",
              runtime["source_sha"] as? String == releaseRuntimeCommit,
              runtime["tree_sha"] as? String == releaseRuntimeTree,
              let applicationServices = inputs["application_services"] as? [String: Any],
              applicationServicesInputIsBound(applicationServices),
              let environment = inputs["environment"] as? [String: Any],
              hasExactKeys(
                environment,
                ["fxa_configuration", "fxa_hosts", "sync_hosts", "wire_protocol"]
              ),
              environment["fxa_configuration"] as? String == "FxAConfig.Server.release",
              environment["wire_protocol"] as? String == "sync15",
              environment["fxa_hosts"] as? [String] == fxaHosts,
              environment["sync_hosts"] as? [String] == syncHosts,
              let contract = inputs["contract"] as? [String: Any],
              hasExactKeys(
                contract,
                ["fixture_sha256", "case_set_sha256", "endpoint_policy_sha256"]
              ),
              contract["fixture_sha256"] as? String == mergeFixtureSHA256,
              contract["case_set_sha256"] as? String == mergeCaseSetSHA256,
              contract["endpoint_policy_sha256"] as? String == endpointMatrixSHA256 else {
            return false
        }
        return true
    }

    private static func applicationServicesInputIsBound(_ input: [String: Any]) -> Bool {
        guard hasExactKeys(input, ["repository", "source_sha", "tree_sha", "release_tag", "artifacts"]),
              input["repository"] as? String == "Floorp-Projects/application-services",
              input["source_sha"] as? String == releaseApplicationServicesCommit,
              input["tree_sha"] as? String == releaseApplicationServicesTree,
              input["release_tag"] as? String == releaseApplicationServicesTag,
              let artifacts = input["artifacts"] as? [String: Any],
              hasExactKeys(artifacts, Set(applicationServicesArtifacts.keys)) else {
            return false
        }
        return applicationServicesArtifacts.allSatisfy { name, expected in
            artifacts[name] as? String == expected
        }
    }

    private static func validateGates(
        _ gates: [String: Any],
        requiredGateNames: [String],
        releaseInputs: [String: Any],
        now: Date
    ) -> Bool {
        guard let g1 = gates["g1"] as? [String: Any],
              hasExactKeys(g1, ["status", "issued_at", "artifact", "contract"]),
              commonGateIsValid(g1, now: now, maximumAgeDays: nil),
              artifactRolesAreValid(g1, gateName: "g1"),
              let g1Contract = g1["contract"] as? [String: Any],
              let ios = releaseInputs["ios"] as? [String: Any],
              let desktop = releaseInputs["desktop"] as? [String: Any],
              g1ContractIsBound(g1Contract, ios: ios, desktop: desktop),
              let g2 = gates["g2"] as? [String: Any],
              hasExactKeys(
                g2,
                [
                    "status", "issued_at", "expires_at", "artifact",
                    "application_services", "fake_server_run_sha256",
                ]
              ),
              commonGateIsValid(g2, now: now, maximumAgeDays: 30),
              artifactRolesAreValid(g2, gateName: "g2"),
              isSHA256(g2["fake_server_run_sha256"]),
              let g2ApplicationServices = g2["application_services"] as? [String: Any],
              let applicationServices = releaseInputs["application_services"] as? [String: Any],
              jsonObjectsAreEqual(g2ApplicationServices, applicationServices),
              let g3 = gates["g3"] as? [String: Any],
              hasExactKeys(
                g3,
                ["status", "issued_at", "expires_at", "artifact", "candidate", "xcresult_sha256"]
              ),
              commonGateIsValid(g3, now: now, maximumAgeDays: 7),
              artifactRolesAreValid(g3, gateName: "g3"),
              isSHA256(g3["xcresult_sha256"]),
              let candidate = g3["candidate"] as? [String: Any],
              jsonObjectsAreEqual(candidate, ios),
              let g4 = gates["g4"] as? [String: Any],
              hasExactKeys(
                g4,
                [
                    "status", "issued_at", "expires_at", "artifact", "desktop", "runtime",
                    "xpcshell_run_sha256", "tps_run_sha256",
                ]
              ),
              commonGateIsValid(g4, now: now, maximumAgeDays: 30),
              artifactRolesAreValid(g4, gateName: "g4"),
              isSHA256(g4["xpcshell_run_sha256"]),
              isSHA256(g4["tps_run_sha256"]),
              let g4Desktop = g4["desktop"] as? [String: Any],
              jsonObjectsAreEqual(g4Desktop, desktop),
              let runtime = releaseInputs["runtime"] as? [String: Any],
              let g4Runtime = g4["runtime"] as? [String: Any],
              jsonObjectsAreEqual(g4Runtime, runtime) else {
            return false
        }

        if requiredGateNames.contains("g5") {
            guard let g5 = gates["g5"] as? [String: Any],
                  hasExactKeys(
                    g5,
                    [
                        "status", "issued_at", "expires_at", "artifact", "ios", "desktop",
                        "runtime", "application_services", "account_isolation_run_sha256",
                        "proxy_trace_sha256",
                    ]
                  ),
                  commonGateIsValid(g5, now: now, maximumAgeDays: 7),
                  artifactRolesAreValid(g5, gateName: "g5"),
                  isSHA256(g5["account_isolation_run_sha256"]),
                  isSHA256(g5["proxy_trace_sha256"]),
                  let g5IOS = g5["ios"] as? [String: Any],
                  jsonObjectsAreEqual(g5IOS, ios),
                  let g5Desktop = g5["desktop"] as? [String: Any],
                  jsonObjectsAreEqual(g5Desktop, desktop),
                  let g5Runtime = g5["runtime"] as? [String: Any],
                  jsonObjectsAreEqual(g5Runtime, runtime),
                  let g5ApplicationServices = g5["application_services"] as? [String: Any],
                  g5ApplicationServicesIsBound(g5ApplicationServices, input: applicationServices) else {
                return false
            }
        }

        return true
    }

    private static func g1ContractIsBound(
        _ contract: [String: Any],
        ios: [String: Any],
        desktop: [String: Any]
    ) -> Bool {
        guard hasExactKeys(
                contract,
                [
                    "ios_contract_sha", "desktop_contract_sha", "fixture_sha256",
                    "case_set_sha256", "record_id", "notes_pref_name", "control_pref_name",
                    "control_pref_value",
                ]
              ),
              contract["ios_contract_sha"] as? String == ios["source_sha"] as? String,
              contract["desktop_contract_sha"] as? String == desktop["source_sha"] as? String,
              contract["fixture_sha256"] as? String == mergeFixtureSHA256,
              contract["case_set_sha256"] as? String == mergeCaseSetSHA256,
              contract["record_id"] as? String == recordID,
              contract["notes_pref_name"] as? String == notesPrefName,
              contract["control_pref_name"] as? String == controlPrefName,
              contract["control_pref_value"] as? Bool == true else {
            return false
        }
        return true
    }

    private static func g5ApplicationServicesIsBound(
        _ gateInput: [String: Any],
        input: [String: Any]
    ) -> Bool {
        guard hasExactKeys(
                gateInput,
                ["source_sha", "release_tag", "mozilla_xcframework_sha256"]
              ),
              let artifacts = input["artifacts"] as? [String: Any] else {
            return false
        }
        return gateInput["source_sha"] as? String == input["source_sha"] as? String
            && gateInput["release_tag"] as? String == input["release_tag"] as? String
            && gateInput["mozilla_xcframework_sha256"] as? String
                == artifacts["mozilla_xcframework_sha256"] as? String
    }

    private static func commonGateIsValid(
        _ gate: [String: Any],
        now: Date,
        maximumAgeDays: Int?
    ) -> Bool {
        guard gate["status"] as? String == "passed",
              let issuedAt = timestamp(gate["issued_at"]),
              issuedAt <= now,
              let artifact = gate["artifact"] as? [String: Any],
              artifactIsValid(artifact) else {
            return false
        }
        guard let maximumAgeDays else { return gate["expires_at"] == nil }
        guard let expiresAt = timestamp(gate["expires_at"]),
              expiresAt > issuedAt,
              expiresAt <= issuedAt.addingTimeInterval(TimeInterval(maximumAgeDays * 86_400)),
              now <= expiresAt,
              now <= issuedAt.addingTimeInterval(TimeInterval(maximumAgeDays * 86_400)) else {
            return false
        }
        return true
    }

    private static func artifactIsValid(_ artifact: [String: Any]) -> Bool {
        guard hasExactKeys(artifact, ["sources", "sha256"]),
              let sources = artifact["sources"] as? [[String: Any]],
              (1...16).contains(sources.count),
              sources.allSatisfy(artifactSourceIsValid),
              isSHA256(artifact["sha256"]) else {
            return false
        }
        let roles = sources.compactMap { $0["role"] as? String }
        guard roles.count == sources.count,
              Set(roles).count == roles.count else {
            return false
        }
        return digest(["sources": sources]) == artifact["sha256"] as? String
    }

    private static func artifactRolesAreValid(
        _ gate: [String: Any],
        gateName: String
    ) -> Bool {
        typealias SourceContract = (kind: String, policy: String)
        let localMetadata: SourceContract = ("local-file", "metadata-json")
        let repositoryMetadata: SourceContract = (
            "github-repository-file",
            "metadata-json"
        )
        let repositorySource: SourceContract = (
            "github-repository-file",
            "source-code"
        )
        let actionsRun: SourceContract = ("github-actions-run", "metadata-json")
        let actionsResult: SourceContract = (
            "github-actions-artifact",
            "test-result-bundle"
        )
        let releaseBinary: SourceContract = (
            "github-release-asset",
            "release-binary"
        )
        let expected: [String: [String: SourceContract]] = [
            "g1": [
                "task-manifest": localMetadata,
                "todo16-contract": repositoryMetadata,
                "ios-contract-source": repositorySource,
                "desktop-contract-source": repositorySource,
                "merge-fixture": repositoryMetadata,
            ],
            "g2": [
                "task-manifest": localMetadata,
                "fake-server-run": localMetadata,
                "focus-xcframework": releaseBinary,
                "mozilla-xcframework": releaseBinary,
                "release-manifest": releaseBinary,
                "sha256sums": releaseBinary,
                "swift-components": releaseBinary,
            ],
            "g3": [
                "integration-receipt": localMetadata,
                "ci-run": actionsRun,
                "xcresult": actionsResult,
            ],
            "g4": [
                "task-manifest": localMetadata,
                "task18-execution-verdict": localMetadata,
                "desktop-ci-run": actionsRun,
                "runtime-ci-run": actionsRun,
                "g4-attestation-source": repositoryMetadata,
                "g4-attestation-ci-run": actionsRun,
                "g4-attestation-xcresult": actionsResult,
                "xpcshell-run": localMetadata,
                "tps-run": localMetadata,
            ],
            "g5": [
                "task-manifest": localMetadata,
                "ci-run": actionsRun,
                "xcresult": actionsResult,
                "account-isolation-run": localMetadata,
                "proxy-trace": ("local-file", "network-metadata-json"),
            ],
        ]
        guard let expectedSources = expected[gateName],
              let artifact = gate["artifact"] as? [String: Any],
              let sources = artifact["sources"] as? [[String: Any]] else {
            return false
        }
        let sourcesByRole = Dictionary(
            uniqueKeysWithValues: sources.compactMap { source -> (String, [String: Any])? in
                guard let role = source["role"] as? String else { return nil }
                return (role, source)
            }
        )
        guard sourcesByRole.count == sources.count,
              Set(sourcesByRole.keys) == Set(expectedSources.keys) else {
            return false
        }
        return expectedSources.allSatisfy { role, contract in
            sourcesByRole[role]?["kind"] as? String == contract.kind
                && sourcesByRole[role]?["content_policy"] as? String == contract.policy
        }
    }

    private static func artifactSourceIsValid(_ source: [String: Any]) -> Bool {
        guard let kind = source["kind"] as? String,
              isArtifactRole(source["role"]),
              isArtifactPolicy(source["content_policy"]),
              isSHA256(source["sha256"]) else {
            return false
        }
        switch kind {
        case "local-file", "local-directory":
            return hasExactKeys(
                source,
                ["kind", "role", "content_policy", "path", "sha256"]
            ) && isSafeRelativePath(source["path"])
        case "github-repository-file":
            return hasExactKeys(
                source,
                [
                    "kind", "role", "content_policy", "repository", "commit_sha",
                    "path", "blob_sha", "sha256",
                ]
            )
                && isGitHubRepository(source["repository"])
                && isSHA1(source["commit_sha"])
                && isSafeRelativePath(source["path"])
                && isSHA1(source["blob_sha"])
        case "github-actions-run":
            return hasExactKeys(
                source,
                [
                    "kind", "role", "content_policy", "repository", "run_id",
                    "workflow_path", "head_sha", "sha256",
                ]
            )
                && isGitHubRepository(source["repository"])
                && isPositiveSafeInteger(source["run_id"])
                && isWorkflowPath(source["workflow_path"])
                && isSHA1(source["head_sha"])
        case "github-actions-artifact":
            return hasExactKeys(
                source,
                [
                    "kind", "role", "content_policy", "repository", "run_id",
                    "artifact_id", "artifact_name", "artifact_created_at",
                    "artifact_expires_at", "head_sha", "sha256",
                ]
            )
                && isGitHubRepository(source["repository"])
                && isPositiveSafeInteger(source["run_id"])
                && isPositiveSafeInteger(source["artifact_id"])
                && isNonempty(source["artifact_name"] as? String)
                && timestamp(source["artifact_created_at"]) != nil
                && timestamp(source["artifact_expires_at"]) != nil
                && isSHA1(source["head_sha"])
        case "github-release-asset":
            return hasExactKeys(
                source,
                [
                    "kind", "role", "content_policy", "repository", "release_id",
                    "release_tag", "release_immutable", "release_prerelease",
                    "release_published_at",
                    "asset_id", "asset_name", "source_sha", "sha256",
                ]
            )
                && isGitHubRepository(source["repository"])
                && isPositiveSafeInteger(source["release_id"])
                && isNonempty(source["release_tag"] as? String)
                && source["release_immutable"] as? Bool == true
                && source["release_prerelease"] as? Bool == true
                && timestamp(source["release_published_at"]) != nil
                && isPositiveSafeInteger(source["asset_id"])
                && isNonempty(source["asset_name"] as? String)
                && isSHA1(source["source_sha"])
        default:
            return false
        }
    }

    private static func isArtifactRole(_ value: Any?) -> Bool {
        guard let value = value as? String,
              let expression = try? NSRegularExpression(
                pattern: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"
              ) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func isArtifactPolicy(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return [
            "metadata-json", "network-metadata-json", "source-code",
            "test-result-bundle", "release-binary",
        ].contains(value)
    }

    private static func isSafeRelativePath(_ value: Any?) -> Bool {
        guard let value = value as? String,
              isNonempty(value),
              !value.hasPrefix("/"),
              !value.contains("\\") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isWorkflowPath(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return isSafeRelativePath(value)
            && value.hasPrefix(".github/workflows/")
            && (value.hasSuffix(".yml") || value.hasSuffix(".yaml"))
    }

    private static func isGitHubRepository(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { !$0.isEmpty }
    }

    private static func isPositiveSafeInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return false
        }
        return number.doubleValue > 0
            && number.doubleValue <= 9_007_199_254_740_991
    }

    private static func isSHA1(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return isLowercaseHex(value, count: 40)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String,
              value.utf8.count == 20 else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    private static func digest(_ value: Any) -> String? {
        canonicalJSONData(value).map { SHA256.hash(data: $0).hexString }
    }

    private static func canonicalJSONData(_ value: Any) -> Data? {
        canonicalJSONString(value)?.data(using: .utf8)
    }

    private static func canonicalJSONString(_ value: Any) -> String? {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  abs(doubleValue) <= 9_007_199_254_740_991 else {
                return nil
            }
            return String(Int64(doubleValue))
        }
        if let string = value as? String { return canonicalJSONStringLiteral(string) }
        if let array = value as? [Any] {
            let encoded = array.compactMap(canonicalJSONString)
            guard encoded.count == array.count else { return nil }
            return "[" + encoded.joined(separator: ",") + "]"
        }
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            var encoded: [String] = []
            encoded.reserveCapacity(keys.count)
            for key in keys {
                guard let keyString = canonicalJSONStringLiteral(key),
                      let item = dictionary[key],
                      let valueString = canonicalJSONString(item) else {
                    return nil
                }
                encoded.append(keyString + ":" + valueString)
            }
            return "{" + encoded.joined(separator: ",") + "}"
        }
        return nil
    }

    private static func canonicalJSONStringLiteral(_ value: String) -> String? {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0A: encoded += "\\n"
            case 0x0C: encoded += "\\f"
            case 0x0D: encoded += "\\r"
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x00...0x1F:
                encoded += String(format: "\\u%04x", scalar.value)
            case 0xD800...0xDFFF:
                return nil
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        return encoded + "\""
    }

    private static func jsonObjectsAreEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        canonicalJSONData(lhs) == canonicalJSONData(rhs)
    }

    private static func hasExactKeys(_ object: [String: Any], _ keys: Set<String>) -> Bool {
        Set(object.keys) == keys
    }

    private static func isJSONInteger(_ value: Any?, equalTo expected: Int64) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return number.doubleValue == Double(expected)
    }

    private static func isJSONInteger(_ value: Any?, greaterThan expected: Int64) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return number.int64Value > expected && number.doubleValue == Double(number.int64Value)
    }

    private static func isSHA256(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return isLowercaseHex(value, count: 64)
    }

    private static func isNonempty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return ["YES", "TRUE", "1"].contains(value.uppercased())
        default:
            return false
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
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
