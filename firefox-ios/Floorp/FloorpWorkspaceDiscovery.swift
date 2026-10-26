// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Account
import CryptoKit
import Foundation
import MozillaAppServices
import Shared
import UIKit

struct FloorpSharedWorkspaceTab: Codable, Equatable, Sendable {
    let id: String
    let url: String
    let title: String
    let pinned: Bool
    let position: UInt64
}

struct FloorpSharedWorkspace: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let icon: String?
    let tabs: [FloorpSharedWorkspaceTab]
}

struct FloorpWorkspaceSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let accountUid: String?
    let revision: UInt64
    let globalSyncId: String?
    let collectionSyncId: String?
    let engineVersion: UInt64?
    let status: String
    let lastReceivedMillis: Int64?
    let workspaces: [FloorpSharedWorkspace]

    var lastReceivedAt: Date? {
        lastReceivedMillis.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    var hasConfirmedSnapshot: Bool {
        schemaVersion == 1 && status == "ready" && engineVersion == 1
            && globalSyncId != nil && collectionSyncId != nil && lastReceivedMillis != nil
    }

    func hasSameAssociation(as other: Self) -> Bool {
        accountUid == other.accountUid && globalSyncId == other.globalSyncId
            && collectionSyncId == other.collectionSyncId && engineVersion == other.engineVersion
    }
}

enum FloorpWorkspaceDiscoveryState: Equatable, Sendable {
    case signedOut
    case loading
    case ready
    case offline
    case failed
    case unsupportedVersion
    case notPublished
    case disabled
    case runtimeUnavailable
}

extension Notification.Name {
    static let floorpWorkspaceDiscoveryDidChange = Notification.Name("FloorpWorkspaceDiscoveryDidChange")
}

protocol FloorpWorkspaceStoreProtocol: AnyObject {
    func bindAccount(uid: String) throws
    func invalidate() throws
    func registerWithSyncManager()
    func snapshotJson() throws -> String
    func copyEligibilityJson() throws -> String
}

extension FloorpWorkspacesStore: FloorpWorkspaceStoreProtocol {}

enum FloorpWorkspaceProviderEvent: Sendable {
    case loaded(FloorpWorkspaceSnapshot, UInt64)
    case finished(FloorpWorkspaceSnapshot?, Bool, ServiceStatus, UInt64)
    case invalidated(UInt64)

    var generation: UInt64 {
        switch self {
        case .loaded(_, let generation), .finished(_, _, _, let generation), .invalidated(let generation):
            return generation
        }
    }
}

enum FloorpWorkspaceDiscoveryError: Error {
    case emptyAccountID
}

final class FloorpWorkspaceSyncEngineProvider: FloorpWorkspaceSyncEngineProviding, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let store: any FloorpWorkspaceStoreProtocol
    private let invalidationURL: URL
    private let event: @Sendable (FloorpWorkspaceProviderEvent) -> Void
    private var accountID: String?
    private var generation: UInt64 = 0
    private var suspended = true

    init(
        store: any FloorpWorkspaceStoreProtocol,
        invalidationURL: URL,
        event: @escaping @Sendable (FloorpWorkspaceProviderEvent) -> Void
    ) {
        self.store = store
        self.invalidationURL = invalidationURL
        self.event = event
    }

    func prepare(accountID: String) throws -> UInt64 {
        try lock.withLock {
            guard !accountID.isEmpty else { throw FloorpWorkspaceDiscoveryError.emptyAccountID }
            if suspended || self.accountID != accountID {
                if FileManager.default.fileExists(atPath: invalidationURL.path) {
                    try store.invalidate()
                    try FileManager.default.removeItem(at: invalidationURL)
                }
                try store.bindAccount(uid: accountID)
                store.registerWithSyncManager()
                self.accountID = accountID
                generation &+= 1
                suspended = false
            }
            let snapshot = try readSnapshot()
            event(.loaded(snapshot, generation))
            return generation
        }
    }

    func didFinishSync(successful: Bool, status: ServiceStatus, generation: UInt64) {
        lock.withLock {
            guard !suspended, self.generation == generation else { return }
            event(.finished(try? readSnapshot(), successful, status, generation))
        }
    }

    func snapshotForCopyValidation() -> FloorpWorkspaceSnapshot? {
        lock.withLock {
            guard !suspended else { return nil }
            return try? readSnapshot(forCopy: true)
        }
    }

    func suspend() {
        lock.withLock {
            suspended = true
            generation &+= 1
            try? Data().write(to: invalidationURL, options: .atomic)
            try? store.invalidate()
            event(.invalidated(generation))
        }
    }

    func clear() throws {
        try lock.withLock {
            suspended = true
            generation &+= 1
            event(.invalidated(generation))
            try Data().write(to: invalidationURL, options: .atomic)
            try store.invalidate()
            accountID = nil
        }
    }

    private func readSnapshot(forCopy: Bool = false) throws -> FloorpWorkspaceSnapshot {
        let json = try forCopy ? store.copyEligibilityJson() : store.snapshotJson()
        let snapshot = try JSONDecoder().decode(
            FloorpWorkspaceSnapshot.self,
            from: Data(json.utf8)
        )
        guard snapshot.schemaVersion == 1, snapshot.accountUid == accountID else {
            throw CocoaError(.coderReadCorrupt)
        }
        return snapshot
    }
}

