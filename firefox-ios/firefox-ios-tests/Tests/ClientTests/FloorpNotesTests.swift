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

    func testPlainJSONCreatedOnIOSRemainsEditableAfterRestart() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let jsonLookingText = #"{"project":"Floorp","done":false}"#
        let store = FloorpNotesStore(fileURL: location.archive)
        let created = try await store.createNote(title: "JSON", content: jsonLookingText)
        XCTAssertEqual(created.contentFormat, .plainText)

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let restartedNotes = try await restartedStore.loadNotes()
        let restarted = try XCTUnwrap(restartedNotes.first)
        let analysis = FloorpNoteContent.analyze(
            restarted.content,
            contentFormat: restarted.contentFormat
        )

        XCTAssertEqual(analysis.format, .plainText)
        XCTAssertEqual(analysis.editorText, jsonLookingText)
        XCTAssertEqual(analysis.editPolicy, .direct)
    }

    func testV1ArchiveMigratesToV2WithoutChangingSourceContent() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        let richContent = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Keep me"}]}]}"#
        let legacyArchive: [String: Any] = [
            "schemaVersion": 1,
            "revision": 7,
            "notes": [[
                "id": "legacy-note",
                "title": "Legacy",
                "content": richContent,
                "createdAt": 1_000,
                "updatedAt": 2_000,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: legacyArchive).write(to: location.archive)

        let store = FloorpNotesStore(fileURL: location.archive)
        let migratedNotes = try await store.loadNotes()
        let migrated = try XCTUnwrap(migratedNotes.first)
        XCTAssertEqual(migrated.content, richContent)
        XCTAssertEqual(migrated.contentFormat, .automatic)
        XCTAssertEqual(
            FloorpNoteContent.analyze(
                migrated.content,
                contentFormat: migrated.contentFormat
            ).format,
            .tipTap
        )

        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: location.archive)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, FloorpNotesStore.currentSchemaVersion)

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let restartedNotes = try await restartedStore.loadNotes()
        XCTAssertEqual(restartedNotes, [migrated])
    }

    func testBoundarySizedV1ArchiveMigratesWithoutFormatMetadataGrowth() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        let prefix = "{\"notes\":[{\"content\":\""
        let suffix = "\",\"createdAt\":1,\"id\":\"legacy\",\"title\":\"Boundary\",\"updatedAt\":1}],\"revision\":1,\"schemaVersion\":1}"
        let contentByteCount = FloorpNotesStore.legacyMaximumArchiveBytes
            - prefix.utf8.count
            - suffix.utf8.count
        let source = Data((prefix + String(repeating: "/", count: contentByteCount) + suffix).utf8)
        XCTAssertEqual(source.count, FloorpNotesStore.legacyMaximumArchiveBytes)
        try source.write(to: location.archive)

        let store = FloorpNotesStore(fileURL: location.archive)
        let migratedNotes = try await store.loadNotes()
        let migrated = try XCTUnwrap(migratedNotes.first)
        XCTAssertEqual(migrated.content.count, contentByteCount)
        XCTAssertEqual(migrated.contentFormat, .plainText)

        let persisted = try Data(contentsOf: location.archive)
        XCTAssertLessThanOrEqual(persisted.count, FloorpNotesStore.maximumArchiveBytes)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("contentFormat"))
    }

    func testBoundarySizedRichV1ArchiveFitsReservedV2MigrationHeadroom() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        let prefix = "{\"notes\":[{\"content\":\"{\\\"type\\\":\\\"doc\\\",\\\"content\\\":[{\\\"type\\\":\\\"paragraph\\\",\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\""
        let suffix = "\\\"}]}]}\",\"createdAt\":1,\"id\":\"rich-boundary\",\"title\":\"Rich Boundary\",\"updatedAt\":1}],\"revision\":1,\"schemaVersion\":1}"
        let textLength = FloorpNotesStore.legacyMaximumArchiveBytes
            - prefix.utf8.count
            - suffix.utf8.count
        let source = Data((prefix + String(repeating: "/", count: textLength) + suffix).utf8)
        XCTAssertEqual(source.count, FloorpNotesStore.legacyMaximumArchiveBytes)
        try source.write(to: location.archive)

        let migratedNotes = try await FloorpNotesStore(fileURL: location.archive).loadNotes()
        let migrated = try XCTUnwrap(migratedNotes.first)
        XCTAssertEqual(migrated.contentFormat, .automatic)
        XCTAssertEqual(
            FloorpNoteContent.analyze(
                migrated.content,
                contentFormat: migrated.contentFormat
            ).format,
            .tipTap
        )

        let persisted = try Data(contentsOf: location.archive)
        XCTAssertGreaterThan(persisted.count, FloorpNotesStore.legacyMaximumArchiveBytes)
        XCTAssertLessThanOrEqual(persisted.count, FloorpNotesStore.maximumArchiveBytes)
    }

    func testMaximumRichMetadataAndExponentNormalizationFitsV2Headroom() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        let richPrefix = "{\\\"type\\\":\\\"doc\\\",\\\"content\\\":[{\\\"type\\\":\\\"paragraph\\\",\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\""
        let richSuffix = "\\\"}]}]}"
        func encodedNote(index: Int, filler: String = "") -> String {
            "{\"content\":\"\(richPrefix)\(filler)\(richSuffix)\",\"createdAt\":9e18,\"id\":\"note-\(index)\",\"title\":\"\",\"updatedAt\":9e18}"
        }

        var encodedNotes = (0..<FloorpNotesStore.maximumNoteCount).map {
            encodedNote(index: $0)
        }
        let archivePrefix = "{\"notes\":["
        let archiveSuffix = "],\"revision\":9e18,\"schemaVersion\":1}"
        let baseSize = archivePrefix.utf8.count
            + encodedNotes.joined(separator: ",").utf8.count
            + archiveSuffix.utf8.count
        let fillerSize = FloorpNotesStore.legacyMaximumArchiveBytes - baseSize
        XCTAssertGreaterThan(fillerSize, 0)
        encodedNotes[0] = encodedNote(
            index: 0,
            filler: String(repeating: "/", count: fillerSize)
        )
        let source = Data(
            (archivePrefix + encodedNotes.joined(separator: ",") + archiveSuffix).utf8
        )
        XCTAssertEqual(source.count, FloorpNotesStore.legacyMaximumArchiveBytes)
        try source.write(to: location.archive)

        let migrated = try await FloorpNotesStore(fileURL: location.archive).loadNotes()
        XCTAssertEqual(migrated.count, FloorpNotesStore.maximumNoteCount)
        XCTAssertTrue(migrated.allSatisfy { $0.contentFormat == .automatic })

        let persisted = try Data(contentsOf: location.archive)
        XCTAssertGreaterThan(
            persisted.count,
            FloorpNotesStore.legacyMaximumArchiveBytes + 50_000
        )
        XCTAssertLessThanOrEqual(persisted.count, FloorpNotesStore.maximumArchiveBytes)
    }

    func testV1ArbitraryJSONMigratesAsEditablePlainText() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        let jsonLookingText = #"{"project":"Floorp","done":false}"#
        let legacyArchive: [String: Any] = [
            "schemaVersion": 1,
            "revision": 3,
            "notes": [[
                "id": "native-json",
                "title": "Native JSON",
                "content": jsonLookingText,
                "createdAt": 1_000,
                "updatedAt": 2_000,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: legacyArchive).write(to: location.archive)

        let migratedNotes = try await FloorpNotesStore(fileURL: location.archive).loadNotes()
        let migrated = try XCTUnwrap(migratedNotes.first)
        XCTAssertEqual(migrated.contentFormat, .plainText)
        XCTAssertEqual(
            FloorpNoteContent.analyze(
                migrated.content,
                contentFormat: migrated.contentFormat
            ).editPolicy,
            .direct
        )

        let restartedNotes = try await FloorpNotesStore(fileURL: location.archive).loadNotes()
        XCTAssertEqual(restartedNotes, [migrated])
    }

    func testUnsupportedNewerSchemaIsLeftByteForByteUntouched() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let source = Data(#"{"schemaVersion":999,"revision":1,"notes":[]}"#.utf8)
        try source.write(to: location.archive)

        let store = FloorpNotesStore(fileURL: location.archive)
        do {
            _ = try await store.loadNotes()
            XCTFail("Expected unsupportedSchema")
        } catch FloorpNotesStoreError.unsupportedSchema(let version) {
            XCTAssertEqual(version, 999)
        }

        XCTAssertEqual(try Data(contentsOf: location.archive), source)
        let recoveryCopies = try FileManager.default.contentsOfDirectory(
            at: location.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertTrue(recoveryCopies.isEmpty)
    }

    func testRecoveryCopyMustMatchBeforeResetIsAllowed() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let source = Data("not-json".utf8)
        try source.write(to: location.archive)

        let store = FloorpNotesStore(
            fileURL: location.archive,
            copyItem: { _, destination in
                try Data("truncated".utf8).write(to: destination)
            }
        )
        do {
            _ = try await store.loadNotes()
            XCTFail("Expected corruptArchiveCouldNotBePreserved")
        } catch FloorpNotesStoreError.corruptArchiveCouldNotBePreserved {
            // Expected.
        }
        do {
            try await store.resetAfterCorruption()
            XCTFail("Reset must stay blocked after a mismatched recovery copy")
        } catch FloorpNotesStoreError.corruptArchiveCouldNotBePreserved {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: location.archive), source)
    }

    func testReorderReplaceAndDesktopExportCoverUnusedStoreOperations() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(
            fileURL: location.archive,
            now: { 1_000 }
        )
        let first = try await store.createNote(title: "First", content: "A")
        let second = try await store.createNote(title: "Second", content: "B")
        let third = try await store.createNote(title: "Third", content: "C")

        try await store.reorderNotes(orderedIDs: [first.id, first.id, "missing"])
        let reorderedIDs = try await store.loadNotes().map(\.id)
        XCTAssertEqual(reorderedIDs, [first.id, third.id, second.id])

        try await store.replaceAllNotes(with: [second, first])
        let payloadData = try await store.desktopPayloadData()
        let payload = try JSONDecoder().decode(FloorpNotesDesktopPayload.self, from: payloadData)
        XCTAssertEqual(payload.ids, [second.id, first.id])
        XCTAssertEqual(payload.contents, ["B", "A"])

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let restartedNotes = try await restartedStore.loadNotes()
        XCTAssertEqual(restartedNotes, [second, first])
    }

    func testReplaceRejectsDuplicateIDsAndTooManyNotesWithoutWriting() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(fileURL: location.archive)
        let note = FloorpNote(
            id: "duplicate",
            title: "One",
            content: "",
            createdAt: 1,
            updatedAt: 1
        )

        do {
            try await store.replaceAllNotes(with: [note, note])
            XCTFail("Expected duplicateNoteID")
        } catch FloorpNotesStoreError.duplicateNoteID(let id) {
            XCTAssertEqual(id, note.id)
        }

        let tooMany = (0...FloorpNotesStore.maximumNoteCount).map { index in
            FloorpNote(
                id: "note-\(index)",
                title: "Note",
                content: "",
                createdAt: 1,
                updatedAt: 1
            )
        }
        do {
            try await store.replaceAllNotes(with: tooMany)
            XCTFail("Expected tooManyNotes")
        } catch FloorpNotesStoreError.tooManyNotes(let count) {
            XCTAssertEqual(count, FloorpNotesStore.maximumNoteCount + 1)
        }
        let notes = try await store.loadNotes()
        XCTAssertEqual(notes, [])
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
final class FloorpNoteEditorViewControllerTests: XCTestCase {
    func testExplicitSavePersistsUntouchedNewDraftOnlyOnce() async {
        let draft = makeDraft()
        var savedDrafts = [FloorpNote]()
        let editor = makeEditor(note: draft, isPersisted: false) { note in
            savedDrafts.append(note)
            return FloorpNote(
                id: "persisted-id",
                title: note.title,
                content: note.content,
                createdAt: 1_000,
                updatedAt: 1_000
            )
        }

        let firstSaveSucceeded = await editor.saveForExplicitRequest()
        let secondSaveSucceeded = await editor.saveForExplicitRequest()

        XCTAssertTrue(firstSaveSucceeded)
        XCTAssertTrue(secondSaveSucceeded)
        XCTAssertEqual(savedDrafts, [draft])
    }

