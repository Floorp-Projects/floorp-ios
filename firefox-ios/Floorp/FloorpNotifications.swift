// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

// MARK: - Floorp Notification Names
extension Notification.Name {
    /// Posted when the Floorp overlay drawer toolbar button is tapped.
    /// userInfo contains "windowUUID" with the WindowUUID value.
    static let FloorpToggleDrawer = Notification.Name("FloorpToggleDrawer")
}
