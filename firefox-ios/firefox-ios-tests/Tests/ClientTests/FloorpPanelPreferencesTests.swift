// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Common
import UIKit
@testable import Client

@MainActor
final class FloorpPanelPreferencesTests: XCTestCase {
    private let panelsKey = "floorp.overlayDrawer.panels"
    private let configKey = "floorp.overlayDrawer.config"
    private let schemaVersionKey = "floorp.overlayDrawer.schemaVersion"

    func testLegacyWebPanelMigratesSafeDefaultsAndPersistsAcrossRestart() throws {
        let (defaults, suiteName) = try makeDefaults(schemaVersion: 2)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPanel = makeWebPanel(id: "legacy-web")
        try store([legacyPanel], in: defaults)

        let manager = FloorpPanelManager(defaults: defaults)
        let preferences = try manager.webPanelPreferences(for: legacyPanel.id)

        XCTAssertEqual(preferences.schemaVersion, FloorpWebPanelPreferences.currentSchemaVersion)
        XCTAssertEqual(preferences.revision, 0)
        XCTAssertEqual(preferences.contentWidth, FloorpWebPanelPreferences.defaultContentWidth)
        XCTAssertEqual(preferences.zoomLevel, .defaultLevel)
        XCTAssertEqual(preferences.contentMode, .mobile)
        XCTAssertFalse(manager.config.autoUnload)
        XCTAssertEqual(defaults.integer(forKey: schemaVersionKey), 3)

        let rawPanels = try rawPanelObjects(in: defaults)
        let rawPreferences = try XCTUnwrap(rawPanels.first?["webPreferences"] as? [String: Any])
        XCTAssertEqual(
            (rawPreferences["schemaVersion"] as? NSNumber)?.intValue,
            FloorpWebPanelPreferences.currentSchemaVersion
        )
        let rawConfigData = try XCTUnwrap(defaults.data(forKey: configKey))
        let rawConfig = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rawConfigData) as? [String: Any]
        )
        XCTAssertEqual(rawConfig["autoUnload"] as? Bool, false)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(try restarted.webPanelPreferences(for: legacyPanel.id), preferences)
        XCTAssertFalse(restarted.config.autoUnload)
    }

    func testPreferencesRemainIndependentPerWebPanelAcrossRestart() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let first = try addWebPanel(to: manager, title: "First")
        let second = try addWebPanel(to: manager, title: "Second")
        notificationCenter.postCallCount = 0

        _ = try manager.setWebPanelContentWidth(
            450,
            for: first.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: first.id)
        )
        _ = try manager.setWebPanelContentMode(
            .desktop,
            for: first.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: first.id)
        )
        for _ in 0..<2 {
            _ = try manager.adjustWebPanelZoom(
                for: second.id,
                change: .increase,
                expectedRevision: try manager.webPanelPreferencesRevision(for: second.id)
            )
        }

        XCTAssertEqual(notificationCenter.postCallCount, 4)
        let restarted = FloorpPanelManager(defaults: defaults)
        let firstPreferences = try restarted.webPanelPreferences(for: first.id)
        let secondPreferences = try restarted.webPanelPreferences(for: second.id)
        XCTAssertEqual(firstPreferences.contentWidth, 450)
        XCTAssertEqual(firstPreferences.zoomLevel, .oneHundredPercent)
        XCTAssertEqual(firstPreferences.contentMode, .desktop)
        XCTAssertEqual(secondPreferences.contentWidth, FloorpWebPanelPreferences.defaultContentWidth)
        XCTAssertEqual(secondPreferences.zoomLevel, .oneHundredTwentyFivePercent)
        XCTAssertEqual(secondPreferences.contentMode, .mobile)
    }

    func testStoredWidthClampsToModelBoundsWhilePresentationOwnsAvailableWidthClamp() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let panel = try addWebPanel(to: manager)
        notificationCenter.postCallCount = 0

        let minimum = try manager.setWebPanelContentWidth(
            Int.min,
            for: panel.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(minimum.contentWidth, FloorpWebPanelPreferences.minimumContentWidth)
        let minimumRevision = minimum.revision
        let dataAtMinimum = try XCTUnwrap(defaults.data(forKey: panelsKey))

        let minimumNoOp = try manager.setWebPanelContentWidth(
            FloorpWebPanelPreferences.minimumContentWidth - 1,
            for: panel.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(minimumNoOp.revision, minimumRevision)
        XCTAssertEqual(defaults.data(forKey: panelsKey), dataAtMinimum)
        XCTAssertEqual(notificationCenter.postCallCount, 1)

        let maximum = try manager.setWebPanelContentWidth(
            Int.max,
            for: panel.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(maximum.contentWidth, FloorpWebPanelPreferences.maximumContentWidth)
        XCTAssertEqual(notificationCenter.postCallCount, 2)
        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(
            try restarted.webPanelPreferences(for: panel.id).contentWidth,
            FloorpWebPanelPreferences.maximumContentWidth
        )
    }

    func testZoomUsesBoundedNativeStepsAndResetWithoutNoOpNotification() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let panel = try addWebPanel(to: manager)
        notificationCenter.postCallCount = 0

        var observedDecrease = [FloorpWebPanelZoomLevel]()
        while try manager.webPanelPreferences(for: panel.id).zoomLevel != .fiftyPercent {
            let preferences = try manager.adjustWebPanelZoom(
                for: panel.id,
                change: .decrease,
                expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
            )
            observedDecrease.append(preferences.zoomLevel)
        }
        XCTAssertEqual(observedDecrease, [.ninetyPercent, .seventyFivePercent, .fiftyPercent])

        let minimumRevision = try manager.webPanelPreferences(for: panel.id).revision
        _ = try manager.adjustWebPanelZoom(
            for: panel.id,
            change: .decrease,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).revision, minimumRevision)

        while try manager.webPanelPreferences(for: panel.id).zoomLevel != .threeHundredPercent {
            _ = try manager.adjustWebPanelZoom(
                for: panel.id,
                change: .increase,
                expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
            )
        }
        let maximumRevision = try manager.webPanelPreferences(for: panel.id).revision
        _ = try manager.adjustWebPanelZoom(
            for: panel.id,
            change: .increase,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).revision, maximumRevision)

        let reset = try manager.adjustWebPanelZoom(
            for: panel.id,
            change: .reset,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(reset.zoomLevel, .defaultLevel)
        let postResetCount = notificationCenter.postCallCount
        _ = try manager.adjustWebPanelZoom(
            for: panel.id,
            change: .reset,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(notificationCenter.postCallCount, postResetCount)
        XCTAssertEqual(FloorpWebPanelZoomLevel.fiftyPercent.scale, 0.5)
        XCTAssertEqual(FloorpWebPanelZoomLevel.threeHundredPercent.scale, 3)
    }

    func testContentModeAndGlobalAutoUnloadPersistAndSuppressNoOpNotifications() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let panel = try addWebPanel(to: manager)
        notificationCenter.postCallCount = 0

        let desktop = try manager.setWebPanelContentMode(
            .desktop,
            for: panel.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(desktop.contentMode, .desktop)
        let panelDataAtDesktop = try XCTUnwrap(defaults.data(forKey: panelsKey))
        _ = try manager.setWebPanelContentMode(
            .desktop,
            for: panel.id,
            expectedRevision: try manager.webPanelPreferencesRevision(for: panel.id)
        )
        XCTAssertEqual(defaults.data(forKey: panelsKey), panelDataAtDesktop)

        let enabled = try manager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
        )
        XCTAssertTrue(enabled.autoUnload)
        let configDataAtEnabled = try XCTUnwrap(defaults.data(forKey: configKey))
        _ = try manager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
        )
        XCTAssertEqual(defaults.data(forKey: configKey), configDataAtEnabled)
        XCTAssertEqual(notificationCenter.postCallCount, 2)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(try restarted.webPanelPreferences(for: panel.id).contentMode, .desktop)
        XCTAssertTrue(restarted.config.autoUnload)
    }

    func testTwoManagerCASRejectsStalePanelAndConfigEditsWithoutOverwrite() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstNotifications = MockNotificationCenter()
        let secondNotifications = MockNotificationCenter()
        let firstManager = FloorpPanelManager(defaults: defaults, notificationCenter: firstNotifications)
        let panel = try addWebPanel(to: firstManager)
        let secondManager = FloorpPanelManager(defaults: defaults, notificationCenter: secondNotifications)
        let stalePanelRevision = try secondManager.webPanelPreferencesRevision(for: panel.id)
        let staleConfigRevision = FloorpOverlayDrawerConfigRevision(config: secondManager.config)

        _ = try firstManager.setWebPanelContentWidth(
            440,
            for: panel.id,
            expectedRevision: try firstManager.webPanelPreferencesRevision(for: panel.id)
        )
        _ = try firstManager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: firstManager.config)
        )

        XCTAssertThrowsError(
            try secondManager.setWebPanelContentMode(
                .desktop,
                for: panel.id,
                expectedRevision: stalePanelRevision
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .editConflict(id: panel.id))
        }
        XCTAssertThrowsError(
            try secondManager.setAutoUnload(false, expectedRevision: staleConfigRevision)
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .configEditConflict)
        }
        XCTAssertEqual(secondNotifications.postCallCount, 0)
        XCTAssertEqual(try secondManager.webPanelPreferences(for: panel.id).contentWidth, 440)
        XCTAssertTrue(secondManager.config.autoUnload)

        let retriedPreferences = try secondManager.setWebPanelContentMode(
            .desktop,
            for: panel.id,
            expectedRevision: try secondManager.webPanelPreferencesRevision(for: panel.id)
        )
        let retriedConfig = try secondManager.setAutoUnload(
            false,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: secondManager.config)
        )
        XCTAssertEqual(retriedPreferences.contentMode, .desktop)
        XCTAssertFalse(retriedConfig.autoUnload)
        XCTAssertEqual(secondNotifications.postCallCount, 2)

        let verifier = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(try verifier.webPanelPreferences(for: panel.id).contentWidth, 440)
        XCTAssertEqual(try verifier.webPanelPreferences(for: panel.id).contentMode, .desktop)
        XCTAssertFalse(verifier.config.autoUnload)
    }

    func testStaleRegistryMutationsMergeLatestWebPanelPreferences() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = FloorpPanelManager(defaults: defaults)
        let target = try addWebPanel(to: writer, title: "Target")
        let removable = try addWebPanel(to: writer, title: "Removable")

        func advanceWidth(to width: Int) throws {
            _ = try writer.setWebPanelContentWidth(
                width,
                for: target.id,
                expectedRevision: try writer.webPanelPreferencesRevision(for: target.id)
            )
        }

        func assertStoredWidth(_ width: Int) throws {
            let verifier = FloorpPanelManager(defaults: defaults)
            XCTAssertEqual(try verifier.webPanelPreferences(for: target.id).contentWidth, width)
        }

        let staleEditor = FloorpPanelManager(defaults: defaults)
        let stalePanel = try XCTUnwrap(staleEditor.panel(for: target.id))
        try advanceWidth(to: 410)
        try staleEditor.updateWebPanel(
            id: target.id,
            draft: FloorpWebPanelDraft(title: "Updated", urlText: "example.org"),
            expectedRevision: FloorpWebPanelRevision(panel: stalePanel)
        )
        try assertStoredWidth(410)

        let staleMover = FloorpPanelManager(defaults: defaults)
        try advanceWidth(to: 420)
        try staleMover.movePanel(id: target.id, to: 0)
        try assertStoredWidth(420)

        let staleAdder = FloorpPanelManager(defaults: defaults)
        try advanceWidth(to: 430)
        _ = try addWebPanel(to: staleAdder, title: "Added")
        try assertStoredWidth(430)

        let staleRemover = FloorpPanelManager(defaults: defaults)
        try advanceWidth(to: 440)
        try staleRemover.removePanel(id: removable.id)
        try assertStoredWidth(440)

        try writer.removePanel(id: "floorp//history")
        let staleRestorer = FloorpPanelManager(defaults: defaults)
        try advanceWidth(to: 450)
        XCTAssertEqual(try staleRestorer.restoreMissingBuiltIns().map(\.id), ["floorp//history"])
        try assertStoredWidth(450)

        let staleReorderer = FloorpPanelManager(defaults: defaults)
        let reversedIDs = staleReorderer.panels.map(\.id).reversed()
        try advanceWidth(to: 460)
        try staleReorderer.reorderPanels(orderedIds: Array(reversedIDs))
        try assertStoredWidth(460)

        let verifier = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(verifier.panel(for: target.id)?.title, "Updated")
    }

    func testGenericConfigMutationUsesLatestRevisionAndCanRetryAfterConflict() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = FloorpPanelManager(defaults: defaults)
        let notificationCenter = MockNotificationCenter()
        let staleManager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let staleRevision = FloorpOverlayDrawerConfigRevision(config: staleManager.config)

        _ = try writer.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: writer.config)
        )
        XCTAssertThrowsError(
            try staleManager.updateConfig(
                FloorpOverlayDrawerConfig(isEnabled: false, sidebarWidth: 72, autoUnload: false),
                expectedRevision: staleRevision
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .configEditConflict)
        }
        XCTAssertTrue(staleManager.config.autoUnload)
        XCTAssertEqual(notificationCenter.postCallCount, 0)

        let updated = try staleManager.updateConfig(
            FloorpOverlayDrawerConfig(isEnabled: false, sidebarWidth: 72, autoUnload: true),
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: staleManager.config)
        )
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.sidebarWidth, 72)
        XCTAssertTrue(updated.autoUnload)
        XCTAssertEqual(notificationCenter.postCallCount, 1)

        let dataAfterUpdate = try XCTUnwrap(defaults.data(forKey: configKey))
        let noOp = try staleManager.updateConfig(
            updated,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: staleManager.config)
        )
        XCTAssertEqual(noOp, updated)
        XCTAssertEqual(defaults.data(forKey: configKey), dataAfterUpdate)
        XCTAssertEqual(notificationCenter.postCallCount, 1)
    }

    func testBuiltInPreferenceMutationIsRejectedWithoutRewriteOrNotification() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)
        let bookmark = try XCTUnwrap(manager.panel(for: "floorp//bookmarks"))
        let rawData = try XCTUnwrap(defaults.data(forKey: panelsKey))

        XCTAssertThrowsError(
            try manager.setWebPanelContentWidth(
                420,
                for: bookmark.id,
                expectedRevision: FloorpWebPanelPreferencesRevision(panel: bookmark)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .panelIsNotWeb(id: bookmark.id))
        }
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        XCTAssertEqual(notificationCenter.postCallCount, 0)
    }

    func testFuturePreferenceSchemaLeavesStoredRegistryByteForByteUntouched() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bookmark = try XCTUnwrap(FloorpPanel.defaultPanels().first)
        let bookmarkObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bookmark)) as? [String: Any]
        )
        let futurePanel: [String: Any] = [
            "id": "future-preferences-web",
            "type": "web",
            "title": "Future",
            "url": "https://example.com",
            "iconName": "globe",
            "sortOrder": 1,
            "webPreferences": [
                "schemaVersion": FloorpWebPanelPreferences.currentSchemaVersion + 1,
                "revision": 7,
                "contentWidth": 420,
                "zoomLevel": 100,
                "contentMode": "mobile",
                "futureValue": "preserve-me",
            ],
        ]
        let rawData = try JSONSerialization.data(withJSONObject: [bookmarkObject, futurePanel])
        defaults.set(rawData, forKey: panelsKey)
        let configData = try JSONEncoder().encode(FloorpOverlayDrawerConfig())
        defaults.set(configData, forKey: configKey)
        let notificationCenter = MockNotificationCenter()

        let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)

        XCTAssertTrue(manager.isRegistryReadOnly)
        XCTAssertEqual(manager.panels.map(\.id), [bookmark.id])
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        XCTAssertEqual(defaults.data(forKey: configKey), configData)
        XCTAssertThrowsError(
            try manager.updateConfig(
                FloorpOverlayDrawerConfig(autoUnload: true),
                expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
        }
        XCTAssertThrowsError(
            try manager.setAutoUnload(
                true,
                expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
        }
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        XCTAssertEqual(defaults.data(forKey: configKey), configData)
        XCTAssertEqual(notificationCenter.postCallCount, 0)
    }

    func testInvalidWidthClampsButUnknownTypedValuesRemainReadOnly() throws {
        let clamped = try JSONDecoder().decode(
            FloorpWebPanelPreferences.self,
            from: try JSONSerialization.data(withJSONObject: [
                "schemaVersion": FloorpWebPanelPreferences.currentSchemaVersion,
                "revision": 0,
                "contentWidth": -1,
                "zoomLevel": 100,
                "contentMode": "mobile",
            ])
        )
        XCTAssertEqual(clamped.contentWidth, FloorpWebPanelPreferences.minimumContentWidth)

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var panelObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeWebPanel())) as? [String: Any]
        )
        panelObject["webPreferences"] = [
            "schemaVersion": FloorpWebPanelPreferences.currentSchemaVersion,
            "revision": 0,
            "contentWidth": 400,
            "zoomLevel": 42,
            "contentMode": "future-mode",
        ]
        let rawData = try JSONSerialization.data(withJSONObject: [panelObject])
        defaults.set(rawData, forKey: panelsKey)

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertTrue(manager.isRegistryReadOnly)
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
    }

    func testCorruptSchemaMarkersRemainReadOnlyAndPreserveThePersistentDomain() throws {
        let corruptMarkers: [Any] = ["garbage", true, 3.5, Data([0x03])]

        for (index, marker) in corruptMarkers.enumerated() {
            let suiteName = "FloorpPanelPreferencesTests-CorruptSchema-\(index)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var panel = makeWebPanel(id: "corrupt-schema-web-\(index)")
            panel.webPreferences = FloorpWebPanelPreferences(contentWidth: 420)
            try store([panel], in: defaults)
            defaults.set(
                try JSONEncoder().encode(FloorpOverlayDrawerConfig(autoUnload: true)),
                forKey: configKey
            )
            defaults.set(marker, forKey: schemaVersionKey)
            let domainBeforeInitialization = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
            let notificationCenter = MockNotificationCenter()

            let manager = FloorpPanelManager(defaults: defaults, notificationCenter: notificationCenter)

            XCTAssertTrue(manager.isRegistryReadOnly)
            XCTAssertThrowsError(
                try manager.setWebPanelContentWidth(
                    440,
                    for: panel.id,
                    expectedRevision: FloorpWebPanelPreferencesRevision(panel: panel)
                )
            ) { error in
                XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
            }
            XCTAssertThrowsError(
                try manager.updateConfig(
                    FloorpOverlayDrawerConfig(autoUnload: false),
                    expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
                )
            ) { error in
                XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
            }
            let domainAfterMutations = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
            XCTAssertTrue(
                NSDictionary(dictionary: domainBeforeInitialization).isEqual(to: domainAfterMutations)
            )
            XCTAssertEqual(notificationCenter.postCallCount, 0)
        }
    }

    func testMissingSchemaMarkerIsTheOnlyImplicitLegacyVersion() throws {
        let suiteName = "FloorpPanelPreferencesTests-MissingSchema-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPanel = makeWebPanel(id: "missing-schema-web")
        try store([legacyPanel], in: defaults)
        XCTAssertNil(defaults.object(forKey: schemaVersionKey))

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertFalse(manager.isRegistryReadOnly)
        XCTAssertEqual(defaults.integer(forKey: schemaVersionKey), 3)
        XCTAssertNotNil(manager.panel(for: "floorp//notes"))
        let preferences = try manager.webPanelPreferences(for: legacyPanel.id)
        XCTAssertEqual(preferences, FloorpWebPanelPreferences())
        XCTAssertNotNil(defaults.data(forKey: configKey))
    }

    func testCorruptConfigBlocksMigrationAndAllTypedWrites() throws {
        let (defaults, suiteName) = try makeDefaults(schemaVersion: 2)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let panel = makeWebPanel()
        try store([panel], in: defaults)
        let rawPanels = try XCTUnwrap(defaults.data(forKey: panelsKey))
        let invalidConfig = Data(#"{"autoUnload":"future"}"#.utf8)
        defaults.set(invalidConfig, forKey: configKey)

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertTrue(manager.isRegistryReadOnly)
        XCTAssertEqual(defaults.integer(forKey: schemaVersionKey), 2)
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawPanels)
        XCTAssertEqual(defaults.data(forKey: configKey), invalidConfig)
        XCTAssertThrowsError(
            try manager.setWebPanelContentMode(
                .desktop,
                for: panel.id,
                expectedRevision: FloorpWebPanelPreferencesRevision(panel: panel)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
        }
    }

    private func makeDefaults(
        schemaVersion: Int = 3
    ) throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "FloorpPanelPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(schemaVersion, forKey: schemaVersionKey)
        return (defaults, suiteName)
    }

    private func makeWebPanel(id: String = "web-panel") -> FloorpPanel {
        FloorpPanel(
            id: id,
            type: .web,
            title: "Panel",
            url: "https://example.com",
            iconName: "globe",
            sortOrder: 0
        )
    }

    private func addWebPanel(
        to manager: FloorpPanelManager,
        title: String = "Panel"
    ) throws -> FloorpPanel {
        try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: title, urlText: "example.com")
        )
    }

    private func store(_ panels: [FloorpPanel], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(panels), forKey: panelsKey)
    }

    private func rawPanelObjects(in defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: panelsKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}

