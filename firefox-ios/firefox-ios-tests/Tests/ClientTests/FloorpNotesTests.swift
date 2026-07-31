// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class FloorpNotesStoreTests: XCTestCase, @unchecked Sendable {
    func testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive)
        let created = try await store.createNote(title: "First", content: "Body")
        var loaded = try await store.loadNotes()
        XCTAssertEqual(loaded, [created])

        let updated = try await store.updateNote(id: created.id, title: "Updated", content: "New body")
        XCTAssertEqual(updated.title, "Updated")
        XCTAssertGreaterThanOrEqual(updated.updatedAt, updated.createdAt)

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        loaded = try await restartedStore.loadNotes()
        XCTAssertEqual(loaded, [updated])

        try await restartedStore.deleteNote(id: created.id)
        let afterDeletingLastNote = FloorpNotesStore(fileURL: location.archive)
        let emptyNotes = try await afterDeletingLastNote.loadNotes()
        XCTAssertEqual(emptyNotes, [])
    }

    func testConcurrentUpdatesToDifferentNotesDoNotOverwriteEachOther() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive)
        let first = try await store.createNote(title: "First")
        let second = try await store.createNote(title: "Second")

        async let updateFirst = store.updateNote(
            id: first.id,
            title: "First updated",
            content: "A",
            expectedUpdatedAt: first.updatedAt
        )
        async let updateSecond = store.updateNote(
            id: second.id,
            title: "Second updated",
            content: "B",
            expectedUpdatedAt: second.updatedAt
        )
        _ = try await (updateFirst, updateSecond)

        let notes = try await store.loadNotes()
        XCTAssertEqual(notes.first(where: { $0.id == first.id })?.content, "A")
        XCTAssertEqual(notes.first(where: { $0.id == second.id })?.content, "B")
    }

    func testStaleEditIsRejectedAndTimestampAdvancesWhenClockDoesNot() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive, now: { 1_000 })
        let original = try await store.createNote(title: "Original")
        let firstEdit = try await store.updateNote(
            id: original.id,
            title: "First editor",
            content: "preserve me",
            expectedUpdatedAt: original.updatedAt
        )
        XCTAssertEqual(firstEdit.updatedAt, original.updatedAt + 1)

        do {
            _ = try await store.updateNote(
                id: original.id,
                title: "Stale editor",
                content: "must not win",
                expectedUpdatedAt: original.updatedAt
            )
            XCTFail("Expected editConflict")
        } catch FloorpNotesStoreError.editConflict(let id) {
            XCTAssertEqual(id, original.id)
        }

        let persisted = try await store.loadNotes().first
        XCTAssertEqual(persisted, firstEdit)
    }

    func testOversizedUpdateFailsWithoutReplacingLastGoodArchive() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive)
        let note = try await store.createNote(title: "Safe", content: "original")
        let oversizedContent = String(repeating: "x", count: FloorpNotesStore.maximumArchiveBytes)

        do {
            _ = try await store.updateNote(id: note.id, title: note.title, content: oversizedContent)
            XCTFail("Expected archiveTooLarge")
        } catch FloorpNotesStoreError.archiveTooLarge(_, _) {
            // Expected.
        }

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let persistedContent = try await restartedStore.loadNotes().first?.content
        XCTAssertEqual(persistedContent, "original")
    }

    func testCorruptArchiveIsPreservedAndRequiresExplicitReset() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: location.archive)

        let store = FloorpNotesStore(fileURL: location.archive)
        var recoveryURL: URL?
        do {
            _ = try await store.loadNotes()
            XCTFail("Expected corruptArchive")
        } catch FloorpNotesStoreError.corruptArchive(let url) {
            recoveryURL = url
        }

        guard let recoveryURL else {
            return XCTFail("Expected a recovery URL")
        }
        XCTAssertEqual(try Data(contentsOf: location.archive), Data("not-json".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        do {
            _ = try await restartedStore.loadNotes()
            XCTFail("Expected corruptArchive after restart")
        } catch FloorpNotesStoreError.corruptArchive(let restartedRecoveryURL) {
            XCTAssertEqual(restartedRecoveryURL, recoveryURL)
        }
        let recoveryCopies = try FileManager.default.contentsOfDirectory(
            at: location.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(recoveryCopies.count, 1)

        do {
            _ = try await store.createNote(title: "Must not overwrite recovery")
            XCTFail("Expected writesBlockedByCorruption")
        } catch FloorpNotesStoreError.writesBlockedByCorruption(_) {
            // Expected.
        }

        try await store.resetAfterCorruption()
        let resetNotes = try await store.loadNotes()
        XCTAssertEqual(resetNotes, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testCorruptArchiveStaysUntouchedWhenRecoveryCopyFails() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        let originalData = Data("not-json".utf8)
        try originalData.write(to: location.archive)

        let store = FloorpNotesStore(
            fileURL: location.archive,
            copyItem: { _, _ in throw CopyFailure.expected }
        )
        do {
            _ = try await store.loadNotes()
            XCTFail("Expected corruptArchiveCouldNotBePreserved")
        } catch FloorpNotesStoreError.corruptArchiveCouldNotBePreserved {
            // Expected.
        }

        do {
            try await store.resetAfterCorruption()
            XCTFail("Reset must remain blocked without a recovery copy")
        } catch FloorpNotesStoreError.corruptArchiveCouldNotBePreserved {
            // Expected.
        }
        do {
            _ = try await store.createNote(title: "Must not overwrite the original")
            XCTFail("Writes must remain blocked without a recovery copy")
        } catch FloorpNotesStoreError.corruptArchiveCouldNotBePreserved {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: location.archive), originalData)
    }

    func testDesktopLegacyPayloadNormalizesMissingMetadataAndDuplicateIDs() throws {
        let payload = FloorpNotesDesktopPayload(
            ids: ["duplicate", "duplicate"],
            titles: ["One", "Two"],
            contents: ["A", "B"],
            createdAts: nil,
            updatedAts: nil
        )
        var generatedIDs = ["generated-id"]
        let notes = try payload.normalizedNotes(now: 1_000) {
            generatedIDs.removeFirst()
        }

        XCTAssertEqual(notes.map(\.title), ["One", "Two"])
        XCTAssertEqual(notes.map(\.id), ["duplicate", "generated-id"])
        XCTAssertEqual(notes.map(\.createdAt), [1_000, 1_000])
        XCTAssertEqual(FloorpNotesDesktopPayload(notes: notes).contents, ["A", "B"])
    }

    func testTipTapProjectionSupportsParagraphs() {
        let tipTap = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Hello"}]},
          {"type":"paragraph","content":[{"type":"text","text":"World"}]}
        ]}
        """
        XCTAssertTrue(FloorpNoteContent.isRichText(tipTap))
        XCTAssertEqual(FloorpNoteContent.plainText(from: tipTap), "Hello\nWorld")
        XCTAssertEqual(FloorpNoteContent.plainText(from: "plain text"), "plain text")
    }

    func testUnknownJSONRemainsVerbatimAndReadOnly() {
        let unknownObject = #"{"text":"hello","metadata":"must survive"}"#
        let unknownArray = #"[{"text":"A"},{"text":"B"}]"#

        for content in [unknownObject, unknownArray] {
            let analysis = FloorpNoteContent.analyze(content)
            XCTAssertEqual(analysis.format, .unknownJSON)
            XCTAssertEqual(analysis.previewText, content)
            XCTAssertEqual(analysis.editorText, content)
            XCTAssertEqual(analysis.editPolicy, .readOnly)
        }
    }

    func testLexicalProjectionPreservesLineAndBlockBoundaries() {
        let lexical = """
        {"root":{"children":[
          {"type":"paragraph","children":[
            {"type":"text","text":"A"},
            {"type":"linebreak"},
            {"type":"text","text":"B"}
          ]},
          {"type":"list","children":[
            {"type":"listitem","children":[{"type":"text","text":"One"}]},
            {"type":"listitem","children":[{"type":"text","text":"Two"}]}
          ]},
          {"type":"quote","children":[{"type":"text","text":"Quote"}]}
        ]}}
        """
        let analysis = FloorpNoteContent.analyze(lexical)

        XCTAssertEqual(analysis.format, .lexical)
        XCTAssertEqual(analysis.editorText, "A\nB\nOne\nTwo\nQuote")
        XCTAssertEqual(analysis.editPolicy, .requiresConversion)
    }

    func testRichContentWithImageIsReadOnlyAndDoesNotExposeSource() {
        let source = "data:image/png;base64,SECRET_PAYLOAD"
        let tipTap = """
        {"type":"doc","content":[{"type":"image","attrs":{"src":"\(source)"}}]}
        """
        let analysis = FloorpNoteContent.analyze(tipTap)

        XCTAssertEqual(analysis.format, .tipTap)
        XCTAssertTrue(analysis.losses.contains(.embeddedMedia))
        XCTAssertEqual(analysis.editPolicy, .readOnly)
        XCTAssertFalse(analysis.previewText.contains(source))
        XCTAssertFalse(analysis.editorText.contains(source))
    }

    func testRichEditorProjectionPreservesMeaningfulWhitespace() {
        let tipTap = """
        {"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"  keep me  "}]}]}
        """
        let analysis = FloorpNoteContent.analyze(tipTap)

        XCTAssertEqual(analysis.previewText, "keep me")
        XCTAssertEqual(analysis.editorText, "  keep me  ")
        XCTAssertEqual(analysis.editPolicy, .requiresConversion)
    }

    func testIncompleteRichProjectionIsReadOnly() throws {
        var node: [String: Any] = ["type": "text", "text": "deep"]
        for _ in 0..<70 {
            node = ["type": "paragraph", "content": [node]]
        }
        let document: [String: Any] = ["type": "doc", "content": [node]]
        let data = try JSONSerialization.data(withJSONObject: document)
        let content = try XCTUnwrap(String(data: data, encoding: .utf8))
        let analysis = FloorpNoteContent.analyze(content)

        XCTAssertFalse(analysis.isComplete)
        XCTAssertTrue(analysis.losses.contains(.projectionLimit))
        XCTAssertEqual(analysis.editPolicy, .readOnly)
    }

    private func makeTemporaryArchiveLocation() throws -> (directory: URL, archive: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNotesTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("notes.json"))
    }

    private enum CopyFailure: Error {
        case expected
    }
}

@MainActor
final class FloorpNotePersistenceSessionTests: XCTestCase {
    func testNewDraftDoesNotPersistBeforeFirstSave() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive)
        _ = FloorpNotePersistenceSession(notesStore: store, persistedNote: nil)

        let notes = try await store.loadNotes()
        XCTAssertTrue(notes.isEmpty)
    }

    func testFirstSaveCreatesAndSubsequentSaveUpdatesSameNote() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(
            fileURL: location.archive,
            now: { 1_000 },
            makeID: { "persisted-id" }
        )
        let session = FloorpNotePersistenceSession(notesStore: store, persistedNote: nil)
        var draft = makeDraft(title: "First", content: "Body")

        let created = try await session.save(draft)
        XCTAssertEqual(created.id, "persisted-id")

        draft.title = "Updated"
        draft.content = "New body"
        let updated = try await session.save(draft)
        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let notes = try await restartedStore.loadNotes()

        XCTAssertEqual(updated.id, created.id)
        XCTAssertGreaterThan(updated.updatedAt, created.updatedAt)
        XCTAssertEqual(notes, [updated])
    }

    func testConcurrentFirstSavesCreateOneNote() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive, now: { 1_000 })
        let session = FloorpNotePersistenceSession(notesStore: store, persistedNote: nil)
        let firstDraft = makeDraft(title: "First", content: "A")
        let secondDraft = makeDraft(title: "Second", content: "B")

        let firstSave = Task { @MainActor in
            try await session.save(firstDraft)
        }
        let secondSave = Task { @MainActor in
            try await session.save(secondDraft)
        }
        defer {
            firstSave.cancel()
            secondSave.cancel()
        }

        let firstSaved = try await firstSave.value
        let secondSaved = try await secondSave.value
        let notes = try await store.loadNotes()

        XCTAssertEqual(firstSaved.id, secondSaved.id)
        XCTAssertEqual(notes.count, 1)
        let finalNote = try XCTUnwrap(notes.first)
        XCTAssertTrue(finalNote == firstSaved || finalNote == secondSaved)
    }

    func testFailedFirstSaveCanRetryWithoutDuplicate() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(
            fileURL: location.archive,
            makeID: { "persisted-id" }
        )
        let session = FloorpNotePersistenceSession(notesStore: store, persistedNote: nil)
        var draft = makeDraft(
            title: "Too large",
            content: String(repeating: "x", count: FloorpNotesStore.maximumArchiveBytes)
        )

        do {
            _ = try await session.save(draft)
            XCTFail("Expected archiveTooLarge")
        } catch FloorpNotesStoreError.archiveTooLarge {
            // Expected.
        }
        let notesAfterFailure = try await store.loadNotes()
        XCTAssertTrue(notesAfterFailure.isEmpty)

        draft.title = "Retry"
        draft.content = "Saved"
        let saved = try await session.save(draft)
        let notesAfterRetry = try await store.loadNotes()

        XCTAssertEqual(saved.id, "persisted-id")
        XCTAssertEqual(notesAfterRetry, [saved])
    }

    func testExistingNoteSessionPreservesConflictDetection() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(
            fileURL: location.archive,
            now: { 1_000 },
            makeID: { "persisted-id" }
        )
        let original = try await store.createNote(title: "Original")
        let session = FloorpNotePersistenceSession(notesStore: store, persistedNote: original)
        let otherWindowEdit = try await store.updateNote(
            id: original.id,
            title: "Other window",
            content: "Keep this",
            expectedUpdatedAt: original.updatedAt
        )
        var staleDraft = original
        staleDraft.title = "Stale editor"

        do {
            _ = try await session.save(staleDraft)
            XCTFail("Expected editConflict")
        } catch FloorpNotesStoreError.editConflict(let id) {
            XCTAssertEqual(id, original.id)
        }

        let notes = try await store.loadNotes()
        XCTAssertEqual(notes, [otherWindowEdit])
    }

    private func makeDraft(title: String, content: String) -> FloorpNote {
        FloorpNote(
            id: "draft-id",
            title: title,
            content: content,
            createdAt: 500,
            updatedAt: 500
        )
    }

    private func makeTemporaryArchiveLocation() -> (directory: URL, archive: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNoteSessionTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("notes.json"))
    }
}

@MainActor
final class FloorpPanelNotesMigrationTests: XCTestCase {
    func testLegacyPanelConfigurationReceivesNotesExactlyOnce() throws {
        let suiteName = "FloorpPanelNotesMigrationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyPanels = Array(FloorpPanel.defaultPanels().filter { $0.type != .notes })
        var legacyConfig = FloorpOverlayDrawerConfig()
        legacyConfig.panelOrder = legacyPanels.map(\.id)
        defaults.set(try JSONEncoder().encode(legacyPanels), forKey: "floorp.overlayDrawer.panels")
        defaults.set(try JSONEncoder().encode(legacyConfig), forKey: "floorp.overlayDrawer.config")

        let migrated = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(migrated.panels.filter { $0.type == .notes }.count, 1)
        XCTAssertTrue(migrated.config.panelOrder.contains("floorp//notes"))

        try migrated.removePanel(id: "floorp//notes")
        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertFalse(restarted.panels.contains(where: { $0.type == .notes }))
    }

    func testReorderPreservesPanelsMissingFromOlderOrderList() {
        let suiteName = "FloorpPanelNotesReorderTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = FloorpPanelManager(defaults: defaults)
        manager.reorderPanels(orderedIds: ["floorp//history", "floorp//bookmarks", "floorp//downloads"])

        XCTAssertEqual(manager.panels.last?.id, "floorp//notes")
        XCTAssertEqual(manager.panels.map(\.sortOrder), Array(manager.panels.indices))
    }

    func testNoteSearchUsesContentBeyondDisplayedPreview() {
        let fullContent = String(repeating: "a", count: 200) + " deep needle"
        let item = DrawerItem(
            id: "note-id",
            title: "Title",
            subtitle: String(fullContent.prefix(160)),
            searchText: fullContent,
            source: .note(id: "note-id")
        )

        XCTAssertTrue(item.matchesSearchQuery("DEEP NEEDLE"))
        XCTAssertFalse(item.matchesSearchQuery("not present"))
    }
}
