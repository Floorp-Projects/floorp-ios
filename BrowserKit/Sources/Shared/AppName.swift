// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import UIKit

public enum AppName: String, CustomStringConvertible {
    case shortName = "Floorp"

    public var description: String {
        return self.rawValue
    }
}

/// Canonical Floorp names and public endpoints.
///
/// Keep these values aligned with the desktop `floorp-official` branding.
/// Mozilla service names (for example Firefox Sync and Pocket) remain separate.
public enum FloorpBrand {
    public static let marketingName = "Floorp Browser"
    public static let fullName = "Ablaze Floorp"
    public static let vendorName = "Ablaze"
    public static let projectName = "Floorp Projects"

    public static let officialWebsiteURL = URL(string: "https://floorp.app")
    public static let termsOfUseURL = URL(string: "https://floorp.app/terms")
    public static let privacyNoticeURL = URL(string: "https://floorp.app/privacy")

    /// Settings > Help destination for the iOS app. Replace this central value
    /// when a dedicated Floorp iOS support site is published.
    public static let iOSHelpURL = URL(
        string: "https://github.com/Floorp-Projects/floorp-ios#readme"
    )

    /// Supplemental information linked from the Terms of Use prompt. Floorp
    /// currently has no separate legal-update FAQ, so the canonical Terms page
    /// is used with an in-product campaign URL that remains distinct for link classification.
    public static let termsOfUseLearnMoreURL = URL(
        string: "https://floorp.app/terms?utm_source=floorp-ios&utm_medium=in-product&utm_campaign=terms-of-use"
    )

    public static let releaseNotesURL = URL(
        string: "https://blog.floorp.app/en/categories/release/"
    )
    public static let feedbackURL = URL(
        string: "https://github.com/Floorp-Projects/floorp-ios/issues/new/choose"
    )
}

public enum PocketAppName: String, CustomStringConvertible {
    case shortName = "Pocket"

    public var description: String {
        return self.rawValue
    }
}

public enum MozillaName: String, CustomStringConvertible {
    case shortName = "Mozilla"

    public var description: String {
        return self.rawValue
    }
}

public enum KVOConstants: String, Sendable {
    case loading
    case estimatedProgress
    case URL
    case title
    case canGoBack
    case canGoForward
    case contentSize
    case hasOnlySecureContent
}
