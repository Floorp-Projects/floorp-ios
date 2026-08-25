// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Common
@testable import Client

final class FloorpNotesListOrderTests: XCTestCase {
    func testFilteredMergePreservesHiddenPositions() throws {
        XCTAssertEqual(
            try FloorpNotesListOrder.merge(
                latestFullIDs: makeFloorpTestNoteIDs(["first", "hidden-a", "second", "hidden-b", "third"]),
                originalVisibleIDs: makeFloorpTestNoteIDs(["first", "second", "third"]),
                orderedVisibleIDs: makeFloorpTestNoteIDs(["third", "first", "second"])
            ),
            makeFloorpTestNoteIDs(["third", "hidden-a", "first", "hidden-b", "second"])
        )
    }

    func testMergeRejectsDuplicateMismatchedAndStaleIDsWithTypedErrors() {
        XCTAssertThrowsError(
            try FloorpNotesListOrder.merge(
                latestFullIDs: makeFloorpTestNoteIDs(["first", "second"]),
                originalVisibleIDs: makeFloorpTestNoteIDs(["first", "first"]),
                orderedVisibleIDs: makeFloorpTestNoteIDs(["first", "second"])
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesListOrderError, .duplicateID(FloorpNoteID("first")))
        }
        XCTAssertThrowsError(
            try FloorpNotesListOrder.merge(
                latestFullIDs: makeFloorpTestNoteIDs(["first", "second"]),
                originalVisibleIDs: makeFloorpTestNoteIDs(["first"]),
                orderedVisibleIDs: makeFloorpTestNoteIDs(["second"])
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesListOrderError, .mismatchedVisibleIDs)
        }
        XCTAssertThrowsError(
            try FloorpNotesListOrder.merge(
                latestFullIDs: makeFloorpTestNoteIDs(["first"]),
                originalVisibleIDs: makeFloorpTestNoteIDs(["first", "removed"]),
                orderedVisibleIDs: makeFloorpTestNoteIDs(["removed", "first"])
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesListOrderError,
                .staleVisibleIDs(makeFloorpTestNoteIDs(["removed"]))
            )
        }
    }

    func testMergeTreatsCanonicallyEquivalentIDsAsDistinct() throws {
        let composedID = FloorpNoteID("note-\u{00E9}")
        let decomposedID = FloorpNoteID("note-e\u{0301}")
        let hiddenID = FloorpNoteID("hidden")

        let merged = try FloorpNotesListOrder.merge(
            latestFullIDs: [composedID, hiddenID, decomposedID],
            originalVisibleIDs: [composedID, decomposedID],
            orderedVisibleIDs: [decomposedID, composedID]
        )

        XCTAssertEqual(merged, [decomposedID, hiddenID, composedID])
        XCTAssertNotEqual(Data(merged[0].rawValue.utf8), Data(merged[2].rawValue.utf8))
    }
}

final class FloorpNotesReorderStoreTests: XCTestCase, @unchecked Sendable {
    func testFilteredReorderPersistsAndNoOpDoesNotAdvanceRevision() async throws {
        let location = temporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(fileURL: location.archive)
        try await store.replaceAllNotes(with: makeNotes())
        let original = try await store.loadSnapshot()

        let didReorder = try await store.reorderVisibleNotes(
            originalVisibleIDs: makeFloorpTestNoteIDs(["first", "third"]),
            orderedVisibleIDs: makeFloorpTestNoteIDs(["third", "first"]),
            expectedRevision: original.revision
        )
        XCTAssertTrue(didReorder)
        let reordered = try await store.loadSnapshot()
        XCTAssertEqual(reordered.notes.map(\.id), makeFloorpTestNoteIDs(["third", "second", "first"]))
        XCTAssertEqual(reordered.revision, original.revision + 1)

        let didWriteNoOp = try await store.reorderVisibleNotes(
            originalVisibleIDs: makeFloorpTestNoteIDs(["third", "first"]),
            orderedVisibleIDs: makeFloorpTestNoteIDs(["third", "first"]),
            expectedRevision: reordered.revision
        )
        XCTAssertFalse(didWriteNoOp)
        let afterNoOp = try await FloorpNotesStore(fileURL: location.archive).loadSnapshot()
        XCTAssertEqual(afterNoOp, reordered)
    }

