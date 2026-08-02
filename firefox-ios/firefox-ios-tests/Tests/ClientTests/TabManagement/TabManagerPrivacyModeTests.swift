// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
import Shared
import WebEngine
@testable import Client

final class TabManagerPrivacyModeTests: TabManagerTestsBase {
    @MainActor
    func testMultipleWindowOwnersRotateOnlyAfterBothLoseTheirLastPrivateTab() {
        let coordinator = WKPrivateBrowsingSessionCoordinator()
        let initialStore = coordinator.websiteDataStore
        let firstWindow = createSubject(
            tabs: generateTabs(ofType: .privateAny, count: 1),
            windowUUID: UUID(),
            privateBrowsingSessionCoordinator: coordinator
        )
        let secondWindow = createSubject(
            tabs: generateTabs(ofType: .privateAny, count: 1),
            windowUUID: UUID(),
            privateBrowsingSessionCoordinator: coordinator
        )

        firstWindow.removeAllTabs(isPrivateMode: true)
        XCTAssertTrue(initialStore === coordinator.websiteDataStore)

        secondWindow.removeAllTabs(isPrivateMode: true)
        XCTAssertFalse(initialStore === coordinator.websiteDataStore)
    }

    @MainActor
    func testRestoredPrivateZombieTabsOwnTheSessionBeforeCreatingAWebView() {
        let coordinator = WKPrivateBrowsingSessionCoordinator()
        let restoredPrivateTabs = generateTabs(ofType: .privateAny, count: 2)
        XCTAssertTrue(restoredPrivateTabs.allSatisfy { $0.webView == nil })
        let subject = createSubject(
            tabs: restoredPrivateTabs,
            privateBrowsingSessionCoordinator: coordinator
        )
        let restoredSessionStore = coordinator.websiteDataStore

        coordinator.endSessionIfUnowned()

        XCTAssertTrue(restoredSessionStore === coordinator.websiteDataStore)
        subject.removeAllTabs(isPrivateMode: true)
        XCTAssertFalse(restoredSessionStore === coordinator.websiteDataStore)
    }

    @MainActor
    func testLastPrivateTabDoesNotResetStoreWhilePanelLeaseIsAlive() {
        let coordinator = WKPrivateBrowsingSessionCoordinator()
        let initialStore = coordinator.websiteDataStore
        let privateTabs = generateTabs(ofType: .privateAny, count: 2)
        let subject = createSubject(
            tabs: privateTabs,
            privateBrowsingSessionCoordinator: coordinator
        )
        let panelLease = coordinator.acquireLease()

        subject.removeAllTabs(isPrivateMode: true)

        XCTAssertTrue(initialStore === coordinator.websiteDataStore)
        panelLease.invalidate()
        XCTAssertFalse(initialStore === coordinator.websiteDataStore)
    }

    @MainActor
    func testPrivateTabAndLaterPanelUseTheSameStore() {
        let coordinator = WKPrivateBrowsingSessionCoordinator()
        let privateTab = generateTabs(ofType: .privateAny, count: 1)
        let subject = createSubject(
            tabs: privateTab,
            privateBrowsingSessionCoordinator: coordinator
        )
        let tabStore = coordinator.websiteDataStore

        let panelLease = coordinator.acquireLease()

        XCTAssertTrue(tabStore === coordinator.websiteDataStore)
        panelLease.invalidate()
        subject.removeAllTabs(isPrivateMode: true)
    }

    // MARK: - removeAllPrivateTabs (triggered via selectTab)

    @MainActor
    func testRemoveAllPrivateTabs_whenSelectingNormalTab_withClosePrivateTabsEnabled() {
        mockProfile.prefs.setBool(true, forKey: PrefsKeys.Settings.closePrivateTabs)
        let normalTabs = generateTabs(ofType: .normal, count: 3)
        let privateTabs = generateTabs(ofType: .privateAny, count: 3)
        let subject = createSubject(tabs: normalTabs + privateTabs)

        guard let privateTab = subject.privateTabs.first,
              let normalTab = subject.normalTabs.first else {
            XCTFail("Test did not meet preconditions")
            return
        }

        subject.selectTab(privateTab)

        XCTAssertEqual(subject.normalTabs.count, 3)
        XCTAssertEqual(subject.privateTabs.count, 3)
        XCTAssertTrue(subject.selectedTab?.isPrivate ?? false)

        // Select a normal tab — this should trigger removeAllPrivateTabs
        subject.selectTab(normalTab)

        XCTAssertEqual(subject.privateTabs.count, 0, "All private tabs should be removed")
        XCTAssertEqual(subject.normalTabs.count, 3, "Normal tabs should be untouched")
        XCTAssertEqual(subject.tabs.count, 3)
        XCTAssertFalse(subject.selectedTab?.isPrivate ?? true)
    }

