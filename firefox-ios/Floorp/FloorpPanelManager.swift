// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Overlay Drawer - Panel Manager
// Manages panel CRUD, persistence, and data access for bookmarks/history/downloads.
//
// This file is part of the Floorp customization layer.

import Foundation
import CoreFoundation
import Common
import Storage
import Shared
import MozillaAppServices

// MARK: - Errors

/// Errors that can occur during panel operations.
enum FloorpPanelError: Error, LocalizedError, Equatable {
    case panelNotFound(id: String)
    case duplicatePanel(id: String)
    case invalidConfiguration
    case panelLimitReached(maximum: Int)
    case reservedIdentifier(id: String)
    case panelIsNotWeb(id: String)
    case editConflict(id: String)
    case configEditConflict
    case revisionExhausted
    case cannotRemoveLastPanel
    case invalidMoveDestination(index: Int)
    case registryReadOnly
    case storageError(String)

    var errorDescription: String? {
        switch self {
        case .panelNotFound(let id): return "Panel not found: \(id)"
        case .duplicatePanel(let id): return "Panel already exists: \(id)"
        case .invalidConfiguration: return "Invalid panel configuration"
        case .panelLimitReached(let maximum): return "Panel limit reached: \(maximum)"
        case .reservedIdentifier(let id): return "Reserved panel identifier: \(id)"
        case .panelIsNotWeb(let id): return "Panel is not a Web panel: \(id)"
        case .editConflict(let id): return "Panel changed while being edited: \(id)"
        case .configEditConflict: return "Panel configuration changed while being edited"
        case .revisionExhausted: return "Panel preference revision cannot be advanced"
        case .cannotRemoveLastPanel: return "At least one panel must remain"
        case .invalidMoveDestination(let index): return "Invalid panel destination: \(index)"
        case .registryReadOnly: return "The stored panel registry is read-only"
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

    // MARK: - Deletion

    /// Deletes a bookmark from the database by its GUID.
    /// - Parameter guid: The bookmark's unique identifier.
    func deleteBookmark(guid: String) async throws {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            profile.places.deleteBookmarkNode(guid: guid).uponQueue(.main) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Deletes all visits for a given URL from browsing history.
    /// - Parameter url: The URL whose visits should be removed.
    func deleteHistory(url: String) async throws {
        guard let profile = getProfile() else {
            throw FloorpPanelError.storageError("Failed to resolve Profile from AppContainer")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            profile.places.deleteVisitsFor(url).uponQueue(.main) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
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
    static let maximumPanelCount = 32

    // MARK: - Storage Keys
    private enum StorageKey {
        static let panels = "floorp.overlayDrawer.panels"
        static let config = "floorp.overlayDrawer.config"
        static let schemaVersion = "floorp.overlayDrawer.schemaVersion"
    }

    private struct PanelLoadResult {
        let panels: [FloorpPanel]?
        let hasStoredData: Bool
        let encounteredDecodingFailure: Bool
    }

    private struct ConfigLoadResult {
        let config: FloorpOverlayDrawerConfig?
        let encounteredDecodingFailure: Bool
    }

    private struct SchemaVersionLoadResult {
        let version: Int
        let encounteredDecodingFailure: Bool
    }

    private struct MutableSnapshot {
        let panels: [FloorpPanel]
        let config: FloorpOverlayDrawerConfig
    }

    private static let notesSchemaVersion = 1
    private static let currentSchemaVersion = 3

    // MARK: - Properties
    private let logger: Logger
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let notificationCenter: NotificationProtocol

    /// Current list of panels, sorted by `sortOrder`.
    private(set) var panels: [FloorpPanel]

    /// Protects unknown future-schema or partially undecodable data from a
    /// lossy rewrite. Reading known panels remains available for recovery.
    private(set) var isRegistryReadOnly: Bool

    /// Global drawer configuration.
    private(set) var config: FloorpOverlayDrawerConfig

    /// Data provider for accessing Firefox's bookmarks/history.
    let dataProvider: FloorpPanelDataProvider

    // MARK: - Initialization

    init(
        logger: Logger = DefaultLogger.shared,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationProtocol = NotificationCenter.default
    ) {
        self.logger = logger
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.notificationCenter = notificationCenter
        self.dataProvider = FloorpPanelDataProvider(logger: logger)

        // Load persisted data or use defaults. Schema v1 introduced Notes;
        // schema v2 separates per-window presentation state from this
        // profile-wide registry and configuration; schema v3 adds persistent
        // Web panel preferences and automatic unloading.
        let panelLoadResult = Self.loadPanels(from: defaults, decoder: decoder)
        let storedPanels = panelLoadResult.panels
        var loadedPanels = storedPanels ?? FloorpPanel.defaultPanels()
        let configLoadResult = Self.loadConfig(from: defaults, decoder: decoder)
        let loadedConfig = configLoadResult.config ?? FloorpOverlayDrawerConfig()
        let schemaVersionLoadResult = Self.loadSchemaVersion(from: defaults)
        let storedSchemaVersion = schemaVersionLoadResult.version
        let needsNotesMigration = !schemaVersionLoadResult.encounteredDecodingFailure
            && storedSchemaVersion < Self.notesSchemaVersion
        let needsMigration = !schemaVersionLoadResult.encounteredDecodingFailure
            && storedSchemaVersion < Self.currentSchemaVersion
        let isRegistryReadOnly = schemaVersionLoadResult.encounteredDecodingFailure
            || storedSchemaVersion < 0
            || storedSchemaVersion > Self.currentSchemaVersion
            || panelLoadResult.encounteredDecodingFailure
            || configLoadResult.encounteredDecodingFailure
        let canRewriteStoredData = (0...Self.currentSchemaVersion).contains(storedSchemaVersion)
            && !schemaVersionLoadResult.encounteredDecodingFailure
            && !panelLoadResult.encounteredDecodingFailure
            && !configLoadResult.encounteredDecodingFailure

        if needsNotesMigration {
            Self.migrateNotesPanelIfNeeded(panels: &loadedPanels)
        }
        let sanitizedPanels = Self.sanitizeLoadedPanels(
            loadedPanels,
            suppliesMissingWebPreferences: canRewriteStoredData
        )

        self.panels = sanitizedPanels
        self.isRegistryReadOnly = isRegistryReadOnly
        self.config = loadedConfig

        logger.log("Floorp: PanelManager initialized with \(panels.count) panels", level: .info, category: .setup)

        if canRewriteStoredData,
           !panelLoadResult.hasStoredData || storedPanels != sanitizedPanels || needsMigration {
            persistPanels()
        }
        if needsMigration, canRewriteStoredData {
            persistConfig()
            defaults.set(Self.currentSchemaVersion, forKey: StorageKey.schemaVersion)
        }
    }

    // MARK: - Panel CRUD

    /// Adds a validated custom Web panel. Identity and ordering are generated
    /// here so callers cannot spoof built-in panels or overwrite another item.
    @discardableResult
    func addWebPanel(draft: FloorpWebPanelDraft) throws -> FloorpPanel {
        let snapshot = try latestMutableSnapshot()
        let validated = try FloorpWebPanelValidator.validate(draft)
        guard snapshot.panels.count < Self.maximumPanelCount else {
            throw FloorpPanelError.panelLimitReached(maximum: Self.maximumPanelCount)
        }

        var id = UUID().uuidString
        while snapshot.panels.contains(where: { $0.id == id }) || FloorpPanel.isReservedIdentifier(id) {
            id = UUID().uuidString
        }
        let panel = FloorpPanel(
            id: id,
            type: .web,
            title: validated.title,
            url: validated.url.absoluteString,
            iconName: validated.iconName,
            sortOrder: snapshot.panels.count,
            webPreferences: FloorpWebPanelPreferences()
        )
        try commitPanels(snapshot.panels + [panel])
        logger.log("Floorp: Added Web panel (\(panel.id))", level: .info, category: .setup)
        return panel
    }

    /// Updates only user-editable values of a custom Web panel.
    func updateWebPanel(
        id: String,
        draft: FloorpWebPanelDraft,
        expectedRevision: FloorpWebPanelRevision
    ) throws {
        let snapshot = try latestMutableSnapshot()
        guard !FloorpPanel.isReservedIdentifier(id) else {
            throw FloorpPanelError.reservedIdentifier(id: id)
        }
        guard let index = snapshot.panels.firstIndex(where: { $0.id == id }) else {
            // An update always originates from an editor that captured this
            // panel. If it vanished, another window changed the registry.
            throw FloorpPanelError.editConflict(id: id)
        }
        guard snapshot.panels[index].type == .web else {
            throw FloorpPanelError.panelIsNotWeb(id: id)
        }
        guard FloorpWebPanelRevision(panel: snapshot.panels[index]) == expectedRevision else {
            throw FloorpPanelError.editConflict(id: id)
        }
        let validated = try FloorpWebPanelValidator.validate(draft)
        var updatedPanels = snapshot.panels
        updatedPanels[index].title = validated.title
        updatedPanels[index].url = validated.url.absoluteString
        updatedPanels[index].iconName = validated.iconName
        try commitPanels(updatedPanels)
        logger.log("Floorp: Updated Web panel (\(id))", level: .info, category: .setup)
    }

    /// Moves a panel to a zero-based destination in the current registry.
    func movePanel(id: String, to destination: Int) throws {
        let snapshot = try latestMutableSnapshot()
        guard let source = snapshot.panels.firstIndex(where: { $0.id == id }) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        guard snapshot.panels.indices.contains(destination) else {
            throw FloorpPanelError.invalidMoveDestination(index: destination)
        }
        guard source != destination else { return }

        var reordered = snapshot.panels
        let panel = reordered.remove(at: source)
        reordered.insert(panel, at: destination)
        try commitPanels(reordered)
    }

    /// Removes a panel by ID.
    func removePanel(id: String) throws {
        let snapshot = try latestMutableSnapshot()
        guard let index = snapshot.panels.firstIndex(where: { $0.id == id }) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        guard snapshot.panels.count > 1 else {
            throw FloorpPanelError.cannotRemoveLastPanel
        }
        var updatedPanels = snapshot.panels
        updatedPanels.remove(at: index)
        try commitPanels(updatedPanels)
        logger.log("Floorp: Removed panel (\(id))", level: .info, category: .setup)
    }

    /// Restores built-in panels that the user previously removed, appending
    /// them in their canonical order without disturbing the current registry.
    @discardableResult
    func restoreMissingBuiltIns() throws -> [FloorpPanel] {
        let snapshot = try latestMutableSnapshot()
        let existingIDs = Set(snapshot.panels.map(\.id))
        let missing = FloorpPanel.defaultPanels().filter { !existingIDs.contains($0.id) }
        guard !missing.isEmpty else { return [] }
        guard snapshot.panels.count + missing.count <= Self.maximumPanelCount else {
            throw FloorpPanelError.panelLimitReached(maximum: Self.maximumPanelCount)
        }
        try commitPanels(snapshot.panels + missing)
        return missing
    }

    /// Reorders panels based on the given array of IDs.
    func reorderPanels(orderedIds: [String]) throws {
        let snapshot = try latestMutableSnapshot()
        let panelsByID = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        var seen = Set<String>()
        var reordered = orderedIds.compactMap { id -> FloorpPanel? in
            guard seen.insert(id).inserted else { return nil }
            return panelsByID[id]
        }
        // Preserve panels unknown to an older order list, including Notes.
        reordered.append(contentsOf: snapshot.panels.filter { !seen.contains($0.id) })
        Self.assignSortOrder(&reordered)
        guard reordered != snapshot.panels else { return }
        try commitPanels(reordered)
    }

    /// Gets a panel by ID.
    func panel(for id: String) -> FloorpPanel? {
        panels.first { $0.id == id }
    }

    /// Revalidates the URL at the final loading boundary.
    func validatedWebURL(for id: String) throws -> URL {
        guard let panel = panel(for: id) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        guard panel.type == .web else {
            throw FloorpPanelError.panelIsNotWeb(id: id)
        }
        return try FloorpWebPanelValidator.validate(panel).url
    }

    func webPanelPreferences(for id: String) throws -> FloorpWebPanelPreferences {
        guard let panel = panel(for: id) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        guard let preferences = panel.effectiveWebPreferences else {
            throw FloorpPanelError.panelIsNotWeb(id: id)
        }
        return preferences
    }

    func webPanelPreferencesRevision(for id: String) throws -> FloorpWebPanelPreferencesRevision {
        guard let panel = panel(for: id) else {
            throw FloorpPanelError.panelNotFound(id: id)
        }
        guard panel.effectiveWebPreferences != nil else {
            throw FloorpPanelError.panelIsNotWeb(id: id)
        }
        return FloorpWebPanelPreferencesRevision(panel: panel)
    }

    @discardableResult
    func setWebPanelContentWidth(
        _ contentWidth: Int,
        for id: String,
        expectedRevision: FloorpWebPanelPreferencesRevision
    ) throws -> FloorpWebPanelPreferences {
        try mutateWebPanelPreferences(
            id: id,
            expectedRevision: expectedRevision,
            registryChange: .webPanelContentWidth(panelID: id)
        ) { current in
            FloorpWebPanelPreferences(
                revision: current.revision,
                contentWidth: contentWidth,
                zoomLevel: current.zoomLevel,
                contentMode: current.contentMode
            )
        }
    }

    @discardableResult
    func adjustWebPanelZoom(
        for id: String,
        change: FloorpWebPanelZoomChange,
        expectedRevision: FloorpWebPanelPreferencesRevision
    ) throws -> FloorpWebPanelPreferences {
        try mutateWebPanelPreferences(id: id, expectedRevision: expectedRevision) { current in
            FloorpWebPanelPreferences(
                revision: current.revision,
                contentWidth: current.contentWidth,
                zoomLevel: current.zoomLevel.applying(change),
                contentMode: current.contentMode
            )
        }
    }

    @discardableResult
    func setWebPanelContentMode(
        _ contentMode: FloorpWebPanelContentMode,
        for id: String,
        expectedRevision: FloorpWebPanelPreferencesRevision
    ) throws -> FloorpWebPanelPreferences {
        try mutateWebPanelPreferences(id: id, expectedRevision: expectedRevision) { current in
            FloorpWebPanelPreferences(
                revision: current.revision,
                contentWidth: current.contentWidth,
                zoomLevel: current.zoomLevel,
                contentMode: contentMode
            )
        }
    }

    // MARK: - Config Management

    /// Updates the drawer configuration.
    @discardableResult
    func updateConfig(
        _ newConfig: FloorpOverlayDrawerConfig,
        expectedRevision: FloorpOverlayDrawerConfigRevision
    ) throws -> FloorpOverlayDrawerConfig {
        try mutateConfig(expectedRevision: expectedRevision) { current in
            FloorpOverlayDrawerConfig(
                isEnabled: newConfig.isEnabled,
                sidebarWidth: newConfig.sidebarWidth,
                autoUnload: newConfig.autoUnload,
                revision: current.revision
            )
        }
    }

    @discardableResult
    func setAutoUnload(
        _ autoUnload: Bool,
        expectedRevision: FloorpOverlayDrawerConfigRevision
    ) throws -> FloorpOverlayDrawerConfig {
        try mutateConfig(expectedRevision: expectedRevision) { current in
            FloorpOverlayDrawerConfig(
                isEnabled: current.isEnabled,
                sidebarWidth: current.sidebarWidth,
                autoUnload: autoUnload,
                revision: current.revision
            )
        }
    }

    // MARK: - Persistence

    private func mutateWebPanelPreferences(
        id: String,
        expectedRevision: FloorpWebPanelPreferencesRevision,
        registryChange: FloorpPanelRegistryChange? = nil,
        mutation: (FloorpWebPanelPreferences) -> FloorpWebPanelPreferences
    ) throws -> FloorpWebPanelPreferences {
        let snapshot = try latestMutableSnapshot()
        guard let index = snapshot.panels.firstIndex(where: { $0.id == id }) else {
            throw FloorpPanelError.editConflict(id: id)
        }
        guard let currentPreferences = snapshot.panels[index].effectiveWebPreferences else {
            throw FloorpPanelError.panelIsNotWeb(id: id)
        }
        guard expectedRevision.panelID == id,
              expectedRevision.value == currentPreferences.revision else {
            throw FloorpPanelError.editConflict(id: id)
        }

        let requestedPreferences = mutation(currentPreferences)
        guard requestedPreferences != currentPreferences else {
            return currentPreferences
        }
        guard currentPreferences.revision < UInt64.max else {
            throw FloorpPanelError.revisionExhausted
        }

        let updatedPreferences = FloorpWebPanelPreferences(
            revision: currentPreferences.revision + 1,
            contentWidth: requestedPreferences.contentWidth,
            zoomLevel: requestedPreferences.zoomLevel,
            contentMode: requestedPreferences.contentMode
        )
        var updatedPanels = snapshot.panels
        updatedPanels[index].webPreferences = updatedPreferences
        try commitPanels(updatedPanels, registryChange: registryChange)
        return updatedPreferences
    }

    private func mutateConfig(
        expectedRevision: FloorpOverlayDrawerConfigRevision,
        mutation: (FloorpOverlayDrawerConfig) -> FloorpOverlayDrawerConfig
    ) throws -> FloorpOverlayDrawerConfig {
        let snapshot = try latestMutableSnapshot()
        guard snapshot.config.revision == expectedRevision.value else {
            throw FloorpPanelError.configEditConflict
        }

        let requestedConfig = mutation(snapshot.config)
        let normalizedRequest = FloorpOverlayDrawerConfig(
            isEnabled: requestedConfig.isEnabled,
            sidebarWidth: requestedConfig.sidebarWidth,
            autoUnload: requestedConfig.autoUnload,
            revision: snapshot.config.revision
        )
        guard normalizedRequest != snapshot.config else {
            return snapshot.config
        }
        guard snapshot.config.revision < UInt64.max else {
            throw FloorpPanelError.revisionExhausted
        }

        let updatedConfig = FloorpOverlayDrawerConfig(
            isEnabled: normalizedRequest.isEnabled,
            sidebarWidth: normalizedRequest.sidebarWidth,
            autoUnload: normalizedRequest.autoUnload,
            revision: snapshot.config.revision + 1
        )
        try commitConfig(updatedConfig, latestPanels: snapshot.panels)
        return updatedConfig
    }

    private func latestMutableSnapshot() throws -> MutableSnapshot {
        try ensureRegistryIsMutable()

        let schemaVersionLoadResult = Self.loadSchemaVersion(from: defaults)
        let storedSchemaVersion = schemaVersionLoadResult.version
        let panelLoadResult = Self.loadPanels(from: defaults, decoder: decoder)
        let configLoadResult = Self.loadConfig(from: defaults, decoder: decoder)
        guard !schemaVersionLoadResult.encounteredDecodingFailure,
              (0...Self.currentSchemaVersion).contains(storedSchemaVersion),
              !panelLoadResult.encounteredDecodingFailure,
              !configLoadResult.encounteredDecodingFailure else {
            isRegistryReadOnly = true
            throw FloorpPanelError.registryReadOnly
        }

        var latestPanels = panelLoadResult.panels ?? FloorpPanel.defaultPanels()
        if storedSchemaVersion < Self.notesSchemaVersion {
            Self.migrateNotesPanelIfNeeded(panels: &latestPanels)
        }
        latestPanels = Self.sanitizeLoadedPanels(
            latestPanels,
            suppliesMissingWebPreferences: true
        )
        let snapshot = MutableSnapshot(
            panels: latestPanels,
            config: configLoadResult.config ?? FloorpOverlayDrawerConfig()
        )
        panels = snapshot.panels
        config = snapshot.config
        return snapshot
    }

    private func commitPanels(
        _ candidatePanels: [FloorpPanel],
        registryChange: FloorpPanelRegistryChange? = nil
    ) throws {
        try ensureRegistryIsMutable()
        var normalizedPanels = candidatePanels
        Self.assignSortOrder(&normalizedPanels)
        try Self.validateRegistryStructure(normalizedPanels)

        let data: Data
        do {
            data = try encoder.encode(normalizedPanels)
        } catch {
            throw FloorpPanelError.storageError(error.localizedDescription)
        }
        defaults.set(data, forKey: StorageKey.panels)
        panels = normalizedPanels
        notificationCenter.post(
            name: .FloorpPanelRegistryDidChange,
            withObject: self,
            withUserInfo: registryChange.map {
                [FloorpPanelRegistryNotification.changeUserInfoKey: $0]
            }
        )
    }

    private func commitConfig(
        _ candidateConfig: FloorpOverlayDrawerConfig,
        latestPanels: [FloorpPanel]
    ) throws {
        try ensureRegistryIsMutable()
        let data: Data
        do {
            data = try encoder.encode(candidateConfig)
        } catch {
            throw FloorpPanelError.storageError(error.localizedDescription)
        }
        defaults.set(data, forKey: StorageKey.config)
        panels = latestPanels
        config = candidateConfig
        notificationCenter.post(
            name: .FloorpPanelRegistryDidChange,
            withObject: self,
            withUserInfo: nil
        )
    }

    private func ensureRegistryIsMutable() throws {
        guard !isRegistryReadOnly else {
            throw FloorpPanelError.registryReadOnly
        }
    }

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

    private static func loadSchemaVersion(from defaults: UserDefaults) -> SchemaVersionLoadResult {
        guard let storedValue = defaults.object(forKey: StorageKey.schemaVersion) else {
            return SchemaVersionLoadResult(version: 0, encounteredDecodingFailure: false)
        }
        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number),
              let version = Int(number.stringValue) else {
            return SchemaVersionLoadResult(version: 0, encounteredDecodingFailure: true)
        }
        return SchemaVersionLoadResult(version: version, encounteredDecodingFailure: false)
    }

    private static func loadPanels(from defaults: UserDefaults, decoder: JSONDecoder) -> PanelLoadResult {
        guard let storedValue = defaults.object(forKey: StorageKey.panels) else {
            return PanelLoadResult(
                panels: nil,
                hasStoredData: false,
                encounteredDecodingFailure: false
            )
        }
        guard let data = storedValue as? Data else {
            return PanelLoadResult(
                panels: nil,
                hasStoredData: true,
                encounteredDecodingFailure: true
            )
        }
        do {
            guard let rawPanels = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                return PanelLoadResult(
                    panels: nil,
                    hasStoredData: true,
                    encounteredDecodingFailure: true
                )
            }
            var encounteredDecodingFailure = false
            let panels = rawPanels.compactMap { rawPanel -> FloorpPanel? in
                guard let wrappedData = try? JSONSerialization.data(withJSONObject: [rawPanel]) else {
                    encounteredDecodingFailure = true
                    return nil
                }
                guard let panel = try? decoder.decode([FloorpPanel].self, from: wrappedData).first else {
                    encounteredDecodingFailure = true
                    return nil
                }
                return panel
            }
            return PanelLoadResult(
                panels: panels,
                hasStoredData: true,
                encounteredDecodingFailure: encounteredDecodingFailure
            )
        } catch {
            return PanelLoadResult(
                panels: nil,
                hasStoredData: true,
                encounteredDecodingFailure: true
            )
        }
    }

    private static func loadConfig(from defaults: UserDefaults, decoder: JSONDecoder) -> ConfigLoadResult {
        guard let storedValue = defaults.object(forKey: StorageKey.config) else {
            return ConfigLoadResult(config: nil, encounteredDecodingFailure: false)
        }
        guard let data = storedValue as? Data else {
            return ConfigLoadResult(config: nil, encounteredDecodingFailure: true)
        }
        do {
            return ConfigLoadResult(
                config: try decoder.decode(FloorpOverlayDrawerConfig.self, from: data),
                encounteredDecodingFailure: false
            )
        } catch {
            return ConfigLoadResult(config: nil, encounteredDecodingFailure: true)
        }
    }

    private static func migrateNotesPanelIfNeeded(panels: inout [FloorpPanel]) {
        let notesID = "floorp//notes"
        if !panels.contains(where: { $0.id == notesID && $0.type == .notes }),
           let notesPanel = FloorpPanel.defaultPanels().first(where: { $0.id == notesID }) {
            let insertionIndex = panels.firstIndex(where: { $0.id == "floorp//downloads" })
                .map { panels.index(after: $0) } ?? panels.endIndex
            panels.insert(notesPanel, at: insertionIndex)
        }
    }

    private static func normalizeSortOrder(_ panels: inout [FloorpPanel]) {
        panels = panels.enumerated().sorted { lhs, rhs in
            lhs.element.sortOrder == rhs.element.sortOrder
                ? lhs.offset < rhs.offset
                : lhs.element.sortOrder < rhs.element.sortOrder
        }.map(\.element)
        assignSortOrder(&panels)
    }

    private static func sanitizeLoadedPanels(
        _ loadedPanels: [FloorpPanel],
        suppliesMissingWebPreferences: Bool
    ) -> [FloorpPanel] {
        var sortedPanels = loadedPanels
        normalizeSortOrder(&sortedPanels)

        var sanitizedPanels = [FloorpPanel]()
        var seenIDs = Set<String>()
        for panel in sortedPanels where sanitizedPanels.count < maximumPanelCount {
            if FloorpPanel.isReservedIdentifier(panel.id) {
                guard let canonicalPanel = FloorpPanel.canonicalBuiltInPanel(for: panel.id),
                      panel.type == canonicalPanel.type,
                      seenIDs.insert(panel.id).inserted else {
                    continue
                }
                var restoredPanel = canonicalPanel
                restoredPanel.sortOrder = sanitizedPanels.count
                sanitizedPanels.append(restoredPanel)
                continue
            }

            guard !panel.id.isEmpty,
                  panel.type == .web,
                  seenIDs.insert(panel.id).inserted else {
                continue
            }
            var preservedPanel = panel
            preservedPanel.sortOrder = sanitizedPanels.count
            if suppliesMissingWebPreferences, preservedPanel.webPreferences == nil {
                preservedPanel.webPreferences = FloorpWebPanelPreferences()
            }
            sanitizedPanels.append(preservedPanel)
        }

        return sanitizedPanels.isEmpty ? FloorpPanel.defaultPanels() : sanitizedPanels
    }

    private static func validateRegistryStructure(_ panels: [FloorpPanel]) throws {
        guard !panels.isEmpty else { throw FloorpPanelError.cannotRemoveLastPanel }
        guard panels.count <= maximumPanelCount else {
            throw FloorpPanelError.panelLimitReached(maximum: maximumPanelCount)
        }

        var seenIDs = Set<String>()
        for panel in panels {
            guard seenIDs.insert(panel.id).inserted else {
                throw FloorpPanelError.duplicatePanel(id: panel.id)
            }
            if FloorpPanel.isReservedIdentifier(panel.id) {
                guard let canonical = FloorpPanel.canonicalBuiltInPanel(for: panel.id),
                      panel.type == canonical.type,
                      panel.webPreferences == nil else {
                    throw FloorpPanelError.reservedIdentifier(id: panel.id)
                }
            } else {
                guard !panel.id.isEmpty,
                      panel.type == .web,
                      panel.webPreferences != nil else {
                    throw FloorpPanelError.invalidConfiguration
                }
            }
        }
    }

    private static func assignSortOrder(_ panels: inout [FloorpPanel]) {
        for index in panels.indices {
            panels[index].sortOrder = index
        }
    }
}