    func testStaleRevisionRejectsReorderWithoutOverwritingLatestArchive() async throws {
        let location = temporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(fileURL: location.archive)
        try await store.replaceAllNotes(with: makeNotes())
        let staleSnapshot = try await store.loadSnapshot()
        _ = try await store.updateNote(id: FloorpNoteID("second"), title: "Latest", content: "kept")
        let latestSnapshot = try await store.loadSnapshot()

        do {
            _ = try await store.reorderVisibleNotes(
                originalVisibleIDs: makeFloorpTestNoteIDs(["first", "second", "third"]),
                orderedVisibleIDs: makeFloorpTestNoteIDs(["third", "second", "first"]),
                expectedRevision: staleSnapshot.revision
            )
            XCTFail("Expected reorderConflict")
        } catch FloorpNotesStoreError.reorderConflict(let expected, let actual) {
            XCTAssertEqual(expected, staleSnapshot.revision)
            XCTAssertEqual(actual, latestSnapshot.revision)
        }

        let afterRejectedReorder = try await store.loadSnapshot()
        XCTAssertEqual(afterRejectedReorder, latestSnapshot)
    }

    private func makeNotes() -> [FloorpNote] {
        [
            makeFloorpTestNote(id: "first", title: "First", content: "", createdAt: 1, updatedAt: 1),
            makeFloorpTestNote(id: "second", title: "Second", content: "", createdAt: 2, updatedAt: 2),
            makeFloorpTestNote(id: "third", title: "Third", content: "", createdAt: 3, updatedAt: 3),
        ]
    }

    private func temporaryArchiveLocation() -> (directory: URL, archive: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNotesReorderTests-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("notes.json"))
    }
}

final class FloorpNotesReorderSessionTests: XCTestCase {
    func testMovesAreStagedWithoutChangingOriginalOrder() {
        var session = FloorpNotesReorderSession(
            visibleIDs: makeFloorpTestNoteIDs(["first", "second", "third"]),
            expectedRevision: 9
        )

        XCTAssertFalse(session.hasChanges)
        XCTAssertTrue(session.move(from: 0, to: 2))
        XCTAssertEqual(session.orderedVisibleIDs, makeFloorpTestNoteIDs(["second", "third", "first"]))
        XCTAssertEqual(session.originalVisibleIDs, makeFloorpTestNoteIDs(["first", "second", "third"]))
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(session.move(id: FloorpNoteID("first"), offset: -1), 1)
        XCTAssertEqual(session.orderedVisibleIDs, makeFloorpTestNoteIDs(["second", "first", "third"]))
        XCTAssertNil(session.move(id: FloorpNoteID("second"), offset: -1))
    }
}

