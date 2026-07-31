// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import XCTest

class SupportUtilsTests: XCTestCase {
    func testConfiguredSharedContainerIdentifierOverridesDerivedIdentifier() {
        XCTAssertEqual(
            AppInfo.resolvedSharedContainerIdentifier(
                configuredIdentifier: " group.app.floorp.Floorp.DV2U35YBHT ",
                baseBundleIdentifier: "app.floorp.Floorp"
            ),
            "group.app.floorp.Floorp.DV2U35YBHT"
        )
    }

    func testSharedContainerIdentifierFallsBackToBundleIdentifier() {
        XCTAssertEqual(
            AppInfo.resolvedSharedContainerIdentifier(
                configuredIdentifier: "  ",
                baseBundleIdentifier: "app.floorp.Floorp"
            ),
            "group.app.floorp.Floorp"
        )
        XCTAssertEqual(
            AppInfo.resolvedSharedContainerIdentifier(
                configuredIdentifier: nil,
                baseBundleIdentifier: "org.mozilla.ios.FennecEnterprise"
            ),
            "group.org.mozilla.ios.Fennec.enterprise"
        )
    }

    func testURLForTopic() {
        let appVersion = AppInfo.appVersion
        let languageIdentifier = Locale.preferredLanguages.first!
        XCTAssertEqual(SupportUtils.URLForTopic("Bacon")?.absoluteString, "https://support.mozilla.org/1/mobile/\(appVersion)/iOS/\(languageIdentifier)/Bacon")
        XCTAssertEqual(SupportUtils.URLForTopic("Cheese & Crackers")?.absoluteString, "https://support.mozilla.org/1/mobile/\(appVersion)/iOS/\(languageIdentifier)/Cheese%20&%20Crackers")
        XCTAssertEqual(SupportUtils.URLForTopic("Möbelträgerfüße")?.absoluteString, "https://support.mozilla.org/1/mobile/\(appVersion)/iOS/\(languageIdentifier)/M%C3%B6beltr%C3%A4gerf%C3%BC%C3%9Fe")
    }

    func testURLForPrivacyNotice_withoutContentParam() {
        let languageIdentifier = Locale.preferredLanguages.first!

        let urlString = SupportUtils.URLForPrivacyNotice(
            source: "modal",
            campaign: "microsurvey",
            content: nil
        )?.absoluteString

        XCTAssertEqual(
            urlString,
            "https://www.mozilla.org/\(languageIdentifier)/privacy/firefox/?utm_medium=firefox-mobile&utm_source=modal&utm_campaign=microsurvey"
        )
    }

    func testURLForPrivacyNotice_withContentParam() {
        let languageIdentifier = Locale.preferredLanguages.first!

        let urlString = SupportUtils.URLForPrivacyNotice(
            source: "modal",
            campaign: "microsurvey",
            content: "homepage"
        )?.absoluteString

        XCTAssertEqual(
            urlString,
            "https://www.mozilla.org/\(languageIdentifier)/privacy/firefox/?utm_medium=firefox-mobile&utm_source=modal&utm_campaign=microsurvey&utm_content=homepage"
        )
    }
}
