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
    static let reservedIdentifierPrefix = "floorp//"

    static var builtInIdentifiers: Set<String> {
        Set(defaultPanels().map(\.id))
    }

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

    static func isReservedIdentifier(_ id: String) -> Bool {
        id.hasPrefix(reservedIdentifierPrefix)
    }

    static func canonicalBuiltInPanel(for id: String) -> FloorpPanel? {
        defaultPanels().first { $0.id == id }
    }

    var isBuiltIn: Bool {
        guard let canonicalPanel = Self.canonicalBuiltInPanel(for: id) else { return false }
        return type == canonicalPanel.type
    }

    /// A bounded title that is safe to render in the rail, header, and
    /// accessibility labels. A nil value tells the UI to use its localized
    /// invalid-panel placeholder while retaining the raw title for repair.
    var safeDisplayTitle: String? {
        if isBuiltIn {
            return type.localizedBuiltInTitle
        }
        guard type == .web else { return nil }
        return FloorpWebPanelValidator.safeDisplayTitle(title)
    }
}

// MARK: - Custom Web Panel Validation

/// User-editable values for a custom Web panel. Identity, type, and ordering
/// are deliberately owned by `FloorpPanelManager` rather than the UI.
struct FloorpWebPanelDraft: Equatable {
    var title: String
    var urlText: String
    var iconName: String

    init(title: String, urlText: String, iconName: String = "globe") {
        self.title = title
        self.urlText = urlText
        self.iconName = iconName
    }
}

struct FloorpValidatedWebPanelDraft: Equatable {
    let title: String
    let url: URL
    let iconName: String
}

/// Snapshot of the editable fields used for optimistic concurrency control.
/// Ordering is intentionally excluded so a drag in another window does not
/// invalidate an otherwise independent content edit.
struct FloorpWebPanelRevision: Equatable {
    let title: String
    let url: String?
    let iconName: String

    init(panel: FloorpPanel) {
        title = panel.title
        url = panel.url
        iconName = panel.iconName
    }
}

enum FloorpWebPanelValidationError: Error, Equatable {
    case emptyTitle
    case titleTooLong(maximum: Int)
    case titleContainsControlCharacters
    case emptyURL
    case urlTooLong(maximum: Int)
    case urlContainsControlCharacters
    case invalidURL
    case unsupportedScheme
    case missingHost
    case credentialsNotAllowed
    case unsupportedIcon
}

/// Canonicalizes and validates all values that can eventually reach a Web
/// panel's `WKWebView`. The same policy is used for new drafts and persisted
/// records so storage is never treated as a trust boundary.
struct FloorpWebPanelValidator {
    static let maximumTitleLength = 100
    static let maximumTitleUTF8Length = 4_096
    static let maximumURLLength = 2_048
    static let defaultIconName = "globe"
    static let curatedIconNames = [
        "globe",
        "link",
        "bubble.left",
        "envelope",
        "calendar",
        "doc",
        "play.rectangle",
        "star",
    ]

    private static let allowedSchemes: Set<String> = ["http", "https"]
    private static let allowedIconNames = Set(curatedIconNames)

