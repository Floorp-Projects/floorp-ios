// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

/// A non-live admission check for the protected G5 XCTest selector.
///
/// This policy only interprets serialized test-runner environment facts. It
/// does not launch an app, contact a service, or authorize a production run.
enum FloorpNotesSyncG5LaunchPolicy {
    private static let requiredIntentFlags = [
        "FLOORP_NOTES_SYNC_G5_RUN",
        "FLOORP_NOTES_SYNC_PRODUCTION_QA",
    ]

    private static let rejectedEndpointEnvironmentKeys: Set<String> = [
        "FIREFOX_USE_STAGE_SERVER",
        "CUSTOM_FXA_SERVER",
        "CUSTOM_SYNC_TOKEN_SERVER",
        "FIREFOX_FXA_CHINA_SERVER",
        "FIREFOX_USE_CHINA_SYNC_SERVICE",
        "FIREFOX_FXA_CONTENT_SERVER",
        "FIREFOX_SYNC_TOKEN_SERVER",
        "FIREFOX_USE_CUSTOM_FXA_CONTENT_SERVER",
        "FIREFOX_USE_CUSTOM_SYNC_TOKEN_SERVER",
    ]

    static func allows(environment: [String: String]) -> Bool {
        guard requiredIntentFlags.allSatisfy({ environment[$0] == "1" }) else {
            return false
        }

        let notesSyncEnvironmentKeys = environment.keys.filter {
            $0.hasPrefix("FLOORP_NOTES_SYNC_")
        }
        guard Set(notesSyncEnvironmentKeys) == Set(requiredIntentFlags) else {
            return false
        }

        return rejectedEndpointEnvironmentKeys.isDisjoint(with: Set(environment.keys))
    }
}