@MainActor
final class FloorpNotesInteractionControllerTests: XCTestCase {
    func testStagedReorderGatesInteractionsAndCancelDoesNotPersist() async throws {
        let fixture = try await makeDrawerFixture(prefix: "FloorpNotesReorderController")
        defer { fixture.cleanup() }
        let table = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.Content"
        ) as? UITableView)
        let didLoadInitialRows = await waitUntil { table.numberOfRows(inSection: 0) == 3 }
        XCTAssertTrue(didLoadInitialRows)
        fixture.drawer.view.layoutIfNeeded()

        let reorder = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Reorder"
        ) as? UIButton)
        let add = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Add"
        ) as? UIButton)
        let search = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Search"
        ) as? UITextField)
        let middleCell = fixture.drawer.tableView(
            table,
            cellForRowAt: IndexPath(row: 1, section: 0)
        )
        XCTAssertEqual(middleCell.accessibilityIdentifier, "Floorp.Notes.Row.second")
        XCTAssertEqual(
            Set(middleCell.accessibilityCustomActions?.map(\.name) ?? []),
            Set([
                FloorpStrings.Notes.moveUp,
                FloorpStrings.Notes.moveDown,
                FloorpStrings.Notes.delete,
            ])
        )
        XCTAssertTrue(fixture.drawer.tableView(
            table,
            canEditRowAt: IndexPath(row: 1, section: 0)
        ))
        XCTAssertNotNil(fixture.drawer.tableView(
            table,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 1, section: 0)
        ))

        reorder.sendActions(for: .touchUpInside)
        XCTAssertTrue(table.isEditing)
        XCTAssertFalse(search.isEnabled)
        XCTAssertTrue(add.isHidden)
        XCTAssertEqual(reorder.accessibilityLabel, FloorpStrings.Notes.reorderDone)
        XCTAssertNil(fixture.drawer.tableView(
            table,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 1, section: 0)
        ))
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        let stagedCell = fixture.drawer.tableView(
            table,
            cellForRowAt: IndexPath(row: 1, section: 0)
        )
        XCTAssertFalse(
            stagedCell.accessibilityCustomActions?.contains {
                $0.name == FloorpStrings.Notes.delete
            } ?? false
        )
        try assertRegistryActionsAreLocked(fixture: fixture, table: table)

        let cancel = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Reorder.Cancel"
        ) as? UIButton)
        cancel.sendActions(for: .touchUpInside)
        XCTAssertFalse(table.isEditing)
        XCTAssertTrue(search.isEnabled)
        let idsAfterCancel = try await fixture.store.loadNotes().map(\.id)
        XCTAssertEqual(idsAfterCancel, makeFloorpTestNoteIDs(["first", "second", "third"]))
        let didRestoreVisibleOrder = await waitUntil {
            fixture.drawer.tableView(
                table,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ).accessibilityIdentifier == "Floorp.Notes.Row.first"
        }
        XCTAssertTrue(didRestoreVisibleOrder)

        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        reorder.sendActions(for: .touchUpInside)
        let didPersistOrder = await waitUntilStoredIDs(
            ["second", "third", "first"],
            in: fixture.store
        )
        XCTAssertTrue(didPersistOrder)
    }

    func testExternalArchiveChangeCancelsStagedReorder() async throws {
        let fixture = try await makeDrawerFixture(prefix: "FloorpNotesStaleController")
        defer { fixture.cleanup() }
        let table = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.Content"
        ) as? UITableView)
        let didLoadInitialRows = await waitUntil { table.numberOfRows(inSection: 0) == 3 }
        XCTAssertTrue(didLoadInitialRows)
        let reorder = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Reorder"
        ) as? UIButton)

        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        _ = try await fixture.store.createNote(title: "External")

        let didCancelStaleReorder = await waitUntil {
            !table.isEditing && table.numberOfRows(inSection: 0) == 4
        }
        XCTAssertTrue(didCancelStaleReorder)
        XCTAssertEqual(reorder.accessibilityLabel, FloorpStrings.Notes.reorder)
        let storedIDs = try await fixture.store.loadNotes().dropFirst().map(\.id)
        XCTAssertEqual(
            storedIDs,
            makeFloorpTestNoteIDs(["first", "second", "third"])
        )
    }

    func testForeignArchiveCreationDoesNotStealAccessibilityFocus() async throws {
        var focusedIdentifiers = [String?]()
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesForeignFocus",
            noteAccessibilityFocusPoster: {
                focusedIdentifiers.append(($0 as? UIView)?.accessibilityIdentifier)
            }
        )
        defer { fixture.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }

        _ = try await fixture.store.createNote(title: "Created in another drawer")

        await assertEventually { table.numberOfRows(inSection: 0) == 4 }
        XCTAssertTrue(focusedIdentifiers.isEmpty)
    }

    func testOwningCreationClearsSearchAndFocusesOnlyTheSavedNote() async throws {
        let notificationCenter = NotificationCenter()
        var focusedIdentifiers = [String?]()
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesOwningFocus",
            notificationCenter: notificationCenter,
            noteAccessibilityFocusPoster: {
                focusedIdentifiers.append(($0 as? UIView)?.accessibilityIdentifier)
            }
        )
        defer { fixture.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }
        let search = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Search"
        ) as? UITextField)
        search.text = "no matching note"
        search.sendActions(for: .editingChanged)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0)

        let savedNote = try await fixture.store.createNote(title: "Owned creation")
        fixture.drawer.noteCreatedInOwningDrawer(savedNote)

        let savedIdentifier = "Floorp.Notes.Row.\(savedNote.id.rawValue)"
        await assertEventually {
            table.numberOfRows(inSection: 0) == 4
                && focusedIdentifiers.last == savedIdentifier
        }
        XCTAssertTrue(search.text?.isEmpty ?? true)

        focusedIdentifiers.removeAll()
        fixture.drawer.noteCreatedInOwningDrawer(makeNote(id: "missing"))
        await assertEventually { !focusedIdentifiers.isEmpty }
        XCTAssertNotEqual(focusedIdentifiers.last, "Floorp.Notes.Row.missing")
        let focusCount = focusedIdentifiers.count
        fixture.drawer.viewDidAppear(false)
        XCTAssertEqual(focusedIdentifiers.count, focusCount)
    }

    func testSnapshotArrivingAfterReorderBeginsDiscardsStagedOrder() async throws {
        let notificationCenter = NotificationCenter()
        let initial = makeSnapshot(revision: 10, ids: ["first", "second", "third"])
        let latest = makeSnapshot(revision: 11, ids: ["external", "third", "second", "first"])
        let loader = ControlledFloorpNotesSnapshotLoader(queuedSnapshots: [initial])
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesSnapshotDuringReorder",
            notificationCenter: notificationCenter,
            notesSnapshotLoader: { try await loader.load() }
        )
        defer { fixture.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }

        notificationCenter.post(name: .FloorpNotesDidChange, object: nil)
        await assertEventually { loader.pendingLoadCount == 1 }
        let reorder = try reorderButton(in: fixture.drawer)
        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        loader.resumeLoad(at: 0, with: latest)

        await assertEventually {
            !table.isEditing && table.numberOfRows(inSection: 0) == 4
        }
        XCTAssertEqual(rowIdentifiers(in: fixture.drawer, table: table), latest.notes.map {
            "Floorp.Notes.Row.\($0.id.rawValue)"
        })
    }

    func testLatestGenerationWinsAndOlderRevisionIsRejected() async throws {
        let notificationCenter = NotificationCenter()
        let initial = makeSnapshot(revision: 20, ids: ["first", "second", "third"])
        let loader = ControlledFloorpNotesSnapshotLoader(queuedSnapshots: [initial])
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesLoadGeneration",
            notificationCenter: notificationCenter,
            notesSnapshotLoader: { try await loader.load() }
        )
        defer { fixture.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }

        notificationCenter.post(name: .FloorpNotesDidChange, object: nil)
        await assertEventually { loader.pendingLoadCount == 1 }
        notificationCenter.post(name: .FloorpNotesDidChange, object: nil)
        await assertEventually { loader.pendingLoadCount == 2 }
        let latest = makeSnapshot(revision: 22, ids: ["latest", "third", "first"])
        loader.resumeLoad(at: 1, with: latest)
        await assertEventually {
            rowIdentifiers(in: fixture.drawer, table: table) == latest.notes.map {
                "Floorp.Notes.Row.\($0.id.rawValue)"
            }
        }

        loader.resumeLoad(at: 0, with: makeSnapshot(revision: 21, ids: ["stale"]))
        await assertEventually { loader.returnedLoadCount == 3 }
        await Task.yield()
        notificationCenter.post(name: .FloorpNotesDidChange, object: nil)
        await assertEventually { loader.pendingLoadCount == 1 }
        loader.resumeLoad(at: 0, with: makeSnapshot(revision: 19, ids: ["older"]))
        await assertEventually { loader.returnedLoadCount == 4 }
        await Task.yield()

        XCTAssertEqual(rowIdentifiers(in: fixture.drawer, table: table), latest.notes.map {
            "Floorp.Notes.Row.\($0.id.rawValue)"
        })
    }

    func testCommitBlocksEveryDrawerDismissalUntilTheWriterFinishes() async throws {
        let writer = ControlledFloorpNotesReorderWriter()
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesCommitDismissalGate",
            notesReorderWriter: { try await writer.write($0, $1, $2) }
        )
        defer { fixture.cleanup() }
        let presentation = try await present(fixture.drawer)
        defer { presentation.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }
        let reorder = try reorderButton(in: fixture.drawer)
        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        reorder.sendActions(for: .touchUpInside)
        await assertEventually { writer.isWaiting }

        let close = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.Close"
        ) as? UIButton)
        let dimming = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.Dimming"
        ) as? UIControl)
        XCTAssertFalse(close.isEnabled)
        XCTAssertTrue(fixture.drawer.isModalInPresentation)
        XCTAssertFalse(fixture.drawer.accessibilityPerformEscape())
        dimming.sendActions(for: .touchUpInside)
        fixture.drawer.dismissDrawer()
        XCTAssertTrue(presentation.parent.presentedViewController === fixture.drawer)

        writer.completeSuccessfully()
        await assertEventually { close.isEnabled }
        XCTAssertFalse(fixture.drawer.isModalInPresentation)
        fixture.drawer.dismissDrawer()
        await assertEventually { presentation.parent.presentedViewController == nil }
    }

    func testStagedReorderDismissesWithoutPersistingItsOrder() async throws {
        let fixture = try await makeDrawerFixture(prefix: "FloorpNotesStagedDismissal")
        defer { fixture.cleanup() }
        let presentation = try await present(fixture.drawer)
        defer { presentation.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }
        let reorder = try reorderButton(in: fixture.drawer)
        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )

        fixture.drawer.dismissDrawer()

        await assertEventually { presentation.parent.presentedViewController == nil }
        let storedIDs = try await fixture.store.loadNotes().map(\.id)
        XCTAssertEqual(storedIDs, makeFloorpTestNoteIDs(["first", "second", "third"]))
    }

    func testFailureAfterExternalDismissalIsShownByReplacementDrawer() async throws {
        let writer = ControlledFloorpNotesReorderWriter()
        let fixture = try await makeDrawerFixture(
            prefix: "FloorpNotesDeferredCommitError",
            notesReorderWriter: { try await writer.write($0, $1, $2) }
        )
        defer { fixture.cleanup() }
        let presentation = try await present(fixture.drawer)
        defer { presentation.cleanup() }
        let table = try notesTable(in: fixture.drawer)
        await assertEventually { table.numberOfRows(inSection: 0) == 3 }
        let reorder = try reorderButton(in: fixture.drawer)
        reorder.sendActions(for: .touchUpInside)
        fixture.drawer.tableView(
            table,
            moveRowAt: IndexPath(row: 0, section: 0),
            to: IndexPath(row: 2, section: 0)
        )
        reorder.sendActions(for: .touchUpInside)
        await assertEventually { writer.isWaiting }

        presentation.parent.dismiss(animated: false)
        await assertEventually { presentation.parent.presentedViewController == nil }
        writer.completeWithFailure()
        await assertEventually {
            fixture.presentationState.hasPendingNotesOperationError
        }

        let replacement = makeReplacementDrawer(for: fixture)
        XCTAssertTrue(replacement.show(from: presentation.parent))
        await assertEventually { replacement.presentedViewController is UIAlertController }
        XCTAssertTrue(fixture.presentationState.hasPendingNotesOperationError)
    }

    private func notesTable(
        in drawer: FloorpOverlayDrawerViewController
    ) throws -> UITableView {
        try XCTUnwrap(drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.Content"
        ) as? UITableView)
    }

    private func reorderButton(
        in drawer: FloorpOverlayDrawerViewController
    ) throws -> UIButton {
        try XCTUnwrap(drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Reorder"
        ) as? UIButton)
    }

    private func rowIdentifiers(
        in drawer: FloorpOverlayDrawerViewController,
        table: UITableView
    ) -> [String] {
        (0..<table.numberOfRows(inSection: 0)).compactMap { row in
            drawer.tableView(
                table,
                cellForRowAt: IndexPath(row: row, section: 0)
            ).accessibilityIdentifier
        }
    }

    private func makeSnapshot(revision: UInt64, ids: [String]) -> FloorpNotesSnapshot {
        FloorpNotesSnapshot(
            revision: revision,
            notes: ids.enumerated().map { index, id in
                makeNote(id: id, timestamp: Int64(index + 1))
            }
        )
    }

    private func makeNote(id: String, timestamp: Int64 = 1) -> FloorpNote {
        makeFloorpTestNote(
            id: id,
            title: id.capitalized,
            content: "",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func present(
        _ drawer: FloorpOverlayDrawerViewController
    ) async throws -> DrawerPresentation {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let parent = UIViewController()
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        let presentation = DrawerPresentation(
            parent: parent,
            window: window,
            previousKeyWindow: previousKeyWindow,
            animationsWereEnabled: animationsWereEnabled
        )
        let didPresent = expectation(description: "Drawer presentation completed")
        guard drawer.show(from: parent, onPresented: { didPresent.fulfill() }) else {
            presentation.cleanup()
            throw PresentationError.failed
        }
        await fulfillment(of: [didPresent], timeout: 1)
        return presentation
    }

    private func makeReplacementDrawer(
        for fixture: DrawerFixture
    ) -> FloorpOverlayDrawerViewController {
        FloorpOverlayDrawerViewController(
            panelManager: FloorpPanelManager(defaults: fixture.defaults),
            notesStore: fixture.store,
            presentationState: fixture.presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: NotificationCenter()
        )
    }

    private func makeDrawerFixture(
        prefix: String,
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        notesSnapshotLoader: FloorpNotesSnapshotLoader? = nil,
        notesReorderWriter: FloorpNotesReorderWriter? = nil,
        noteAccessibilityFocusPoster: @escaping FloorpNoteAccessibilityFocusPoster = { _ in }
    ) async throws -> DrawerFixture {
        let suiteName = "\(prefix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        let store = FloorpNotesStore(fileURL: directory.appendingPathComponent("notes.json"))
        try await store.replaceAllNotes(with: [
            makeFloorpTestNote(id: "first", title: "First", content: "", createdAt: 1, updatedAt: 1),
            makeFloorpTestNote(id: "second", title: "Second", content: "", createdAt: 2, updatedAt: 2),
            makeFloorpTestNote(id: "third", title: "Third", content: "", createdAt: 3, updatedAt: 3),
        ])
        await Task.yield()

        let panelManager = FloorpPanelManager(defaults: defaults)
        let presentationState = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        presentationState.select(try XCTUnwrap(panelManager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: panelManager,
            notesStore: store,
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            notesSnapshotLoader: notesSnapshotLoader,
            notesReorderWriter: notesReorderWriter,
            noteAccessibilityFocusPoster: noteAccessibilityFocusPoster
        )
        drawer.loadViewIfNeeded()
        drawer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        drawer.view.layoutIfNeeded()
        return DrawerFixture(
            drawer: drawer,
            store: store,
            presentationState: presentationState,
            defaults: defaults,
            suiteName: suiteName,
            directory: directory
        )
    }

    private func assertRegistryActionsAreLocked(
        fixture: DrawerFixture,
        table: UITableView
    ) throws {
        let stagedOrder = (0..<3).map { row in
            fixture.drawer.tableView(
                table,
                cellForRowAt: IndexPath(row: row, section: 0)
            ).accessibilityIdentifier
        }
        let historyButton = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "floorp//history"
        ) as? UIButton)
        let addWebPanelButton = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.AddWebPanel"
        ) as? UIButton)
        let managePanelsButton = try XCTUnwrap(fixture.drawer.view.floorpDescendant(
            withIdentifier: "Floorp.Drawer.ManagePanels"
        ) as? UIButton)

        XCTAssertFalse(historyButton.isEnabled)
        XCTAssertFalse(addWebPanelButton.isEnabled)
        XCTAssertFalse(managePanelsButton.isEnabled)
        historyButton.sendActions(for: .touchUpInside)
        addWebPanelButton.sendActions(for: .touchUpInside)
        managePanelsButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.presentationState.selectedPanelId, "floorp//notes")
        XCTAssertNil(fixture.drawer.presentedViewController)
        XCTAssertEqual(
            (0..<3).map { row in
                fixture.drawer.tableView(
                    table,
                    cellForRowAt: IndexPath(row: row, section: 0)
                ).accessibilityIdentifier
            },
            stagedOrder
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func assertEventually(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didSucceed = await waitUntil(condition)
        XCTAssertTrue(didSucceed, file: file, line: line)
    }

    private func waitUntilStoredIDs(
        _ expectedIDs: [String],
        in store: FloorpNotesStore
    ) async -> Bool {
        let expectedIDs = makeFloorpTestNoteIDs(expectedIDs)
        for _ in 0..<100 {
            if (try? await store.loadNotes().map(\.id)) == expectedIDs { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return (try? await store.loadNotes().map(\.id)) == expectedIDs
    }

    private struct DrawerFixture {
        let drawer: FloorpOverlayDrawerViewController
        let store: FloorpNotesStore
        let presentationState: FloorpPanelPresentationState
        let defaults: UserDefaults
        let suiteName: String
        let directory: URL

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct DrawerPresentation {
        let parent: UIViewController
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let animationsWereEnabled: Bool

        @MainActor
        func cleanup() {
            parent.dismiss(animated: false)
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }

    private enum PresentationError: Error {
        case failed
    }
}

@MainActor
private final class ControlledFloorpNotesSnapshotLoader {
    private var queuedSnapshots: [FloorpNotesSnapshot]
    private var pendingLoads = [CheckedContinuation<FloorpNotesSnapshot, Error>]()
    private(set) var returnedLoadCount = 0

    init(queuedSnapshots: [FloorpNotesSnapshot] = []) {
        self.queuedSnapshots = queuedSnapshots
    }

    var pendingLoadCount: Int {
        pendingLoads.count
    }

    func load() async throws -> FloorpNotesSnapshot {
        defer { returnedLoadCount += 1 }
        if !queuedSnapshots.isEmpty {
            return queuedSnapshots.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingLoads.append(continuation)
        }
    }

    func resumeLoad(at index: Int, with snapshot: FloorpNotesSnapshot) {
        pendingLoads.remove(at: index).resume(returning: snapshot)
    }
}

@MainActor
private final class ControlledFloorpNotesReorderWriter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldFail = false
    private(set) var isWaiting = false

    func write(_: [FloorpNoteID], _: [FloorpNoteID], _: UInt64) async throws -> Bool {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
        if shouldFail {
            throw WriterError.expected
        }
        return true
    }

    func completeSuccessfully() {
        complete(shouldFail: false)
    }

    func completeWithFailure() {
        complete(shouldFail: true)
    }

    private func complete(shouldFail: Bool) {
        self.shouldFail = shouldFail
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    private enum WriterError: Error {
        case expected
    }
}

@MainActor
final class FloorpNoteEditorInteractionTests: XCTestCase {
    func testStableIdentifiersAndExplicitRetryReflectSaveState() async throws {
        var saveCount = 0
        let editor = makeEditor(isPersisted: false) { note in
            saveCount += 1
            guard saveCount > 1 else { throw SaveError.expected }
            return note
        }
        let host = installEditor(
            editor,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        defer { removeEditor(editor, from: host) }
        let title = try XCTUnwrap(editor.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Editor.Title"
        ) as? UITextField)
        let body = try XCTUnwrap(editor.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertNotNil(body)
        XCTAssertEqual(
            editor.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
            "Floorp.Notes.Editor.Close"
        )
        XCTAssertEqual(
            editor.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "Floorp.Notes.Editor.Save"
        )

        title.text = "Changed"
        title.sendActions(for: .editingChanged)
        guard case .failed = await editor.saveLatestDraft() else {
            return XCTFail("Expected the first save to fail")
        }
        let errorStatus = try XCTUnwrap(editor.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Editor.Status.Error"
        ) as? UILabel)
        XCTAssertEqual(errorStatus.text, FloorpStrings.Notes.saveFailed)
        let retry = try XCTUnwrap(editor.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Editor.Retry"
        ) as? UIButton)
        XCTAssertFalse(retry.isHidden)
        host.view.layoutIfNeeded()
        editor.view.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(retry.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(retry.bounds.height, 44)

        retry.sendActions(for: .touchUpInside)
        let didSave = await waitUntil {
            editor.view.floorpDescendant(
                withIdentifier: "Floorp.Notes.Editor.Status.Saved"
            ) != nil
        }
        XCTAssertTrue(didSave)
        XCTAssertEqual(saveCount, 2)
    }

    func testNewDraftFocusesAndSelectsTitleOnFirstAppearance() async throws {
        let editor = makeEditor(isPersisted: false) { $0 }
        let navigationController = UINavigationController(rootViewController: editor)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.loadViewIfNeeded()
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        let title = try XCTUnwrap(editor.view.floorpDescendant(
            withIdentifier: "Floorp.Notes.Editor.Title"
        ) as? UITextField)
        let didFocusTitle = await waitUntil {
            guard title.isFirstResponder,
                  let range = title.selectedTextRange else { return false }
            return title.offset(from: title.beginningOfDocument, to: range.start) == 0
                && title.offset(from: title.beginningOfDocument, to: range.end) == title.text?.count
        }
        XCTAssertTrue(didFocusTitle)
        let selectedRange = try XCTUnwrap(title.selectedTextRange)
        XCTAssertEqual(title.offset(from: title.beginningOfDocument, to: selectedRange.start), 0)
        XCTAssertEqual(
            title.offset(from: title.beginningOfDocument, to: selectedRange.end),
            title.text?.count
        )
    }

    private func makeEditor(
        isPersisted: Bool,
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote
    ) -> FloorpNoteEditorViewController {
        FloorpNoteEditorViewController(
            note: makeFloorpTestNote(
                id: "draft",
                title: "New Note",
                content: "",
                createdAt: 1,
                updatedAt: 1
            ),
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPersisted: isPersisted,
            onSave: onSave
        )
    }

    private func installEditor(
        _ editor: FloorpNoteEditorViewController,
        contentSizeCategory: UIContentSizeCategory
    ) -> UIViewController {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.addChild(editor)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
            forChild: editor
        )
        editor.view.frame = host.view.bounds
        host.view.addSubview(editor.view)
        editor.didMove(toParent: host)
        host.view.layoutIfNeeded()
        editor.view.layoutIfNeeded()
        return host
    }

    private func removeEditor(
        _ editor: FloorpNoteEditorViewController,
        from host: UIViewController
    ) {
        host.setOverrideTraitCollection(nil, forChild: editor)
        editor.willMove(toParent: nil)
        editor.view.removeFromSuperview()
        editor.removeFromParent()
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private enum SaveError: Error {
        case expected
    }
}

private extension UIView {
    func floorpDescendant(withIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.floorpDescendant(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
