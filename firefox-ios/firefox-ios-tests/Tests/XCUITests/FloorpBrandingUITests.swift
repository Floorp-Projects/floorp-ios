// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest

/// Floorp-owned branding smoke coverage over shipped main-app surfaces.
///
/// Runs in the EN/JA iPhone/iPad matrix (see `FloorpBrandingUI.xctestplan`).
/// Assertions use stable accessibility identifiers and the non-localized
/// Floorp product name; permission-copy coverage is provided by the compiled
/// archive inspection (`rg` over the localized InfoPlist.strings) in the
/// release evidence, per `docs/branding.md`.
@MainActor
class FloorpBrandingUITests: BaseTestCase {
    private static let logoIdentifier =
        AccessibilityIdentifiers.FirefoxHomepage.OtherButtons.logoID
    private static let privateHomeCardIdentifier =
        AccessibilityIdentifiers.PrivateMode.Homepage.card

    private lazy var toolbarScreen = ToolbarScreen(app: app)
    private lazy var tabTrayScreen = TabTrayScreen(app: app)

    func testLaunchHomeHeaderShowsFloorpBranding() {
        app.launch()

        // Home page header carries the Floorp product label on its logo stack.
        let logo = app.descendants(matching: .any)
            .matching(identifier: Self.logoIdentifier)
            .allElementsBoundByIndex
            .first { $0.isHittable }
        XCTAssertNotNil(logo, "Home header logo not found")
        XCTAssertEqual(logo?.label, "Floorp")
    }

    func testPrivateHomeHeaderShowsFloorpBranding() {
        app.launch()

        waitForTabsButton()
        toolbarScreen.tapOnTabsButton()
        tabTrayScreen.switchToPrivateBrowsing()
        tabTrayScreen.assertNewTabButtonExist()
        tabTrayScreen.tapOnNewTabButton()

        let privateHomeCard = app.descendants(matching: .any)
            .matching(identifier: Self.privateHomeCardIdentifier)
            .firstMatch
        XCTAssertTrue(
            privateHomeCard.waitForExistence(timeout: TIMEOUT),
            "Private home page card did not appear"
        )

        let logo = app.descendants(matching: .any)
            .matching(identifier: Self.logoIdentifier)
            .allElementsBoundByIndex
            .first { $0.isHittable }
        XCTAssertNotNil(logo, "Private home header logo not found")
        XCTAssertEqual(logo?.label, "Floorp")
    }

    func testSettingsAboutShowsFloorpIdentity() {
        app.launch()
        navigator.goto(SettingsScreen)

        // The About section version row is built from AppName.shortName and
        // must read "Floorp <version> (<build>)".
        let versionRow = app.cells.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Floorp'"))
            .firstMatch
        XCTAssertTrue(
            versionRow.waitForExistence(timeout: TIMEOUT),
            "About section version row must identify the app as Floorp"
        )
        XCTAssertFalse(
            versionRow.label.localizedCaseInsensitiveContains("Firefox"),
            "About version row must not name Firefox"
        )

        // The About rows for the Floorp legal surfaces use stable
        // accessibility identifiers (the visible titles are localized).
        for identifier in [
            AccessibilityIdentifiers.Settings.Licenses.title,
            AccessibilityIdentifiers.Settings.YourRights.title,
        ] {
            let cell = app.cells.containing(.any, identifier: identifier).firstMatch
            XCTAssertTrue(
                cell.waitForExistence(timeout: TIMEOUT),
                "About row missing: \(identifier)"
            )
        }
    }

    func testQuickActionsUseFloorpCopy() {
        app.launch()
        XCUIDevice.shared.press(.home)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // On iPad the icon appears in both the home screen and the Dock,
        // so resolve the first match.
        let icon = springboard.icons["Floorp"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: TIMEOUT))
        icon.press(forDuration: 2.0)

        // The home-screen context menu follows the simulator system language,
        // so assert the stable shortcut-item identifiers from the app
        // Info.plist (bundleID.NewTab / bundleID.NewPrivateTab) instead of
        // localized labels. The release plist contains only product-neutral
        // shortcut copy, verified by the compiled archive inspection.
        for identifier in [
            "app.floorp.Floorp.NewTab",
            "app.floorp.Floorp.NewPrivateTab",
        ] {
            let row = springboard.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: TIMEOUT),
                "Quick action missing: \(identifier)"
            )
        }
    }
}

/// Onboarding branding smoke: the first-run intro must render the Floorp
/// loader artwork. Runs without `SkipIntro`.
@MainActor
class FloorpBrandingOnboardingUITests: BaseTestCase {
    override func setUpApp() {
        launchArguments = launchArguments.filter { $0 != LaunchArguments.SkipIntro }
    }

    func testOnboardingShowsFloorpLoader() {
        app.launch()

        let loader = app.images["floorpLoader"]
        XCTAssertTrue(
            loader.waitForExistence(timeout: TIMEOUT),
            "Onboarding must render the Floorp loader artwork"
        )
    }
}
