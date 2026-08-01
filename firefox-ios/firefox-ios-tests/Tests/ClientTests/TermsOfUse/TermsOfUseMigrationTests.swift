// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Shared
@testable import Client

final class TermsOfUseMigrationTests: XCTestCase {
    func testMigrationActivatesCurrentFloorpTermsPolicy() {
        let mockPrefs = MockProfilePrefs()
        let migration = TermsOfUseMigration(prefs: mockPrefs)

        XCTAssertFalse(migration.isCurrentFloorpTermsPolicyActive)

        migration.migrateToFloorpTermsIfNeeded()

        XCTAssertTrue(migration.isCurrentFloorpTermsPolicyActive)
    }

    func testMigrationClearsInheritedMozillaAcceptanceAndPromptState() {
        let mockPrefs = MockProfilePrefs()
        mockPrefs.setInt(1, forKey: PrefsKeys.TermsOfServiceAccepted)
        let testTimestamp = Date().toTimestamp()
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfServiceAcceptedDate)
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseAccepted)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUseAcceptedDate)
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseFirstShown)
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseShownRecorded)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUseDismissedDate)
        mockPrefs.setInt(4, forKey: PrefsKeys.TermsOfUseImpressionCount)
        mockPrefs.setInt(2, forKey: PrefsKeys.TermsOfUseRemindMeLaterCount)
        mockPrefs.setInt(1, forKey: PrefsKeys.TermsOfUseDismissCount)
        mockPrefs.setInt(3, forKey: PrefsKeys.TermsOfUseRemindersCount)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUseRemindMeLaterTapDate)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUseLearnMoreTapDate)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUsePrivacyNoticeTapDate)
        mockPrefs.setTimestamp(testTimestamp, forKey: PrefsKeys.TermsOfUseTermsLinkTapDate)
        mockPrefs.setString("mozilla-experiment", forKey: PrefsKeys.TermsOfUseExperimentKey)
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseExperimentTrackingInitialized)

        TermsOfUseMigration(prefs: mockPrefs).migrateToFloorpTermsIfNeeded()

        XCTAssertNil(mockPrefs.intForKey(PrefsKeys.TermsOfServiceAccepted))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfServiceAcceptedDate))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseAccepted))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseAcceptedDate))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseFirstShown))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseShownRecorded))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseDismissedDate))
        XCTAssertNil(mockPrefs.intForKey(PrefsKeys.TermsOfUseImpressionCount))
        XCTAssertNil(mockPrefs.intForKey(PrefsKeys.TermsOfUseRemindMeLaterCount))
        XCTAssertNil(mockPrefs.intForKey(PrefsKeys.TermsOfUseDismissCount))
        XCTAssertNil(mockPrefs.intForKey(PrefsKeys.TermsOfUseRemindersCount))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseRemindMeLaterTapDate))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseLearnMoreTapDate))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUsePrivacyNoticeTapDate))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseTermsLinkTapDate))
        XCTAssertNil(mockPrefs.stringForKey(PrefsKeys.TermsOfUseExperimentKey))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseExperimentTrackingInitialized))
    }

    func testMigrationLeavesAcceptanceNilSoFloorpTermsAreEligibleForPresentation() {
        let mockPrefs = MockProfilePrefs()
        mockPrefs.setInt(1, forKey: PrefsKeys.TermsOfServiceAccepted)

        TermsOfUseMigration(prefs: mockPrefs).migrateToFloorpTermsIfNeeded()

        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseAccepted))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseFirstShown))
    }

    func testMigrationOnFreshInstallLeavesFloorpPromptStateUnset() {
        let mockPrefs = MockProfilePrefs()

        TermsOfUseMigration(prefs: mockPrefs).migrateToFloorpTermsIfNeeded()

        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseAccepted))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseAcceptedDate))
        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseFirstShown))
        XCTAssertNil(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseDismissedDate))
    }

    func testRepeatedMigrationPreservesFloorpAcceptance() {
        let mockPrefs = MockProfilePrefs()
        let migration = TermsOfUseMigration(prefs: mockPrefs)
        migration.migrateToFloorpTermsIfNeeded()

        let acceptedTimestamp = Date().toTimestamp()
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseAccepted)
        mockPrefs.setTimestamp(acceptedTimestamp, forKey: PrefsKeys.TermsOfUseAcceptedDate)

        migration.migrateToFloorpTermsIfNeeded()

        XCTAssertTrue(mockPrefs.boolForKey(PrefsKeys.TermsOfUseAccepted) ?? false)
        XCTAssertEqual(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseAcceptedDate), acceptedTimestamp)
    }

    func testRepeatedMigrationPreservesFloorpPromptStateBeforeAcceptance() {
        let mockPrefs = MockProfilePrefs()
        let migration = TermsOfUseMigration(prefs: mockPrefs)
        migration.migrateToFloorpTermsIfNeeded()

        let dismissedTimestamp = Date().toTimestamp()
        mockPrefs.setBool(true, forKey: PrefsKeys.TermsOfUseFirstShown)
        mockPrefs.setTimestamp(dismissedTimestamp, forKey: PrefsKeys.TermsOfUseDismissedDate)
        mockPrefs.setInt(1, forKey: PrefsKeys.TermsOfUseRemindersCount)

        migration.migrateToFloorpTermsIfNeeded()

        XCTAssertNil(mockPrefs.boolForKey(PrefsKeys.TermsOfUseAccepted))
        XCTAssertEqual(mockPrefs.boolForKey(PrefsKeys.TermsOfUseFirstShown), true)
        XCTAssertEqual(mockPrefs.timestampForKey(PrefsKeys.TermsOfUseDismissedDate), dismissedTimestamp)
        XCTAssertEqual(mockPrefs.intForKey(PrefsKeys.TermsOfUseRemindersCount), 1)
    }
}
