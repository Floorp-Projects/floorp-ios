// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Darwin
import Foundation
import XCTest

/// The protected Todo 20 mobile actor.
///
/// This test intentionally exchanges only a canonical, metadata-only event
/// stream with the host runner. Note titles, bodies, account identifiers, and
/// credentials stay inside the UI/session process and are never written to
/// the coordination directory, XCTest attachments, or test output.
@MainActor
final class FloorpNotesSyncActualG5TwoClientTests: BaseTestCase {
    private enum Identifier {
        static let toolbarButton = "floorpDrawerToolbarButton"
        static let drawerContainer = "Floorp.Drawer.Container"
        static let notesPanel = "floorp//notes"
        static let notesSearch = "Floorp.Notes.Search"
        static let notesAdd = "Floorp.Notes.Add"
        static let editorTitle = "Floorp.Notes.Editor.Title"
        static let editorBody = "Floorp.Notes.Editor.Body"
        static let editorClose = "Floorp.Notes.Editor.Close"
        static let editorSave = "Floorp.Notes.Editor.Save"
        static let rowPrefix = "Floorp.Notes.Row."
    }

    private struct CaseSpec {
        let name: String
        let index: Int

        var seed: String { "T20-\(String(format: "%02d", index + 1))" }
        var readySequence: Int { index * 4 + 1 }
        var ackSequence: Int { index * 4 + 2 }
        var completeSequence: Int { index * 4 + 3 }
        var finalSequence: Int { index * 4 + 4 }
    }

    private enum MobileActorError: Error {
        case missingEnvironment(String)
        case coordination(String)
        case unsupported(String)
        case ui(String)
    }

    private final class MetadataCoordination {
        private let events: URL

