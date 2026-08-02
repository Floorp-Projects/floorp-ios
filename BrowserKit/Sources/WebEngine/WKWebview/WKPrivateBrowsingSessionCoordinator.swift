// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit

/// Coordinates the process-wide non-persistent website data store used by
/// private tabs and other private browser surfaces.
///
/// Every surface that can keep private browsing state alive owns a lease.
/// The store is replaced only after the final lease from the current session
/// is released, so one window or surface cannot clear another one's session.
@MainActor
public final class WKPrivateBrowsingSessionCoordinator {
    public static let shared = WKPrivateBrowsingSessionCoordinator()

    public var websiteDataStore: WKWebsiteDataStore {
        dataStore
    }

    private let dataStoreFactory: @MainActor () -> WKWebsiteDataStore
    private var dataStore: WKWebsiteDataStore
    private var generation: UInt64 = 0
    private var leases = [UUID: UInt64]()

    public init(
        dataStoreFactory: @escaping @MainActor () -> WKWebsiteDataStore = {
            WKWebsiteDataStore.nonPersistent()
        }
    ) {
        self.dataStoreFactory = dataStoreFactory
        self.dataStore = dataStoreFactory()
    }

    public func acquireLease() -> WKPrivateBrowsingSessionLease {
        let identifier = UUID()
        leases[identifier] = generation
        return WKPrivateBrowsingSessionLease(
            coordinator: self,
            identifier: identifier,
            generation: generation
        )
    }

    /// Preserves compatibility for clients that do not own a lease. A caller
    /// cannot end a session while another private surface still owns it.
    public func endSessionIfUnowned() {
        guard leases.isEmpty else { return }
        rotateDataStore()
    }

    var activeLeaseCount: Int {
        leases.count
    }

    fileprivate func releaseLease(identifier: UUID, generation: UInt64) {
        guard leases[identifier] == generation else { return }
        leases.removeValue(forKey: identifier)
        guard leases.isEmpty else { return }
        rotateDataStore()
    }

    private func rotateDataStore() {
        generation &+= 1
        dataStore = dataStoreFactory()
    }
}

/// An idempotent ownership token for one private browsing surface.
@MainActor
public final class WKPrivateBrowsingSessionLease {
    private let releaseState: PrivateBrowsingLeaseReleaseState

    fileprivate init(
        coordinator: WKPrivateBrowsingSessionCoordinator,
        identifier: UUID,
        generation: UInt64
    ) {
        self.releaseState = PrivateBrowsingLeaseReleaseState {
            coordinator.releaseLease(identifier: identifier, generation: generation)
        }
    }

    public func invalidate() {
        releaseState.takeRelease()?()
    }

    deinit {
        guard let release = releaseState.takeRelease() else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                release()
            }
        } else {
            Task { @MainActor in
                release()
            }
        }
    }
}

private final class PrivateBrowsingLeaseReleaseState: @unchecked Sendable {
    typealias Release = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var release: Release?

    init(release: @escaping Release) {
        self.release = release
    }

    func takeRelease() -> Release? {
        lock.lock()
        defer { lock.unlock() }
        let release = release
        self.release = nil
        return release
    }
}
