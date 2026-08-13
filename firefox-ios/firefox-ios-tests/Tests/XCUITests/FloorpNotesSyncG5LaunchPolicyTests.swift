// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest

final class FloorpNotesSyncG5LaunchPolicyTests: XCTestCase {
    private let allowedEnvironment = [
        "FLOORP_NOTES_SYNC_G5_RUN": "1",
        "FLOORP_NOTES_SYNC_PRODUCTION_QA": "1",
    ]

    func testAllowsExactlyTheTwoExplicitIntentFlags() {
        XCTAssertTrue(FloorpNotesSyncG5LaunchPolicy.allows(environment: allowedEnvironment))

        var missingIntent = allowedEnvironment
        missingIntent.removeValue(forKey: "FLOORP_NOTES_SYNC_G5_RUN")
        XCTAssertFalse(FloorpNotesSyncG5LaunchPolicy.allows(environment: missingIntent))

        var nonLiteralIntent = allowedEnvironment
        nonLiteralIntent["FLOORP_NOTES_SYNC_PRODUCTION_QA"] = "true"
        XCTAssertFalse(FloorpNotesSyncG5LaunchPolicy.allows(environment: nonLiteralIntent))

        var additionalIntent = allowedEnvironment
        additionalIntent["FLOORP_NOTES_SYNC_ADDITIONAL_INTENT"] = "1"
        XCTAssertFalse(FloorpNotesSyncG5LaunchPolicy.allows(environment: additionalIntent))
    }

    func testRejectsEachNonProductionEndpointOverride() {
        let rejectedOverrides = [
            "FIREFOX_USE_STAGE_SERVER",
            "CUSTOM_FXA_SERVER",
            "CUSTOM_SYNC_TOKEN_SERVER",
            "FIREFOX_FXA_CHINA_SERVER",
            "FIREFOX_USE_CHINA_SYNC_SERVICE",
            "FIREFOX_FXA_CONTENT_SERVER",
            "FIREFOX_SYNC_TOKEN_SERVER",
            "FIREFOX_USE_CUSTOM_FXA_CONTENT_SERVER",
            "FIREFOX_USE_CUSTOM_SYNC_TOKEN_SERVER",
        ]

        for override in rejectedOverrides {
            var environment = allowedEnvironment
            environment[override] = ""
            XCTAssertFalse(
                FloorpNotesSyncG5LaunchPolicy.allows(environment: environment),
                "G5 preflight must reject \\(override) even when its value is empty."
            )
        }
    }
}
