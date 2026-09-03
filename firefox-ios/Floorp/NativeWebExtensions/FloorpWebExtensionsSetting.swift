// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

@MainActor
protocol FloorpWebExtensionsSettingsDelegate: AnyObject {
    func pressedWebExtensions()
}

@MainActor
final class FloorpWebExtensionsSetting: Setting {
    private weak var settingsDelegate: (any FloorpWebExtensionsSettingsDelegate)?

    override var accessoryView: UIImageView? {
        guard let theme else { return nil }
        return SettingDisclosureUtility.buildDisclosureIndicator(theme: theme)
    }

    override var accessibilityIdentifier: String? {
        "Floorp.WebExtensions.Settings.Entry"
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(
            string: FloorpStrings.WebExtensions.introMessage,
            attributes: [.foregroundColor: theme.colors.textSecondary]
        )
    }

    init(
        settings: SettingsTableViewController,
        settingsDelegate: (any FloorpWebExtensionsSettingsDelegate)?
    ) {
        self.settingsDelegate = settingsDelegate
        let theme = settings.currentTheme()
        super.init(
            title: NSAttributedString(
                string: FloorpStrings.WebExtensions.title,
                attributes: [.foregroundColor: theme.colors.textPrimary]
            )
        )
    }

    override func onClick(_ navigationController: UINavigationController?) {
        settingsDelegate?.pressedWebExtensions()
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        let symbol = UIImage(systemName: "puzzlepiece.extension.fill")
            ?? UIImage(systemName: "puzzlepiece.fill")
        cell.imageView?.image = symbol?.withRenderingMode(.alwaysTemplate)
        cell.imageView?.tintColor = theme.colors.iconAccent
    }
}
