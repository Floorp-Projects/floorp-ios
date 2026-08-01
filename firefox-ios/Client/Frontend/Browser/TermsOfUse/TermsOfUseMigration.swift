// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Shared

struct TermsOfUseMigration {
    private enum FloorpTerms {
        /// Bump this value whenever an existing acceptance must not carry over
        /// to a new set of Floorp legal documents.
        static let currentMigrationVersion: Int32 = 1
        static let migrationVersionKey = "app.floorp.terms.acceptanceMigrationVersion"
    }

    private let prefs: Prefs

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    var isCurrentFloorpTermsPolicyActive: Bool {
        let migratedVersion = prefs.intForKey(FloorpTerms.migrationVersionKey) ?? 0
        return migratedVersion >= FloorpTerms.currentMigrationVersion
    }

    /// Invalidates inherited Mozilla acceptance and prompt state exactly once.
    ///
    /// The migration marker is written after the reset. A subsequent launch
    /// therefore preserves any Floorp acceptance or dismissal recorded after
    /// this migration ran.
    func migrateToFloorpTermsIfNeeded() {
        let migratedVersion = prefs.intForKey(FloorpTerms.migrationVersionKey) ?? 0
        guard migratedVersion < FloorpTerms.currentMigrationVersion else { return }

        inheritedAcceptanceKeys.forEach { prefs.removeObjectForKey($0) }
        inheritedPromptStateKeys.forEach { prefs.removeObjectForKey($0) }
        prefs.setInt(FloorpTerms.currentMigrationVersion, forKey: FloorpTerms.migrationVersionKey)
    }

    private var inheritedAcceptanceKeys: [String] {
        [
            PrefsKeys.TermsOfServiceAccepted,
            PrefsKeys.TermsOfServiceAcceptedDate,
            PrefsKeys.TermsOfUseAccepted,
            PrefsKeys.TermsOfUseAcceptedDate
        ]
    }

    private var inheritedPromptStateKeys: [String] {
        [
            PrefsKeys.TermsOfUseFirstShown,
            PrefsKeys.TermsOfUseShownRecorded,
            PrefsKeys.TermsOfUseDismissedDate,
            PrefsKeys.TermsOfUseImpressionCount,
            PrefsKeys.TermsOfUseRemindMeLaterCount,
            PrefsKeys.TermsOfUseDismissCount,
            PrefsKeys.TermsOfUseRemindersCount,
            PrefsKeys.TermsOfUseRemindMeLaterTapDate,
            PrefsKeys.TermsOfUseLearnMoreTapDate,
            PrefsKeys.TermsOfUsePrivacyNoticeTapDate,
            PrefsKeys.TermsOfUseTermsLinkTapDate,
            PrefsKeys.TermsOfUseExperimentKey,
            PrefsKeys.TermsOfUseExperimentTrackingInitialized
        ]
    }
}
