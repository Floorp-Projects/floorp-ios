// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import XCTest

@testable import Client

@MainActor
final class MicrosurveyCoordinatorTests: XCTestCase {
    private var mockRouter = MockRouter(navigationController: MockNavigationController())
    private var mockTabManager = MockTabManager()

    override func setUp() async throws {
        try await super.setUp()
        DependencyHelperMock().bootstrapDependencies()
        mockRouter = MockRouter(navigationController: MockNavigationController())
        mockTabManager = MockTabManager()
    }

    override func tearDown() async throws {
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    func testInitialState() {
        _ = createSubject()

        XCTAssertFalse(mockRouter.rootViewController is MicrosurveyViewController)
        XCTAssertEqual(mockRouter.setRootViewControllerCalled, 0)
    }

    func testStart_presentsMicrosurveyController() throws {
        let subject = createSubject()

        subject.start()

        XCTAssertTrue(mockRouter.rootViewController is MicrosurveyViewController)
        XCTAssertEqual(mockRouter.setRootViewControllerCalled, 1)
    }

    func testMicrosurveyDelegate_dismissFlow_callsRouterDismiss() throws {
        let subject = createSubject()

        subject.start()
        subject.dismissFlow()

        XCTAssertEqual(mockRouter.dismissCalled, 1)
    }

    @MainActor
    func testMicrosurveyDelegate_showPrivacy_callsRouterDismiss_andCreatesNewTab() throws {
        let subject = createSubject()
        let expectedURL = try XCTUnwrap(
            SupportUtils.URLForPrivacyNotice(source: "modal", campaign: "microsurvey", content: nil)
        )

        subject.start()
        subject.showPrivacy(with: nil)

        XCTAssertEqual(mockRouter.dismissCalled, 1)
        XCTAssertEqual(mockTabManager.addTabsForURLsCalled, 1)
        XCTAssertEqual(mockTabManager.addTabsURLs, [expectedURL])
    }

    @MainActor
    func testMicrosurveyDelegate_showPrivacyWithContentParams_callsRouterDismiss_andCreatesNewTab() throws {
        let subject = createSubject()
        let expectedURL = try XCTUnwrap(
            SupportUtils.URLForPrivacyNotice(source: "modal", campaign: "microsurvey", content: "homepage")
        )

        subject.start()
        subject.showPrivacy(with: "homepage")

        XCTAssertEqual(mockRouter.dismissCalled, 1)
        XCTAssertEqual(mockTabManager.addTabsForURLsCalled, 1)
        XCTAssertEqual(mockTabManager.addTabsURLs, [expectedURL])
    }

    private func createSubject(file: StaticString = #filePath,
                               line: UInt = #line) -> MicrosurveyCoordinator {
        let subject = MicrosurveyCoordinator(
            model: MicrosurveyMock.model,
            router: mockRouter,
            tabManager: mockTabManager
        )

        trackForMemoryLeaks(subject, file: file, line: line)
        return subject
    }
}
