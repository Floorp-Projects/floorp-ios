/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import XCTest

@testable import MozillaAppServices

final class SyncManagerComponentTests: XCTestCase {
    func testDisconnectCheckedForwardsToGeneratedAPI() throws {
        let api = FakeGeneratedSyncManager()
        let component = SyncManagerComponent(api: api)

        try component.disconnectChecked()

        XCTAssertEqual(api.checkedDisconnectCallCount, 1)
    }

    func testDisconnectCheckedPropagatesGeneratedError() {
        let api = FakeGeneratedSyncManager(checkedDisconnectShouldThrow: true)
        let component = SyncManagerComponent(api: api)

        XCTAssertThrowsError(try component.disconnectChecked()) { error in
            XCTAssertTrue(error is FakeGeneratedSyncManagerError)
        }
    }
}

private enum FakeGeneratedSyncManagerError: Error {
    case expected
}

private final class FakeGeneratedSyncManager: SyncManagerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let checkedDisconnectShouldThrow: Bool
    private var checkedDisconnectCalls = 0

    init(checkedDisconnectShouldThrow: Bool = false) {
        self.checkedDisconnectShouldThrow = checkedDisconnectShouldThrow
    }

    var checkedDisconnectCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkedDisconnectCalls
    }

    func disconnect() {}

    func disconnectChecked() throws {
        lock.lock()
        checkedDisconnectCalls += 1
        lock.unlock()
        if checkedDisconnectShouldThrow {
            throw FakeGeneratedSyncManagerError.expected
        }
    }

    func getAvailableEngines() -> [String] {
        []
    }

    func sync(params: SyncParams) throws -> SyncResult {
        SyncResult(
            status: .ok,
            successful: [],
            failures: [:],
            persistedState: "",
            declined: nil,
            nextSyncAllowedAt: nil,
            telemetryJson: nil
        )
    }
}
