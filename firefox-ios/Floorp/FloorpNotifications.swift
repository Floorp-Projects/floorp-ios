// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

enum FloorpPanelRegistryChange: Equatable {
    case webPanelContentWidth(panelID: String)
    case webPanelZoom(panelID: String)
    case webPanelContentMode(panelID: String)
}

enum FloorpPanelRegistryNotification {
    static let changeUserInfoKey = "FloorpPanelRegistryChange"
}

extension Notification {
    var floorpPanelRegistryChange: FloorpPanelRegistryChange? {
        userInfo?[FloorpPanelRegistryNotification.changeUserInfoKey]
            as? FloorpPanelRegistryChange
    }
}

// MARK: - Floorp Notification Names
extension Notification.Name {
    /// Posted when the Floorp overlay drawer toolbar button is tapped.
    /// userInfo contains "windowUUID" with the WindowUUID value.
    static let FloorpToggleDrawer = Notification.Name("FloorpToggleDrawer")

    /// Posted after a local Floorp Notes transaction has been committed.
    static let FloorpNotesDidChange = Notification.Name("FloorpNotesDidChange")

    /// Posted after the profile-wide Floorp panel registry has changed.
    ///
    /// Presentation state remains window-scoped; each visible drawer uses this
    /// notification to reconcile its rail and selected panel against the new
    /// registry without persisting window UI state globally. Preference-only
    /// Web panel changes are identified in `userInfo` so an active WebView is
    /// not detached and rebuilt while the user resizes its pinned drawer or
    /// changes its zoom level or requested content mode.
    static let FloorpPanelRegistryDidChange = Notification.Name("FloorpPanelRegistryDidChange")

    /// Posted after the profile-wide Block Images preference changes.
    ///
    /// Normal browser tabs keep using their existing direct update path. Floorp
    /// Web panels observe this dedicated notification so they can reinstall
    /// content rules without broadening `contentBlockerTabSetupRequired`.
    static let FloorpWebPanelImageBlockingPreferenceDidChange = Notification.Name(
        "FloorpWebPanelImageBlockingPreferenceDidChange"
    )
}
