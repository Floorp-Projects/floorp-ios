// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import WebKit
@testable import WebEngine

@MainActor
final class WKPrivateBrowsingSessionCoordinatorTests: XCTestCase {
    func testPanelOnlySessionRotatesStoreWhenClosed() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let originalStore = subject.websiteDataStore
        let panelLease = subject.acquireLease()

        panelLease.invalidate()

        XCTAssertFalse(originalStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 0)
    }

    func testLastTabDoesNotRotateStoreWhilePanelIsAlive() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let tabLease = subject.acquireLease()
        let panelLease = subject.acquireLease()
        let sharedStore = subject.websiteDataStore

        tabLease.invalidate()

        XCTAssertTrue(sharedStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 1)

        panelLease.invalidate()
        XCTAssertFalse(sharedStore === subject.websiteDataStore)
    }

    func testLaterPanelJoinsTheExistingPrivateSession() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let tabLease = subject.acquireLease()
        let sharedStore = subject.websiteDataStore
        let laterPanelLease = subject.acquireLease()

        XCTAssertTrue(sharedStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 2)

        laterPanelLease.invalidate()
        tabLease.invalidate()
    }

    func testDelayedDuplicateReleaseCannotRotateANewerSession() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let oldLease = subject.acquireLease()
        oldLease.invalidate()
        let newLease = subject.acquireLease()
        let newerStore = subject.websiteDataStore

        oldLease.invalidate()

        XCTAssertTrue(newerStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 1)
        newLease.invalidate()
    }

    func testLeaseDeinitReleasesTheOwnerExactlyOnce() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let originalStore = subject.websiteDataStore
        var lease: WKPrivateBrowsingSessionLease? = subject.acquireLease()
        XCTAssertNotNil(lease)

        lease = nil

        XCTAssertFalse(originalStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 0)
    }

    func testExplicitInvalidationThenDeinitDoesNotRotateAgain() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        var lease: WKPrivateBrowsingSessionLease? = subject.acquireLease()

        lease?.invalidate()
        let replacementStore = subject.websiteDataStore
        lease = nil

        XCTAssertTrue(replacementStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 0)
    }

    func testLeaseDeinitOffMainActorEventuallyReleasesOwner() async {
        let storeRotated = expectation(description: "Private data store rotated")
        var dataStoreCreationCount = 0
        let subject = WKPrivateBrowsingSessionCoordinator {
            dataStoreCreationCount += 1
            if dataStoreCreationCount == 2 {
                storeRotated.fulfill()
            }
            return WKWebsiteDataStore.nonPersistent()
        }
        let originalStore = subject.websiteDataStore

        await Task.detached {
            let lease = await MainActor.run {
                subject.acquireLease()
            }
            withExtendedLifetime(lease) {}
        }.value

        await fulfillment(of: [storeRotated], timeout: 1)
        XCTAssertFalse(originalStore === subject.websiteDataStore)
        XCTAssertEqual(subject.activeLeaseCount, 0)
    }

    func testLegacyEndCannotRotateStoreOwnedByAnotherSurface() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let panelLease = subject.acquireLease()
        let sharedStore = subject.websiteDataStore

        subject.endSessionIfUnowned()

        XCTAssertTrue(sharedStore === subject.websiteDataStore)
        panelLease.invalidate()
    }
}
