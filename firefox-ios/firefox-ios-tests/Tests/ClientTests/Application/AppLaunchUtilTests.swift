// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import XCTest

@testable import Client

@MainActor
final class AppLaunchUtilTests: XCTestCase {
    var profile: MockProfile!

    override func setUp() async throws {
        try await super.setUp()
        DependencyHelperMock().bootstrapDependencies()
        TelemetryContextualIdentifier.clearUserDefaults()
        profile = MockProfile()
        LegacyFeatureFlagsManager.shared.initializeDeveloperFeatures(with: profile)
    }

    override func tearDown() async throws {
        FloorpFlags.setTelemetryDisabled(false)
        FloorpFlags.setSponsoredShortcutsDisabled(false)
        FloorpFlags.setAdAttributionDisabled(false)
        DependencyHelperMock().reset()
        TelemetryContextualIdentifier.clearUserDefaults()
        profile = nil
        try await super.tearDown()
    }

    // MARK: Telemetry contextual identifier setup

    func testGivenTosEnabled_WhenTosAccepted_ThenContextIdIsSet() {
        profile.prefs.setInt(1, forKey: PrefsKeys.TermsOfServiceAccepted)
        setupNimbusToSForTesting(isEnabled: true)
        let subject = createSubject()
        subject.setUpPreLaunchDependencies()

        XCTAssertNotNil(TelemetryContextualIdentifier.contextId)
    }

    func testGivenTosEnabled_WhenTosNotAccepted_ThenContextIdIsSet() {
        profile.prefs.setInt(0, forKey: PrefsKeys.TermsOfServiceAccepted)
        setupNimbusToSForTesting(isEnabled: true)
        let subject = createSubject()
        subject.setUpPreLaunchDependencies()

        XCTAssertNotNil(TelemetryContextualIdentifier.contextId)
    }

    func testGivenTosDisabled_ThenContextIdIsSet() {
        setupNimbusToSForTesting(isEnabled: false)
        let subject = createSubject()
        subject.setUpPreLaunchDependencies()

        XCTAssertNotNil(TelemetryContextualIdentifier.contextId)
    }

    func testGivenFloorpSponsoredContentDisabled_WhenTosNotAccepted_ThenContextIdIsNotSet() {
        FloorpFlags.setSponsoredShortcutsDisabled(true)
        profile.prefs.setInt(0, forKey: PrefsKeys.TermsOfServiceAccepted)
        setupNimbusToSForTesting(isEnabled: true)

        createSubject().setUpPreLaunchDependencies()

        XCTAssertNil(TelemetryContextualIdentifier.contextId)
        XCTAssertEqual(profile.prefs.boolForKey(PrefsKeys.FeatureFlags.SponsoredShortcuts), false)
        XCTAssertEqual(profile.prefs.boolForKey(PrefsKeys.GoogleTopSiteHideKey), true)
    }

    func testFloorpDataCollectionPolicyPersistsAllDisabledPreferences() {
        FloorpFlags.setTelemetryDisabled(true)
        let manager = TermsOfServiceManager(prefs: profile.prefs)

        manager.enforceFloorpDataCollectionPreferences()

        [
            AppConstants.prefSendUsageData,
            AppConstants.prefSendDailyUsagePing,
            AppConstants.prefStudiesToggle,
            AppConstants.prefRolloutsToggle,
            AppConstants.prefSendCrashReports
        ].forEach {
            XCTAssertEqual(profile.prefs.boolForKey($0), false, "\($0) should be disabled")
        }
    }

    // MARK: Helper methods

    func createSubject() -> AppLaunchUtil {
        let subject = AppLaunchUtil(profile: profile)
        return subject
    }

    private func setupNimbusToSForTesting(isEnabled: Bool) {
        FxNimbus.shared.features.tosFeature.with { _, _ in
            return TosFeature(
                status: isEnabled
            )
        }
    }
}
