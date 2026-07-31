// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Common

final class AppServicesPolicyTests: XCTestCase {
    func testIsExplicitlyEnabledWithYesReturnsTrue() {
        XCTAssertTrue(AppServicesPolicy.isExplicitlyEnabled("YES"))
    }

    func testIsExplicitlyEnabledWithoutExactYesReturnsFalse() {
        let disabledValues: [Any?] = [nil, "", "NO", "true", "yes", true, 1]

        for value in disabledValues {
            XCTAssertFalse(AppServicesPolicy.isExplicitlyEnabled(value))
        }
    }
}