    func testExplicitSaveDoesNotRewriteUntouchedExistingNote() async {
        var saveCount = 0
        let editor = makeEditor(note: makeDraft(), isPersisted: true) { note in
            saveCount += 1
            return note
        }

        let saveSucceeded = await editor.saveForExplicitRequest()

        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(saveCount, 0)
    }

    func testFailedExplicitSaveOfUntouchedDraftCanRetry() async {
        var saveCount = 0
        let editor = makeEditor(note: makeDraft(), isPersisted: false) { note in
            saveCount += 1
            guard saveCount > 1 else { throw SaveError.expected }
            return FloorpNote(
                id: "persisted-id",
                title: note.title,
                content: note.content,
                createdAt: 1_000,
                updatedAt: 1_000
            )
        }

        let firstSaveSucceeded = await editor.saveForExplicitRequest()
        let retrySucceeded = await editor.saveForExplicitRequest()

        XCTAssertFalse(firstSaveSucceeded)
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(saveCount, 2)
    }

    func testEditingAutomaticContentAsJSONPersistsExplicitPlainTextFormat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNoteEditorFormatTests-\(UUID().uuidString)")
        let archive = directory.appendingPathComponent("notes.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FloorpNotesStore(fileURL: archive)
        let original = try await store.createNote(
            title: "Migrated",
            content: "Legacy plain text",
            contentFormat: .automatic
        )
        let editor = FloorpNoteEditorViewController(
            note: original,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            persistence: FloorpNotePersistenceSession(notesStore: store, persistedNote: original)
        )
        editor.loadViewIfNeeded()
        let textView = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UITextView }.first)
        let jsonLookingText = #"{"project":"Floorp","done":false}"#
        textView.text = jsonLookingText
        editor.textViewDidChange(textView)

        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)

        let restartedNotes = try await FloorpNotesStore(fileURL: archive).loadNotes()
        let restarted = try XCTUnwrap(restartedNotes.first)
        XCTAssertEqual(restarted.contentFormat, .plainText)
        let analysis = FloorpNoteContent.analyze(
            restarted.content,
            contentFormat: restarted.contentFormat
        )
        XCTAssertEqual(analysis.editorText, jsonLookingText)
        XCTAssertEqual(analysis.editPolicy, .direct)
    }

    private func makeEditor(
        note: FloorpNote,
        isPersisted: Bool,
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote
    ) -> FloorpNoteEditorViewController {
        FloorpNoteEditorViewController(
            note: note,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPersisted: isPersisted,
            onSave: onSave
        )
    }

    private func makeDraft() -> FloorpNote {
        FloorpNote(
            id: "draft-id",
            title: "New Note",
            content: "",
            createdAt: 500,
            updatedAt: 500
        )
    }

    private enum SaveError: Error {
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
final class FloorpNoteSaveCoordinatorTests: XCTestCase {
    func testConflictIsTypedAndReloadReplacesTheDirtyDraft() async throws {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let latest = makeNote(id: "note", title: "Remote", updatedAt: 2)
        let persistence = MockFloorpNotePersistence()
        persistence.saveHandler = { _ in
            throw FloorpNotesStoreError.editConflict(original.id)
        }
        persistence.reloadHandler = { latest }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateTitle("Local")

        let outcome = await coordinator.saveLatest()
        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected a typed save failure")
        }
        XCTAssertEqual(failure.kind, .conflict)
        XCTAssertTrue(coordinator.hasUnsavedChanges)

        let reloaded = try await coordinator.reload()
        XCTAssertEqual(reloaded, latest)
        XCTAssertEqual(coordinator.draft, latest)
        XCTAssertEqual(persistence.acceptedReloads, [latest])
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testDeletedNoteCanBeRecoveredAsCopy() async {
        let original = makeNote(id: "deleted", title: "Original", updatedAt: 1)
        let copy = makeNote(id: "copy", title: "Recovered", updatedAt: 10)
        let persistence = MockFloorpNotePersistence()
        persistence.saveHandler = { _ in
            throw FloorpNotesStoreError.noteNotFound(original.id)
        }
        persistence.copyHandler = { draft in
            FloorpNote(
                id: copy.id,
                title: draft.title,
                content: draft.content,
                createdAt: copy.createdAt,
                updatedAt: copy.updatedAt,
                contentFormat: draft.contentFormat
            )
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateTitle("Recovered")

        guard case .failed(let failure) = await coordinator.saveLatest() else {
            return XCTFail("Expected noteNotFound")
        }
        XCTAssertEqual(failure.kind, .noteDeleted)

        guard case .saved = await coordinator.saveAsCopy() else {
            return XCTFail("Expected save-as-copy recovery")
        }
        XCTAssertEqual(coordinator.draft.id, copy.id)
        XCTAssertEqual(coordinator.draft.title, "Recovered")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testEditMadeDuringSaveIsPersistedInFollowUpWrite() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        var firstSaveContinuation: CheckedContinuation<Void, Never>?
        var savedDrafts = [FloorpNote]()
        persistence.saveHandler = { draft in
            savedDrafts.append(draft)
            if savedDrafts.count == 1 {
                await withCheckedContinuation { continuation in
                    firstSaveContinuation = continuation
                }
            }
            var saved = draft
            saved.updatedAt += Int64(savedDrafts.count)
            return saved
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateTitle("First edit")

        let saveTask = Task { await coordinator.saveLatest() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while firstSaveContinuation == nil,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let firstSaveContinuation else {
            saveTask.cancel()
            return XCTFail("First save did not reach persistence before the timeout")
        }
        coordinator.updateContent("Second edit", contentFormat: .plainText)
        firstSaveContinuation.resume()

        guard case .saved = await saveTask.value else {
            return XCTFail("Expected both edits to save")
        }
        XCTAssertEqual(savedDrafts.count, 2)
        XCTAssertEqual(savedDrafts.last?.content, "Second edit")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testArchiveLimitFailureRemainsDirtyAndTyped() async {
        let persistence = MockFloorpNotePersistence()
        persistence.saveHandler = { _ in
            throw FloorpNotesStoreError.archiveTooLarge(actualBytes: 2, maximumBytes: 1)
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: makeNote(id: "note", title: "Original", updatedAt: 1),
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateContent("Too large")

        guard case .failed(let failure) = await coordinator.saveLatest() else {
            return XCTFail("Expected archiveTooLarge")
        }
        XCTAssertEqual(failure.kind, .archiveTooLarge)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
    }

    func testSaveDuringDelayedCopySerializesAndTargetsTheCopyIdentity() async {
        let original = makeNote(id: "original", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        var copyContinuation: CheckedContinuation<Void, Never>?
        var operations = [String]()
        persistence.copyHandler = { draft in
            operations.append("copy:\(draft.id)")
            await withCheckedContinuation { continuation in
                copyContinuation = continuation
            }
            return FloorpNote(
                id: "copy",
                title: draft.title,
                content: draft.content,
                createdAt: 10,
                updatedAt: 10,
                contentFormat: draft.contentFormat
            )
        }
        persistence.saveHandler = { draft in
            operations.append("save:\(draft.id)")
            var saved = draft
            saved.updatedAt += 1
            return saved
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateTitle("Recovered")

        let copyTask = Task { await coordinator.saveAsCopy() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while copyContinuation == nil,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let copyContinuation else {
            copyTask.cancel()
            return XCTFail("Copy did not reach persistence before the timeout")
        }

        coordinator.updateContent("Edit during copy", contentFormat: .plainText)
        let saveTask = Task { await coordinator.saveLatest() }
        copyContinuation.resume()

        guard case .saved = await copyTask.value else {
            return XCTFail("Expected copy recovery to save")
        }
        _ = await saveTask.value
        XCTAssertEqual(operations, ["copy:original", "save:copy"])
        XCTAssertEqual(coordinator.draft.id, "copy")
        XCTAssertEqual(coordinator.draft.content, "Edit during copy")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testEditDuringReloadIsKeptInsteadOfBeingOverwritten() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let remote = makeNote(id: "note", title: "Remote", updatedAt: 2)
        let persistence = MockFloorpNotePersistence()
        var reloadContinuation: CheckedContinuation<Void, Never>?
        persistence.reloadHandler = {
            await withCheckedContinuation { continuation in
                reloadContinuation = continuation
            }
            return remote
        }
        persistence.saveHandler = { _ in
            throw FloorpNotesStoreError.editConflict(original.id)
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.updateTitle("Local")

        let reloadTask = Task { try await coordinator.reload() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while reloadContinuation == nil,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let reloadContinuation else {
            reloadTask.cancel()
            return XCTFail("Reload did not reach persistence before the timeout")
        }

        coordinator.updateContent("Edit during reload", contentFormat: .plainText)
        reloadContinuation.resume()

        do {
            _ = try await reloadTask.value
            XCTFail("Reload must not overwrite an edit made while it was pending")
        } catch FloorpNotesStoreError.editConflict(let id) {
            XCTAssertEqual(id, original.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(coordinator.draft.title, "Local")
        XCTAssertEqual(coordinator.draft.content, "Edit during reload")
        XCTAssertTrue(persistence.acceptedReloads.isEmpty)
        XCTAssertTrue(coordinator.hasUnsavedChanges)

        guard case .failed(let failure) = await coordinator.saveLatest() else {
            return XCTFail("Rejected reload must preserve the original conflict baseline")
        }
        XCTAssertEqual(failure.kind, .conflict)
    }

    private func makeNote(id: String, title: String, updatedAt: Int64) -> FloorpNote {
        FloorpNote(
            id: id,
            title: title,
            content: "",
            createdAt: 1,
            updatedAt: updatedAt,
            contentFormat: .plainText
        )
    }
}

@MainActor
private final class MockFloorpNotePersistence: FloorpNotePersistence {
    var saveHandler: (FloorpNote) async throws -> FloorpNote = { note in note }
    var reloadHandler: () async throws -> FloorpNote? = { nil }
    var copyHandler: (FloorpNote) async throws -> FloorpNote = { note in note }
    private(set) var acceptedReloads = [FloorpNote]()

    func save(_ draft: FloorpNote) async throws -> FloorpNote {
        try await saveHandler(draft)
    }

    func reload() async throws -> FloorpNote? {
        try await reloadHandler()
    }

    func acceptReloaded(_ note: FloorpNote) {
        acceptedReloads.append(note)
    }

    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote {
        try await copyHandler(draft)
    }
}

@MainActor
final class FloorpOverlayDrawerPresentationTests: XCTestCase {
    func testDrawerUsesModalOverlayOutsideBrowserSubviewZOrder() async {
        let suiteName = "FloorpOverlayDrawerPresentationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpOverlayDrawerPresentationTests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveDirectory)
        }

        let panelManager = FloorpPanelManager(defaults: defaults)
        panelManager.selectPanel(id: "floorp//notes")
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: panelManager,
            notesStore: FloorpNotesStore(fileURL: archiveDirectory.appendingPathComponent("notes.json")),
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        var dismissalCount = 0
        let presented = expectation(description: "Drawer presentation completed")
        let dismissed = expectation(description: "Drawer dismissal completed")
        drawer.onDismissed = {
            dismissalCount += 1
            dismissed.fulfill()
        }
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)

        XCTAssertEqual(drawer.modalPresentationStyle, .overFullScreen)
        XCTAssertTrue(parent.presentedViewController === drawer)
        XCTAssertFalse(parent.view.subviews.contains(where: { $0 === drawer.view }))

        let simulatedAddressBar = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        parent.view.addSubview(simulatedAddressBar)
        parent.view.bringSubviewToFront(simulatedAddressBar)
        XCTAssertTrue(parent.presentedViewController === drawer)

        drawer.dismissDrawer()
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(dismissalCount, 1)
    }

    func testExternalDismissalFinishesOnceAndAllowsReplacementDrawer() async {
        let suiteName = "FloorpOverlayDrawerExternalDismissalTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpOverlayDrawerExternalDismissalTests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveDirectory)
        }
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let makeDrawer = {
            let manager = FloorpPanelManager(defaults: defaults)
            manager.selectPanel(id: "floorp//notes")
            return FloorpOverlayDrawerViewController(
                panelManager: manager,
                notesStore: FloorpNotesStore(
                    fileURL: archiveDirectory.appendingPathComponent("notes.json")
                ),
                windowUUID: .XCTestDefaultUUID,
                themeManager: MockThemeManager(),
                notificationCenter: MockNotificationCenter()
            )
        }
        let drawer = makeDrawer()
        var dismissalCount = 0
        let presented = expectation(description: "Initial drawer presentation completed")
        let dismissed = expectation(description: "External dismissal completed")
        drawer.onDismissed = {
            dismissalCount += 1
            dismissed.fulfill()
        }
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)

        parent.dismiss(animated: false)
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(dismissalCount, 1)

        let replacement = makeDrawer()
        let replacementPresented = expectation(description: "Replacement drawer presented")
        let replacementDismissed = expectation(description: "Replacement drawer dismissed")
        replacement.onDismissed = { replacementDismissed.fulfill() }
        XCTAssertTrue(replacement.show(from: parent) { replacementPresented.fulfill() })
        await fulfillment(of: [replacementPresented], timeout: 1)
        replacement.dismissDrawer()
        await fulfillment(of: [replacementDismissed], timeout: 1)
    }

    func testPresentationIsRejectedWhileParentAlreadyOwnsAModal() async {
        let suiteName = "FloorpOverlayDrawerRejectedPresentationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let blocker = UIViewController()
        let blockerPresented = expectation(description: "Blocking modal presented")
        parent.present(blocker, animated: false) { blockerPresented.fulfill() }
        await fulfillment(of: [blockerPresented], timeout: 1)
        let manager = FloorpPanelManager(defaults: defaults)
        manager.selectPanel(id: "floorp//notes")
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("unused-\(UUID().uuidString).json")
            ),
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )

        XCTAssertFalse(drawer.show(from: parent))
        XCTAssertNil(drawer.presentingViewController)

        let blockerDismissed = expectation(description: "Blocking modal dismissed")
        parent.dismiss(animated: false) { blockerDismissed.fulfill() }
        await fulfillment(of: [blockerDismissed], timeout: 1)
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
        XCTAssertTrue(item.matchesSearchQuery("  needle   title "))
        XCTAssertFalse(item.matchesSearchQuery("not present"))

        let localizedItem = DrawerItem(id: "localized", title: "Café Ｆｌｏｏｒｐ")
        XCTAssertTrue(localizedItem.matchesSearchQuery("cafe floorp"))
    }
}
