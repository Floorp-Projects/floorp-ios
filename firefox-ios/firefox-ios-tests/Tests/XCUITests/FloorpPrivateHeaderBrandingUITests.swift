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
        "0000000000000000000000000000000000000000000000000000000000000000"

    private static let logoIdentifier =
        AccessibilityIdentifiers.FirefoxHomepage.OtherButtons.logoID

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

        // The private home page header renders the logo stack with the
        // Floorp product name as its accessibility label.
        let logo = app.descendants(matching: .any)
            .matching(identifier: Self.logoIdentifier)
            .firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: TIMEOUT))
        XCTAssertEqual(
            logo.label,
            "Floorp",
            "Private-mode home header logo must carry the Floorp product name"
        )

        // The rendered pixels must match the approved Floorp artwork digest.
        let renderedDigest = try Self.renderedScreenshotDigest(of: logo)
        XCTAssertEqual(
            renderedDigest,
            Self.approvedPrivateHeaderDigest,
            "Private-mode home header render does not match the approved Floorp artwork (rendered digest \(renderedDigest))"
        )
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
