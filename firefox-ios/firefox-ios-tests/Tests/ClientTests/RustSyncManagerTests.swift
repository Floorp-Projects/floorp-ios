// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

@testable import Client
@testable import Sync
import Common
import Shared
import TestKit
import XCTest

import enum MozillaAppServices.SyncEngineSelection
import enum MozillaAppServices.ServiceStatus
import enum MozillaAppServices.SyncReason
import struct MozillaAppServices.DeviceSettings
import struct MozillaAppServices.SyncAuthInfo
import struct MozillaAppServices.SyncParams
import struct MozillaAppServices.SyncResult

class RustSyncManagerTests: XCTestCase {
    struct Keys {
        static let bookmarksStateChangedPrefKey = "sync.engine.bookmarks.enabledStateChanged"
        static let bookmarksEnabledPrefKey = "sync.engine.bookmarks.enabled"
        static let creditcardsStateChangedPrefKey = "sync.engine.creditcards.enabledStateChanged"
        static let creditcardsEnabledPrefKey = "sync.engine.creditcards.enabled"
        static let addressesStateChangedPrefKey = "sync.engine.addresses.enabledStateChanged"
        static let addressesEnabledPrefKey = "sync.engine.addresses.enabled"
        static let historyStateChangedPrefKey = "sync.engine.history.enabledStateChanged"
        static let historyEnabledPrefKey = "sync.engine.history.enabled"
        static let passwordsStateChangedPrefKey = "sync.engine.passwords.enabledStateChanged"
        static let passwordsEnabledPrefKey = "sync.engine.passwords.enabled"
        static let tabsStateChangedPrefKey = "sync.engine.tabs.enabledStateChanged"
        static let tabsEnabledPrefKey = "sync.engine.tabs.enabled"
    }

    private final class Fixture {
        let profile: MockBrowserProfile
        let logins: MockLoginProvider
        let autofill: MockAutofill
        let places: MockPlaces
        let tabs: MockRemoteTabs
        var rustSyncManager: RustSyncManager

