// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/
@testable import Client

import XCTest
import Common
import Sync
import TestKit

import enum MozillaAppServices.SyncReason

@MainActor
class SyncContentSettingsViewControllerTests: XCTestCase {
    var profile: MockProfile!
    var syncContentSettingsVC: SyncContentSettingsViewController?
    let windowUUID: WindowUUID = .XCTestDefaultUUID

    override func setUp() async throws {
        try await super.setUp()
        DependencyHelperMock().bootstrapDependencies()
        profile = MockProfile()
        syncContentSettingsVC = SyncContentSettingsViewController(windowUUID: windowUUID)
        syncContentSettingsVC?.profile = profile
    }

    override func tearDown() async throws {
        DependencyHelperMock().reset()
        profile = nil
        syncContentSettingsVC = nil
        try await super.tearDown()
    }

    func test_syncContentSettingsViewController_generateSettingsCount() {
        let settingSections = syncContentSettingsVC?.generateSettings()
        // Count should be 4 as the sections contains
        // - manageSection [0]
        // - enginesSection [1]
        // - deviceNameSection [2]
        // - disconnectSection [3]
        XCTAssertEqual(settingSections?.count, 4)
    }

    func test_syncContentSettingsViewController_engineSectionForSettings() {
        let settingSections = syncContentSettingsVC?.generateSettings()
        let engineSectionChildren = settingSections?[1].children
        // Count for engine section children should be 5
        // as the sub engine section contains
        // bookmarks
        // history
        // tabs
        // passwords
        // credit cards
        XCTAssertEqual(engineSectionChildren?.count, 6)
    }

    func test_notesRuntimePolicySettingIsExposedOnlyForReleaseEnabledBuild() throws {
        let viewController = SyncContentSettingsViewController(
            windowUUID: windowUUID,
            notesSyncAvailable: { true }
        )
        viewController.profile = profile

        let sections = viewController.generateSettings()
        let notesSetting = try XCTUnwrap(
            sections[1].children.first { setting in
                setting.title?.string == "Sync Notes"
            } as? BoolSetting
        )

        XCTAssertEqual(
            notesSetting.prefKey,
            RustSyncManager.floorpNotesRuntimeEnabledPref
        )
        XCTAssertEqual(sections[1].children.count, 7)
    }

    func testNotesRuntimeSettingDoesNotPublishBeforeManagerBarrier() throws {
        profile.prefs.setBool(
            true,
            forKey: RustSyncManager.floorpNotesRuntimeEnabledPref
        )
        let viewController = SyncContentSettingsViewController(
            windowUUID: windowUUID,
            notesSyncAvailable: { true }
        )
        viewController.profile = profile
        let notesSetting = try XCTUnwrap(
            viewController.generateSettings()[1].children.first { setting in
                setting.title?.string == "Sync Notes"
            } as? FloorpNotesRuntimeSetting
        )
        let toggle = UISwitch()
        toggle.isOn = false

        notesSetting.writeBool(toggle)

        XCTAssertEqual(
            profile.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ),
            true
        )
    }

    func testSyncNowTriggersUserSyncExactlyOnce() throws {
        let settings = SettingsTableViewController(
            style: .grouped,
            windowUUID: windowUUID,
            themeManager: MockThemeManager()
        )
        settings.profile = profile
        let syncManager = try XCTUnwrap(
            profile.syncManager as? ClientSyncManagerSpy
        )
        let setting = SyncNowSetting(
            settings: settings,
            settingsDelegate: nil,
            hasConnectivity: { true }
        )

        setting.onClick(nil)

        XCTAssertEqual(syncManager.syncEverythingCalled, 1)
        XCTAssertEqual(syncManager.lastSyncEverythingReason, .user)
    }

    func testBackgroundPart2RequestsNotesThroughNamedSyncPath() throws {
        let syncManager = try XCTUnwrap(
            profile.syncManager as? ClientSyncManagerSpy
        )

        BackgroundSyncUtility.performPart2Sync(profile: profile) {}

        XCTAssertEqual(syncManager.syncNamedCollectionsCalled, 1)
        XCTAssertEqual(syncManager.lastSyncNamedCollectionsReason, .backgrounded)
        XCTAssertEqual(
            syncManager.lastSyncNamedCollectionsNames,
            ["tabs", "logins", "clients", "prefs"]
        )
    }

    func testNotesToggleRequestsOnlyAnEffectiveEnable() async {
        let browserProfile = MockBrowserProfile(
            localName: "NotesToggleTriggerTests"
        )
        let requests = SettingsSyncRequestRecorder()
        let manager = RustSyncManager(
            profile: browserProfile,
            logger: MockLogger(),
            notificationCenter: MockNotificationCenter(),
            syncRequestObserver: requests.record
        )
        manager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        browserProfile.syncManager = manager
        manager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        let viewController = SyncContentSettingsViewController(
            windowUUID: windowUUID,
            notesSyncAvailable: { true }
        )
        viewController.profile = browserProfile

        await withCheckedContinuation { continuation in
            viewController.applyNotesSyncRuntimePolicy(enabled: false) {
                continuation.resume()
            }
        }
        XCTAssertTrue(requests.reasons.isEmpty)

        await withCheckedContinuation { continuation in
            viewController.applyNotesSyncRuntimePolicy(enabled: true) {
                continuation.resume()
            }
        }

        XCTAssertEqual(requests.reasons, [.enabledChange])
        XCTAssertEqual(requests.engines, [["prefs"]])
        XCTAssertEqual(
            browserProfile.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ),
            true
        )
        manager.endTimedSyncs()
        browserProfile.prefs.clearAll()
    }
}

private final class SettingsSyncRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReasons = [SyncReason]()
    private var recordedEngines = [[String]]()

    var reasons: [SyncReason] {
        lock.withLock { recordedReasons }
    }

    var engines: [[String]] {
        lock.withLock { recordedEngines }
    }

    func record(_ reason: SyncReason, _ engines: [String]) {
        lock.withLock {
            recordedReasons.append(reason)
            recordedEngines.append(engines)
        }
    }
}
