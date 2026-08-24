// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

enum FloorpWebExtensionAlarmStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidStoreDirectory
    case corruptedRegistry
    case profileMismatch
    case invalidAlarmName(String)
    case invalidSchedule
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .invalidStoreDirectory:
            return "The WebExtensions alarm store directory is invalid."
        case .corruptedRegistry:
            return "The WebExtensions alarm registry is corrupted."
        case .profileMismatch:
            return "The WebExtensions alarm store belongs to another browser profile."
        case .invalidAlarmName(let name):
            return "The alarm name is invalid: \(name)"
        case .invalidSchedule:
            return "The alarm schedule is outside the supported bounds."
        case .quotaExceeded:
            return "The extension has reached the alarm quota."
        }
    }
}

/// The persisted definition of a single named MV3 alarm.
///
/// A repeating alarm produces at most one wake event per foreground delivery
/// pass. This intentionally coalesces elapsed intervals while iOS suspended
/// the app instead of trying to replay an unbounded queue on resume.
struct FloorpWebExtensionAlarm: Codable, Equatable, Sendable {
    let name: String
    let scheduledTime: Date
    let period: TimeInterval?

    init(name: String, scheduledTime: Date, period: TimeInterval? = nil) {
        self.name = name
        self.scheduledTime = scheduledTime
        self.period = period
    }
}

struct FloorpWebExtensionAlarmEvent: Codable, Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let alarm: FloorpWebExtensionAlarm
    let deliveredAt: Date
}

/// Delivers due alarms to a lazily-installed background event hook.
///
/// The host intentionally stores no package state and does not keep a worker
/// alive. Package composition registers a handler only while a reviewed lazy
/// background host is available, then feeds it events returned by the durable
/// alarm store when the app has an execution opportunity.
@MainActor
final class FloorpWebExtensionAlarmEventHost {
    typealias Handler = @MainActor (FloorpWebExtensionAlarmEvent) async -> Void

    private var handlers = [FloorpWebExtensionID: Handler]()

    func register(
        extensionID: FloorpWebExtensionID,
        handler: @escaping Handler
    ) {
        handlers[extensionID] = handler
    }

    func unregister(extensionID: FloorpWebExtensionID) {
        handlers.removeValue(forKey: extensionID)
    }

    func tearDown() {
        handlers.removeAll()
    }

    func dispatch(_ events: [FloorpWebExtensionAlarmEvent]) async {
        for event in events {
            await handlers[event.extensionID]?(event)
        }
    }
}

