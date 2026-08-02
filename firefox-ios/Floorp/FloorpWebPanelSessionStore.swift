// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation

enum FloorpWebPanelSessionStoreError: Error, Equatable {
    case factoryReturnedMismatchedKey
}

@MainActor
final class FloorpWebPanelSessionStore {
    private struct Entry {
        let session: any FloorpWebPanelSessionProtocol
        var configuration: FloorpWebPanelSessionConfiguration
    }

    private struct RestorationSnapshot {
        let homeURL: URL
        let currentURL: URL
    }

    private let windowUUID: WindowUUID
    private let regularSessionLimit: Int
    private let factory: any FloorpWebPanelSessionFactory
    private var entries = [FloorpWebPanelSessionKey: Entry]()
    private var regularSessionLRU = [FloorpWebPanelSessionKey]()
    private var restorationSnapshots = [FloorpWebPanelSessionKey: RestorationSnapshot]()

    init(
        windowUUID: WindowUUID,
        regularSessionLimit: Int = 4,
        factory: any FloorpWebPanelSessionFactory
    ) {
        self.windowUUID = windowUUID
        self.regularSessionLimit = max(1, regularSessionLimit)
        self.factory = factory
    }

    var cachedSessionCount: Int {
        entries.count
    }

    var cachedSessionKeys: Set<FloorpWebPanelSessionKey> {
        Set(entries.keys)
    }

    func session(
        for panel: FloorpPanel,
        isPrivate: Bool
    ) throws -> any FloorpWebPanelSessionProtocol {
        let configuration = try Self.configuration(for: panel)
        let key = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: panel.id,
            isPrivate: isPrivate
        )

        if var entry = entries[key] {
            guard entry.configuration.homeURL == configuration.homeURL else {
                removeSession(for: key, preservingRestoration: false)
                return try makeSession(for: key, configuration: configuration)
            }

            if entry.configuration != configuration {
                entry.session.updateConfiguration(configuration)
                entry.configuration = configuration
                entries[key] = entry
            }
            touchRegularSession(for: key)
            return entry.session
        }

