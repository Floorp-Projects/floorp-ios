// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest

/// Guards the separate, manually authorized production-QA XCUITest route.
///
/// This is deliberately not the G5 two-client matrix. It only proves that a
/// caller selected the isolated FloorpRelease test scheme intentionally; the
/// future matrix must still prove actual iOS/Desktop behavior separately.
@MainActor
final class FloorpNotesSyncProductionQAConfigurationTests: XCTestCase {
    func testReleaseBuildConfigurationIsExplicit() {
        XCTAssertEqual(
            ProcessInfo.processInfo.environment["FLOORP_NOTES_SYNC_PRODUCTION_QA"],
            "1",
            "Production-QA XCUITests require an explicit, protected-environment opt-in."
        )
        XCTAssertNil(
            ProcessInfo.processInfo.environment["FIREFOX_USE_STAGE_SERVER"],
            "Production-QA XCUITests must not use a staging FxA override."
        )
    }
}