/// A profile-owned durable registry for the supported `alarms` subset.
///
/// The caller supplies a profile-local directory. The committed registry also
/// records the profile identity, so accidentally reusing a normal-profile
/// directory for private browsing fails closed rather than leaking schedules.
actor FloorpWebExtensionAlarmStore {
    private struct Profile: Codable, Equatable, Sendable {
        let identifier: String
        let isPrivateBrowsing: Bool
    }

    private struct Registry: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let profile: Profile
        var alarmsByExtension: [FloorpWebExtensionID: [String: FloorpWebExtensionAlarm]]

        init(profile: Profile) {
            schemaVersion = Self.currentSchemaVersion
            self.profile = profile
            alarmsByExtension = [:]
        }
    }

    static let maximumAlarmsPerExtension = 500
    static let minimumPeriod: TimeInterval = 60
    static let maximumPeriod: TimeInterval = 31 * 24 * 60 * 60
    static let maximumDueEventsPerDelivery = 100

    private let profile: Profile
    private let registryURL: URL
    private var registry: Registry

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL
    ) throws {
        guard Self.isValidProfileIdentifier(profileIdentifier) else {
            throw FloorpWebExtensionAlarmStoreError.invalidStoreDirectory
        }
        let profile = Profile(identifier: profileIdentifier, isPrivateBrowsing: isPrivateBrowsing)
        let directory = directory.standardizedFileURL
        try Self.ensureDirectory(directory)

        self.profile = profile
        registryURL = directory.appendingPathComponent("alarms-v1.json", isDirectory: false)
        registry = try Self.loadRegistry(from: registryURL, expectedProfile: profile)
    }

    func create(
        _ alarm: FloorpWebExtensionAlarm,
        for extensionID: FloorpWebExtensionID,
        permissionBroker: FloorpWebExtensionPermissionBroker
    ) async throws {
        guard await permissionBroker.allows(.alarms, extensionID: extensionID) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.alarms.rawValue)
        }
        try createValidated(alarm, for: extensionID)
    }

    /// Removes one alarm. Returning `false` matches the WebExtensions API's
    /// no-op semantics when the named alarm was not present.
    @discardableResult
    func clear(named name: String, for extensionID: FloorpWebExtensionID) throws -> Bool {
        guard var alarms = registry.alarmsByExtension[extensionID], alarms.removeValue(forKey: name) != nil else {
            return false
        }
        var next = registry
        if alarms.isEmpty {
            next.alarmsByExtension.removeValue(forKey: extensionID)
        } else {
            next.alarmsByExtension[extensionID] = alarms
        }
        try commit(next)
        return true
    }

    @discardableResult
    func clearAll(for extensionID: FloorpWebExtensionID) throws -> Bool {
        guard registry.alarmsByExtension[extensionID] != nil else { return false }
        var next = registry
        next.alarmsByExtension.removeValue(forKey: extensionID)
        try commit(next)
        return true
    }

    func alarm(named name: String, for extensionID: FloorpWebExtensionID) -> FloorpWebExtensionAlarm? {
        registry.alarmsByExtension[extensionID]?[name]
    }

    func alarms(for extensionID: FloorpWebExtensionID) -> [FloorpWebExtensionAlarm] {
        (registry.alarmsByExtension[extensionID] ?? [:]).values.sorted { lhs, rhs in
            lhs.name < rhs.name
        }
    }

    /// Atomically consumes due one-shot alarms and advances repeating alarms.
    /// Delivery is capped to protect foreground resume from an unbounded event
    /// burst; a later call receives any remaining due definitions.
    func takeDueEvents(now: Date) throws -> [FloorpWebExtensionAlarmEvent] {
        var next = registry
        var events = [FloorpWebExtensionAlarmEvent]()

        for extensionID in next.alarmsByExtension.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard events.count < Self.maximumDueEventsPerDelivery,
                  var alarms = next.alarmsByExtension[extensionID] else {
                break
            }
            for name in alarms.keys.sorted() where events.count < Self.maximumDueEventsPerDelivery {
                guard let alarm = alarms[name], alarm.scheduledTime <= now else { continue }
                events.append(.init(extensionID: extensionID, alarm: alarm, deliveredAt: now))
                if let period = alarm.period {
                    alarms[name] = FloorpWebExtensionAlarm(
                        name: alarm.name,
                        scheduledTime: Self.nextTime(after: now, from: alarm.scheduledTime, period: period),
                        period: period
                    )
                } else {
                    alarms.removeValue(forKey: name)
                }
            }
            if alarms.isEmpty {
                next.alarmsByExtension.removeValue(forKey: extensionID)
            } else {
                next.alarmsByExtension[extensionID] = alarms
            }
        }

        guard next != registry else { return [] }
        try commit(next)
        return events
    }

    private func createValidated(
        _ alarm: FloorpWebExtensionAlarm,
        for extensionID: FloorpWebExtensionID
    ) throws {
        try Self.validate(alarm)
        var next = registry
        var alarms = next.alarmsByExtension[extensionID] ?? [:]
        if alarms[alarm.name] == nil, alarms.count >= Self.maximumAlarmsPerExtension {
            throw FloorpWebExtensionAlarmStoreError.quotaExceeded
        }
        alarms[alarm.name] = alarm
        next.alarmsByExtension[extensionID] = alarms
        try commit(next)
    }

    private func commit(_ next: Registry) throws {
        try Self.persist(next, to: registryURL)
        registry = next
    }

    private static func validate(_ alarm: FloorpWebExtensionAlarm) throws {
        let name = alarm.name
        guard !name.isEmpty,
              name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw FloorpWebExtensionAlarmStoreError.invalidAlarmName(name)
        }
        guard alarm.scheduledTime.timeIntervalSinceReferenceDate.isFinite else {
            throw FloorpWebExtensionAlarmStoreError.invalidSchedule
        }
        if let period = alarm.period {
            guard period.isFinite,
                  (minimumPeriod...maximumPeriod).contains(period) else {
                throw FloorpWebExtensionAlarmStoreError.invalidSchedule
            }
        }
    }

    private static func nextTime(after now: Date, from scheduledTime: Date, period: TimeInterval) -> Date {
        let elapsed = max(0, now.timeIntervalSince(scheduledTime))
        let intervals = max(1, Int((elapsed / period).rounded(.down)) + 1)
        return scheduledTime.addingTimeInterval(period * Double(intervals))
    }

    private static func ensureDirectory(_ directory: URL) throws {
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FloorpWebExtensionAlarmStoreError.invalidStoreDirectory
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FloorpWebExtensionAlarmStoreError.invalidStoreDirectory
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
                    throw FloorpWebExtensionAlarmStoreError.profileMismatch
                }
                throw FloorpWebExtensionAlarmStoreError.corruptedRegistry
            }
            for alarms in registry.alarmsByExtension.values {
                guard alarms.count <= maximumAlarmsPerExtension else {
                    throw FloorpWebExtensionAlarmStoreError.corruptedRegistry
                }
                try alarms.values.forEach(validate)
            }
            return registry
        } catch let error as FloorpWebExtensionAlarmStoreError {
            throw error
        } catch {
            throw FloorpWebExtensionAlarmStoreError.corruptedRegistry
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
