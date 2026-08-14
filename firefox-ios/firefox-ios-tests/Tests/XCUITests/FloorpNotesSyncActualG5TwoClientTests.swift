// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest

@MainActor
final class FloorpNotesSyncActualG5TwoClientTests: XCTestCase {
    func testActualG5TwoClientProductionMatrix() throws {
        throw XCTSkip(
            "UPSTREAM_ARTIFACT_MISSING: actual G5 requires an admitted external driver."
        )
    }
}
