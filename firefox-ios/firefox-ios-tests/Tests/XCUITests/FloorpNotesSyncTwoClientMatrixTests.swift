// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest

/// Protected-run preflight only. The separate operational runner owns actual
/// iOS/Desktop behavior, account isolation, cleanup, and network evidence.
@MainActor
final class FloorpNotesSyncTwoClientMatrixTests: XCTestCase {
    func testTwoClientProductionMatrix() {
        let environment = ProcessInfo.processInfo.environment

        XCTAssertTrue(
            FloorpNotesSyncG5LaunchPolicy.allows(environment: environment),
            "G5 preflight requires only its two explicit intent flags and no endpoint override."
        )
    }
}
