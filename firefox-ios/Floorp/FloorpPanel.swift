// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Overlay Drawer - Panel Data Model
// Represents a single panel in the overlay drawer (bookmarks, history, downloads, notes, web, etc.).
//
// Inspired by Floorp desktop's Panel Sidebar architecture:
// - Vertical icon sidebar for panel switching (matching desktop layout)
// - Multiple panel types: bookmarks, history, downloads, notes, web
// - Per-panel icon and title configuration
// - Persistent panel order and selection state

import Foundation

// MARK: - Panel Types

/// Types of panels that can be displayed in the overlay drawer.
///
/// Mirrors Floorp desktop's static panel types with iOS-appropriate additions.
enum FloorpPanelType: String, Codable, CaseIterable {
    /// Built-in bookmarks panel (desktop: `floorp//bookmarks`)
    case bookmarks
    /// Built-in browsing history panel (desktop: `floorp//history`)
    case history
    /// Built-in downloads panel (desktop: `floorp//downloads`)
    case downloads
    /// Built-in Floorp Notes panel (desktop: `floorp//notes`)
    case notes
    /// Custom web panel loading an arbitrary URL (desktop: `web` type)
    case web
}

// MARK: - Panel Icon Mapping

extension FloorpPanelType {
    /// SF Symbol name for this panel type, used in the vertical icon sidebar.
    var systemIconName: String {
        switch self {
        case .bookmarks: return "book"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .notes: return "note.text"
        case .web: return "globe"
        }
    }

    /// Built-in labels are resolved at render time so an app language change
    /// is not masked by the localized title persisted in an older session.
    var localizedBuiltInTitle: String? {
        switch self {
        case .bookmarks: return FloorpStrings.Drawer.bookmarksTab
        case .history: return FloorpStrings.Drawer.historyTab
        case .downloads: return FloorpStrings.Drawer.downloadsTab
        case .notes: return FloorpStrings.Notes.panelTitle
        case .web: return nil
        }
    }
}

// MARK: - Panel Model

/// A single panel configuration in the overlay drawer.
///
/// Inspired by Floorp desktop's Panel data model, adapted for iOS.
/// Panels are persisted to UserDefaults as JSON, following the desktop pattern
/// of `floorp.panel.sidebar.data`.
struct FloorpPanel: Codable, Identifiable, Equatable {
    /// Unique identifier for this panel.
    /// Desktop uses `floorp//<name>` format (e.g., `floorp//bookmarks`).
    let id: String

    /// The type of panel content.
    let type: FloorpPanelType

    /// Display name shown in the panel header and accessibility labels.
    /// For static panels, this is auto-generated from localized strings.
    var title: String

    /// URL to load (only for `.web` type panels).
    var url: String?

    /// Icon name or SF Symbol name for the panel button in the sidebar.
    var iconName: String

    /// Sort order index (0 = first/top).
    var sortOrder: Int

    // MARK: - Factory Methods

    /// Creates the default set of static panels matching Floorp desktop defaults.
    ///
    /// Desktop default order: bookmarks, history, downloads, notes.
    static func defaultPanels() -> [FloorpPanel] {
        return [
            FloorpPanel(
                id: "floorp//bookmarks",
                type: .bookmarks,
                title: FloorpStrings.Drawer.bookmarksTab,
                url: nil,
                iconName: FloorpPanelType.bookmarks.systemIconName,
                sortOrder: 0
            ),
            FloorpPanel(
                id: "floorp//history",
                type: .history,
                title: FloorpStrings.Drawer.historyTab,
                url: nil,
                iconName: FloorpPanelType.history.systemIconName,
                sortOrder: 1
            ),
            FloorpPanel(
                id: "floorp//downloads",
                type: .downloads,
                title: FloorpStrings.Drawer.downloadsTab,
                url: nil,
                iconName: FloorpPanelType.downloads.systemIconName,
                sortOrder: 2
            ),
            FloorpPanel(
                id: "floorp//notes",
                type: .notes,
                title: FloorpStrings.Notes.panelTitle,
                url: nil,
                iconName: FloorpPanelType.notes.systemIconName,
                sortOrder: 3
            ),
        ]
    }
}

// MARK: - Drawer Item (display model)

/// A single item displayed in the drawer's content list.
///
/// Represents a bookmark, history entry, or download item with
/// display metadata for the table view cell.
enum DrawerItemSource {
    case bookmark(guid: String)
    case history(url: String)
    case download(fileURL: URL)
    case note(id: String)
    case none
}

struct DrawerItem: Identifiable {
    let id: String
    let title: String
    let url: String?
    let icon: UIImage?
    let subtitle: String?
    let searchText: String?

    /// Carries the item's identity and operation target independently of the
    /// currently selected panel, preventing cross-panel deletion races.
    let source: DrawerItemSource

    init(
        id: String,
        title: String,
        url: String? = nil,
        icon: UIImage? = nil,
        subtitle: String? = nil,
        searchText: String? = nil,
        source: DrawerItemSource = .none
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.icon = icon
        self.subtitle = subtitle
        self.searchText = searchText
        self.source = source
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }
        let searchableText = [title, searchText ?? subtitle ?? ""].joined(separator: "\n")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return tokens.allSatisfy {
            searchableText.range(of: $0, options: options, locale: .current) != nil
        }
    }
}

// MARK: - Drawer Configuration

/// Global configuration for the overlay drawer.
///
/// Mirrors Floorp desktop's `floorp.panel.sidebar.config` preferences,
/// adapted for iOS (no floating mode, no position_start toggle).
struct FloorpOverlayDrawerConfig: Codable, Equatable {
    /// Whether the drawer is enabled.
    var isEnabled = true

    /// The ID of the currently selected panel.
    var selectedPanelId: String?

    /// Ordered list of panel IDs.
    /// Desktop stores this in `floorp.panel.sidebar.data`.
    var panelOrder: [String] = [
        "floorp//bookmarks", "floorp//history", "floorp//downloads", "floorp//notes"
    ]

    /// Whether the drawer is currently visible.
    var isDisplayed = false

    /// Width of the icon sidebar column in points.
    /// Desktop: 42px (compact), 60px (touch). iOS uses 50px.
    var sidebarWidth = 50
}