        init() {
            profile = MockBrowserProfile(localName: "RustSyncManagerTests")
            logins = MockLoginProvider()
            autofill = MockAutofill()
            places = MockPlaces()
            tabs = MockRemoteTabs()
            rustSyncManager = RustSyncManager(
                profile: profile,
                creditCardAutofillEnabled: true,
                logger: MockLogger(),
                logins: logins,
                autofill: autofill,
                places: places,
                tabs: tabs,
                notificationCenter: MockNotificationCenter()
            )
            rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
                dispatchQueue: MockDispatchQueue()
            )
            profile.syncManager = rustSyncManager
        }
    }

    private var fixture: Fixture?
    private var requiredFixture: Fixture {
        guard let fixture else {
            preconditionFailure("fixture accessed outside the test lifecycle")
        }
        return fixture
    }
    private var rustSyncManager: RustSyncManager {
        get { requiredFixture.rustSyncManager }
        set { requiredFixture.rustSyncManager = newValue }
    }
    private var profile: MockBrowserProfile { requiredFixture.profile }
    private var logins: MockLoginProvider { requiredFixture.logins }
    private var autofill: MockAutofill { requiredFixture.autofill }
    private var places: MockPlaces { requiredFixture.places }
    private var tabs: MockRemoteTabs { requiredFixture.tabs }

    override func setUp() {
        super.setUp()
        fixture = Fixture()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fxa.cwts.declinedSyncEngines")
        profile.prefs.clearAll()
        fixture = nil
        super.tearDown()
    }

    func testGetEnginesAndKeys_withLoginsVerified() {
        logins.loginsVerified = true
        let engines: [RustSyncManagerAPI.TogglableEngine] = [
            .bookmarks,
            .creditcards,
            .history,
            .passwords,
            .tabs,
            .addresses
        ]

        rustSyncManager.getEnginesAndKeys(engines: engines) { [tabs, logins, autofill, places] (engines, keys) in
            XCTAssertEqual(engines.count, 6)

            XCTAssertEqual(engines[safe: 0], "bookmarks")
            XCTAssertEqual(engines[safe: 1], "creditcards")
            XCTAssertEqual(engines[safe: 2], "history")
            XCTAssertEqual(engines[safe: 3], "passwords")
            XCTAssertEqual(engines[safe: 4], "tabs")
            XCTAssertEqual(engines[safe: 5], "addresses")
            XCTAssertFalse(keys.isEmpty)

            XCTAssertNotNil(keys["creditcards"])

            XCTAssertEqual(tabs.registerWithSyncManagerCalled, 1)
            XCTAssertEqual(logins.registerWithSyncManagerCalled, 1)
            XCTAssertEqual(autofill.registerWithSyncManagerCalled, 1)
            XCTAssertEqual(places.registerWithSyncManagerCalled, 1)
        }
    }

    func testGetEnginesWithRetrievedKeys() {
        let enginesToSync = rustSyncManager
            .getEnginesWithRetrievedKeys("testCCKey",
                                         "testLoginsKey",
                                         rustSyncManager.syncManagerAPI.rustTogglableEngines)
        XCTAssertEqual(enginesToSync.count, 6)
        XCTAssertTrue(enginesToSync.contains(.creditcards))
        XCTAssertTrue(enginesToSync.contains(.passwords))

        let enginesToSync2 = rustSyncManager
            .getEnginesWithRetrievedKeys(nil, nil, rustSyncManager.syncManagerAPI.rustTogglableEngines)
        XCTAssertEqual(enginesToSync2.count, 4)
        XCTAssertFalse(enginesToSync2.contains(.creditcards))
        XCTAssertFalse(enginesToSync2.contains(.passwords))

        let enginesToSync3 = rustSyncManager
            .getEnginesWithRetrievedKeys("testCCKey",
                                         nil,
                                         rustSyncManager.syncManagerAPI.rustTogglableEngines)
        XCTAssertEqual(enginesToSync3.count, 5)
        XCTAssertTrue(enginesToSync3.contains(.creditcards))
        XCTAssertFalse(enginesToSync3.contains(.passwords))

        let enginesToSync4 = rustSyncManager
            .getEnginesWithRetrievedKeys(nil,
                                         "testLoginsKey",
                                         rustSyncManager.syncManagerAPI.rustTogglableEngines)
        XCTAssertEqual(enginesToSync4.count, 5)
        XCTAssertFalse(enginesToSync4.contains(.creditcards))
        XCTAssertTrue(enginesToSync4.contains(.passwords))
    }

    func testGetEnginesAndKeys_withOutLoginsVerified() {
        logins.loginsVerified = false
        let engines: [RustSyncManagerAPI.TogglableEngine] = [
            .bookmarks,
            .creditcards,
            .history,
            .passwords,
            .tabs,
            .addresses
        ]

        rustSyncManager.getEnginesAndKeys(engines: engines) { [tabs, logins, autofill, places] (engines, keys) in
            XCTAssertEqual(engines.count, 5)

            XCTAssertEqual(engines[safe: 0], "bookmarks")
            XCTAssertEqual(engines[safe: 1], "creditcards")
            XCTAssertEqual(engines[safe: 2], "history")
            XCTAssertEqual(engines[safe: 3], "tabs")
            XCTAssertEqual(engines[safe: 4], "addresses")
            XCTAssertFalse(keys.isEmpty)

            XCTAssertNotNil(keys["creditcards"])

            XCTAssertEqual(tabs.registerWithSyncManagerCalled, 1)
            XCTAssertEqual(logins.registerWithSyncManagerCalled, 0)
            XCTAssertEqual(autofill.registerWithSyncManagerCalled, 1)
            XCTAssertEqual(places.registerWithSyncManagerCalled, 1)
        }
    }

    // Temp. Disabled: https://mozilla-hub.atlassian.net/browse/FXIOS-7505
    func testGetEnginesAndKeysWithNoKey() {
        rustSyncManager.getEnginesAndKeys(engines: [.tabs]) { (engines, keys) in
            XCTAssertEqual(engines.count, 1)
            XCTAssertTrue(engines.contains("tabs"))
            XCTAssertTrue(keys.isEmpty)
        }
    }

    func testGetEngineEnablementChangesForAccountWithNewAccount() {
        let declinedEngines = ["tabs", "creditcards"]
        UserDefaults.standard.set(declinedEngines, forKey: "fxa.cwts.declinedSyncEngines")
        let changes = rustSyncManager.getEngineEnablementChangesForAccount()
        XCTAssertFalse(changes["tabs"]!)
        XCTAssertFalse(changes["creditcards"]!)
    }

    func testGetEngineEnablementChangesForAccountWithNoChanges() {
        let changes = rustSyncManager.getEngineEnablementChangesForAccount()
        XCTAssertTrue(changes.isEmpty)
    }

    func testGetEngineEnablementChangesForAccountWithNoRecentChanges() {
        profile.prefs.setBool(true, forKey: Keys.bookmarksEnabledPrefKey)

        let changes = rustSyncManager.getEngineEnablementChangesForAccount()
        XCTAssertTrue(changes.isEmpty)
    }

    func testGetEngineEnablementChangesForAccountWithRecentChanges() {
        profile.prefs.setBool(true, forKey: Keys.bookmarksStateChangedPrefKey)
        profile.prefs.setBool(true, forKey: Keys.bookmarksEnabledPrefKey)
        profile.prefs.setBool(true, forKey: Keys.creditcardsStateChangedPrefKey)
        profile.prefs.setBool(false, forKey: Keys.creditcardsEnabledPrefKey)

        let changes = rustSyncManager.getEngineEnablementChangesForAccount()
        XCTAssertTrue(changes["bookmarks"]!)
        XCTAssertFalse(changes["creditcards"]!)
    }

    // Temp. Disabled: https://mozilla-hub.atlassian.net/browse/FXIOS-7505
    func testUpdateEnginePrefs_bookmarksEnabled() throws {
        profile.prefs.setBool(true, forKey: Keys.bookmarksEnabledPrefKey)
        profile.prefs.setBool(true, forKey: Keys.bookmarksStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.bookmarksEnabledPrefKey))
        XCTAssertFalse(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.bookmarksStateChangedPrefKey))
    }

    func testUpdateEnginePrefs_creditCardEnabled() throws {
        profile.prefs.setBool(true, forKey: Keys.creditcardsEnabledPrefKey)
        profile.prefs.setBool(true, forKey: Keys.creditcardsStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.creditcardsEnabledPrefKey))
        XCTAssertFalse(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.creditcardsStateChangedPrefKey))
    }

    func testUpdateEnginePrefs_historyEnabled() throws {
        profile.prefs.setBool(true, forKey: Keys.historyEnabledPrefKey)
        profile.prefs.setBool(false, forKey: Keys.historyStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.historyEnabledPrefKey))
        XCTAssertTrue(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.historyStateChangedPrefKey))
    }

    func testUpdateEnginePrefs_passwordsEnabled() throws {
        profile.prefs.setBool(false, forKey: Keys.passwordsEnabledPrefKey)
        profile.prefs.setBool(false, forKey: Keys.passwordsStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.passwordsEnabledPrefKey))
        XCTAssertFalse(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.passwordsStateChangedPrefKey))
    }

    func testUpdateEnginePrefs_tabsEnabled() throws {
        profile.prefs.setBool(false, forKey: Keys.tabsEnabledPrefKey)
        profile.prefs.setBool(true, forKey: Keys.tabsStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.tabsEnabledPrefKey))
        XCTAssertTrue(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.tabsStateChangedPrefKey))
    }

    // FXIOS-8331: Disable History Highlight tests while FXIOS-8059 (Epic) is in progress
    // FXIOS-8367: Added a ticket to enable these tests when we re-enable history highlights
    func testUpdateEnginePrefs_addressesEnabled() throws {
        profile.prefs.setBool(true, forKey: Keys.addressesEnabledPrefKey)
        profile.prefs.setBool(true, forKey: Keys.addressesStateChangedPrefKey)

        let declined = ["bookmarks", "creditcards", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.addressesEnabledPrefKey))
        XCTAssertTrue(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.addressesStateChangedPrefKey))
    }

    // FXIOS-8331: Disable History Highlight tests while FXIOS-8059 (Epic) is in progress
    // FXIOS-8367: Added a ticket to enable these tests when we re-enable history highlights
    func testUpdateEnginePrefs_addressesDisabled() throws {
        profile.prefs.setBool(false, forKey: Keys.addressesEnabledPrefKey)
        profile.prefs.setBool(false, forKey: Keys.addressesStateChangedPrefKey)

        let declined = ["bookmarks", "addresses", "passwords"]
        rustSyncManager.updateEnginePrefs(declined: declined)

        let key = try XCTUnwrap(profile.prefs.boolForKey(Keys.addressesEnabledPrefKey))
        XCTAssertFalse(key)
        XCTAssertNil(profile.prefs.boolForKey(Keys.addressesStateChangedPrefKey))
    }

    func test_applicationDidBecomeActive_updateSignInPrefs() throws {
        rustSyncManager.applicationDidBecomeActive()
        let value = try XCTUnwrap(profile.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount))
        XCTAssertFalse(value)
    }

    func testForegroundAndScheduledTriggersUseCommonSyncPath() {
        let requests = SyncRequestRecorder()
        rustSyncManager = RustSyncManager(
            profile: profile,
            creditCardAutofillEnabled: true,
            logger: MockLogger(),
            logins: logins,
            autofill: autofill,
            places: places,
            tabs: tabs,
            notificationCenter: MockNotificationCenter(),
            syncableAccountOverride: { true },
            delayedSyncScheduler: { _, work in work() },
            syncRequestObserver: requests.record
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        profile.syncManager = rustSyncManager
        rustSyncManager.lastSyncFinishTime = 0

        rustSyncManager.applicationDidBecomeActive()
        rustSyncManager.syncOnTimer()
        rustSyncManager.endTimedSyncs()

        XCTAssertEqual(requests.reasons, [.startup, .scheduled])
        XCTAssertTrue(
            requests.engines.allSatisfy {
                $0.contains(FloorpNotesSyncEngineSelection.engineName)
            }
        )
    }

    func test_onRemovedAccount_updatePrefs() throws {
        profile.prefs.setBool(true, forKey: PrefsKeys.Sync.signedInFxaAccount)
        profile.prefs.setInt(7, forKey: PrefsKeys.Sync.numberOfSyncedDevices)

        _ = rustSyncManager.onRemovedAccount()

        XCTAssertEqual(
            profile.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount),
            true
        )
        XCTAssertEqual(
            profile.prefs.intForKey(PrefsKeys.Sync.numberOfSyncedDevices),
            7
        )

        _ = rustSyncManager.finalizeAccountRemoval()
        let signedInStatus = try XCTUnwrap(profile.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount))
        let syncedDevicesCount = try XCTUnwrap(profile.prefs.intForKey(PrefsKeys.Sync.numberOfSyncedDevices))
        XCTAssertFalse(signedInStatus)
        XCTAssertEqual(syncedDevicesCount, 0)
    }

    func testPostLogoutNotesFinalizeFailureStillCompletesAccountCleanup() {
        let accountChanged = expectation(
            forNotification: .FirefoxAccountChanged,
            object: nil
        )
        let profile = MockBrowserProfile(
            localName: "PostLogoutCleanup-\(UUID().uuidString)",
            clear: true,
            accountDisconnect: { completion in completion(true) }
        )
        let syncManager = PostLogoutFailureSyncManager()
        profile.syncManager = syncManager
        profile.prefs.setInt(42, forKey: PrefsKeys.KeyLastRemoteTabSyncTime)
        let removalFinished = expectation(description: "account removal finished")

        profile.removeAccount().uponQueue(.main) { result in
            XCTAssertTrue(result.isSuccess)
            removalFinished.fulfill()
        }

        wait(for: [accountChanged, removalFinished], timeout: 2)
        XCTAssertNil(profile.prefs.intForKey(PrefsKeys.KeyLastRemoteTabSyncTime))
        XCTAssertEqual(syncManager.finalizeAccountRemovalCallCount, 1)
        profile.shutdown()
    }

    func testRuntimePolicyDefaultsClosedWhenCompiledEvidenceFails() {
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)

        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: false
        )

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            false
        )
        XCTAssertEqual(provider.invalidateCallCount, 1)
    }

    func testRuntimePolicySeedsEnabledOnlyFromValidCompiledEvidence() {
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: true
        )

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            true
        )
    }

    func testRuntimePolicyPreservesPersistedDisableAcrossBootstrap() {
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        profile.prefs.setBool(
            false,
            forKey: RustSyncManager.floorpNotesRuntimeEnabledPref
        )

        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: true
        )

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            false
        )
        XCTAssertEqual(provider.invalidateCallCount, 1)
    }

    func testRuntimePolicyDisableInvalidatesRegisteredProvider() throws {
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: true
        )
        try provider.register(accountID: "account-a")

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false)

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            false
        )
        XCTAssertEqual(provider.invalidateCallCount, 1)
        XCTAssertNil(provider.registeredAccountID)
    }

    func testRuntimePolicyCannotEnableWithoutValidCompiledEvidence() {
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: false
        )

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: true)

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            false
        )
    }

    func testRuntimePolicyReenableRequiresEvidenceAndDoesNotChangeOtherEngines() {
        profile.prefs.setBool(true, forKey: Keys.bookmarksEnabledPrefKey)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: true
        )
        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false)

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: true)

        XCTAssertEqual(
            profile.prefs.boolForKey(RustSyncManager.floorpNotesRuntimeEnabledPref),
            true
        )
        XCTAssertEqual(
            profile.prefs.boolForKey(Keys.bookmarksEnabledPrefKey),
            true
        )
    }

    func testExecutionPreparationRechecksCurrentNotesPolicy() throws {
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let initialContext = FloorpNotesSyncExecutionContext()

        let initiallyPrepared = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["bookmarks", "prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: initialContext
        )

        XCTAssertEqual(
            initiallyPrepared?.engines,
            .some(engines: ["bookmarks", "prefs"])
        )
        XCTAssertNotNil(initialContext.generation)
        let invalidationCount = provider.invalidateCallCount
        provider.setAllowsSync(false)

        let deniedContext = FloorpNotesSyncExecutionContext()
        let policyRechecked = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["bookmarks", "prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: deniedContext
        )

        XCTAssertEqual(policyRechecked?.engines, .some(engines: ["bookmarks"]))
        XCTAssertNil(deniedContext.generation)
        XCTAssertEqual(provider.invalidateCallCount, invalidationCount + 1)
    }

    func testPriorNotesGenerationCannotReenterAfterDisableReenable() throws {
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let firstContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: firstContext
        )
        let priorGeneration = try XCTUnwrap(firstContext.generation)

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false)
        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: true)
        let currentContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: currentContext
        )
        let registrationCount = provider.registerCallCount
        let invalidationCount = provider.invalidateCallCount

        let staleContext = FloorpNotesSyncExecutionContext()
        let stalePreparation = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: priorGeneration,
            executionContext: staleContext
        )

        XCTAssertNil(stalePreparation)
        XCTAssertNil(staleContext.generation)
        XCTAssertEqual(provider.registerCallCount, registrationCount)
        XCTAssertEqual(provider.invalidateCallCount, invalidationCount)
        XCTAssertEqual(provider.registeredAccountID, "account-a")
        XCTAssertNotEqual(currentContext.generation, priorGeneration)
    }

    func testRuntimeDisableDoesNotInvalidatePreparedCheckedDisconnect() throws {
        let queue = ControllableRustSyncDispatchQueue()
        let component = TestRustSyncManagerComponent()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        try provider.register(accountID: "account-a")

        _ = rustSyncManager.onRemovedAccount()
        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false)

        XCTAssertEqual(provider.invalidateCallCount, 0)
        XCTAssertEqual(queue.pendingCount, 2)
        queue.runNext()
        XCTAssertEqual(provider.prepareForDisconnectCallCount, 1)
        XCTAssertEqual(component.checkedDisconnectCallCount, 1)
        queue.runNext()
        XCTAssertEqual(provider.invalidateCallCount, 0)

        _ = rustSyncManager.finalizeAccountRemoval()
        XCTAssertEqual(provider.finalizeDisconnectCallCount, 1)
        XCTAssertEqual(provider.invalidateCallCount, 0)
        XCTAssertEqual(queue.pendingCount, 1)
        queue.runNext()
        XCTAssertEqual(provider.invalidateCallCount, 1)
    }

    func testAccountMismatchSkipsNotesFinalizationAfterCheckedDisconnect() {
        let provider = TestFloorpNotesSyncEngineProvider(
            disconnectAvailability: .accountMismatch
        )
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)

        _ = rustSyncManager.onRemovedAccount()
        _ = rustSyncManager.finalizeAccountRemoval()

        XCTAssertEqual(provider.prepareForDisconnectCallCount, 1)
        XCTAssertEqual(provider.finalizeDisconnectCallCount, 0)
    }

    func testPostLogoutNotesFinalizeFailureClearsSyncStateWithoutCancel() {
        let provider = TestFloorpNotesSyncEngineProvider(
            finalizeShouldFail: true
        )
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        profile.prefs.setBool(true, forKey: PrefsKeys.Sync.signedInFxaAccount)
        profile.prefs.setInt(7, forKey: PrefsKeys.Sync.numberOfSyncedDevices)
        profile.prefs.setString(
            "persisted",
            forKey: PrefsKeys.RustSyncManagerPersistedState
        )
        profile.prefs.branch("sync").setBool(
            true,
            forKey: "engine.bookmarks.enabled"
        )

        _ = rustSyncManager.onRemovedAccount()
        let result = rustSyncManager.finalizeAccountRemoval()

        XCTAssertTrue(result.value.isFailure)
        XCTAssertEqual(
            profile.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount),
            false
        )
        XCTAssertEqual(
            profile.prefs.intForKey(PrefsKeys.Sync.numberOfSyncedDevices),
            0
        )
        XCTAssertNil(
            profile.prefs.stringForKey(PrefsKeys.RustSyncManagerPersistedState)
        )
        XCTAssertNil(
            profile.prefs.branch("sync").boolForKey(
                "engine.bookmarks.enabled"
            )
        )
        XCTAssertEqual(provider.cancelDisconnectCallCount, 0)
        XCTAssertEqual(provider.invalidateCallCount, 1)
    }

    func testCancelAccountRemovalInvalidatesProviderWhenStateRestoreFails() {
        let provider = TestFloorpNotesSyncEngineProvider(
            disconnectAvailability: .available,
            cancelDisconnectResult: false
        )
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)

        _ = rustSyncManager.onRemovedAccount()
        rustSyncManager.cancelAccountRemoval()

        XCTAssertEqual(provider.cancelDisconnectCallCount, 1)
        XCTAssertEqual(provider.invalidateCallCount, 1)
    }

    func testInstallingCurrentNotesProviderDoesNotInvalidateIt() throws {
        let providerA = TestFloorpNotesSyncEngineProvider()
        let providerB = TestFloorpNotesSyncEngineProvider()

        rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)
        try providerA.register(accountID: "account-a")
        rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)

        XCTAssertEqual(providerA.invalidateCallCount, 0)
        XCTAssertEqual(providerA.registeredAccountID, "account-a")

        rustSyncManager.installFloorpNotesSyncEngineProvider(providerB)
        rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)

        XCTAssertEqual(providerA.invalidateCallCount, 1)
        XCTAssertEqual(providerB.invalidateCallCount, 1)
    }

    func testQueuedProviderInvalidationCannotInvalidateReinstalledProvider() throws {
        let queue = ControllableRustSyncDispatchQueue()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { TestRustSyncManagerComponent() }
        )
        let providerA = TestFloorpNotesSyncEngineProvider()
        let providerB = TestFloorpNotesSyncEngineProvider()
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)
        )

        rustSyncManager.disableFloorpNotesEngine()
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(providerB)
        )
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)
        )
        try providerA.register(accountID: "account-a")
        let invalidationCount = providerA.invalidateCallCount

        queue.runNext()

        XCTAssertEqual(providerA.invalidateCallCount, invalidationCount)
        XCTAssertEqual(providerA.registeredAccountID, "account-a")
    }

    func testQueuedProviderInvalidationCannotInvalidateSameProviderReinstall() throws {
        let queue = ControllableRustSyncDispatchQueue()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { TestRustSyncManagerComponent() }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        )

        rustSyncManager.disableFloorpNotesEngine()
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        )
        try provider.register(accountID: "account-a")

        queue.runNext()

        XCTAssertEqual(provider.invalidateCallCount, 0)
        XCTAssertEqual(provider.registeredAccountID, "account-a")
    }

    func testPreparedRemovalRejectsReplacementAndFinalizesPreparedProvider() {
        let providerA = TestFloorpNotesSyncEngineProvider()
        let providerB = TestFloorpNotesSyncEngineProvider()
        XCTAssertTrue(
            rustSyncManager.installFloorpNotesSyncEngineProvider(providerA)
        )

        _ = rustSyncManager.onRemovedAccount()
        XCTAssertFalse(
            rustSyncManager.installFloorpNotesSyncEngineProvider(providerB)
        )
        _ = rustSyncManager.finalizeAccountRemoval()

        XCTAssertEqual(providerA.prepareForDisconnectCallCount, 1)
        XCTAssertEqual(providerA.finalizeDisconnectCallCount, 1)
        XCTAssertEqual(providerB.finalizeDisconnectCallCount, 0)
        XCTAssertEqual(providerB.invalidateCallCount, 1)
    }

    func testSecondAccountRemovalCannotOverwritePreparingPhase() {
        let queue = ControllableRustSyncDispatchQueue()
        let component = TestRustSyncManagerComponent()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)

        _ = rustSyncManager.onRemovedAccount()
        _ = rustSyncManager.onRemovedAccount()

        XCTAssertEqual(queue.pendingCount, 1)
        queue.runNext()
        XCTAssertEqual(provider.prepareForDisconnectCallCount, 1)
        XCTAssertEqual(component.checkedDisconnectCallCount, 1)
        rustSyncManager.cancelAccountRemoval()
    }

    func testFinalizeCannotRunBeforeCheckedDisconnectFailureResolves() {
        let disconnectStarted = DispatchSemaphore(value: 0)
        let allowDisconnect = DispatchSemaphore(value: 0)
        let disconnectFinished = DispatchSemaphore(value: 0)
        let queue = ControllableRustSyncDispatchQueue()
        let component = TestRustSyncManagerComponent(
            checkedDisconnectStarted: disconnectStarted,
            allowCheckedDisconnect: allowDisconnect,
            checkedDisconnectShouldFail: true
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        profile.prefs.setBool(true, forKey: PrefsKeys.Sync.signedInFxaAccount)
        let removal = rustSyncManager.onRemovedAccount()

        DispatchQueue.global(qos: .userInitiated).async {
            queue.runNext()
            disconnectFinished.signal()
        }
        XCTAssertEqual(disconnectStarted.wait(timeout: .now() + 1), .success)

        let earlyFinalize = rustSyncManager.finalizeAccountRemoval()

        XCTAssertTrue(earlyFinalize.value.isFailure)
        XCTAssertEqual(
            profile.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount),
            true
        )
        allowDisconnect.signal()
        XCTAssertEqual(disconnectFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(removal.value.isFailure)
        XCTAssertEqual(provider.cancelDisconnectCallCount, 1)
        XCTAssertEqual(provider.finalizeDisconnectCallCount, 0)
    }

    func testAccountRemovalBlocksForegroundTimerAndCancelRestoresIt() {
        rustSyncManager = RustSyncManager(
            profile: profile,
            creditCardAutofillEnabled: true,
            logger: MockLogger(),
            logins: logins,
            autofill: autofill,
            places: places,
            tabs: tabs,
            notificationCenter: MockNotificationCenter(),
            syncableAccountOverride: { true },
            timedSyncResumeScheduler: { work in work() }
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        profile.syncManager = rustSyncManager
        rustSyncManager.applicationDidBecomeActive()
        XCTAssertTrue(rustSyncManager.hasActiveSyncTimer)

        _ = rustSyncManager.onRemovedAccount()
        XCTAssertFalse(rustSyncManager.hasActiveSyncTimer)
        rustSyncManager.applicationDidBecomeActive()
        XCTAssertFalse(rustSyncManager.hasActiveSyncTimer)

        rustSyncManager.cancelAccountRemoval()

        XCTAssertTrue(rustSyncManager.hasActiveSyncTimer)
        rustSyncManager.endTimedSyncs()
    }

    func testAccountRemovalFinalizeLeavesForegroundTimerStopped() {
        rustSyncManager = RustSyncManager(
            profile: profile,
            creditCardAutofillEnabled: true,
            logger: MockLogger(),
            logins: logins,
            autofill: autofill,
            places: places,
            tabs: tabs,
            notificationCenter: MockNotificationCenter(),
            syncableAccountOverride: { true },
            timedSyncResumeScheduler: { work in work() }
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        profile.syncManager = rustSyncManager
        rustSyncManager.applicationDidBecomeActive()
        _ = rustSyncManager.onRemovedAccount()
        rustSyncManager.applicationDidBecomeActive()

        _ = rustSyncManager.finalizeAccountRemoval()

        XCTAssertFalse(rustSyncManager.hasActiveSyncTimer)
    }

    func testDoSyncFinalGateControlsActualComponentRequests() throws {
        let queue = ControllableRustSyncDispatchQueue()
        let component = TestRustSyncManagerComponent()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        profile.prefs.setBool(false, forKey: AppConstants.prefSendUsageData)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let allowedContext = FloorpNotesSyncExecutionContext()

        rustSyncManager.doSync(
            params: makeSyncParams(engines: ["bookmarks", "prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            floorpNotesAccountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            floorpNotesExecutionContext: allowedContext
        ) { _ in }
        XCTAssertEqual(queue.pendingCount, 1)
        queue.runNext()

        XCTAssertEqual(
            component.syncEngineSelections,
            [.some(engines: ["bookmarks", "prefs"])]
        )
        XCTAssertNotNil(allowedContext.generation)

        provider.setAllowsSync(false)
        let mixedDeniedContext = FloorpNotesSyncExecutionContext()
        rustSyncManager.doSync(
            params: makeSyncParams(engines: ["bookmarks", "prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            floorpNotesAccountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            floorpNotesExecutionContext: mixedDeniedContext
        ) { _ in }
        queue.runNext()

        XCTAssertEqual(
            component.syncEngineSelections,
            [
                .some(engines: ["bookmarks", "prefs"]),
                .some(engines: ["bookmarks"])
            ]
        )
        XCTAssertNil(mixedDeniedContext.generation)

        let notesOnlyDeniedContext = FloorpNotesSyncExecutionContext()
        rustSyncManager.doSync(
            params: makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            floorpNotesAccountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            floorpNotesExecutionContext: notesOnlyDeniedContext
        ) { _ in }
        queue.runNext()

        XCTAssertEqual(component.syncCallCount, 2)
        XCTAssertNil(notesOnlyDeniedContext.generation)
    }

    func testFinalGateRejectsStaleCustomTokenServerAfterPrefsReturnToProduction() throws {
        let queue = ControllableRustSyncDispatchQueue()
        let component = TestRustSyncManagerComponent()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        profile.prefs.setBool(false, forKey: AppConstants.prefSendUsageData)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let context = FloorpNotesSyncExecutionContext()

        rustSyncManager.doSync(
            params: makeSyncParams(
                engines: ["bookmarks", "prefs"],
                tokenServerURL: "https://custom.example.invalid/1.0/sync/1.5"
            ),
            lifecycleGeneration: lifecycleGeneration,
            floorpNotesAccountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            floorpNotesExecutionContext: context
        ) { _ in }
        XCTAssertEqual(queue.pendingCount, 1)
        queue.runNext()

        XCTAssertEqual(
            component.syncEngineSelections,
            [.some(engines: ["bookmarks"])]
        )
        XCTAssertNil(context.generation)
    }

    func testRuntimeDisableReturnsBeforeSyncAndPublishesAfterBarrier() throws {
        let syncStarted = DispatchSemaphore(value: 0)
        let allowSyncToFinish = DispatchSemaphore(value: 0)
        let syncFinished = DispatchSemaphore(value: 0)
        let disableReturned = DispatchSemaphore(value: 0)
        let policyApplied = DispatchSemaphore(value: 0)
        let component = TestRustSyncManagerComponent(
            syncStarted: syncStarted,
            allowSyncToFinish: allowSyncToFinish
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: DispatchQueue.global(qos: .userInitiated),
            componentFactory: { component }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        profile.prefs.setBool(false, forKey: AppConstants.prefSendUsageData)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )

        rustSyncManager.doSync(
            params: makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            floorpNotesAccountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            floorpNotesExecutionContext: FloorpNotesSyncExecutionContext()
        ) { _ in
            syncFinished.signal()
        }
        XCTAssertEqual(syncStarted.wait(timeout: .now() + 1), .success)
        let invalidationCountBeforeDisable = provider.invalidateCallCount

        DispatchQueue.global(qos: .userInitiated).async { [rustSyncManager] in
            rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false) {
                policyApplied.signal()
            }
            disableReturned.signal()
        }
        XCTAssertEqual(disableReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            policyApplied.wait(timeout: .now() + 0.1),
            .timedOut
        )
        XCTAssertEqual(
            profile.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ),
            true
        )

        allowSyncToFinish.signal()
        XCTAssertEqual(syncFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(policyApplied.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            profile.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ),
            false
        )
        XCTAssertEqual(
            provider.invalidateCallCount,
            invalidationCountBeforeDisable + 1
        )
    }

    func testRapidOffOnKeepsLatestPolicyWhenQueuedOffRuns() {
        let queue = ControllableRustSyncDispatchQueue()
        let completions = FloorpNotesPolicyCompletionRecorder()
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: queue,
            componentFactory: { TestRustSyncManagerComponent() }
        )
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(
            compiledEvidenceAllows: true
        )

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false) {
            completions.record("off")
        }
        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: true) {
            completions.record("on")
        }

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(completions.values, ["on"])
        queue.runNext()

        XCTAssertEqual(
            profile.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ),
            true
        )
        XCTAssertEqual(provider.invalidateCallCount, 0)
        XCTAssertEqual(completions.values, ["on", "off"])
    }

    func testStaleNotesResultCannotCancelCurrentGenerationRetry() throws {
        let retries = FloorpNotesRetryRecorder()
        rustSyncManager = RustSyncManager(
            profile: profile,
            creditCardAutofillEnabled: true,
            logger: MockLogger(),
            logins: logins,
            autofill: autofill,
            places: places,
            tabs: tabs,
            notificationCenter: MockNotificationCenter(),
            floorpNotesRetryScheduler: retries.record
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        profile.syncManager = rustSyncManager
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let firstContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: firstContext
        )
        let firstGeneration = try XCTUnwrap(firstContext.generation)
        let firstRequestSequence = try XCTUnwrap(firstContext.requestSequence)

        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .networkError),
            why: .user,
            floorpNotesGeneration: firstGeneration,
            requestSequence: firstRequestSequence
        )
        XCTAssertEqual(retries.workItems.count, 1)
        XCTAssertFalse(retries.workItems[0].isCancelled)

        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: false)
        rustSyncManager.applyFloorpNotesRuntimePolicy(enabled: true)
        XCTAssertTrue(retries.workItems[0].isCancelled)
        let currentContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: currentContext
        )
        let currentGeneration = try XCTUnwrap(currentContext.generation)
        let currentRequestSequence = try XCTUnwrap(
            currentContext.requestSequence
        )
        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .networkError),
            why: .user,
            floorpNotesGeneration: currentGeneration,
            requestSequence: currentRequestSequence
        )
        XCTAssertEqual(retries.workItems.count, 2)
        XCTAssertFalse(retries.workItems[1].isCancelled)

        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .ok, successful: ["prefs"]),
            why: .user,
            floorpNotesGeneration: firstGeneration,
            requestSequence: firstRequestSequence
        )
        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .networkError),
            why: .user,
            floorpNotesGeneration: firstGeneration,
            requestSequence: firstRequestSequence
        )

        XCTAssertEqual(retries.workItems.count, 2)
        XCTAssertFalse(retries.workItems[1].isCancelled)
    }

    func testOlderSameGenerationResultCannotReinstateRetry() throws {
        let retries = FloorpNotesRetryRecorder()
        rustSyncManager = RustSyncManager(
            profile: profile,
            creditCardAutofillEnabled: true,
            logger: MockLogger(),
            logins: logins,
            autofill: autofill,
            places: places,
            tabs: tabs,
            notificationCenter: MockNotificationCenter(),
            floorpNotesRetryScheduler: retries.record
        )
        rustSyncManager.syncManagerAPI = RustSyncManagerAPI(
            dispatchQueue: MockDispatchQueue()
        )
        profile.syncManager = rustSyncManager
        let provider = TestFloorpNotesSyncEngineProvider()
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        rustSyncManager.bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: true)
        let lifecycleGeneration = try XCTUnwrap(
            rustSyncManager.activeSyncLifecycleGeneration()
        )
        let olderContext = FloorpNotesSyncExecutionContext()
        let newerContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: olderContext
        )
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: newerContext
        )
        let generation = try XCTUnwrap(olderContext.generation)
        XCTAssertEqual(newerContext.generation, generation)

        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .ok, successful: ["prefs"]),
            why: .user,
            floorpNotesGeneration: generation,
            requestSequence: try XCTUnwrap(newerContext.requestSequence)
        )
        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .networkError),
            why: .user,
            floorpNotesGeneration: generation,
            requestSequence: try XCTUnwrap(olderContext.requestSequence)
        )
        XCTAssertTrue(retries.workItems.isEmpty)

        let thirdContext = FloorpNotesSyncExecutionContext()
        let fourthContext = FloorpNotesSyncExecutionContext()
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: thirdContext
        )
        _ = rustSyncManager.prepareSyncParamsForExecution(
            makeSyncParams(engines: ["prefs"]),
            lifecycleGeneration: lifecycleGeneration,
            accountID: "account-a",
            expectedFloorpNotesGeneration: nil,
            executionContext: fourthContext
        )
        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .networkError),
            why: .user,
            floorpNotesGeneration: generation,
            requestSequence: try XCTUnwrap(thirdContext.requestSequence)
        )
        rustSyncManager.handleFloorpNotesSyncResult(
            makeSyncResult(status: .ok, successful: ["prefs"]),
            why: .user,
            floorpNotesGeneration: generation,
            requestSequence: try XCTUnwrap(fourthContext.requestSequence)
        )

        XCTAssertEqual(retries.workItems.count, 1)
        XCTAssertTrue(retries.workItems[0].isCancelled)
    }

    func testFinalizeAndCancelAccountRemovalResolveExactlyOnce() {
        let finalizeStarted = DispatchSemaphore(value: 0)
        let allowFinalize = DispatchSemaphore(value: 0)
        let finalizeFinished = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let provider = TestFloorpNotesSyncEngineProvider(
            finalizeStarted: finalizeStarted,
            allowFinalize: allowFinalize
        )
        rustSyncManager.installFloorpNotesSyncEngineProvider(provider)
        _ = rustSyncManager.onRemovedAccount()

        DispatchQueue.global(qos: .userInitiated).async { [rustSyncManager] in
            _ = rustSyncManager.finalizeAccountRemoval()
            finalizeFinished.signal()
        }
        XCTAssertEqual(finalizeStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async { [rustSyncManager] in
            rustSyncManager.cancelAccountRemoval()
            cancelFinished.signal()
        }
        XCTAssertEqual(
            cancelFinished.wait(timeout: .now() + 0.1),
            .timedOut
        )

        allowFinalize.signal()
        XCTAssertEqual(finalizeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(provider.finalizeDisconnectCallCount, 1)
        XCTAssertEqual(provider.cancelDisconnectCallCount, 0)
    }

    private func makeSyncParams(
        engines: [String],
        tokenServerURL: String = "https://token.services.mozilla.com/1.0/sync/1.5"
    ) -> SyncParams {
        SyncParams(
            reason: .user,
            engines: SyncEngineSelection.some(engines: engines),
            enabledChanges: [:],
            localEncryptionKeys: [:],
            authInfo: SyncAuthInfo(
                kid: "test-kid",
                fxaAccessToken: "test-token",
                syncKey: "test-key",
                tokenserverUrl: tokenServerURL
            ),
            persistedState: nil,
            deviceSettings: DeviceSettings(
                fxaDeviceId: "test-device",
                name: "test-device",
                kind: .mobile
            )
        )
    }

    private func makeSyncResult(
        status: ServiceStatus,
        successful: [String] = []
    ) -> SyncResult {
        SyncResult(
            status: status,
            successful: successful,
            failures: [:],
            persistedState: "",
            declined: nil,
            nextSyncAllowedAt: nil,
            telemetryJson: nil
        )
    }
}

private final class TestFloorpNotesSyncEngineProvider:
    FloorpNotesSyncEngineProviding,
    @unchecked Sendable {
    private(set) var invalidateCallCount = 0
    private(set) var registeredAccountID: String?
    private(set) var registerCallCount = 0
    private(set) var prepareForDisconnectCallCount = 0
    private(set) var finalizeDisconnectCallCount = 0
    private(set) var cancelDisconnectCallCount = 0
    private let disconnectAvailability: FloorpNotesSyncAccountAvailability
    private let cancelDisconnectResult: Bool
    private let finalizeStarted: DispatchSemaphore?
    private let allowFinalize: DispatchSemaphore?
    private let finalizeShouldFail: Bool
    private var allowsSyncValue = true

    init(
        disconnectAvailability: FloorpNotesSyncAccountAvailability = .available,
        cancelDisconnectResult: Bool = true,
        finalizeStarted: DispatchSemaphore? = nil,
        allowFinalize: DispatchSemaphore? = nil,
        finalizeShouldFail: Bool = false
    ) {
        self.disconnectAvailability = disconnectAvailability
        self.cancelDisconnectResult = cancelDisconnectResult
        self.finalizeStarted = finalizeStarted
        self.allowFinalize = allowFinalize
        self.finalizeShouldFail = finalizeShouldFail
    }

    func resumePendingDisconnectCleanup() throws {}

    func allowsSync(accountID: String) -> Bool {
        allowsSyncValue
    }

    func register(accountID: String) throws {
        registerCallCount += 1
        registeredAccountID = accountID
    }

    func setAllowsSync(_ allowsSync: Bool) {
        allowsSyncValue = allowsSync
    }

    func prepareForDisconnect(
        accountID: String?
    ) throws -> FloorpNotesSyncAccountAvailability {
        prepareForDisconnectCallCount += 1
        return disconnectAvailability
    }

    func finalizeDisconnect() throws {
        finalizeDisconnectCallCount += 1
        finalizeStarted?.signal()
        allowFinalize?.wait()
        if finalizeShouldFail {
            throw TestFloorpNotesProviderError.finalize
        }
    }

    func cancelDisconnect() -> Bool {
        cancelDisconnectCallCount += 1
        return cancelDisconnectResult
    }

    func invalidate() {
        invalidateCallCount += 1
        registeredAccountID = nil
    }
}

private enum TestFloorpNotesProviderError: Error {
    case finalize
}

private final class PostLogoutFailureSyncManager: SyncManager, @unchecked Sendable {
    private(set) var finalizeAccountRemovalCallCount = 0
    var isSyncing = false
    var lastSyncFinishTime: Timestamp?
    var syncDisplayState: SyncDisplayState?

    func syncTabs() -> Deferred<Maybe<SyncResult>> { Deferred() }
    func syncHistory() -> Deferred<Maybe<SyncResult>> { Deferred() }
    func syncNamedCollections(
        why: SyncReason,
        names: [String]
    ) -> Deferred<Maybe<SyncResult>> {
        Deferred()
    }
    func syncPostSyncSettingsChange(why: SyncReason, names: [String]) {}
    func reportOpenSyncSettingsMenuTelemetry() {}
    func syncEverything(why: SyncReason) -> Success { succeed() }
    func endTimedSyncs() {}
    func applicationDidBecomeActive() {}
    func applicationDidEnterBackground() {}
    func checkCreditCardEngineEnablement() -> Bool { false }
    func onRemovedAccount() -> Success { succeed() }
    func finalizeAccountRemoval() -> Success {
        finalizeAccountRemovalCallCount += 1
        return deferMaybe(PostLogoutNotesCleanupError())
    }
    func cancelAccountRemoval() {}
    func onAddedAccount() -> Success { succeed() }
}

private struct PostLogoutNotesCleanupError: MaybeErrorType {
    let description = "Expected Notes cleanup failure after logout."
}

private final class FloorpNotesRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWorkItems = [DispatchWorkItem]()

    var workItems: [DispatchWorkItem] {
        lock.withLock { recordedWorkItems }
    }

    func record(_: TimeInterval, _ workItem: DispatchWorkItem) {
        lock.withLock { recordedWorkItems.append(workItem) }
    }
}

