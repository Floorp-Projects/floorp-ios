// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import CryptoKit
import XCTest

/// Verifies that the Nova-design private-mode home header renders the approved
/// Floorp mark and never the upstream Firefox "Private mode" artwork.
///
/// The upstream sync introduced `fxHomeHeaderLogoPrivate` (Firefox artwork)
/// for the Nova-design private homepage header. Floorp must ship its official
/// mark instead. The rendered element is compared against a SHA-256 digest of
/// the approved Floorp render so that reintroducing Firefox artwork fails the
/// image-digest assertion even if the asset name stays the same.
///
/// Digest calibration: `approvedPrivateHeaderDigest` was recorded from the
/// element screenshot on iPhone 17 / iOS 26.2 with the official Floorp mark in
/// `fxHomeHeaderLogoPrivate.imageset`. Recalibrate only with reviewed approval
/// and record the device/OS matrix in the calibration note.
@MainActor
class FloorpPrivateHeaderBrandingUITests: FeatureFlaggedTestBase {
    private static let approvedPrivateHeaderDigest =
        "fe5958f7023bd3b4dcb7b1c3be431b7d504c016bac8bac965818eaac048e128c"

    private static let logoIdentifier =
        AccessibilityIdentifiers.FirefoxHomepage.OtherButtons.logoID
    private static let privateHomeCardIdentifier =
        AccessibilityIdentifiers.PrivateMode.Homepage.card

    private var toolbarScreen: ToolbarScreen!
    private var tabTrayScreen: TabTrayScreen!

    override func setUpApp() {
        super.setUpApp()
        addLaunchArgument(
            jsonFileName: "floorpNovaDesignEnabled",
            featureName: "nova-design-feature"
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        toolbarScreen = ToolbarScreen(app: app)
        tabTrayScreen = TabTrayScreen(app: app)
    }

    func testPrivateModeHomeHeaderRendersApprovedFloorpMark() throws {
        // Launch is explicit for FeatureFlaggedTestBase.
        app.launch()

        // Reach the private-mode home page through the tab tray.
        waitForTabsButton()
        toolbarScreen.tapOnTabsButton()
        tabTrayScreen.switchToPrivateBrowsing()
        tabTrayScreen.assertNewTabButtonExist()
        tabTrayScreen.tapOnNewTabButton()

        // Confirm the private home page is on screen before locating its header.
        let privateHomeCard = app.descendants(matching: .any)
            .matching(identifier: Self.privateHomeCardIdentifier)
            .firstMatch
        XCTAssertTrue(
            privateHomeCard.waitForExistence(timeout: TIMEOUT),
            "Private home page card did not appear"
        )

        // Select the visible (hittable) header logo and verify the Floorp
        // product label before comparing the rendered pixels.
        let logo = Self.visibleLogo(in: app)
        XCTAssertNotNil(logo, "No visible private home header logo found")
        guard let logo else { return }
        XCTAssertEqual(
            logo.label,
            "Floorp",
            "Private-mode home header logo must carry the Floorp product name"
        )

        let renderedDigest = try Self.renderedScreenshotDigest(of: logo)
        XCTAssertEqual(
            renderedDigest,
            Self.approvedPrivateHeaderDigest,
            "Private-mode home header render does not match the approved Floorp artwork (rendered digest \(renderedDigest))"
        )
    }

    /// Returns the on-screen header logo element. The regular home page can
    /// linger in the accessibility tree behind the tab tray, so the first
    /// match is not necessarily visible; prefer a hittable element and record
    /// the candidates for diagnostics.
    private static func visibleLogo(in app: XCUIApplication) -> XCUIElement? {
        let candidates = app.descendants(matching: .any)
            .matching(identifier: logoIdentifier)
            .allElementsBoundByIndex
        return candidates.first { $0.isHittable } ?? candidates.last
    }

    private static func renderedScreenshotDigest(of element: XCUIElement) throws -> String {
        let screenshot = element.screenshot()
        guard let pngData = screenshot.image.pngData() else {
            throw NSError(
                domain: "FloorpPrivateHeaderBrandingUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Element screenshot produced no PNG data"]
            )
        }
        return SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
    }
}
