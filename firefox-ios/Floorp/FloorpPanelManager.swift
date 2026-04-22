// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Overlay Drawer - Panel Manager
// Manages panel CRUD, persistence, and data access for bookmarks/history/downloads.
//
// This file is part of the Floorp customization layer.

import Foundation
import Common
import Storage
import Shared
import MozillaAppServices

// MARK: - Errors

/// Errors that can occur during panel operations.
enum FloorpPanelError: Error, LocalizedError {
    case panelNotFound(id: String)
    case duplicatePanel(id: String)
    case invalidConfiguration
    case storageError(String)

    var errorDescription: String? {
        switch self {
        case .panelNotFound(let id): return "Panel not found: \(id)"
        case .duplicatePanel(let id): return "Panel already exists: \(id)"
        case .invalidConfiguration: return "Invalid panel configuration"
        case .storageError(let msg): return "Storage error: \(msg)"
        }
    }
}

// MARK: - Panel Data Provider

/// Provides data for each panel type by accessing Firefox's RustPlaces database.
///
/// Accesses data via `AppContainer.shared.resolve() as Profile` → `profile.places`.
/// This follows the same pattern used by Firefox's own Library panels.
@MainActor
final class FloorpPanelDataProvider {
    private let logger: Logger

    init(logger: Logger = DefaultLogger.shared) {
        self.logger = logger
    }

    // MARK: - Bookmarks

    /// Fetches recent bookmarks.
    /// - Parameter limit: Maximum number of bookmarks to return.
    /// - Returns: Array of bookmark items.
    func getRecentBookmarks(limit: UInt = 20) async throws -> [BookmarkItemData] {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        return try await withCheckedThrowingContinuation { continuation in
            profile.places.getRecentBookmarks(limit: limit) { bookmarks in
                continuation.resume(returning: bookmarks)
            }
        }
    }