        init(rootPath: String) throws {
            guard !rootPath.isEmpty else {
                throw MobileActorError.coordination("coordination root is empty")
            }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            events = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(
                at: events,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try ensurePrivateDirectory(root)
            try ensurePrivateDirectory(events)
        }

        func write(
            actor: String,
            caseName: String,
            phase: String,
            outcome: String,
            sequence: Int
        ) throws {
            let event: [String: Any] = [
                "actor": actor,
                "case_name": caseName,
                "outcome": outcome,
                "phase": phase,
                "schema_version": 1,
                "sequence": sequence,
            ]
            let json = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([0x0A])
            let path = events.appendingPathComponent("\(actor)-\(String(format: "%04d", sequence)).json")
            let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw MobileActorError.coordination("event publish failed")
            }
            do {
                try json.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        throw MobileActorError.coordination("event payload is empty")
                    }
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(
                            descriptor,
                            baseAddress.advanced(by: written),
                            bytes.count - written
                        )
                        guard count > 0 else {
                            throw MobileActorError.coordination("event write failed")
                        }
                        written += count
                    }
                }
                guard fsync(descriptor) == 0 else {
                    throw MobileActorError.coordination("event sync failed")
                }
                close(descriptor)
            } catch {
                close(descriptor)
                try? FileManager.default.removeItem(at: path)
                throw error
            }
        }

        func wait(
            actor: String,
            sequence: Int,
            caseName: String,
            phase: String,
            timeout: TimeInterval = 180
        ) throws -> [String: Any] {
            let path = events.appendingPathComponent("\(actor)-\(String(format: "%04d", sequence)).json")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: path.path) {
                    let data = try Data(contentsOf: path)
                    guard data.last == 0x0A,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object.keys.sorted() == [
                              "actor", "case_name", "outcome", "phase", "schema_version", "sequence"
                          ],
                          object["schema_version"] as? Int == 1,
                          object["actor"] as? String == actor,
                          FloorpNotesSyncActualG5TwoClientTests.cases.contains(
                              object["case_name"] as? String ?? ""
                          ),
                          ["ack", "complete", "failed"].contains(object["phase"] as? String ?? ""),
                          ["ready", "present", "confirmed", "passed", "failed"].contains(
                              object["outcome"] as? String ?? ""
                          ),
                          object["case_name"] as? String == caseName,
                          object["phase"] as? String == phase,
                          object["sequence"] as? Int == sequence else {
                        throw MobileActorError.coordination("event is malformed")
                    }
                    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
                    guard canonical == data else {
                        throw MobileActorError.coordination("event is not canonical")
                    }
                    return object
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            throw MobileActorError.coordination("event timed out")
        }

        private func ensurePrivateDirectory(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber,
                  mode.intValue & Int(S_IWGRP | S_IWOTH) == 0 else {
                throw MobileActorError.coordination("coordination directory is not private")
            }
        }
    }

    nonisolated private static let cases = [
        "desktop-create-mobile-sync-desktop-recheck",
        "mobile-create-desktop-sync-mobile-recheck",
        "same-record-concurrent-edit",
        "update-delete-conflict",
        "offline-edit-reconnect-retry",
        "upload-save-commit-failure",
        "restart-preserves-unsynced-local-data",
        "old-new-client-mixed",
        "large-empty-multiple-records",
        "account-switch-isolation",
        "retry-idempotence",
        "base-revision-confirmation-gate",
    ]

    override func setUp() async throws {
        // BaseTestCase includes FIREFOX_USE_STAGE_SERVER for Mozilla's normal
        // integration suite. Todo 20 is explicitly production-only.
        launchArguments.removeAll { $0 == LaunchArguments.StageServer }
        launchArguments.append(LaunchArguments.ClearWebData)
        try await super.setUp()
    }

    func testActualG5TwoClientProductionMatrix() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLOORP_NOTES_SYNC_PRODUCTION_QA"] == "1",
              environment["FLOORP_NOTES_SYNC_G5_RUN"] == "1" else {
            XCTFail("PRODUCTION_QA_NOT_AUTHORIZED")
            return
        }
        guard environment["FLOORP_NOTES_SYNC_CAPABILITY_VERSION"]
                == "todo20-production-sync-integrity-v1",
              environment["FLOORP_NOTES_SYNC_BUILD_NUMBER"] == "4" else {
            XCTFail("PRODUCTION_QA_CAPABILITY_MISSING")
            return
        }
        guard let root = environment["FLOORP_NOTES_SYNC_COORDINATION_ROOT"] else {
            XCTFail("CLIENT_PAIR_COORDINATION_ROOT_MISSING")
            return
        }
        let coordination = try MetadataCoordination(rootPath: root)

        try requireProtectedSecretNames(environment, suffix: "A")
        try signIn(
            email: environment["FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL"]!,
            password: environment["FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD"]!
        )
        try waitForInitialSync()

        for (index, name) in Self.cases.enumerated() {
            let spec = CaseSpec(name: name, index: index)
            do {
                try coordination.write(
                    actor: "mobile",
                    caseName: spec.name,
                    phase: "request",
                    outcome: "ready",
                    sequence: spec.readySequence
                )
                _ = try coordination.wait(
                    actor: "desktop",
                    sequence: spec.ackSequence,
                    caseName: spec.name,
                    phase: "ack"
                )
                try performMobileCase(spec, environment: environment)
                try coordination.write(
                    actor: "mobile",
                    caseName: spec.name,
                    phase: "complete",
                    outcome: "passed",
                    sequence: spec.completeSequence
                )
                _ = try coordination.wait(
                    actor: "desktop",
                    sequence: spec.finalSequence,
                    caseName: spec.name,
                    phase: "complete"
                )
                try verifyMobilePostcondition(spec)
            } catch {
                try? coordination.write(
                    actor: "mobile",
                    caseName: spec.name,
                    phase: "failed",
                    outcome: "failed",
                    sequence: spec.completeSequence
                )
                throw error
            }
        }
    }

    private func requireProtectedSecretNames(
        _ environment: [String: String],
        suffix: String
    ) throws {
        let names = [
            "FLOORP_NOTES_SYNC_ACCOUNT_\(suffix)_EMAIL",
            "FLOORP_NOTES_SYNC_ACCOUNT_\(suffix)_PASSWORD",
        ]
        guard names.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw MobileActorError.missingEnvironment("protected account input")
        }
    }

    private func signIn(email: String, password: String) throws {
        navigator.nowAt(BrowserTabMenu)
        navigator.goto(Intro_FxASignin)
        navigator.performAction(Action.OpenEmailToSignIn)
        guard mozWaitForElementToExist(
            app.navigationBars[AccessibilityIdentifiers.Settings.FirefoxAccount.fxaNavigationBar],
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        ) else {
            throw MobileActorError.ui("FxA sign-in view did not open")
        }

        userState.fxaUsername = email
        userState.fxaPassword = password
        navigator.performAction(Action.FxATypeEmail)
        navigator.performAction(Action.FxATapOnContinueButton)
        guard mozWaitForElementToExist(
            app.webViews.secureTextFields.firstMatch,
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        ) else {
            throw MobileActorError.ui("FxA password view did not open")
        }
        navigator.performAction(Action.FxATypePasswordExistingAccount)
        navigator.performAction(Action.FxATapOnSignInButton)
        guard mozWaitForElementToNotExist(
            app.webViews.secureTextFields.firstMatch,
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        ) else {
            throw MobileActorError.ui("FxA sign-in did not complete")
        }
    }

    private func waitForInitialSync() throws {
        navigator.nowAt(BrowserTab)
        waitForTabsButton()
        navigator.goto(BrowserTabMenu)
        navigator.goto(SettingsScreen)
        guard mozWaitForElementToExist(
            app.staticTexts["ACCOUNT"],
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        ) else {
            throw MobileActorError.ui("signed-in Sync settings did not open")
        }
        if app.tables.staticTexts["Sync Now"].exists {
            app.tables.staticTexts["Sync Now"].tap()
            _ = mozWaitForElementToNotExist(
                app.tables.staticTexts["Syncing…"],
                timeout: TIMEOUT_LONG,
                failOnTimeout: false
            )
        }
        navigator.nowAt(BrowserTab)
    }

    private func performMobileCase(
        _ spec: CaseSpec,
        environment: [String: String]
    ) throws {
        switch spec.name {
        case Self.cases[0]:
            try syncNow()
            try require(rowExists(for: spec.seed), "desktop-created record was not visible on mobile")
        case Self.cases[1]:
            try createNote(title: spec.seed, body: "mobile-create-\(spec.seed)")
            try syncNow()
        case Self.cases[2]:
            try createNote(title: spec.seed, body: "concurrent-base-\(spec.seed)")
            try syncNow()
            try editNote(title: spec.seed, appendBody: "mobile-edit-\(spec.seed)")
        case Self.cases[3]:
            try createNote(title: spec.seed, body: "update-delete-\(spec.seed)")
            try syncNow()
        case Self.cases[4]:
            try createNote(title: spec.seed, body: "offline-base-\(spec.seed)")
            try setAirplaneMode(true)
            defer { try? setAirplaneMode(false) }
            try editNote(title: spec.seed, appendBody: "offline-edit-\(spec.seed)")
            app.terminate()
            app.launch()
            openNotes()
            searchFor(spec.seed)
            try require(rowExists(for: spec.seed), "offline local edit was not retained")
            try setAirplaneMode(false)
            try syncNow()
        case Self.cases[5]:
            throw MobileActorError.unsupported(
                "upload/save/commit failure boundaries require deterministic fault injection"
            )
        case Self.cases[7]:
            throw MobileActorError.unsupported(
                "legacy client artifact and reviewed UI driver are not available"
            )
        case Self.cases[6]:
            try createNote(title: spec.seed, body: "restart-\(spec.seed)")
            app.terminate()
            app.launchArguments = app.launchArguments.filter {
                $0 != LaunchArguments.FloorpNotesClearArchive
            }
            app.launch()
            openNotes()
            searchFor(spec.seed)
            try require(rowExists(for: spec.seed), "unsynced record was not retained after restart")
            try syncNow()
        case Self.cases[8]:
            try createNote(title: spec.seed, body: "large-\(String(repeating: "x", count: 2048))")
            try createNote(title: "\(spec.seed)-empty", body: "")
            try createNote(title: "\(spec.seed)-second", body: "multiple-\(spec.seed)")
            try syncNow()
        case Self.cases[9]:
            try requireProtectedSecretNames(environment, suffix: "B")
            try createNote(title: spec.seed, body: "account-a-\(spec.seed)")
            try syncNow()
            try disconnectFromSync()
            try signIn(
                email: environment["FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL"]!,
                password: environment["FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD"]!
            )
            try waitForInitialSync()
            openNotes()
            searchFor(spec.seed)
            try require(!rowExists(for: spec.seed), "account data crossed the mobile account boundary")
        case Self.cases[10]:
            try createNote(title: spec.seed, body: "retry-\(spec.seed)")
            try syncNow()
            try syncNow()
            openNotes()
            searchFor(spec.seed)
            try require(rowCount() == 1, "retry created a duplicate mobile record")
        case Self.cases[11]:
            throw MobileActorError.unsupported(
                "base/revision metadata observation is not available"
            )
        default:
            throw MobileActorError.ui("unknown matrix case")
        }
    }

    private func verifyMobilePostcondition(_ spec: CaseSpec) throws {
        switch spec.name {
        case Self.cases[0], Self.cases[1], Self.cases[2], Self.cases[6], Self.cases[8], Self.cases[10], Self.cases[11]:
            openNotes()
            searchFor(spec.seed)
            if spec.name == Self.cases[2] {
                try syncNow()
                openNotes()
                searchFor(spec.seed)
                try require((1...2).contains(rowCount()), "concurrent edit lost or duplicated the record")
                return
            }
            try require(rowCount() == 1, "mobile postcondition did not retain exactly one record")
        case Self.cases[3]:
            try syncNow()
            openNotes()
            searchFor(spec.seed)
            try require(!rowExists(for: spec.seed), "deleted record resurrected on mobile")
        case Self.cases[9]:
            // The B-account half is intentionally checked before the event;
            // the desktop actor must perform the corresponding remote check.
            break
        default:
            break
        }
    }

    private func disconnectFromSync() throws {
        navigator.nowAt(BrowserTab)
        navigator.goto(BrowserTabMenu)
        navigator.goto(SettingsScreen)
        let signOut = app.tables.cells["SignOut"]
        guard mozWaitForElementToExist(signOut, timeout: TIMEOUT_LONG, failOnTimeout: false) else {
            throw MobileActorError.ui("Sync disconnect control is unavailable")
        }
        signOut.tap()
        let alert = app.alerts.firstMatch
        guard mozWaitForElementToExist(alert, timeout: TIMEOUT, failOnTimeout: false) else {
            throw MobileActorError.ui("Sync disconnect confirmation is unavailable")
        }
        alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        guard mozWaitForElementToExist(
            app.tables.cells["SignInToSync"],
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        ) else {
            throw MobileActorError.ui("Sync disconnect did not complete")
        }
    }

    private func openNotes() {
        let toolbarButton = element(Identifier.toolbarButton)
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: TIMEOUT))
        toolbarButton.tap()
        let drawer = element(Identifier.drawerContainer)
        XCTAssertTrue(drawer.waitForExistence(timeout: TIMEOUT))
        let notesButton = element(Identifier.notesPanel)
        XCTAssertTrue(notesButton.waitForExistence(timeout: TIMEOUT))
        notesButton.tap()
        XCTAssertTrue(element(Identifier.notesSearch).waitForExistence(timeout: TIMEOUT))
    }

    private func createNote(title: String, body: String) throws {
        openNotes()
        let add = element(Identifier.notesAdd)
        guard add.waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("Notes create control is unavailable")
        }
        add.tap()
        let titleField = element(Identifier.editorTitle)
        guard titleField.waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("Notes title editor is unavailable")
        }
        titleField.clearText()
        titleField.typeText(title)
        let bodyField = element(Identifier.editorBody)
        guard bodyField.waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("Notes body editor is unavailable")
        }
        if !body.isEmpty {
            bodyField.tap()
            bodyField.typeText(body)
        }
        element(Identifier.editorSave).tap()
        element(Identifier.editorClose).tap()
        guard element(Identifier.notesSearch).waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("Notes list did not return after save")
        }
    }

    private func editNote(title: String, appendBody: String) throws {
        openNotes()
        searchFor(title)
        let row = noteRows().firstMatch
        guard row.waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("record to edit is unavailable")
        }
        row.tap()
        let body = element(Identifier.editorBody)
        guard body.waitForExistence(timeout: TIMEOUT) else {
            throw MobileActorError.ui("record body editor is unavailable")
        }
        body.tap()
        body.typeText(appendBody)
        element(Identifier.editorSave).tap()
        element(Identifier.editorClose).tap()
    }

    private func syncNow() throws {
        navigator.nowAt(BrowserTab)
        navigator.goto(BrowserTabMenu)
        navigator.goto(SettingsScreen)
        let syncNow = app.tables.staticTexts["Sync Now"]
        guard syncNow.waitForExistence(timeout: TIMEOUT_LONG) else {
            throw MobileActorError.ui("Sync Now control is unavailable")
        }
        syncNow.tap()
        _ = mozWaitForElementToNotExist(
            app.tables.staticTexts["Syncing…"],
            timeout: TIMEOUT_LONG,
            failOnTimeout: false
        )
        navigator.nowAt(BrowserTab)
    }

    private func setAirplaneMode(_ enabled: Bool) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        let button = springboard.buttons["Airplane Mode"].firstMatch
        let toggle = springboard.switches["Airplane Mode"].firstMatch
        let control = button.waitForExistence(timeout: TIMEOUT) ? button : toggle
        guard control.exists,
              let rawValue = control.value as? String else {
            throw MobileActorError.ui("Simulator Airplane Mode control is unavailable")
        }
        let normalized = rawValue.lowercased()
        let isOn: Bool
        if ["1", "on", "true"].contains(normalized) {
            isOn = true
        } else if ["0", "off", "false"].contains(normalized) {
            isOn = false
        } else {
            throw MobileActorError.ui("Simulator Airplane Mode state is not observable")
        }
        if isOn != enabled {
            control.tap()
        }
        app.activate()
    }

    private func searchFor(_ text: String) {
        let search = element(Identifier.notesSearch)
        XCTAssertTrue(search.waitForExistence(timeout: TIMEOUT))
        search.tap()
        search.clearText()
        search.typeText(text)
    }

    private func rowExists(for title: String) -> Bool {
        noteRows()
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
            .waitForExistence(timeout: TIMEOUT)
    }

    private func rowCount() -> Int {
        noteRows().count
    }

    private func noteRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Identifier.rowPrefix)
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MobileActorError.ui(message) }
    }
}
