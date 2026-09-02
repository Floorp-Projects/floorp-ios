// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
class NightModeTests: BaseTestCase {
    private var nightModeCell: XCUIElement {
        app.tables.cells["MainMenu.NightModeOn"]
    }

    func testBuiltInNightModeIsNotExposed() {
        navigator.openURL(path(forTestPage: TestPages.exampleHTML))
        waitUntilPageLoad()
        navigator.goto(BrowserTabMenuMore)
        XCTAssertFalse(nightModeCell.exists)
    }
}