enum FloorpWorkspaceCacheRecovery {
    static func removeUnusableCache(at cacheURL: URL) throws {
        let cacheBase = cacheURL.deletingPathExtension()
        let files = [cacheURL, cacheBase.appendingPathExtension("pending"), cacheBase.appendingPathExtension("invalidated")]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor
final class FloorpWorkspaceDiscoveryCoordinator {
    static let shared = FloorpWorkspaceDiscoveryCoordinator()
    static let enabledPreference = "floorp.workspaces.discovery.enabled"
    private static let epochPreference = "floorp.workspaces.discovery.epoch"

    private(set) var state: FloorpWorkspaceDiscoveryState = .signedOut
    private(set) var snapshot: FloorpWorkspaceSnapshot?
    private(set) var ownershipToken: String?
    private(set) var isEnabled = true
    private weak var profile: (any Profile)?
    private var providerID = UUID()
    private var copyProvider: FloorpWorkspaceSyncEngineProvider?
    private var latestGeneration: UInt64 = 0
    private var featureEpoch: Int32 = 0
    private var accountID: String?
    private var observers: [NSObjectProtocol] = []
    private var refreshInProgress = false
    private var refreshSequence: UInt64 = 0
    private var profileIdentifier = ""
    private var providerInstalled = false
    private var cacheURL: URL?
    private let notificationCenter: NotificationCenter

    var workspaces: [FloorpSharedWorkspace] { snapshot?.workspaces ?? [] }
    var lastReceivedAt: Date? { snapshot?.lastReceivedAt }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func bootstrap(profile: any Profile) {
        guard self.profile !== profile else { return }
        if let previous = self.profile {
            invalidateCopyAuthorization()
            (previous.syncManager as? RustSyncManager)?.setFloorpWorkspaceDiscoveryEnabled(false)
        }
        self.profile = profile
        guard FloorpWorkspaceRuntimeSupport.isAvailable else {
            state = .runtimeUnavailable
            notify()
            return
        }
        featureEpoch = profile.prefs.intForKey(Self.epochPreference) ?? 0
        isEnabled = profile.prefs.boolForKey(Self.enabledPreference) ?? true
        providerInstalled = false
        cacheURL = nil
        do {
            let directory = try profile.files.getAndEnsureDirectory("WorkspaceDiscovery")
            profileIdentifier = directory
            cacheURL = URL(fileURLWithPath: directory).appendingPathComponent("received.json")
            try installProvider(resetCache: false)
            installObservers()
            accountDidChange()
        } catch {
            state = .failed
            notify()
        }
    }

    private func installProvider(resetCache: Bool) throws {
        guard let profile, let cacheURL,
              let syncManager = profile.syncManager as? RustSyncManager else {
            throw CocoaError(.fileNoSuchFile)
        }
        if resetCache { try FloorpWorkspaceCacheRecovery.removeUnusableCache(at: cacheURL) }
        providerID = UUID()
        latestGeneration = 0
        let identifier = providerID
        let store = try FloorpWorkspacesStore(path: cacheURL.path)
        let provider = FloorpWorkspaceSyncEngineProvider(
            store: store,
            invalidationURL: cacheURL.deletingLastPathComponent().appendingPathComponent("invalidated")
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event, providerID: identifier)
            }
        }
        syncManager.installFloorpWorkspaceSyncEngineProvider(provider)
        copyProvider = provider
        syncManager.setFloorpWorkspaceDiscoveryEnabled(isEnabled)
        providerInstalled = true
    }

