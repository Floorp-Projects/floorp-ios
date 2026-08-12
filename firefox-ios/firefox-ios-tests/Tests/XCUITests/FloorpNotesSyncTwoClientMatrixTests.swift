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

        guard environment["FLOORP_NOTES_SYNC_G5_RUN"] == "1" else {
            XCTFail("G5 preflight was not explicitly authorized.")
            return
        }
        guard environment["FLOORP_NOTES_SYNC_PRODUCTION_QA"] == "1" else {
            XCTFail("G5 preflight requires the protected production-QA route.")
            return
        }
        guard environment["FIREFOX_USE_STAGE_SERVER"] == nil else {
            XCTFail("G5 preflight rejects a staging server override.")
            return
        }
    }
}