    @MainActor
    func testRemoveAllPrivateTabs_whenSelectingNormalTab_withClosePrivateTabsDisabled() {
        mockProfile.prefs.setBool(false, forKey: PrefsKeys.Settings.closePrivateTabs)
        let normalTabs = generateTabs(ofType: .normal, count: 3)
        let privateTabs = generateTabs(ofType: .privateAny, count: 3)
        let subject = createSubject(tabs: normalTabs + privateTabs)

        guard let privateTab = subject.privateTabs.first,
              let normalTab = subject.normalTabs.first else {
            XCTFail("Test did not meet preconditions")
            return
        }

        subject.selectTab(privateTab)
        subject.selectTab(normalTab)

        XCTAssertEqual(subject.privateTabs.count, 3, "Private tabs should be preserved when setting is disabled")
        XCTAssertEqual(subject.normalTabs.count, 3)
    }

    @MainActor
    func testRemoveAllPrivateTabs_resetsSelectedIndex_whenSelectedTabIsPrivate() {
        mockProfile.prefs.setBool(true, forKey: PrefsKeys.Settings.closePrivateTabs)
        let normalTabs = generateTabs(ofType: .normal, count: 2)
        let privateTabs = generateTabs(ofType: .privateAny, count: 2)
        let subject = createSubject(tabs: normalTabs + privateTabs)

        guard let privateTab = subject.privateTabs.first,
              let normalTab = subject.normalTabs.first else {
            XCTFail("Test did not meet preconditions")
            return
        }

        subject.selectTab(privateTab)
        XCTAssertTrue(subject.selectedTab?.isPrivate ?? false)

        subject.selectTab(normalTab)

        XCTAssertEqual(subject.privateTabs.count, 0)
        XCTAssertEqual(subject.selectedTab, normalTab)
        XCTAssertGreaterThanOrEqual(subject.selectedIndex, 0, "Selected index should point to the new normal tab")
    }

    @MainActor
    func testRemoveAllPrivateTabs_notifiesDelegateForEachRemovedTab() {
        mockProfile.prefs.setBool(true, forKey: PrefsKeys.Settings.closePrivateTabs)
        let normalTabs = generateTabs(ofType: .normal, count: 2)
        let privateTabs = generateTabs(ofType: .privateAny, count: 3)
        let subject = createSubject(tabs: normalTabs + privateTabs)

        let delegate = MockTabManagerDelegatePrivacyTests()
        subject.addDelegate(delegate)

        guard let privateTab = subject.privateTabs.first,
              let normalTab = subject.normalTabs.first else {
            XCTFail("Test did not meet preconditions")
            return
        }

        subject.selectTab(privateTab)
        delegate.reset()

        subject.selectTab(normalTab)

        XCTAssertEqual(delegate.didRemoveTabCallCount, 3, "Delegate should be notified once per removed private tab")
        XCTAssertTrue(delegate.removedTabs.allSatisfy { $0.isPrivate }, "All removed tabs should be private")
    }

    @MainActor
    func testRemoveAllPrivateTabs_doesNotRemoveTabs_whenNoPrivateTabsExist() {
        mockProfile.prefs.setBool(true, forKey: PrefsKeys.Settings.closePrivateTabs)
        let normalTabs = generateTabs(ofType: .normal, count: 3)
        let subject = createSubject(tabs: normalTabs)

        guard let firstNormal = subject.normalTabs.first,
              let secondNormal = subject.normalTabs[safe: 1] else {
            XCTFail("Test did not meet preconditions")
            return
        }

        subject.selectTab(firstNormal)
        subject.selectTab(secondNormal)

        XCTAssertEqual(subject.normalTabs.count, 3, "Normal tabs should be untouched when no private tabs exist")
        XCTAssertEqual(subject.privateTabs.count, 0)
    }
}

// MARK: - MockTabManagerDelegatePrivacyTests

private class MockTabManagerDelegatePrivacyTests: TabManagerDelegate {
    var didRemoveTabCallCount = 0
    var removedTabs = [Tab]()

    func reset() {
        didRemoveTabCallCount = 0
        removedTabs = []
    }

    func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab, isRestoring: Bool) {
        didRemoveTabCallCount += 1
        removedTabs.append(tab)
    }
}
