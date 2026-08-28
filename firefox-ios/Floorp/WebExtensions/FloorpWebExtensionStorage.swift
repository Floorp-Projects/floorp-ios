// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

private final class FloorpWebExtensionStoragePersistenceCoordinator: @unchecked Sendable {
    private let lock = NSLock()

    func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

/// A JSON value accepted by the generic WebExtensions API boundary.
///
/// The type deliberately excludes Foundation property-list objects and
/// non-finite numbers. This gives storage a stable, Codable representation and
/// keeps values Sendable before the JavaScript bridge is introduced.
enum FloorpWebExtensionJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The stored value is not valid JSON."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite.")
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum FloorpWebExtensionStorageArea: String, Codable, Sendable {
    case local
    /// A durable, device-local compatibility namespace. It deliberately does
    /// not synchronize through a cloud account.
    case sync
    case session
    case managed
}

enum FloorpWebExtensionStorageQuotaTier: Equatable, Sendable {
    case regular
    case unlimitedStorage
}

struct FloorpWebExtensionStorageQuotas: Equatable, Sendable {
    static let production = Self(
        localByteLimit: 5 * 1_024 * 1_024,
        unlimitedLocalByteLimit: 20 * 1_024 * 1_024,
        sessionByteLimit: 10 * 1_024 * 1_024,
        maximumKeyCount: 8_192,
        maximumKeyByteCount: 512
    )

    let localByteLimit: Int
    let unlimitedLocalByteLimit: Int
    let sessionByteLimit: Int
    let maximumKeyCount: Int
    let maximumKeyByteCount: Int

    init(
        localByteLimit: Int,
        unlimitedLocalByteLimit: Int,
        sessionByteLimit: Int,
        maximumKeyCount: Int,
        maximumKeyByteCount: Int
    ) {
        self.localByteLimit = max(0, localByteLimit)
        self.unlimitedLocalByteLimit = max(0, unlimitedLocalByteLimit)
        self.sessionByteLimit = max(0, sessionByteLimit)
        self.maximumKeyCount = max(0, maximumKeyCount)
        self.maximumKeyByteCount = max(0, maximumKeyByteCount)
    }
}

struct FloorpWebExtensionStorageProfileKey: Hashable, Sendable {
    let profileIdentifier: String
    let isPrivateBrowsing: Bool
}

struct FloorpWebExtensionStorageValueChange: Equatable, Sendable {
    let oldValue: FloorpWebExtensionJSONValue?
    let newValue: FloorpWebExtensionJSONValue?
}

struct FloorpWebExtensionStorageChangeEvent: Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let area: FloorpWebExtensionStorageArea
    let changes: [String: FloorpWebExtensionStorageValueChange]
    let revision: UInt64
}

enum FloorpWebExtensionStorageError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileIdentifier
    case persistentDirectoryRequired
    case invalidPersistentDirectory
    case corruptedPersistentStorage
    case invalidKey(String)
    case quotaExceeded(FloorpWebExtensionStorageArea)
    case managedStorageIsReadOnly
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidProfileIdentifier:
            return "The WebExtensions storage profile identifier is invalid."
        case .persistentDirectoryRequired:
            return "Normal-profile extension storage requires a profile-owned directory."
        case .invalidPersistentDirectory:
            return "The WebExtensions storage directory is invalid."
        case .corruptedPersistentStorage:
            return "The persisted WebExtensions local storage is corrupted."
        case .invalidKey(let key):
            return "The WebExtensions storage key is invalid: \(key)"
        case .quotaExceeded(let area):
            return "The extension exceeded its \(area.rawValue) storage quota."
        case .managedStorageIsReadOnly:
            return "Managed extension storage is read-only."
        case .persistenceFailed:
            return "WebExtensions local storage could not be persisted."
        }
    }
}

