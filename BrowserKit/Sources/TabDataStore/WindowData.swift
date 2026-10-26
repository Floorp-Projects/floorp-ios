// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

public struct WindowData: Codable, Sendable {
    public let id: UUID
    public let activeTabId: UUID
    public let tabData: [TabData]
    /// Account-free copy receipts remain after a copied tab closes. New snapshots
    /// carry these forward so an older queued save cannot erase a committed copy.
    public let workspaceCopyReceipts: [UUID]?
    public let workspaceCopyReceiptInventoryUncertain: Bool?

    /// Providing default values for id and isPrimary for now
    /// This will change when multi-window support is added
    /// - Parameters:
    ///   - id: a unique ID used to identify the window
    ///   - isPrimary: determines if the window is the primary window
    ///   - activeTabId: the ID of the currently selected tab
    ///   - tabData: a list of all tabs associated with the window
    public init(id: UUID,
                activeTabId: UUID,
                tabData: [TabData],
                workspaceCopyReceipts: [UUID]? = nil,
                workspaceCopyReceiptInventoryUncertain: Bool? = nil) {
        self.id = id
        self.activeTabId = activeTabId
        self.tabData = tabData
        self.workspaceCopyReceipts = workspaceCopyReceipts
        self.workspaceCopyReceiptInventoryUncertain = workspaceCopyReceiptInventoryUncertain
    }
}
