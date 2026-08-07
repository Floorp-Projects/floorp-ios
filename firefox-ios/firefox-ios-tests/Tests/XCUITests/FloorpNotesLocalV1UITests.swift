// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest

/// Floorp Notes Local v1 UI smoke coverage (issue #24).
///
/// Runs in the EN/JA iPhone/iPad matrix (see `FloorpNotesUI.xctestplan`).
/// Every interaction targets a stable accessibility identifier; assertions
/// never depend on localized visible text. The archive is cleared through the
/// test-only `LaunchArguments.FloorpNotesClearArchive` hook on the first
/// launch so the create/edit/search/delete/relaunch flow is deterministic.
@MainActor
final class FloorpNotesLocalV1UITests: BaseTestCase {
    private enum Identifier {
        static let toolbarButton = "floorpDrawerToolbarButton"
        static let drawerContainer = "Floorp.Drawer.Container"
        static let notesPanel = "floorp//notes"
        static let notesSearch = "Floorp.Notes.Search"
        static let notesAdd = "Floorp.Notes.Add"
        static let drawerClose = "Floorp.Drawer.Close"
        static let editorTitle = "Floorp.Notes.Editor.Title"
        static let editorBody = "Floorp.Notes.Editor.Body"
        static let editorClose = "Floorp.Notes.Editor.Close"
        static let editorSave = "Floorp.Notes.Editor.Save"
        static let rowPrefix = "Floorp.Notes.Row."
    }

    override func setUp() async throws {
        launchArguments.append(LaunchArguments.FloorpNotesClearArchive)
        try await super.setUp()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func waitFor(
        _ identifier: String,
        timeout: TimeInterval = TIMEOUT
    ) -> XCUIElement {
        let result = element(identifier)
        if !result.waitForExistence(timeout: timeout) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "missing-\(identifier)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "missing-\(identifier)-screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(result.exists, "Timed out waiting for \(identifier)")
        return result
    }

    private func noteRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Identifier.rowPrefix)
        )
    }

    private func openNotes() {
        let toolbarButton = waitFor(Identifier.toolbarButton)
        XCTAssertTrue(toolbarButton.isHittable)
        toolbarButton.tap()
        _ = waitFor(Identifier.drawerContainer)
        let notesButton = waitFor(Identifier.notesPanel)
        XCTAssertTrue(notesButton.isHittable)
        notesButton.tap()
        _ = waitFor(Identifier.notesSearch)
    }

    private func createNote(title: String, body: String) {
        let add = waitFor(Identifier.notesAdd)
        XCTAssertTrue(add.isHittable)
        add.tap()

        let titleField = waitFor(Identifier.editorTitle)
        XCTAssertTrue(titleField.isHittable)
        titleField.clearText()
        titleField.typeText(title)

        let bodyField = waitFor(Identifier.editorBody)
        bodyField.tap()
        bodyField.typeText(body)

        waitFor(Identifier.editorSave).tap()
        // Closing saves the latest draft and returns to the notes list; the
        // resulting row is verified through search rather than a transient
        // status label.
        waitFor(Identifier.editorClose).tap()
        _ = waitFor(Identifier.notesSearch)
    }

    private func searchFor(_ text: String) {
        let search = waitFor(Identifier.notesSearch)
        search.tap()
        search.clearText()
        search.typeText(text)
    }

    /// Reveals the trailing delete action for a row and returns it without
    /// depending on its localized title: the revealed action is the only
    /// hittable drawer button whose frame intersects the row.
    private func revealDeleteAction(for row: XCUIElement) -> XCUIElement {
        row.swipeLeft()
        let drawer = element(Identifier.drawerContainer)
        let candidate = drawer.buttons.allElementsBoundByIndex.first { button in
            button.isHittable && button.frame.intersects(row.frame)
        }
        XCTAssertNotNil(candidate, "Delete action must appear after swiping the row")
        return candidate!
    }

    func testCreateEditSearchDeleteAndRelaunchPersistence() {
        let title = "UITest-\(UUID().uuidString.prefix(8))"
        let editedBody = "Edited-\(UUID().uuidString)"

        openNotes()

        // Create + edit in one pass, then save.
        createNote(title: title, body: "Original-\(UUID().uuidString)")

        // Reopen the note from search and edit it.
        searchFor(title)
        let row = noteRows().firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: TIMEOUT), "created note row must appear in search")
        row.tap()

        let bodyField = waitFor(Identifier.editorBody)
        bodyField.tap()
        bodyField.typeText(editedBody)
        waitFor(Identifier.editorSave).tap()
        waitFor(Identifier.editorClose).tap()
        _ = waitFor(Identifier.notesSearch)

        // Search still finds it after the edit.
        searchFor(title)
        XCTAssertTrue(noteRows().firstMatch.waitForExistence(timeout: TIMEOUT))

        // Relaunch persistence: terminate and relaunch without clearing the archive.
        app.terminate()
        app.launchArguments = app.launchArguments.filter {
            $0 != LaunchArguments.FloorpNotesClearArchive
        }
        app.launch()
        openNotes()
        searchFor(title)
        XCTAssertTrue(
            noteRows().firstMatch.waitForExistence(timeout: TIMEOUT),
            "Note must persist across relaunch"
        )

        // Delete via the trailing swipe action and explicit confirmation.
        let rowToDelete = noteRows().firstMatch
        XCTAssertTrue(rowToDelete.waitForExistence(timeout: TIMEOUT))
        let deleteAction = revealDeleteAction(for: rowToDelete)
        XCTAssertTrue(deleteAction.waitForExistence(timeout: TIMEOUT))
        deleteAction.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: TIMEOUT), "Delete confirmation must appear")
        // Cancel is the first alert button; the destructive Delete is the last.
        alert.buttons.element(boundBy: alert.buttons.count - 1).tap()

        // The table empties immediately, but a stale accessibility cell can
        // linger until the list is rebuilt. Reopen the drawer and search again
        // to verify the deletion persisted.
        waitFor(Identifier.drawerClose).tap()
        let drawerGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element(Identifier.drawerContainer)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [drawerGone], timeout: TIMEOUT),
            .completed,
            "Drawer must close after the delete"
        )
        openNotes()
        searchFor(title)
        XCTAssertFalse(
            noteRows().firstMatch.exists,
            "Deleted note must not reappear after reopening the drawer"
        )
    }

    func testCloseKeepsUnsavedEditsThroughAutosave() {
        let title = "Unsaved-\(UUID().uuidString.prefix(8))"

        openNotes()
        let add = waitFor(Identifier.notesAdd)
        XCTAssertTrue(add.isHittable)
        add.tap()

        let titleField = waitFor(Identifier.editorTitle)
        XCTAssertTrue(titleField.isHittable)
        titleField.tap()
        titleField.typeText(title)

        // Closing an editor with unsaved changes saves the draft rather than
        // silently losing it (recovery smoke).
        waitFor(Identifier.editorClose).tap()
        _ = waitFor(Identifier.notesSearch)

        searchFor(title)
        XCTAssertTrue(
            noteRows().firstMatch.waitForExistence(timeout: TIMEOUT),
            "Closing must not lose the unsaved draft"
        )
    }
}