        return try makeSession(for: key, configuration: configuration)
    }

    @discardableResult
    func hideSession(
        _ session: any FloorpWebPanelSessionProtocol,
        autoUnload: Bool
    ) -> Bool {
        let key = session.key
        guard key.windowUUID == windowUUID,
              let entry = entries[key],
              entry.session === session else {
            return false
        }

        session.setVisible(false)
        if autoUnload {
            removeSession(for: key, preservingRestoration: true)
        }
        return true
    }

    @discardableResult
    func setAudioMuted(
        _ isMuted: Bool,
        for key: FloorpWebPanelSessionKey
    ) -> Bool {
        guard key.windowUUID == windowUUID, let entry = entries[key] else { return false }
        entry.session.setAudioMuted(isMuted)
        return true
    }

    @discardableResult
    func unloadSession(for key: FloorpWebPanelSessionKey) -> Bool {
        guard key.windowUUID == windowUUID, entries[key] != nil else { return false }
        removeSession(for: key, preservingRestoration: true)
        return true
    }

    @discardableResult
    func closePrivateSessions() -> Bool {
        let keys = entries.keys.filter(\.isPrivate)
        Array(restorationSnapshots.keys.filter(\.isPrivate))
            .forEach { restorationSnapshots.removeValue(forKey: $0) }
        keys.forEach { removeSession(for: $0, preservingRestoration: false) }
        return !keys.isEmpty
    }

    func reconcile(with panels: [FloorpPanel]) {
        let configurations = Self.uniqueValidConfigurations(from: panels)

        for key in Array(entries.keys) {
            guard var entry = entries[key],
                  let configuration = configurations[key.panelID] else {
                removeSession(for: key, preservingRestoration: false)
                continue
            }

            guard entry.configuration.homeURL == configuration.homeURL else {
                removeSession(for: key, preservingRestoration: false)
                continue
            }

            if entry.configuration != configuration {
                entry.session.updateConfiguration(configuration)
                entry.configuration = configuration
                entries[key] = entry
            }
        }

        for (key, snapshot) in Array(restorationSnapshots) {
            guard let configuration = configurations[key.panelID],
                  configuration.homeURL == snapshot.homeURL else {
                restorationSnapshots.removeValue(forKey: key)
                continue
            }
        }
    }

    func invalidateAll() {
        let sessions = entries.values.map(\.session)
        entries.removeAll()
        regularSessionLRU.removeAll()
        restorationSnapshots.removeAll()
        sessions.forEach { $0.invalidate() }
    }

    private func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration
    ) throws -> any FloorpWebPanelSessionProtocol {
        let restorationURL: URL?
        if let snapshot = restorationSnapshots[key],
           snapshot.homeURL == configuration.homeURL {
            restorationURL = FloorpWebPanelRestorationPolicy.safeWebURL(snapshot.currentURL)
        } else {
            restorationSnapshots.removeValue(forKey: key)
            restorationURL = nil
        }
        let session = try factory.makeSession(
            for: key,
            configuration: configuration,
            restorationURL: restorationURL
        )
        guard session.key == key else {
            session.invalidate()
            throw FloorpWebPanelSessionStoreError.factoryReturnedMismatchedKey
        }

        restorationSnapshots.removeValue(forKey: key)
        entries[key] = Entry(session: session, configuration: configuration)
        touchRegularSession(for: key)
        trimRegularSessionsIfNeeded()
        return session
    }

    private func touchRegularSession(for key: FloorpWebPanelSessionKey) {
        guard !key.isPrivate else { return }
        regularSessionLRU.removeAll { $0 == key }
        regularSessionLRU.append(key)
    }

    private func trimRegularSessionsIfNeeded() {
        while regularSessionLRU.count > regularSessionLimit {
            let key = regularSessionLRU.removeFirst()
            removeSession(for: key, preservingRestoration: true)
        }
    }

    private func removeSession(
        for key: FloorpWebPanelSessionKey,
        preservingRestoration: Bool
    ) {
        regularSessionLRU.removeAll { $0 == key }
        guard let entry = entries.removeValue(forKey: key) else {
            if !preservingRestoration {
                restorationSnapshots.removeValue(forKey: key)
            }
            return
        }
        if preservingRestoration {
            if let currentURL = FloorpWebPanelRestorationPolicy.safeWebURL(
                entry.session.restorationURLForUnload()
            ) {
                restorationSnapshots[key] = RestorationSnapshot(
                    homeURL: entry.configuration.homeURL,
                    currentURL: currentURL
                )
            } else {
                restorationSnapshots.removeValue(forKey: key)
            }
        } else {
            restorationSnapshots.removeValue(forKey: key)
        }
        entry.session.unload()
    }

    private static func configuration(
        for panel: FloorpPanel
    ) throws -> FloorpWebPanelSessionConfiguration {
        let validated = try FloorpWebPanelValidator.validate(panel)
        return FloorpWebPanelSessionConfiguration(
            panelTitle: validated.title,
            homeURL: validated.url,
            iconName: validated.iconName
        )
    }

    private static func uniqueValidConfigurations(
        from panels: [FloorpPanel]
    ) -> [String: FloorpWebPanelSessionConfiguration] {
        var identifiers = Set<String>()
        var duplicateIdentifiers = Set<String>()

        for panel in panels where !identifiers.insert(panel.id).inserted {
            duplicateIdentifiers.insert(panel.id)
        }

        var configurations = [String: FloorpWebPanelSessionConfiguration]()
        for panel in panels where !duplicateIdentifiers.contains(panel.id) {
            guard let configuration = try? configuration(for: panel) else { continue }
            configurations[panel.id] = configuration
        }
        return configurations
    }
}
