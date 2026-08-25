// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionAlarmsActionTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "alarms-action-fixture")!

    func testAlarmDefinitionsArePermissionGatedDurableAndProfileScoped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = FloorpWebExtensionPermissionBroker()
        let store = try FloorpWebExtensionAlarmStore(
            profileIdentifier: "alarm-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let alarm = FloorpWebExtensionAlarm(
            name: "refresh",
            scheduledTime: Date(timeIntervalSinceReferenceDate: 2_000),
            period: 60
        )

        do {
            try await store.create(alarm, for: extensionID, permissionBroker: broker)
            XCTFail("Expected alarm creation without permission to throw")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionError,
                .permissionDenied(FloorpWebExtensionAPIGrant.alarms.rawValue)
            )
        }

        await broker.grant([.alarms], requestedHosts: [], hostAccess: .denied, to: extensionID)
        try await store.create(alarm, for: extensionID, permissionBroker: broker)
        let savedAlarm = await store.alarm(named: "refresh", for: extensionID)
        XCTAssertEqual(savedAlarm, alarm)

        let restarted = try FloorpWebExtensionAlarmStore(
            profileIdentifier: "alarm-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restoredAlarms = await restarted.alarms(for: extensionID)
        XCTAssertEqual(restoredAlarms, [alarm])
        XCTAssertThrowsError(
            try FloorpWebExtensionAlarmStore(
                profileIdentifier: "alarm-test",
                isPrivateBrowsing: true,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionAlarmStoreError, .profileMismatch)
        }
    }

    func testDueRepeatingAlarmsCoalesceAndDispatchOnlyToRegisteredHandler() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = FloorpWebExtensionPermissionBroker()
        await broker.grant([.alarms], requestedHosts: [], hostAccess: .denied, to: extensionID)
        let store = try FloorpWebExtensionAlarmStore(
            profileIdentifier: "alarm-delivery-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let repeating = FloorpWebExtensionAlarm(
            name: "periodic",
            scheduledTime: now.addingTimeInterval(-180),
            period: 60
        )
        try await store.create(repeating, for: extensionID, permissionBroker: broker)

        let events = try await store.takeDueEvents(now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.alarm, repeating)
        let advancedAlarm = await store.alarm(named: "periodic", for: extensionID)
        XCTAssertGreaterThan(
            try XCTUnwrap(advancedAlarm).scheduledTime,
            now
        )

        let host = FloorpWebExtensionAlarmEventHost()
        var delivered = [FloorpWebExtensionAlarmEvent]()
        await host.dispatch(events)
        XCTAssertTrue(delivered.isEmpty)

        host.register(extensionID: extensionID) { event in
            delivered.append(event)
        }
        await host.dispatch(events)
        XCTAssertEqual(delivered, events)
    }

    func testActionStateIsDurableAndRejectsUnsafeMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionActionStore(
            profileIdentifier: "action-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let state = FloorpWebExtensionActionState(
            title: "Fixture controls",
            isEnabled: true,
            badgeText: "3",
            badgeBackgroundColor: "#FF0000",
            popup: try .init("popup/index.html"),
            icon: try .init("icons/action.png")
        )
        try await store.setState(state, for: extensionID)
        let savedState = await store.state(for: extensionID)
        XCTAssertEqual(savedState, state)

        let restarted = try FloorpWebExtensionActionStore(
            profileIdentifier: "action-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restoredState = await restarted.state(for: extensionID)
        XCTAssertEqual(restoredState, state)
        XCTAssertThrowsError(
            try FloorpWebExtensionActionResource("../popup.html")
        )
        do {
            try await restarted.setState(
                .init(badgeBackgroundColor: "red"),
                for: extensionID
            )
            XCTFail("Expected invalid badge color to throw")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionActionStoreError, .invalidState("badge color"))
        }
        XCTAssertThrowsError(
            try FloorpWebExtensionActionStore(
                profileIdentifier: "action-test",
                isPrivateBrowsing: true,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionActionStoreError, .profileMismatch)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