private final class FloorpNotesPolicyCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues = [String]()

    var values: [String] {
        lock.withLock { recordedValues }
    }

    func record(_ value: String) {
        lock.withLock { recordedValues.append(value) }
    }
}

private typealias RustSyncTestBlock = @Sendable @convention(block) () -> Void

private final class SyncRequestRecorder: @unchecked Sendable {
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

private final class ControllableRustSyncDispatchQueue:
    DispatchQueueInterface,
    @unchecked Sendable {
    private let lock = NSLock()
    private var pending = [RustSyncTestBlock]()

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func runNext() {
        let work: RustSyncTestBlock = lock.withLock {
            precondition(!pending.isEmpty)
            return pending.removeFirst()
        }
        work()
    }

    func async(
        group: DispatchGroup?,
        qos: DispatchQoS,
        flags: DispatchWorkItemFlags,
        execute work: @escaping RustSyncTestBlock
    ) {
        lock.withLock { pending.append(work) }
    }

    func asyncAfter(deadline: DispatchTime, execute workItem: DispatchWorkItem) {
        let workItemBox = RustSyncDispatchWorkItemBox(workItem)
        async(group: nil, qos: .unspecified, flags: []) {
            workItemBox.workItem.perform()
        }
    }

    func asyncAfter(
        deadline: DispatchTime,
        qos: DispatchQoS,
        flags: DispatchWorkItemFlags,
        execute work: @escaping RustSyncTestBlock
    ) {
        async(group: nil, qos: qos, flags: flags, execute: work)
    }

    func ensureMainThread(execute work: @escaping () -> Void) {
        work()
    }
}

private final class RustSyncDispatchWorkItemBox: @unchecked Sendable {
    let workItem: DispatchWorkItem