/// Profile-owned implementation of the Stage 2 `storage` contract.
///
/// Normal `local` and compatibility `sync` state are durably committed before
/// they become observable. Private versions of both, and every `session`
/// namespace, are memory-backed, ensuring a private browsing session cannot
/// leak extension state into the normal profile. Callers create one service
/// per profile/private lifecycle.
actor FloorpWebExtensionStorageService {
    typealias Values = [String: FloorpWebExtensionJSONValue]

    private struct PersistedNamespace: Codable, Sendable {
        let extensionID: FloorpWebExtensionID
        let values: Values
    }

    private struct PersistedState: Codable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let profileIdentifier: String
        let namespaces: [PersistedNamespace]
    }

    private struct Observer {
        let extensionID: FloorpWebExtensionID
        let continuation: AsyncStream<FloorpWebExtensionStorageChangeEvent>.Continuation
    }

    private struct NamespaceMutation {
        let old: Values
        let new: Values

        var changed: Bool { old != new }
    }

    static let maximumPersistentFileByteCount = 64 * 1_024 * 1_024
    private static let persistenceCoordinator = FloorpWebExtensionStoragePersistenceCoordinator()

    nonisolated let profileKey: FloorpWebExtensionStorageProfileKey
    private let quotas: FloorpWebExtensionStorageQuotas
    private let persistentURL: URL?
    private let syncPersistentURL: URL?
    private var localValues: [FloorpWebExtensionID: Values]
    private var syncValues: [FloorpWebExtensionID: Values]
    private var sessionValues = [FloorpWebExtensionID: Values]()
    private var observers = [UUID: Observer]()
    private var revision: UInt64 = 0

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL?,
        quotas: FloorpWebExtensionStorageQuotas = .production
    ) throws {
        let identifier = profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.utf8.count <= 256 else {
            throw FloorpWebExtensionStorageError.invalidProfileIdentifier
        }
        profileKey = .init(
            profileIdentifier: identifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        self.quotas = quotas

        if isPrivateBrowsing {
            // Never inspect or create a caller-provided directory for private
            // storage. Its entire local and sync views die with this service
            // instance.
            persistentURL = nil
            syncPersistentURL = nil
            localValues = [:]
            syncValues = [:]
        } else {
            guard let directory else {
                throw FloorpWebExtensionStorageError.persistentDirectoryRequired
            }
            let validatedDirectory = try Self.preparePersistentDirectory(directory)
            let url = validatedDirectory.appendingPathComponent("storage-local.json", isDirectory: false)
            let syncURL = validatedDirectory.appendingPathComponent("storage-sync.json", isDirectory: false)
            persistentURL = url
            syncPersistentURL = syncURL
            localValues = try Self.persistenceCoordinator.synchronized {
                try Self.loadPersistentState(
                    from: url,
                    profileIdentifier: identifier,
                    quotas: quotas
                )
            }
            syncValues = try Self.persistenceCoordinator.synchronized {
                try Self.loadPersistentState(
                    from: syncURL,
                    profileIdentifier: identifier,
                    quotas: quotas
                )
            }
        }
    }

    func values(
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea,
        keys: Set<String>? = nil
    ) throws -> Values {
        let namespace = try namespace(for: extensionID, in: area)
        guard let keys else { return namespace }
        return namespace.filter { keys.contains($0.key) }
    }

    func bytesInUse(
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea,
        keys: Set<String>? = nil
    ) throws -> Int {
        try Self.encodedByteCount(for: try values(for: extensionID, in: area, keys: keys))
    }

    func set(
        _ additions: Values,
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea,
        quotaTier: FloorpWebExtensionStorageQuotaTier = .regular
    ) throws {
        guard area != .managed else {
            throw FloorpWebExtensionStorageError.managedStorageIsReadOnly
        }
        try additions.keys.forEach { try Self.validateKey($0, quotas: quotas) }

        let mutation = try updateNamespace(for: extensionID, in: area) { oldNamespace in
            var nextNamespace = oldNamespace
            additions.forEach { nextNamespace[$0.key] = $0.value }
            try Self.validateQuota(
                nextNamespace,
                area: area,
                tier: quotaTier,
                quotas: quotas
            )
            return nextNamespace
        }
        guard mutation.changed else { return }

        let changes = additions.reduce(into: [String: FloorpWebExtensionStorageValueChange]()) { result, item in
            let oldValue = mutation.old[item.key]
            guard oldValue != item.value else { return }
            result[item.key] = .init(oldValue: oldValue, newValue: item.value)
        }
        publish(changes: changes, extensionID: extensionID, area: area)
    }

    func remove(
        _ keys: Set<String>,
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea
    ) throws {
        guard area != .managed else {
            throw FloorpWebExtensionStorageError.managedStorageIsReadOnly
        }
        let mutation = try updateNamespace(for: extensionID, in: area) { oldNamespace in
            var nextNamespace = oldNamespace
            keys.forEach { nextNamespace.removeValue(forKey: $0) }
            return nextNamespace
        }
        guard mutation.changed else { return }
        let removed = mutation.old.filter { keys.contains($0.key) }
        let changes = removed.mapValues {
            FloorpWebExtensionStorageValueChange(oldValue: $0, newValue: nil)
        }
        publish(changes: changes, extensionID: extensionID, area: area)
    }

    func clear(
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea
    ) throws {
        guard area != .managed else {
            throw FloorpWebExtensionStorageError.managedStorageIsReadOnly
        }
        let mutation = try updateNamespace(for: extensionID, in: area) { _ in [:] }
        guard mutation.changed else { return }
        let changes = mutation.old.mapValues {
            FloorpWebExtensionStorageValueChange(oldValue: $0, newValue: nil)
        }
        publish(changes: changes, extensionID: extensionID, area: area)
    }

    /// Removes every mutable area during uninstall. `storage.local` and
    /// device-local `storage.sync` otherwise survive an immutable
    /// package-generation update as required by MV3.
    func removeAllData(for extensionID: FloorpWebExtensionID) throws {
        try clear(for: extensionID, in: .local)
        try clear(for: extensionID, in: .sync)
        try clear(for: extensionID, in: .session)
    }

    func changeEvents(
        for extensionID: FloorpWebExtensionID
    ) -> AsyncStream<FloorpWebExtensionStorageChangeEvent> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            observers[observerID] = Observer(extensionID: extensionID, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    private func namespace(
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea
    ) throws -> Values {
        switch area {
        case .local:
            if let persistentURL {
                localValues = try Self.persistenceCoordinator.synchronized {
                    try Self.loadPersistentState(
                        from: persistentURL,
                        profileIdentifier: profileKey.profileIdentifier,
                        quotas: quotas
                    )
                }
            }
            return localValues[extensionID] ?? [:]
        case .sync:
            if let syncPersistentURL {
                syncValues = try Self.persistenceCoordinator.synchronized {
                    try Self.loadPersistentState(
                        from: syncPersistentURL,
                        profileIdentifier: profileKey.profileIdentifier,
                        quotas: quotas
                    )
                }
            }
            return syncValues[extensionID] ?? [:]
        case .session:
            return sessionValues[extensionID] ?? [:]
        case .managed:
            return [:]
        }
    }

    private func updateNamespace(
        for extensionID: FloorpWebExtensionID,
        in area: FloorpWebExtensionStorageArea,
        transform: (Values) throws -> Values
    ) throws -> NamespaceMutation {
        switch area {
        case .local:
            if let persistentURL {
                let result = try Self.persistenceCoordinator.synchronized {
                    var allValues = try Self.loadPersistentState(
                        from: persistentURL,
                        profileIdentifier: profileKey.profileIdentifier,
                        quotas: quotas
                    )
                    let oldNamespace = allValues[extensionID] ?? [:]
                    let nextNamespace = try transform(oldNamespace)
                    guard nextNamespace != oldNamespace else {
                        return (NamespaceMutation(old: oldNamespace, new: nextNamespace), allValues)
                    }
                    if nextNamespace.isEmpty {
                        allValues.removeValue(forKey: extensionID)
                    } else {
                        allValues[extensionID] = nextNamespace
                    }
                    try Self.persist(
                        allValues,
                        profileIdentifier: profileKey.profileIdentifier,
                        to: persistentURL
                    )
                    return (NamespaceMutation(old: oldNamespace, new: nextNamespace), allValues)
                }
                localValues = result.1
                return result.0
            }

            let oldNamespace = localValues[extensionID] ?? [:]
            let nextNamespace = try transform(oldNamespace)
            if nextNamespace.isEmpty {
                localValues.removeValue(forKey: extensionID)
            } else {
                localValues[extensionID] = nextNamespace
            }
            return NamespaceMutation(old: oldNamespace, new: nextNamespace)
        case .sync:
            if let syncPersistentURL {
                let result = try Self.persistenceCoordinator.synchronized {
                    var allValues = try Self.loadPersistentState(
                        from: syncPersistentURL,
                        profileIdentifier: profileKey.profileIdentifier,
                        quotas: quotas
                    )
                    let oldNamespace = allValues[extensionID] ?? [:]
                    let nextNamespace = try transform(oldNamespace)
                    guard nextNamespace != oldNamespace else {
                        return (NamespaceMutation(old: oldNamespace, new: nextNamespace), allValues)
                    }
                    if nextNamespace.isEmpty {
                        allValues.removeValue(forKey: extensionID)
                    } else {
                        allValues[extensionID] = nextNamespace
                    }
                    try Self.persist(
                        allValues,
                        profileIdentifier: profileKey.profileIdentifier,
                        to: syncPersistentURL
                    )
                    return (NamespaceMutation(old: oldNamespace, new: nextNamespace), allValues)
                }
                syncValues = result.1
                return result.0
            }

            let oldNamespace = syncValues[extensionID] ?? [:]
            let nextNamespace = try transform(oldNamespace)
            if nextNamespace.isEmpty {
                syncValues.removeValue(forKey: extensionID)
            } else {
                syncValues[extensionID] = nextNamespace
            }
            return NamespaceMutation(old: oldNamespace, new: nextNamespace)
        case .session:
            let oldNamespace = sessionValues[extensionID] ?? [:]
            let nextNamespace = try transform(oldNamespace)
            if nextNamespace.isEmpty {
                sessionValues.removeValue(forKey: extensionID)
            } else {
                sessionValues[extensionID] = nextNamespace
            }
            return NamespaceMutation(old: oldNamespace, new: nextNamespace)
        case .managed:
            throw FloorpWebExtensionStorageError.managedStorageIsReadOnly
        }
    }

    private func publish(
        changes: [String: FloorpWebExtensionStorageValueChange],
        extensionID: FloorpWebExtensionID,
        area: FloorpWebExtensionStorageArea
    ) {
        guard !changes.isEmpty else { return }
        revision &+= 1
        let event = FloorpWebExtensionStorageChangeEvent(
            extensionID: extensionID,
            area: area,
            changes: changes,
            revision: revision
        )
        observers.values
            .filter { $0.extensionID == extensionID }
            .forEach { $0.continuation.yield(event) }
    }

    private func removeObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }

    private static func validateKey(
        _ key: String,
        quotas: FloorpWebExtensionStorageQuotas
    ) throws {
        guard key.utf8.count <= quotas.maximumKeyByteCount else {
            throw FloorpWebExtensionStorageError.invalidKey(key)
        }
    }

    private static func validateQuota(
        _ values: Values,
        area: FloorpWebExtensionStorageArea,
        tier: FloorpWebExtensionStorageQuotaTier,
        quotas: FloorpWebExtensionStorageQuotas
    ) throws {
        guard values.count <= quotas.maximumKeyCount else {
            throw FloorpWebExtensionStorageError.quotaExceeded(area)
        }
        let byteLimit: Int
        switch area {
        case .local, .sync:
            byteLimit = tier == .unlimitedStorage
                ? quotas.unlimitedLocalByteLimit
                : quotas.localByteLimit
        case .session:
            byteLimit = quotas.sessionByteLimit
        case .managed:
            throw FloorpWebExtensionStorageError.managedStorageIsReadOnly
        }
        guard try encodedByteCount(for: values) <= byteLimit else {
            throw FloorpWebExtensionStorageError.quotaExceeded(area)
        }
    }

    private static func encodedByteCount(for values: Values) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try values.keys.reduce(0) { result, key in
                guard let value = values[key] else { return result }
                return result + key.utf8.count + (try encoder.encode(value)).count
            }
        } catch {
            throw FloorpWebExtensionStorageError.corruptedPersistentStorage
        }
    }

    private static func preparePersistentDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL else {
            throw FloorpWebExtensionStorageError.invalidPersistentDirectory
        }
        let standardized = directory.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FloorpWebExtensionStorageError.invalidPersistentDirectory
            }
        } catch let error as FloorpWebExtensionStorageError {
            throw error
        } catch {
            throw FloorpWebExtensionStorageError.invalidPersistentDirectory
        }
        return standardized
    }

    private static func loadPersistentState(
        from url: URL,
        profileIdentifier: String,
        quotas: FloorpWebExtensionStorageQuotas
    ) throws -> [FloorpWebExtensionID: Values] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FloorpWebExtensionStorageError.corruptedPersistentStorage
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumPersistentFileByteCount else {
                throw FloorpWebExtensionStorageError.corruptedPersistentStorage
            }
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard state.schemaVersion == PersistedState.currentSchemaVersion,
                  state.profileIdentifier == profileIdentifier,
                  Set(state.namespaces.map(\.extensionID)).count == state.namespaces.count else {
                throw FloorpWebExtensionStorageError.corruptedPersistentStorage
            }
            var result = [FloorpWebExtensionID: Values]()
            for namespace in state.namespaces {
                try namespace.values.keys.forEach { try validateKey($0, quotas: quotas) }
                try validateQuota(
                    namespace.values,
                    area: .local,
                    tier: .unlimitedStorage,
                    quotas: quotas
                )
                result[namespace.extensionID] = namespace.values
            }
            return result
        } catch let error as FloorpWebExtensionStorageError {
            throw error
        } catch {
            throw FloorpWebExtensionStorageError.corruptedPersistentStorage
        }
    }

    private static func persist(
        _ namespaces: [FloorpWebExtensionID: Values],
        profileIdentifier: String,
        to url: URL
    ) throws {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw FloorpWebExtensionStorageError.persistenceFailed
                }
            }
            let state = PersistedState(
                schemaVersion: PersistedState.currentSchemaVersion,
                profileIdentifier: profileIdentifier,
                namespaces: namespaces.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { extensionID in
                    namespaces[extensionID].map {
                        PersistedNamespace(extensionID: extensionID, values: $0)
                    }
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(state)
            guard data.count <= maximumPersistentFileByteCount else {
                throw FloorpWebExtensionStorageError.persistenceFailed
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as FloorpWebExtensionStorageError {
            throw error
        } catch {
            throw FloorpWebExtensionStorageError.persistenceFailed
        }
    }
}
