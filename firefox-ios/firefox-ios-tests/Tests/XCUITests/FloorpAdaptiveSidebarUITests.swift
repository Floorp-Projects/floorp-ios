// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest

private enum FloorpAdaptiveSidebarIdentifier {
    static let toolbarButton = "floorpDrawerToolbarButton"
    static let drawerContainer = "Floorp.Drawer.Container"
    static let drawerClose = "Floorp.Drawer.Close"
    static let notesPanel = "floorp//notes"
    static let notesSearch = "Floorp.Notes.Search"
    static let resizeHandle = "Floorp.Drawer.ResizeHandle"
    static let addressBar = "AddressToolbar.address"

    static let browserFrames = [
        "content": "Browser.contentContainer",
        "header": "Browser.headerContainer",
        "address bar": addressBar,
    ]
}

@MainActor
class FloorpAdaptiveSidebarUITestCase: BaseTestCase {
    private let frameTolerance: CGFloat = 2

    func element(withIdentifier identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func waitForElement(
        withIdentifier identifier: String,
        timeout: TimeInterval = TIMEOUT
    ) -> XCUIElement {
        let element = element(withIdentifier: identifier)
        let exists = element.waitForExistence(timeout: timeout)
        if !exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "missing-\(identifier)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "missing-\(identifier)-screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(exists, "Timed out waiting for \(identifier)")
        return element
    }

    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = TIMEOUT) {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(element) to become hittable"
        )
    }

    func waitForUnhittable(_ element: XCUIElement, timeout: TimeInterval = TIMEOUT) {
        let predicate = NSPredicate(format: "exists == false OR hittable == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(element) to become unavailable"
        )
    }

    func openNotesDrawer() -> XCUIElement {
        let toolbarButton = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.toolbarButton
        )
        waitForHittable(toolbarButton)
        toolbarButton.tap()
        _ = waitForElement(withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer)
        let notesButton = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.notesPanel
        )
        waitForHittable(notesButton)
        notesButton.tap()
        return waitForElement(withIdentifier: FloorpAdaptiveSidebarIdentifier.notesSearch)
    }

    func closeDrawer() {
        let closeButton = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerClose
        )
        waitForHittable(closeButton)
        closeButton.tap()
        waitForUnhittable(
            element(withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer)
        )
    }

    func assertNotesSearch(contains expectedValue: String) {
        let searchField = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.notesSearch
        )
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else { return false }
            return value.contains(expectedValue)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: searchField)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: TIMEOUT),
            .completed,
            "Notes search did not preserve \(expectedValue)"
        )
    }

    func assertOverlayMode() {
        waitForUnhittable(
            element(withIdentifier: FloorpAdaptiveSidebarIdentifier.resizeHandle)
        )
    }

    func assertPinnedBrowserFrames(rightToLeft: Bool) {
        let drawer = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: TIMEOUT))

        if rightToLeft {
            XCTAssertEqual(drawer.frame.minX, window.frame.minX, accuracy: frameTolerance)
        } else {
            XCTAssertEqual(drawer.frame.maxX, window.frame.maxX, accuracy: frameTolerance)
        }

        for (name, identifier) in FloorpAdaptiveSidebarIdentifier.browserFrames {
            let browserElement = waitForElement(withIdentifier: identifier)
            let browserFrame = browserElement.frame
            XCTAssertGreaterThan(browserFrame.width, 1, "\(name) has no measurable width")
            XCTAssertGreaterThan(browserFrame.height, 1, "\(name) has no measurable height")

            let intersection = browserFrame.intersection(drawer.frame)
            XCTAssertTrue(
                intersection.isNull || intersection.width <= frameTolerance || intersection.height <= frameTolerance,
                "\(name) intersects the pinned drawer: \(intersection)"
            )

            if rightToLeft {
                XCTAssertGreaterThanOrEqual(
                    browserFrame.minX,
                    drawer.frame.maxX - frameTolerance,
                    "\(name) was not reserved to the right of the RTL drawer"
                )
            } else {
                XCTAssertLessThanOrEqual(
                    browserFrame.maxX,
                    drawer.frame.minX + frameTolerance,
                    "\(name) was not reserved to the left of the LTR drawer"
                )
            }
        }
    }

    func resizePinnedDrawer(horizontalOffset: CGFloat) {
        let drawer = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer
        )
        let handle = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.resizeHandle
        )
        waitForHittable(handle)
        let initialWidth = drawer.frame.width
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: horizontalOffset, dy: 0))
        start.press(forDuration: 0.2, thenDragTo: end)

        XCTAssertTrue(
            waitUntil(timeout: TIMEOUT) {
                drawer.exists && drawer.frame.width > initialWidth + 20
            },
            "Pinned drawer width did not increase from \(initialWidth)"
        )
    }

    func attachEvidence(named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let drawer = element(withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer)
        let addressBar = element(withIdentifier: FloorpAdaptiveSidebarIdentifier.addressBar)
        let frames = XCTAttachment(
            string: "window=\(app.windows.firstMatch.frame)\ndrawer=\(drawer.frame)\naddress=\(addressBar.frame)"
        )
        frames.name = "\(name)-frames"
        frames.lifetime = .keepAlways
        add(frames)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

@MainActor
final class FloorpAdaptiveSidebarIPadUITests: FloorpAdaptiveSidebarUITestCase {
    private var initialOrientation: UIDeviceOrientation {
        name.contains("RTL") ? .landscapeLeft : .portrait
    }

    override func setUp() async throws {
        specificForPlatform = .pad
        guard iPad() else { throw XCTSkip("iPad-only adaptive sidebar coverage") }

        if name.contains("RTL") {
            launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        }
        XCUIDevice.shared.orientation = initialOrientation
        try await super.setUp()
        waitForRotation(to: initialOrientation)
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    func testPortraitOverlayMigratesToLandscapePinnedAndPreservesNotesState() {
        let token = "adaptive-state"
        let searchField = openNotesDrawer()
        assertOverlayMode()
        searchField.tap()
        searchField.typeText("\(token)\n")
        assertNotesSearch(contains: token)
        attachEvidence(named: "ipad-portrait-overlay")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForRotation(to: .landscapeLeft)
        waitForHittable(
            element(withIdentifier: FloorpAdaptiveSidebarIdentifier.resizeHandle)
        )
        assertNotesSearch(contains: token)
        assertPinnedBrowserFrames(rightToLeft: false)
        resizePinnedDrawer(horizontalOffset: -72)
        assertPinnedBrowserFrames(rightToLeft: false)
        attachEvidence(named: "ipad-landscape-pinned-resized")

        XCUIDevice.shared.orientation = .portrait
        waitForRotation(to: .portrait)
        assertOverlayMode()
        assertNotesSearch(contains: token)
        attachEvidence(named: "ipad-portrait-overlay-restored")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForRotation(to: .landscapeLeft)
        waitForHittable(
            element(withIdentifier: FloorpAdaptiveSidebarIdentifier.resizeHandle)
        )
        assertNotesSearch(contains: token)
        assertPinnedBrowserFrames(rightToLeft: false)
        closeDrawer()
    }

    func testRTLPinnedResizeKeepsBrowserChromeSeparate() {
        _ = openNotesDrawer()
        waitForHittable(
            element(withIdentifier: FloorpAdaptiveSidebarIdentifier.resizeHandle)
        )
        assertPinnedBrowserFrames(rightToLeft: true)
        resizePinnedDrawer(horizontalOffset: 72)
        assertPinnedBrowserFrames(rightToLeft: true)
        attachEvidence(named: "ipad-rtl-pinned-resized")
        closeDrawer()
    }
}

@MainActor
final class FloorpAdaptiveSidebarIPhoneUITests: FloorpAdaptiveSidebarUITestCase {
    override func setUp() async throws {
        specificForPlatform = .phone
        guard !iPad() else { throw XCTSkip("iPhone-only adaptive sidebar coverage") }
        launchArguments.append(
            name.contains("TopAddressBar")
                ? LaunchArguments.SearchBarTop
                : LaunchArguments.SearchBarBottom
        )
        XCUIDevice.shared.orientation = .portrait
        try await super.setUp()
        waitForRotation(to: .portrait)
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    func testOverlayStaysAboveTopAddressBar() {
        verifyOverlayZOrder(expectAddressBarAtTop: true, evidenceName: "iphone-top-toolbar-overlay")
        closeDrawer()
    }

    func testOverlayStaysAboveBottomAddressBar() {
        verifyOverlayZOrder(expectAddressBarAtTop: false, evidenceName: "iphone-bottom-toolbar-overlay")
        closeDrawer()
    }

    private func verifyOverlayZOrder(
        expectAddressBarAtTop: Bool,
        evidenceName: String
    ) {
        let addressBar = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.addressBar
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: TIMEOUT))
        if expectAddressBarAtTop {
            XCTAssertLessThan(addressBar.frame.midY, window.frame.midY)
        } else {
            XCTAssertGreaterThan(addressBar.frame.midY, window.frame.midY)
        }

        _ = openNotesDrawer()
        assertOverlayMode()
        let drawer = waitForElement(
            withIdentifier: FloorpAdaptiveSidebarIdentifier.drawerContainer
        )
        let overlap = drawer.frame.intersection(addressBar.frame)
        XCTAssertGreaterThan(overlap.width, 10, "Drawer did not cover the address bar horizontally")
        XCTAssertGreaterThan(overlap.height, 10, "Drawer did not cover the address bar vertically")

        let tapPoint = CGPoint(
            x: min(overlap.maxX - 8, drawer.frame.minX + 100),
            y: overlap.midY
        )
        let normalizedOffset = CGVector(
            dx: (tapPoint.x - window.frame.minX) / window.frame.width,
            dy: (tapPoint.y - window.frame.minY) / window.frame.height
        )
        window.coordinate(withNormalizedOffset: normalizedOffset).tap()

        XCTAssertTrue(drawer.exists, "Drawer disappeared after tapping its address-bar overlap")
        XCTAssertFalse(addressBar.hasKeyboardFocus, "Covered address bar received keyboard focus")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Covered address bar opened the keyboard")
        attachEvidence(named: evidenceName)
    }
}
