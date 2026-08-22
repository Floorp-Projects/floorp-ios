// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared

// Sync setting for connecting a Firefox Account. Shown when we don't have an account.
class ConnectSetting: WithoutAccountSetting {
    private weak var settingsDelegate: AccountSettingsDelegate?

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: .Settings.Sync.ButtonTitle,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var accessibilityIdentifier: String? {
        return AccessibilityIdentifiers.Settings.ConnectSetting.title
    }

    init(settings: SettingsTableViewController,
         settingsDelegate: AccountSettingsDelegate?) {
        self.settingsDelegate = settingsDelegate
        super.init(settings: settings)
    }

    override func onClick(_ navigationController: UINavigationController?) {
        TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .signIntoSync)
        settingsDelegate?.pressedConnectSetting()
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        guard let imageView = cell.imageView else { return }
        imageView.subviews.forEach { $0.removeFromSuperview() }
        imageView.frame = CGRect(width: 30, height: 30)
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage.templateImageNamed(StandardImageIdentifiers.Large.logoFloorp)?
            .createScaled(CGSize(width: 30, height: 30))
        imageView.tintColor = theme.colors.textDisabled
        imageView.layer.cornerRadius = 15
        imageView.layer.masksToBounds = true
    }
}
