// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

enum FloorpWebExtensionActionStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidStoreDirectory
    case corruptedRegistry
    case profileMismatch
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .invalidStoreDirectory:
            return "The WebExtensions action store directory is invalid."
        case .corruptedRegistry:
            return "The WebExtensions action registry is corrupted."
        case .profileMismatch:
            return "The WebExtensions action store belongs to another browser profile."
        case .invalidState(let field):
            return "The WebExtensions action state is invalid: \(field)"
        }
    }
}

/// Package-relative metadata used by the future menu, popup, and icon hosts.
/// It names a reviewed package resource; it never opens a URL by itself.
struct FloorpWebExtensionActionResource: Codable, Equatable, Hashable, Sendable {
    let path: String

    init(_ path: String) throws {
        try Self.validate(path)
        self.path = path
    }

    init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }

    private static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }),
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw FloorpWebExtensionActionStoreError.invalidState("resource path")
        }
    }
}

/// Extension-owned presentation state for one browser-menu action.
///
/// The standard MV3 `action` namespace has no manifest permission. State is
/// still profile/private scoped and must only be surfaced for an enabled,
/// reviewed package by the future menu coordinator.
struct FloorpWebExtensionActionState: Codable, Equatable, Sendable {
    var title: String?
    var isEnabled: Bool
    var badgeText: String?
    var badgeBackgroundColor: String?
    var popup: FloorpWebExtensionActionResource?
    var icon: FloorpWebExtensionActionResource?

    init(
        title: String? = nil,
        isEnabled: Bool = true,
        badgeText: String? = nil,
        badgeBackgroundColor: String? = nil,
        popup: FloorpWebExtensionActionResource? = nil,
        icon: FloorpWebExtensionActionResource? = nil
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.badgeText = badgeText
        self.badgeBackgroundColor = badgeBackgroundColor
        self.popup = popup
        self.icon = icon
    }
}

/// Durable, profile-owned state for the supported `action` subset.
actor FloorpWebExtensionActionStore {
    private struct Profile: Codable, Equatable, Sendable {
        let identifier: String
        let isPrivateBrowsing: Bool
    }

    private struct Registry: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let profile: Profile
        var states: [FloorpWebExtensionID: FloorpWebExtensionActionState]

        init(profile: Profile) {
            schemaVersion = Self.currentSchemaVersion
            self.profile = profile
            states = [:]
        }
    }

    private let profile: Profile
    private let registryURL: URL
    private var registry: Registry

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL
    ) throws {
        guard Self.isValidProfileIdentifier(profileIdentifier) else {
            throw FloorpWebExtensionActionStoreError.invalidStoreDirectory
        }
        let profile = Profile(identifier: profileIdentifier, isPrivateBrowsing: isPrivateBrowsing)
        let directory = directory.standardizedFileURL
        try Self.ensureDirectory(directory)

        self.profile = profile
        registryURL = directory.appendingPathComponent("action-state-v1.json", isDirectory: false)
        registry = try Self.loadRegistry(from: registryURL, expectedProfile: profile)
    }

    func state(for extensionID: FloorpWebExtensionID) -> FloorpWebExtensionActionState {
        registry.states[extensionID] ?? .init()
    }

    func setState(
        _ state: FloorpWebExtensionActionState,
        for extensionID: FloorpWebExtensionID
    ) throws {
        try Self.validate(state)
        var next = registry
        next.states[extensionID] = state
        try commit(next)
    }

    @discardableResult
    func clearState(for extensionID: FloorpWebExtensionID) throws -> Bool {
        guard registry.states[extensionID] != nil else { return false }
        var next = registry
        next.states.removeValue(forKey: extensionID)
        try commit(next)
        return true
    }

    func allStates() -> [FloorpWebExtensionID: FloorpWebExtensionActionState] {
        registry.states
    }

    private func commit(_ next: Registry) throws {
        try Self.persist(next, to: registryURL)
        registry = next
    }

    private static func validate(_ state: FloorpWebExtensionActionState) throws {
        if let title = state.title,
           title.utf8.count > 256 || title.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            throw FloorpWebExtensionActionStoreError.invalidState("title")
        }
        if let badge = state.badgeText,
           badge.count > 16 || badge.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            throw FloorpWebExtensionActionStoreError.invalidState("badge text")
        }
        if let color = state.badgeBackgroundColor,
           !isValidColor(color) {
            throw FloorpWebExtensionActionStoreError.invalidState("badge color")
        }
    }

    private static func isValidColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FloorpWebExtensionActionStoreError.invalidStoreDirectory
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FloorpWebExtensionActionStoreError.invalidStoreDirectory
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func loadRegistry(from url: URL, expectedProfile: Profile) throws -> Registry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Registry(profile: expectedProfile)
        }
        do {
            let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
            guard registry.schemaVersion == Registry.currentSchemaVersion,
                  registry.profile == expectedProfile else {
                if registry.profile != expectedProfile {
                    throw FloorpWebExtensionActionStoreError.profileMismatch
                }
                throw FloorpWebExtensionActionStoreError.corruptedRegistry
            }
            try registry.states.values.forEach(validate)
            return registry
        } catch let error as FloorpWebExtensionActionStoreError {
            throw error
        } catch {
            throw FloorpWebExtensionActionStoreError.corruptedRegistry
        }
    }

    private static func persist(_ registry: Registry, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(registry).write(to: url, options: [.atomic])
    }

    private static func isValidProfileIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
        }
    }
}