    /// Fetches the complete bookmarks tree starting from a root folder.
    /// - Parameters:
    ///   - rootGUID: The root folder GUID (e.g., `BookmarkRoots.MobileFolderGUID`).
    ///   - recursive: Whether to include nested folders.
    /// - Returns: The bookmark node tree, or nil if empty.
    func getBookmarksTree(
        rootGUID: String = BookmarkRoots.MobileFolderGUID,
        recursive: Bool = true
    ) async throws -> BookmarkNodeData? {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        return try await withCheckedThrowingContinuation { continuation in
            profile.places.getBookmarksTree(rootGUID: rootGUID, recursive: recursive) { result in
                switch result {
                case .success(let node):
                    continuation.resume(returning: node)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - History

    /// Fetches recent browsing history with pagination.
    /// - Parameters:
    ///   - limit: Maximum number of history entries.
    ///   - offset: Pagination offset.
    /// - Returns: History visit info with bound for pagination.
    func getRecentHistory(limit: Int = 25, offset: Int = 0) async throws -> HistoryVisitInfosWithBound {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        let deferred = profile.places.getVisitPageWithBound(
            limit: limit,
            offset: offset,
            excludedTypes: VisitTransitionSet()
        )
        return try await withCheckedThrowingContinuation { continuation in
            deferred.uponQueue(.main) { result in
                switch result {
                case .success(let infos):
                    continuation.resume(returning: infos)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetches top frecency sites (most visited).
    /// - Parameter limit: Maximum number of sites to return.
    /// - Returns: Array of sites sorted by frecency score.
    func getTopFrecentSites(limit: Int = 20) async throws -> [Site] {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        let deferred = profile.places.getTopFrecentSiteInfos(
            limit: limit,
            thresholdOption: .skipOneTimePages
        )
        return try await withCheckedThrowingContinuation { continuation in
            deferred.uponQueue(.main) { result in
                switch result {
                case .success(let sites):
                    continuation.resume(returning: sites)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func getProfile() -> Profile? {
        AppContainer.shared.resolve() as Profile
    }

    // MARK: - Downloads

    /// Fetches recent downloads from the device's Downloads directory.
    /// - Parameter limit: Maximum number of downloads to return.
    /// - Returns: Array of downloaded file items.
    func getRecentDownloads(limit: Int = 25) -> [DownloadedFile] {
        let fetcher = DefaultDownloadFileFetcher()
        let allFiles = fetcher.fetchData()
        return Array(allFiles.prefix(limit))
    }
}

// MARK: - Panel Manager

/// Manages the lifecycle and persistence of overlay drawer panels.
///
/// Panels are stored in UserDefaults as JSON, following the Floorp desktop pattern
/// of `floorp.panel.sidebar.data` / `floorp.panel.sidebar.config`.
@MainActor
final class FloorpPanelManager {
    static let shared = FloorpPanelManager()

    // MARK: - Storage Keys
    private enum StorageKey {
        static let panels = "floorp.overlayDrawer.panels"
        static let config = "floorp.overlayDrawer.config"
    }

    // MARK: - Properties
    private let logger: Logger
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Current list of panels, sorted by `sortOrder`.
    private(set) var panels: [FloorpPanel]

    /// Global drawer configuration.
    private(set) var config: FloorpOverlayDrawerConfig

    /// Data provider for accessing Firefox's bookmarks/history.
    let dataProvider: FloorpPanelDataProvider

    // MARK: - Initialization

    init(
        logger: Logger = DefaultLogger.shared,
        defaults: UserDefaults = .standard
    ) {
        self.logger = logger
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.dataProvider = FloorpPanelDataProvider(logger: logger)

        // Load persisted data or use defaults
        self.panels = Self.loadPanels(from: defaults, decoder: decoder) ?? FloorpPanel.defaultPanels()
        self.config = Self.loadConfig(from: defaults, decoder: decoder) ?? FloorpOverlayDrawerConfig()

        logger.log("Floorp: PanelManager initialized with \(panels.count) panels", level: .info, category: .setup)
    }

    // MARK: - Panel CRUD

    /// Adds a new panel.
    func addPanel(_ panel: FloorpPanel) throws {
        guard !panels.contains(where: { $0.id == panel.id }) else {
            throw FloorpPanelError.duplicatePanel(id: panel.id)
        }
        panels.append(panel)
        panels.sort { $0.sortOrder < $1.sortOrder }
        persistPanels()
        logger.log("Floorp: Added panel '\(panel.title)' (\(panel.id))", level: .info, category: .setup)
    }

    /// Removes a panel by ID.
    func removePanel(id: String) throws {
        guard let index = panels.firstIndex(where: { $0.id == id }) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        let removed = panels.remove(at: index)
        persistPanels()
        logger.log("Floorp: Removed panel '\(removed.title)' (\(id))", level: .info, category: .setup)
    }

    /// Updates an existing panel.
    func updatePanel(_ panel: FloorpPanel) throws {
        guard let index = panels.firstIndex(where: { $0.id == panel.id }) else {
            throw FloorpPanelError.panelNotFound(id: panel.id)
        }
        panels[index] = panel
        persistPanels()
        logger.log("Floorp: Updated panel '\(panel.title)' (\(panel.id))", level: .info, category: .setup)
    }

    /// Reorders panels based on the given array of IDs.
    func reorderPanels(orderedIds: [String]) {
        var reordered: [FloorpPanel] = []
        for (index, id) in orderedIds.enumerated() {
            if var panel = panels.first(where: { $0.id == id }) {
                panel.sortOrder = index
                reordered.append(panel)
            }
        }
        panels = reordered
        persistPanels()
    }

    /// Gets a panel by ID.
    func panel(for id: String) -> FloorpPanel? {
        panels.first { $0.id == id }
    }

    // MARK: - Config Management

    /// Updates the drawer configuration.
    func updateConfig(_ newConfig: FloorpOverlayDrawerConfig) {
        config = newConfig
        persistConfig()
    }

    /// Selects a panel by ID.
    func selectPanel(id: String) {
        config.selectedPanelId = id
        persistConfig()
    }

    /// Gets the currently selected panel.
    var selectedPanel: FloorpPanel? {
        guard let selectedId = config.selectedPanelId else {
            return panels.first
        }
        return panel(for: selectedId)
    }

    // MARK: - Persistence

    private func persistPanels() {
        do {
            let data = try encoder.encode(panels)
            defaults.set(data, forKey: StorageKey.panels)
        } catch {
            logger.log("Floorp: Failed to persist panels: \(error.localizedDescription)", level: .warning, category: .setup)
        }
    }

    private func persistConfig() {
        do {
            let data = try encoder.encode(config)
            defaults.set(data, forKey: StorageKey.config)
        } catch {
            logger.log("Floorp: Failed to persist config: \(error.localizedDescription)", level: .warning, category: .setup)
        }
    }

    private static func loadPanels(from defaults: UserDefaults, decoder: JSONDecoder) -> [FloorpPanel]? {
        guard let data = defaults.data(forKey: StorageKey.panels) else { return nil }
        do {
            return try decoder.decode([FloorpPanel].self, from: data)
        } catch {
            return nil
        }
    }

    private static func loadConfig(from defaults: UserDefaults, decoder: JSONDecoder) -> FloorpOverlayDrawerConfig? {
        guard let data = defaults.data(forKey: StorageKey.config) else { return nil }
        do {
            return try decoder.decode(FloorpOverlayDrawerConfig.self, from: data)
        } catch {
            return nil
        }
    }
}
