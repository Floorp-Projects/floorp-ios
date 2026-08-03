// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import WebKit
import Common

@testable import Client

@MainActor
class AccountSyncHandlerTests: XCTestCase {
    private var profile = MockProfile()
    private var queue = MockDispatchQueue()
    private var mockWindowManager = MockWindowManager(wrappedManager: WindowManagerImplementation())
    let windowUUID: WindowUUID = .XCTestDefaultUUID

    override func setUp() async throws {
        try await super.setUp()
        profile = MockProfile()
        queue = MockDispatchQueue()
        let mockTabManager = MockTabManager()
        mockWindowManager = MockWindowManager(
            wrappedManager: WindowManagerImplementation(),
            tabManager: mockTabManager
        )
        DependencyHelperMock().bootstrapDependencies(
            injectedProfile: profile,
            injectedWindowManager: mockWindowManager,
            injectedTabManager: mockTabManager
        )
        mockTabManager.recentlyAccessedNormalTabs = [createTab(profile: profile)]
    }

    override func tearDown() async throws {
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    func testTabDidGainFocus_doesntSyncWithoutAccount() {
        let expectation = XCTestExpectation(description: "sync is not called without an account")
        expectation.isInverted = true
        profile.hasSyncableAccountMock = false
        let subject = AccountSyncHandler(
            with: profile,
            windowManager: mockWindowManager,
            queue: queue,
            onSyncCompleted: {
                expectation.fulfill()
            }
        )
        let tab = createTab(profile: profile)
        subject.tabDidGainFocus(tab)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(profile.storeAndSyncTabsCalled, 0)
    }

    func testTabDidGainFocus_syncWithAccount() {
        let expectation = XCTestExpectation(description: "storeAndSyncTabs called after listed time of tab gaining focus")
        let subject = AccountSyncHandler(
            with: profile,
            windowManager: mockWindowManager,
            debounceTime: 0.1,
            queue: queue,
            queueDelay: 0.1,
            onSyncCompleted: {
                expectation.fulfill()
            }
        )
        let tab = createTab(profile: profile)
        subject.tabDidGainFocus(tab)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(profile.storeAndSyncTabsCalled, 1)
    }

    func testTabDidGainFocus_multipleActions_executedAtMostOnce() {
        let expectation = XCTestExpectation(
            description: "storeAndSyncTabs only called once from multiple tab actions")
        let subject = AccountSyncHandler(
            with: profile,
            windowManager: mockWindowManager,
            debounceTime: 0.1,
            queue: DispatchQueue.global(),
            queueDelay: 0.1,
            onSyncCompleted: {
                expectation.fulfill()
            }
        )
        let tab = createTab(profile: profile)

        subject.tabDidGainFocus(tab)
        subject.tabDidGainFocus(tab)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(profile.storeAndSyncTabsCalled, 1)
    }

    func testTabDidGainFocus_multipleDebounce_withWithMultipleSyncs() {
        let expectation = XCTestExpectation(
            description: "storeAndSyncTabs called multiple times if outside of debounce time")
        expectation.expectedFulfillmentCount = 2
        let subject = AccountSyncHandler(
            with: profile,
            windowManager: mockWindowManager,
            debounceTime: 0.1,
            queue: DispatchQueue.global(),
            queueDelay: 0.1,
            onSyncCompleted: {
                expectation.fulfill()
            }
        )
        let tab = createTab(profile: profile)
        subject.tabDidGainFocus(tab)
        subject.tabDidLoseFocus(tab)
        wait(1.0)
        subject.tabDidGainFocus(tab)
        subject.tabDidLoseFocus(tab)
        subject.tabDidGainFocus(tab)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(profile.storeAndSyncTabsCalled, 2)
    }

    func testPendingSyncKeepsInjectedWindowManagerAfterContainerReset() {
        let expectation = XCTestExpectation(description: "sync completes with the injected window manager")
        let subject = AccountSyncHandler(
            with: profile,
            windowManager: mockWindowManager,
            debounceTime: 0.1,
            queueDelay: 0,
            onSyncCompleted: {
                expectation.fulfill()
            }
        )
        let replacementTabManager = MockTabManager()
        let replacementWindowManager = MockWindowManager(
            wrappedManager: WindowManagerImplementation(),
            tabManager: replacementTabManager
        )

        subject.tabDidGainFocus(createTab(profile: profile))
        DependencyHelperMock().bootstrapDependencies(
            injectedProfile: profile,
            injectedWindowManager: replacementWindowManager,
            injectedTabManager: replacementTabManager
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(mockWindowManager.allWindowTabManagersCallCount, 1)
        XCTAssertEqual(replacementWindowManager.allWindowTabManagersCallCount, 0)
    }

    func testDebouncerCancelsPendingActionWhenReleased() {
        let expectation = XCTestExpectation(description: "released debouncer does not run its pending action")
        expectation.isInverted = true
        var subject: Debouncer? = Debouncer(delay: 0.1)

        subject?.call {
            expectation.fulfill()
        }
        subject = nil

        wait(for: [expectation], timeout: 0.25)
    }

    func testDependencyResetReleasesGlobalHandlerBeforePendingSync() {
        GlobalTabEventHandlers.configure(with: profile, windowManager: mockWindowManager)
        NotificationCenter.default.post(name: .accountAuthenticated, object: nil)

        DependencyHelperMock().reset()
        wait(1.0)

        XCTAssertEqual(profile.storeAndSyncTabsCalled, 0)
    }
}

// MARK: - Helper methods
private extension AccountSyncHandlerTests {
    func createTab(profile: MockProfile,
                   urlString: String? = "www.website.com") -> Tab {
        let tab = Tab(profile: profile, windowUUID: windowUUID)

        if let urlString = urlString {
            tab.url = URL(string: urlString)!
        }
        return tab
    }
}