    func setEnabled(_ enabled: Bool) {
        guard FloorpWorkspaceRuntimeSupport.isAvailable else { return }
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        featureEpoch &+= 1
        profile?.prefs.setBool(enabled, forKey: Self.enabledPreference)
        profile?.prefs.setInt(featureEpoch, forKey: Self.epochPreference)
        invalidateCopyAuthorization()
        (profile?.syncManager as? RustSyncManager)?.setFloorpWorkspaceDiscoveryEnabled(enabled)
        state = enabled ? .loading : .disabled
        notify()
        if enabled { refresh() }
    }

    func refresh() {
        guard FloorpWorkspaceRuntimeSupport.isAvailable else { state = .runtimeUnavailable; notify(); return }
        guard isEnabled else { state = .disabled; notify(); return }
        guard let profile, let syncManager = profile.syncManager as? RustSyncManager else { return }
        if !providerInstalled {
            do {
                if cacheURL == nil {
                    let directory = try profile.files.getAndEnsureDirectory("WorkspaceDiscovery")
                    profileIdentifier = directory
                    cacheURL = URL(fileURLWithPath: directory).appendingPathComponent("received.json")
                }
                try installProvider(resetCache: true)
                installObservers()
            } catch {
                state = .failed
                notify()
                return
            }
        }
        let currentAccount = currentAccountID()
        if currentAccount != accountID {
            accountID = currentAccount
            invalidateCopyAuthorization()
        }
        guard let accountID, profile.hasSyncableAccount() else {
            state = .signedOut
            notify()
            return
        }
        guard !refreshInProgress else { return }
        refreshInProgress = true
        refreshSequence &+= 1
        let sequence = refreshSequence
        state = .loading
        notify()
        syncManager.loadFloorpWorkspaceCache(accountID: accountID)
        syncManager.syncNamedCollections(why: .user, names: ["floorp-workspaces"]).uponQueue(.main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.refreshSequence == sequence else { return }
                self.refreshInProgress = false
                let syncResult = result.successValue
                if result.isFailure || (self.state == .loading
                    && syncResult?.successful.contains("floorp-workspaces") != true) {
                    let offline = syncResult?.status == .networkError
                        || (result.failureValue as? NSError)?.domain == NSURLErrorDomain
                    self.state = offline && self.snapshot?.hasConfirmedSnapshot == true ? .offline : .failed
                    self.notify()
                }
            }
        }
    }

    func copyAuthorization(for snapshot: FloorpWorkspaceSnapshot) -> String? {
        guard snapshot.hasConfirmedSnapshot, let current = self.snapshot,
              snapshot.hasSameAssociation(as: current), let ownershipToken,
              isCopyAllowed(ownershipToken: ownershipToken) else { return nil }
        return ownershipToken
    }

    func isCopyAllowed(ownershipToken: String) -> Bool {
        guard isEnabled, self.ownershipToken == ownershipToken, let current = snapshot,
              current.hasConfirmedSnapshot, accountID != nil, currentAccountID() == accountID,
              [.ready, .offline, .failed, .loading].contains(state) else { return false }
        guard let live = copyProvider?.snapshotForCopyValidation() else {
            invalidateCopyAuthorization()
            state = .failed
            notify()
            return false
        }
        guard live.hasConfirmedSnapshot, live.hasSameAssociation(as: current) else {
            accept(live)
            if live.hasConfirmedSnapshot { state = .ready }
            notify()
            return false
        }
        return true
    }

    private func currentAccountID() -> String? {
        RustFirefoxAccounts.shared.accountManager?.accountProfile()?.uid
            ?? RustFirefoxAccounts.shared.userProfile?.uid
    }

    private func installObservers() {
        observers.forEach(notificationCenter.removeObserver)
        observers = [.FirefoxAccountChanged, UIApplication.willEnterForegroundNotification].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.accountDidChange() }
            }
        }
    }

    private func accountDidChange() {
        let current = currentAccountID()
        if accountID != current {
            if accountID != nil || snapshot != nil { invalidateCopyAuthorization() }
            accountID = current
        }
        guard isEnabled else { state = .disabled; notify(); return }
        guard let current, profile?.hasSyncableAccount() == true else {
            try? FloorpWorkspaceCopyService.shared.cancelPendingOperations()
            state = .signedOut
            (profile?.syncManager as? RustSyncManager)?.setFloorpWorkspaceDiscoveryEnabled(false)
            notify()
            return
        }
        (profile?.syncManager as? RustSyncManager)?.setFloorpWorkspaceDiscoveryEnabled(true)
        (profile?.syncManager as? RustSyncManager)?.loadFloorpWorkspaceCache(accountID: current)
        refresh()
    }

    private func receive(_ event: FloorpWorkspaceProviderEvent, providerID: UUID) {
        guard self.providerID == providerID, event.generation >= latestGeneration else { return }
        latestGeneration = event.generation
        let eventSnapshot: FloorpWorkspaceSnapshot?
        switch event {
        case .loaded(let value, _), .finished(let value?, _, _, _): eventSnapshot = value
        default: eventSnapshot = nil
        }
        if let revision = snapshot?.revision, let incoming = eventSnapshot, incoming.revision < revision { return }
        switch event {
        case .invalidated:
            invalidateCopyAuthorization()
            state = isEnabled && accountID != nil ? .failed : (isEnabled ? .signedOut : .disabled)
        case .loaded(let snapshot, _):
            guard isEnabled, snapshot.accountUid == accountID, accountID == currentAccountID() else { return }
            accept(snapshot)
            if snapshot.hasConfirmedSnapshot { state = refreshInProgress ? .loading : .ready }
        case .finished(let snapshot, let successful, let status, _):
            guard isEnabled, accountID != nil, accountID == currentAccountID() else { return }
            if let snapshot, snapshot.accountUid == accountID { accept(snapshot) }
            if self.snapshot?.status == "unsupportedVersion" || self.snapshot?.status == "unpublished" { break }
            if successful, self.snapshot?.hasConfirmedSnapshot == true {
                state = .ready
            } else {
                state = status == .networkError && self.snapshot?.hasConfirmedSnapshot == true ? .offline : .failed
            }
        }
        notify()
    }

    private func accept(_ snapshot: FloorpWorkspaceSnapshot) {
        let newToken: String? = snapshot.hasConfirmedSnapshot ? makeOwnershipToken(snapshot) : nil
        if ownershipToken != nil && newToken != ownershipToken { invalidateCopyAuthorization() }
        self.snapshot = snapshot
        ownershipToken = newToken
        try? FloorpWorkspaceCopyService.shared.invalidatePendingOperations(exceptGeneration: newToken)
        switch snapshot.status {
        case "unsupportedVersion": state = .unsupportedVersion
        case "unpublished": state = .notPublished
        case "ready": break
        default: state = .loading
        }
    }

    private func makeOwnershipToken(_ snapshot: FloorpWorkspaceSnapshot) -> String {
        let fields = [profileIdentifier, snapshot.accountUid ?? "", String(featureEpoch),
                      snapshot.globalSyncId ?? "", snapshot.collectionSyncId ?? "", String(snapshot.engineVersion ?? 0)]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func invalidateCopyAuthorization() {
        try? FloorpWorkspaceCopyService.shared.cancelPendingOperations()
        snapshot = nil
        ownershipToken = nil
        refreshInProgress = false
        refreshSequence &+= 1
    }

    private func notify() {
        notificationCenter.post(name: .floorpWorkspaceDiscoveryDidChange, object: self)
    }
}
