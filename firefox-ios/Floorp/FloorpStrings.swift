// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Strings
// Localized string keys for Floorp features.
// Follows Firefox iOS pattern of struct-based string organization.
//
// This file is part of the Floorp customization layer.

import Foundation

/// Centralized localization strings for Floorp features.
///
/// Uses `NSLocalizedString` with a `Floorp` table name to keep
/// Floorp strings separate from Firefox's main string table.
///
/// ## Adding new strings:
/// 1. Add a static property here with a unique key and version suffix
/// 2. Add the localized value in `Floorp.strings` (or `Floorp.stringsdict`)
/// 3. Use `FloorpStrings.Section.propertyName` in code
///
/// ## Naming convention:
/// - Key format: `Floorp.<Section>.<Name>.v<Version>`
/// - Example: `Floorp.Drawer.Title.v1`
enum FloorpStrings {
    // MARK: - Overlay Drawer

    enum Drawer {
        static let title = NSLocalizedString(
            "Floorp.Drawer.Title.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Floorp",
            comment: "Title displayed at the top of the overlay drawer"
        )

        static let closeAccessibilityLabel = NSLocalizedString(
            "Floorp.Drawer.CloseAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Close drawer",
            comment: "Accessibility label for the close button in the overlay drawer"
        )

        static let bookmarksTab = NSLocalizedString(
            "Floorp.Drawer.BookmarksTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Bookmarks",
            comment: "Tab title for the bookmarks section in the overlay drawer"
        )

        static let historyTab = NSLocalizedString(
            "Floorp.Drawer.HistoryTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "History",
            comment: "Tab title for the history section in the overlay drawer"
        )

        static let noItemsFound = NSLocalizedString(
            "Floorp.Drawer.NoItemsFound.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "No items found",
            comment: "Empty state message when no bookmarks or history items are found"
        )

        static let retryButton = NSLocalizedString(
            "Floorp.Drawer.RetryButton.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Retry",
            comment: "Button label to retry loading bookmarks or history"
        )

        static let bookmarksLoadError = NSLocalizedString(
            "Floorp.Drawer.BookmarksLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load bookmarks",
            comment: "Error message when bookmarks fail to load"
        )

        static let historyLoadError = NSLocalizedString(
            "Floorp.Drawer.HistoryLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load history",
            comment: "Error message when history fails to load"
        )

        static let downloadsTab = NSLocalizedString(
            "Floorp.Drawer.DownloadsTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Downloads",
            comment: "Tab title for the downloads section in the overlay drawer"
        )

        static let downloadsLoadError = NSLocalizedString(
            "Floorp.Drawer.DownloadsLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load downloads",
            comment: "Error message when downloads fail to load"
        )

        static let noDownloads = NSLocalizedString(
            "Floorp.Drawer.NoDownloads.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "No downloads yet",
            comment: "Empty state message when no downloads are found"
        )

        static let searchPlaceholder = NSLocalizedString(
            "Floorp.Drawer.SearchPlaceholder.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Search…",
            comment: "Placeholder text for the search field in the overlay drawer"
        )

        static let searchFieldAccessibility = NSLocalizedString(
            "Floorp.Drawer.SearchFieldAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Search items",
            comment: "Accessibility label for the search field in the overlay drawer"
        )

        static let clearSearchAccessibility = NSLocalizedString(
            "Floorp.Drawer.ClearSearchAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Clear search",
            comment: "Accessibility label for the clear search button"
        )

        static let panelSidebarAccessibility = NSLocalizedString(
            "Floorp.Drawer.PanelSidebarAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Panel sidebar",
            comment: "Accessibility label for the vertical icon sidebar"
        )

        static let openInNewTab = NSLocalizedString(
            "Floorp.Drawer.OpenInNewTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Open in New Tab",
            comment: "Context menu option to open an item in a new tab"
        )

        static let openInPrivateTab = NSLocalizedString(
            "Floorp.Drawer.OpenInPrivateTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Open in Private Tab",
            comment: "Context menu option to open an item in a private tab"
        )

        static let deleteItem = NSLocalizedString(
            "Floorp.Drawer.DeleteItem.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Delete",
            comment: "Context menu option to delete an item"
        )
    }
}