    static func validate(_ draft: FloorpWebPanelDraft) throws -> FloorpValidatedWebPanelDraft {
        let title = try validatedTitle(draft.title)

        let urlText = draft.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { throw FloorpWebPanelValidationError.emptyURL }
        guard urlText.utf8.count <= maximumURLLength else {
            throw FloorpWebPanelValidationError.urlTooLong(maximum: maximumURLLength)
        }
        guard !containsControlCharacters(urlText) else {
            throw FloorpWebPanelValidationError.urlContainsControlCharacters
        }
        guard allowedIconNames.contains(draft.iconName) else {
            throw FloorpWebPanelValidationError.unsupportedIcon
        }

        let candidate: String
        if urlText.hasPrefix("//") {
            candidate = "https:\(urlText)"
        } else if hasExplicitScheme(urlText) {
            candidate = urlText
        } else {
            candidate = "https://\(urlText)"
        }
        guard candidate.utf8.count <= maximumURLLength else {
            throw FloorpWebPanelValidationError.urlTooLong(maximum: maximumURLLength)
        }

        guard var components = URLComponents(string: candidate),
              let rawScheme = components.scheme else {
            throw FloorpWebPanelValidationError.invalidURL
        }
        let scheme = rawScheme.lowercased()
        guard allowedSchemes.contains(scheme) else {
            throw FloorpWebPanelValidationError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw FloorpWebPanelValidationError.credentialsNotAllowed
        }
        if components.rangeOfPort != nil || hasExplicitPortDelimiter(candidate) {
            guard let port = components.port, (1...65_535).contains(port) else {
                throw FloorpWebPanelValidationError.invalidURL
            }
        }
        guard let host = components.host, !host.isEmpty else {
            throw FloorpWebPanelValidationError.missingHost
        }
        guard !host.contains("@") else {
            throw FloorpWebPanelValidationError.credentialsNotAllowed
        }
        guard !host.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw FloorpWebPanelValidationError.missingHost
        }

        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url, url.host != nil else {
            throw FloorpWebPanelValidationError.invalidURL
        }
        guard url.absoluteString.utf8.count <= maximumURLLength else {
            throw FloorpWebPanelValidationError.urlTooLong(maximum: maximumURLLength)
        }
        return FloorpValidatedWebPanelDraft(title: title, url: url, iconName: draft.iconName)
    }

    static func validate(_ panel: FloorpPanel) throws -> FloorpValidatedWebPanelDraft {
        guard panel.type == .web else { throw FloorpWebPanelValidationError.invalidURL }
        return try validate(
            FloorpWebPanelDraft(
                title: panel.title,
                urlText: panel.url ?? "",
                iconName: panel.iconName
            )
        )
    }

    static func safeDisplayTitle(_ rawTitle: String) -> String? {
        try? validatedTitle(rawTitle)
    }

    private static func validatedTitle(_ rawTitle: String) throws -> String {
        let title = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !title.isEmpty else { throw FloorpWebPanelValidationError.emptyTitle }
        guard title.count <= maximumTitleLength,
              title.utf8.count <= maximumTitleUTF8Length else {
            throw FloorpWebPanelValidationError.titleTooLong(maximum: maximumTitleLength)
        }
        guard !containsUnsafeTitleCharacters(title) else {
            throw FloorpWebPanelValidationError.titleContainsControlCharacters
        }
        guard title.unicodeScalars.contains(where: { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !isDefaultIgnorableTitleScalar(scalar)
        }) else {
            throw FloorpWebPanelValidationError.emptyTitle
        }
        return title
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func containsUnsafeTitleCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let codePoint = scalar.value
            let isC0OrC1Control = codePoint <= 0x1F || (0x7F...0x9F).contains(codePoint)
            let isBidirectionalControl = codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return isC0OrC1Control || isBidirectionalControl
        }
    }

    private static func isDefaultIgnorableTitleScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x3164, 0xFEFF, 0xFFA0,
             0x115F...0x1160,
             0x17B4...0x17B5,
             0x180B...0x180F,
             0x200B...0x200F,
             0x202A...0x202E,
             0x2060...0x206F,
             0xFE00...0xFE0F,
             0xFFF0...0xFFF8,
             0x1BCA0...0x1BCA3,
             0x1D173...0x1D17A,
             0xE0000...0xE0FFF:
            return true
        default:
            return false
        }
    }

    /// Treats `localhost:8080` as a schemeless host and `javascript:...` as
    /// an explicit (and therefore rejectable) scheme.
    private static func hasExplicitScheme(_ value: String) -> Bool {
        if isSchemelessHostPortCandidate(value) {
            return false
        }
        guard let colon = value.firstIndex(of: ":") else { return false }
        let prefix = value[..<colon]
        guard let first = prefix.unicodeScalars.first,
              CharacterSet.letters.contains(first),
              prefix.unicodeScalars.dropFirst().allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || "+-.".unicodeScalars.contains(scalar)
              }) else {
            return false
        }

        return true
    }

    /// Disambiguates the small set of host-and-port inputs we accept without
    /// a scheme. Arbitrary `name:number` remains a scheme, preventing values
    /// such as `javascript:1` and `data:123` from becoming HTTPS hosts.
    private static func isSchemelessHostPortCandidate(_ value: String) -> Bool {
        let authority = value.prefix { !"/?#".contains($0) }
        guard authority.filter({ $0 == ":" }).count == 1,
              let colon = authority.lastIndex(of: ":") else {
            return false
        }
        let host = authority[..<colon].lowercased()
        let port = authority[authority.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
        return host == "localhost" || host.contains(".")
    }

    private static func hasExplicitPortDelimiter(_ value: String) -> Bool {
        guard let authoritySeparator = value.range(of: "://") else { return false }
        let authorityStart = authoritySeparator.upperBound
        let authorityEnd = value[authorityStart...].firstIndex(where: { "/?#".contains($0) })
            ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""

        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else { return false }
            let afterBracket = hostAndPort.index(after: closingBracket)
            return afterBracket < hostAndPort.endIndex && hostAndPort[afterBracket] == ":"
        }
        return hostAndPort.contains(":")
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
/// Mirrors the profile-wide portion of Floorp desktop's
/// `floorp.panel.sidebar.config` preferences.
struct FloorpOverlayDrawerConfig: Codable, Equatable {
    /// Whether the drawer is enabled.
    var isEnabled = true

    /// Width of the icon sidebar column in points.
    /// Desktop: 42px (compact), 60px (touch). iOS uses 50px.
    var sidebarWidth = 50

    init(isEnabled: Bool = true, sidebarWidth: Int = 50) {
        self.isEnabled = isEnabled
        self.sidebarWidth = sidebarWidth
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sidebarWidth = try container.decodeIfPresent(Int.self, forKey: .sidebarWidth) ?? 50
    }
}