@MainActor
final class FloorpPanelRegistryAutoUnloadTests: XCTestCase {
    func testSwitchReflectsInitialValueAndKeepsPanelSectionsStable() throws {
        try assertInitialState(isOn: false)
        try assertInitialState(isOn: true)
    }

    func testReusedSettingCellClearsItsCustomAccessibilityContainer() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        let host = host(controller)
        defer { host.cleanup() }
        let cell = UICollectionViewListCell()

        controller.configure(cell: cell, for: .autoUnload)
        XCTAssertFalse(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityElements?.count, 1)

        let firstPanel = try XCTUnwrap(fixture.manager.panels.first)
        controller.configure(cell: cell, for: .panel(firstPanel.id))

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertNil(cell.accessibilityElements)
        XCTAssertEqual(
            cell.accessibilityIdentifier,
            "Floorp.PanelRegistry.panel.\(firstPanel.sortOrder)"
        )
    }

    func testTogglePersistsThroughManagerCASBoundary() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var mutationCount = 0
        let controller = fixture.makeController { value, expectedRevision in
            mutationCount += 1
            XCTAssertEqual(expectedRevision.value, 0)
            return try fixture.manager.setAutoUnload(
                value,
                expectedRevision: expectedRevision
            )
        }
        let host = host(controller)
        defer { host.cleanup() }
        let control = try autoUnloadSwitch(in: controller)

        control.setOn(true, animated: false)
        control.sendActions(for: .valueChanged)

        let didReloadWithoutReentry = await waitUntil {
            guard let currentControl = self.findAutoUnloadSwitch(in: controller) else {
                return false
            }
            return currentControl.isOn && currentControl.expectedRevision.value == 1
        }
        XCTAssertTrue(didReloadWithoutReentry)
        XCTAssertEqual(mutationCount, 1)
        XCTAssertTrue(control.isOn)
        XCTAssertTrue(fixture.manager.config.autoUnload)
        XCTAssertEqual(fixture.manager.config.revision, 1)
        try autoUnloadSwitch(in: controller).sendActions(for: .valueChanged)
        XCTAssertEqual(mutationCount, 1)
        let restartedManager = FloorpPanelManager(defaults: fixture.defaults)
        XCTAssertTrue(restartedManager.config.autoUnload)
    }

    func testCASConflictRollsBackToLatestManagerValueAndShowsError() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        let host = host(controller)
        defer { host.cleanup() }
        let staleControl = try autoUnloadSwitch(in: controller)
        let currentConfig = fixture.manager.config
        _ = try fixture.manager.updateConfig(
            FloorpOverlayDrawerConfig(
                isEnabled: false,
                sidebarWidth: currentConfig.sidebarWidth,
                autoUnload: false
            ),
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: currentConfig)
        )

        staleControl.setOn(true, animated: false)
        staleControl.sendActions(for: .valueChanged)

        XCTAssertFalse(staleControl.isOn)
        XCTAssertFalse(fixture.manager.config.autoUnload)
        XCTAssertEqual(fixture.manager.config.revision, 1)
        let alert = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, FloorpStrings.PanelRegistry.operationFailedTitle)
        XCTAssertEqual(alert.message, FloorpStrings.PanelRegistry.operationFailedMessage)
    }

    func testStorageFailureRollsBackAndShowsExistingOperationError() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var mutationCount = 0
        let controller = fixture.makeController { _, _ in
            mutationCount += 1
            throw FloorpPanelError.storageError("Injected persistence failure")
        }
        let host = host(controller)
        defer { host.cleanup() }
        let control = try autoUnloadSwitch(in: controller)

        control.setOn(true, animated: false)
        control.sendActions(for: .valueChanged)

        XCTAssertEqual(mutationCount, 1)
        XCTAssertFalse(control.isOn)
        XCTAssertFalse(fixture.manager.config.autoUnload)
        XCTAssertEqual(fixture.manager.config.revision, 0)
        let alert = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, FloorpStrings.PanelRegistry.operationFailedTitle)
        XCTAssertEqual(alert.message, FloorpStrings.PanelRegistry.operationFailedMessage)
    }

    func testManagerNotificationUpdatesAnotherControllerWithoutMutating() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let firstController = fixture.makeController()
        var secondMutationCount = 0
        let secondController = fixture.makeController { value, expectedRevision in
            secondMutationCount += 1
            return try fixture.manager.setAutoUnload(
                value,
                expectedRevision: expectedRevision
            )
        }
        let firstHost = host(firstController)
        defer { firstHost.cleanup() }
        let secondHost = host(secondController)
        defer { secondHost.cleanup() }
        let firstControl = try autoUnloadSwitch(in: firstController)
        let initialSecondControl = try autoUnloadSwitch(in: secondController)
        XCTAssertFalse(initialSecondControl.isOn)
        XCTAssertEqual(initialSecondControl.expectedRevision.value, 0)

        firstControl.setOn(true, animated: false)
        firstControl.sendActions(for: .valueChanged)

        let didUpdateSecondController = await waitUntil {
            guard let currentControl = self.findAutoUnloadSwitch(in: secondController) else {
                return false
            }
            return currentControl.isOn && currentControl.expectedRevision.value == 1
        }
        XCTAssertTrue(didUpdateSecondController)
        let updatedSecondControl = try autoUnloadSwitch(in: secondController)
        XCTAssertFalse(updatedSecondControl === initialSecondControl)
        XCTAssertEqual(updatedSecondControl.expectedRevision.value, 1)
        XCTAssertEqual(secondMutationCount, 0)
        XCTAssertTrue(fixture.manager.config.autoUnload)
    }

    func testDuplicateValueChangedIsANoOp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var mutationCount = 0
        let controller = fixture.makeController { value, expectedRevision in
            mutationCount += 1
            return try fixture.manager.setAutoUnload(
                value,
                expectedRevision: expectedRevision
            )
        }
        let host = host(controller)
        defer { host.cleanup() }
        let control = try autoUnloadSwitch(in: controller)

        control.sendActions(for: .valueChanged)
        XCTAssertEqual(mutationCount, 0)
        XCTAssertEqual(fixture.manager.config.revision, 0)

        control.setOn(true, animated: false)
        control.sendActions(for: .valueChanged)
        control.sendActions(for: .valueChanged)

        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(fixture.manager.config.revision, 1)
        XCTAssertTrue(fixture.manager.config.autoUnload)
    }

    private func assertInitialState(isOn: Bool) throws {
        let fixture = try makeFixture(initialAutoUnload: isOn)
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        let host = host(controller)
        defer { host.cleanup() }
        let collectionView = try XCTUnwrap(
            findView(identifier: "Floorp.PanelRegistry.collection", in: controller.view)
                as? UICollectionView
        )
        let control = try autoUnloadSwitch(in: controller)
        let settingsCell = try XCTUnwrap(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 1))
        )

        XCTAssertEqual(collectionView.numberOfSections, 3)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), fixture.manager.panels.count)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 1), 1)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 2), 1)
        XCTAssertNotNil(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(control.isOn, isOn)
        XCTAssertEqual(control.accessibilityIdentifier, "Floorp.PanelRegistry.autoUnload")
        XCTAssertEqual(control.accessibilityLabel, FloorpStrings.PanelRegistry.autoUnload)
        XCTAssertEqual(
            control.accessibilityHint,
            FloorpStrings.PanelRegistry.autoUnloadDescription
        )
        XCTAssertTrue(control.isAccessibilityElement)
        XCTAssertFalse(settingsCell.isAccessibilityElement)
        let accessibilityElements = try XCTUnwrap(settingsCell.accessibilityElements)
        XCTAssertEqual(accessibilityElements.count, 1)
        XCTAssertTrue((accessibilityElements[0] as AnyObject) === control)
    }

    private func makeFixture(
        initialAutoUnload: Bool = false
    ) throws -> FloorpPanelRegistryAutoUnloadFixture {
        let suiteName = "FloorpPanelRegistryAutoUnloadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let notificationCenter = NotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        if initialAutoUnload {
            _ = try manager.setAutoUnload(
                true,
                expectedRevision: FloorpOverlayDrawerConfigRevision(config: manager.config)
            )
        }
        return FloorpPanelRegistryAutoUnloadFixture(
            suiteName: suiteName,
            defaults: defaults,
            manager: manager,
            notificationCenter: notificationCenter
        )
    }

    private func host(
        _ controller: FloorpPanelRegistryViewController
    ) -> FloorpPanelRegistryAutoUnloadHost {
        let navigationController = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        navigationController.view.frame = window.bounds
        navigationController.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return FloorpPanelRegistryAutoUnloadHost(window: window)
    }

    private func autoUnloadSwitch(
        in controller: FloorpPanelRegistryViewController
    ) throws -> FloorpPanelRegistryAutoUnloadSwitch {
        try XCTUnwrap(findAutoUnloadSwitch(in: controller))
    }

    private func findAutoUnloadSwitch(
        in controller: FloorpPanelRegistryViewController
    ) -> FloorpPanelRegistryAutoUnloadSwitch? {
        controller.view.layoutIfNeeded()
        return findView(
            identifier: "Floorp.PanelRegistry.autoUnload",
            in: controller.view
        ) as? FloorpPanelRegistryAutoUnloadSwitch
    }

    private func findView(identifier: String, in rootView: UIView) -> UIView? {
        if rootView.accessibilityIdentifier == identifier {
            return rootView
        }
        for subview in rootView.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

@MainActor
private struct FloorpPanelRegistryAutoUnloadFixture {
    let suiteName: String
    let defaults: UserDefaults
    let manager: FloorpPanelManager
    let notificationCenter: NotificationCenter

    func makeController(
        autoUnloadMutation: FloorpPanelRegistryViewController.AutoUnloadMutation? = nil
    ) -> FloorpPanelRegistryViewController {
        FloorpPanelRegistryViewController(
            panelManager: manager,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            autoUnloadMutation: autoUnloadMutation
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private struct FloorpPanelRegistryAutoUnloadHost {
    let window: UIWindow

    func cleanup() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
