// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
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

    func testLegacyEndCannotRotateStoreOwnedByAnotherSurface() {
        let subject = WKPrivateBrowsingSessionCoordinator()
        let panelLease = subject.acquireLease()
        let sharedStore = subject.websiteDataStore

        subject.endSessionIfUnowned()

        XCTAssertTrue(sharedStore === subject.websiteDataStore)
        panelLease.invalidate()
    }
}
