// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared

/// Opens about:rights page in the content view controller
class YourRightsSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: .AppSettingsTermsOfUse,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var url: URL? {
        return SupportUtils.URLForTermsOfUse
    }

    override var accessibilityIdentifier: String? {
        return AccessibilityIdentifiers.Settings.YourRights.title
    }

    weak var settingsDelegate: AboutSettingsDelegate?

    init(settingsDelegate: AboutSettingsDelegate?) {
        self.settingsDelegate = settingsDelegate
    }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let url = self.url,
              let title = self.title else { return }
        settingsDelegate?.pressedYourRights(url: url, title: title)
        return
    }
}