    init(_ workItem: DispatchWorkItem) {
        self.workItem = workItem
    }
}

private final class TestRustSyncManagerComponent:
    RustSyncManagerComponentProtocol,
    @unchecked Sendable {
    private let lock = NSLock()
    private var checkedDisconnectCalls = 0
    private var syncCalls = 0
    private var recordedSyncEngines = [SyncEngineSelection]()
    private let syncStarted: DispatchSemaphore?
    private let allowSyncToFinish: DispatchSemaphore?
    private let checkedDisconnectStarted: DispatchSemaphore?
    private let allowCheckedDisconnect: DispatchSemaphore?
    private let checkedDisconnectShouldFail: Bool

    init(
        syncStarted: DispatchSemaphore? = nil,
        allowSyncToFinish: DispatchSemaphore? = nil,
        checkedDisconnectStarted: DispatchSemaphore? = nil,
        allowCheckedDisconnect: DispatchSemaphore? = nil,
        checkedDisconnectShouldFail: Bool = false
    ) {
        self.syncStarted = syncStarted
        self.allowSyncToFinish = allowSyncToFinish
        self.checkedDisconnectStarted = checkedDisconnectStarted
        self.allowCheckedDisconnect = allowCheckedDisconnect
        self.checkedDisconnectShouldFail = checkedDisconnectShouldFail
    }

    var checkedDisconnectCallCount: Int {
        lock.withLock { checkedDisconnectCalls }
    }

    var syncCallCount: Int {
        lock.withLock { syncCalls }
    }

    var syncEngineSelections: [SyncEngineSelection] {
        lock.withLock { recordedSyncEngines }
    }

    func disconnect() {}

    func disconnectChecked() throws {
        lock.withLock { checkedDisconnectCalls += 1 }
        checkedDisconnectStarted?.signal()
        allowCheckedDisconnect?.wait()
        if checkedDisconnectShouldFail {
            throw TestRustSyncManagerComponentError.checkedDisconnect
        }
    }

    func sync(params: SyncParams) throws -> SyncResult {
        lock.withLock {
            syncCalls += 1
            recordedSyncEngines.append(params.engines)
        }
        syncStarted?.signal()
        allowSyncToFinish?.wait()
        return SyncResult(
            status: .ok,
            successful: [],
            failures: [:],
            persistedState: "",
            declined: nil,
            nextSyncAllowedAt: nil,
            telemetryJson: nil
        )
    }

    func getAvailableEngines() -> [String] {
        []
    }
}

private enum TestRustSyncManagerComponentError: Error {
    case checkedDisconnect
}
