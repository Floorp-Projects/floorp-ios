// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Common
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import Client

func makeFloorpTestNote(
    id: FloorpNoteID,
    title: String,
    content: String,
    createdAt: Int64,
    updatedAt: Int64,
    contentFormat: FloorpNoteContentFormat = .automatic
) -> FloorpNote {
    FloorpNote(
        id: id,
        title: title,
        content: content,
        createdAt: createdAt,
        updatedAt: updatedAt,
        contentFormat: contentFormat
    )
}

func makeFloorpTestNote(
    id: String,
    title: String,
    content: String,
    createdAt: Int64,
    updatedAt: Int64,
    contentFormat: FloorpNoteContentFormat = .automatic
) -> FloorpNote {
    makeFloorpTestNote(
        id: FloorpNoteID(id),
        title: title,
        content: content,
        createdAt: createdAt,
        updatedAt: updatedAt,
        contentFormat: contentFormat
    )
}

func makeFloorpTestNoteIDs(_ rawValues: [String]) -> [FloorpNoteID] {
    rawValues.map(FloorpNoteID.init)
}

final class FloorpNoteIDTests: XCTestCase {
    func testEqualityHashingAndOrderingUseExactUTF8Bytes() {
        let composed = FloorpNoteID("\u{00E9}")
        let decomposed = FloorpNoteID("e\u{0301}")

        XCTAssertNotEqual(Data(composed.rawValue.utf8), Data(decomposed.rawValue.utf8))
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: [(composed, 1), (decomposed, 2)]).count, 2)
        XCTAssertLessThan(decomposed, composed)
    }

    func testCodableUsesSingleJSONStringAndPreservesRawValue() throws {
        let original = FloorpNoteID(" note-e\u{0301} ")
        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), original.rawValue)
        let decoded = try JSONDecoder().decode(FloorpNoteID.self, from: data)
        XCTAssertEqual(Data(decoded.rawValue.utf8), Data(original.rawValue.utf8))
    }
}

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
        XCTAssertEqual(notes.map(\.id), makeFloorpTestNoteIDs(["duplicate", "generated-id"]))
        XCTAssertEqual(notes.map(\.createdAt), [1_000, 1_000])
        XCTAssertEqual(FloorpNotesDesktopPayload(notes: notes).contents, ["A", "B"])
    }

    func testDesktopPayloadPreservesCanonicallyEquivalentIDsAndUsesByteExactEquality() throws {
        let composed = "note-\u{00E9}"
        let decomposed = "note-e\u{0301}"
        let payload = FloorpNotesDesktopPayload(
            ids: [composed, decomposed],
            titles: ["Composed", "Decomposed"],
            contents: ["A", "B"]
        )
        var generatedIDCount = 0

        let notes = try payload.normalizedNotes(now: 1_000) {
            generatedIDCount += 1
            return "unexpected-generated-id"
        }

        XCTAssertEqual(generatedIDCount, 0)
        XCTAssertEqual(notes.map(\.id), [FloorpNoteID(composed), FloorpNoteID(decomposed)])
        XCTAssertEqual(
            FloorpNotesDesktopPayload(notes: notes).ids?.map { Data($0.utf8) },
            [Data(composed.utf8), Data(decomposed.utf8)]
        )
        XCTAssertNotEqual(
            payload,
            FloorpNotesDesktopPayload(
                ids: [composed, composed],
                titles: payload.titles,
                contents: payload.contents
            )
        )
    }

    func testCanonicallyEquivalentIDsPersistReorderUpdateAndDeleteIndependentlyAcrossRestarts() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let composedID = FloorpNoteID("note-\u{00E9}")
        let decomposedID = FloorpNoteID("note-e\u{0301}")
        let notes = [
            makeFloorpTestNote(
                id: composedID,
                title: "Composed",
                content: "A",
                createdAt: 1,
                updatedAt: 1
            ),
            makeFloorpTestNote(
                id: decomposedID,
                title: "Decomposed",
                content: "B",
                createdAt: 2,
                updatedAt: 2
            ),
        ]

        try await FloorpNotesStore(fileURL: location.archive).replaceAllNotes(with: notes)
        let reorderStore = FloorpNotesStore(fileURL: location.archive)
        let initiallyRestartedIDs = try await reorderStore.loadNotes().map(\.id)
        XCTAssertEqual(initiallyRestartedIDs, [composedID, decomposedID])

        try await reorderStore.reorderNotes(orderedIDs: [decomposedID, composedID])
        let updateStore = FloorpNotesStore(fileURL: location.archive)
        let reorderedRestartedIDs = try await updateStore.loadNotes().map(\.id)
        XCTAssertEqual(reorderedRestartedIDs, [decomposedID, composedID])

        _ = try await updateStore.updateNote(
            id: composedID,
            title: "Updated composed",
            content: "A2"
        )
        let deleteStore = FloorpNotesStore(fileURL: location.archive)
        let updatedNotes = try await deleteStore.loadNotes()
        XCTAssertEqual(updatedNotes.first(where: { $0.id == composedID })?.title, "Updated composed")
        XCTAssertEqual(updatedNotes.first(where: { $0.id == decomposedID })?.title, "Decomposed")

        try await deleteStore.deleteNote(id: decomposedID)
        let finalNotes = try await FloorpNotesStore(fileURL: location.archive).loadNotes()
        XCTAssertEqual(finalNotes.map(\.id), [composedID])
        XCTAssertEqual(finalNotes.first?.content, "A2")
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
        let suffix = "\",\"createdAt\":1,\"id\":\"legacy\",\"title\":\"Boundary\","
            + "\"updatedAt\":1}],\"revision\":1,\"schemaVersion\":1}"
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

        let prefix = "{\"notes\":[{\"content\":\"{\\\"type\\\":\\\"doc\\\","
            + "\\\"content\\\":[{\\\"type\\\":\\\"paragraph\\\","
            + "\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\""
        let suffix = "\\\"}]}]}\",\"createdAt\":1,\"id\":\"rich-boundary\","
            + "\"title\":\"Rich Boundary\",\"updatedAt\":1}],"
            + "\"revision\":1,\"schemaVersion\":1}"
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

        let richPrefix = "{\\\"type\\\":\\\"doc\\\","
            + "\\\"content\\\":[{\\\"type\\\":\\\"paragraph\\\","
            + "\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\""
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

        try await store.reorderNotes(orderedIDs: [first.id, first.id, FloorpNoteID("missing")])
        let reorderedIDs = try await store.loadNotes().map(\.id)
        XCTAssertEqual(reorderedIDs, [first.id, third.id, second.id])

        try await store.replaceAllNotes(with: [second, first])
        let payloadData = try await store.desktopPayloadData()
        let payload = try JSONDecoder().decode(FloorpNotesDesktopPayload.self, from: payloadData)
        XCTAssertEqual(payload.ids, [second.id.rawValue, first.id.rawValue])
        XCTAssertEqual(payload.contents, ["B", "A"])

        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let restartedNotes = try await restartedStore.loadNotes()
        XCTAssertEqual(restartedNotes, [second, first])
    }

    func testReplaceRejectsDuplicateIDsAndTooManyNotesWithoutWriting() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(fileURL: location.archive)
        let note = makeFloorpTestNote(
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
            makeFloorpTestNote(
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

    func testRichDocumentPreflightUsesWholeArchiveBudgetWithoutWriting() async throws {
        let location = try makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = FloorpNotesStore(fileURL: location.archive, now: { 1_000 })
        let original = try await store.createNote(title: "Safe", content: "original")
        let singleCharacter = try FloorpRichTextCodec.document(fromPlainText: "a")
        let fixedBytes = try FloorpRichTextCodec.encode(singleCharacter).utf8.count - 1
        let document = try FloorpRichTextCodec.document(
            fromPlainText: String(
                repeating: "a",
                count: FloorpRichTextCodec.maximumInputBytes - fixedBytes
            )
        )
        let source = try FloorpRichTextCodec.encode(document)
        XCTAssertEqual(source.utf8.count, FloorpRichTextCodec.maximumInputBytes)
        XCTAssertTrue(try FloorpRichTextCodec.decode(source).compatibility.isEditable)
        let before = try await store.loadSnapshot()

        do {
            try await store.preflightUpdateNote(
                id: original.id,
                title: original.title,
                content: source,
                contentFormat: .automatic
            )
            XCTFail("Expected the enclosing archive budget to reject the rich document")
        } catch FloorpNotesStoreError.archiveTooLarge(let actual, let maximum) {
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, FloorpNotesStore.maximumArchiveBytes)
        }

        let after = try await store.loadSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.notes.first?.content, "original")
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
    private let safePNGDataURL = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    func testExplicitSavePersistsUntouchedNewDraftOnlyOnce() async {
        let draft = makeDraft()
        var savedDrafts = [FloorpNote]()
        let editor = makeEditor(note: draft, isPersisted: false) { note in
            savedDrafts.append(note)
            return makeFloorpTestNote(
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
            return makeFloorpTestNote(
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
        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
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

    func testRichNoteExposesAccessibleDesktopFormattingControls() throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hello"}]}]}"#
        let note = makeFloorpTestNote(
            id: "rich-note",
            title: "Rich",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let editor = makeEditor(note: note, isPersisted: true) { $0 }

        editor.loadViewIfNeeded()

        let richBody = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        XCTAssertFalse(richBody.isHidden)
        let expectedControls: [(String, String)] = [
            ("Undo", FloorpStrings.Notes.undo),
            ("Redo", FloorpStrings.Notes.redo),
            ("Heading1", FloorpStrings.Notes.heading1),
            ("Heading2", FloorpStrings.Notes.heading2),
            ("Heading3", FloorpStrings.Notes.heading3),
            ("Bold", FloorpStrings.Notes.bold),
            ("Italic", FloorpStrings.Notes.italic),
            ("Underline", FloorpStrings.Notes.underline),
            ("Strikethrough", FloorpStrings.Notes.strikethrough),
            ("BulletList", FloorpStrings.Notes.bulletList),
            ("OrderedList", FloorpStrings.Notes.orderedList),
            ("AlignLeft", FloorpStrings.Notes.alignLeft),
            ("AlignCenter", FloorpStrings.Notes.alignCenter),
            ("AlignRight", FloorpStrings.Notes.alignRight),
            ("InsertImage", FloorpStrings.Notes.insertImage),
        ]
        for (identifier, label) in expectedControls {
            let button = try XCTUnwrap(editor.view.floorpNotesDescendant(
                withIdentifier: "Floorp.Notes.RichEditor.\(identifier)"
            ) as? UIButton)
            XCTAssertEqual(button.accessibilityLabel, label)
            let hasMinimumHeight = button.constraints.contains { constraint in
                constraint.firstAttribute == NSLayoutConstraint.Attribute.height
                    && constraint.relation == NSLayoutConstraint.Relation.greaterThanOrEqual
                    && constraint.constant >= 44
            }
            XCTAssertTrue(hasMinimumHeight)
        }
    }

    func testRichEditorFactoryRunsOnlyForEditableRichNotes() throws {
        var factoryCount = 0
        let factory: @MainActor () -> FloorpRichTextWebEditorView = {
            factoryCount += 1
            return FloorpRichTextWebEditorView()
        }
        let plainNote = makeFloorpTestNote(
            id: "factory-plain",
            title: "Plain",
            content: "Plain body",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        let plainEditor = makeEditor(
            note: plainNote,
            isPersisted: true,
            richTextEditorFactory: factory
        ) { $0 }
        plainEditor.loadViewIfNeeded()
        XCTAssertEqual(factoryCount, 0)
        XCTAssertNil(plainEditor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))

        let remoteSource = """
          { "type" : "doc", "content" : [
            {"type":"image","attrs":{"src":"https://images.example.test/photo.png"}}
          ] }
        """
        let readOnlyNote = makeFloorpTestNote(
            id: "factory-read-only",
            title: "Remote",
            content: remoteSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let readOnlyEditor = makeEditor(
            note: readOnlyNote,
            isPersisted: true,
            richTextEditorFactory: factory
        ) { $0 }
        readOnlyEditor.loadViewIfNeeded()
        XCTAssertEqual(factoryCount, 0)
        XCTAssertNil(readOnlyEditor.currentRichTextSession)
        XCTAssertEqual(readOnlyEditor.currentDraftForTesting.content, remoteSource)
        XCTAssertNil(readOnlyEditor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
        let readOnlyBody = try XCTUnwrap(readOnlyEditor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertFalse(readOnlyBody.isEditable)

        let richSource = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
        let richNote = makeFloorpTestNote(
            id: "factory-rich",
            title: "Rich",
            content: richSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let richEditor = makeEditor(
            note: richNote,
            isPersisted: true,
            richTextEditorFactory: factory
        ) { $0 }
        richEditor.loadViewIfNeeded()
        XCTAssertEqual(factoryCount, 1)
        XCTAssertNotNil(richEditor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
    }

    func testCloseInvalidatesAndReleasesRichEditorWithPendingJavaScript() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
        let note = makeFloorpTestNote(
            id: "close-release",
            title: "Close",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var factoryCount = 0
        weak var weakRichEditor: FloorpRichTextWebEditorView?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                let richEditor = FloorpRichTextWebEditorView()
                weakRichEditor = richEditor
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editor.loadViewIfNeeded()
        var richEditor: FloorpRichTextWebEditorView? = try XCTUnwrap(weakRichEditor)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richEditor?.snapshot(expectedSession: session)
        richEditor?.setJavaScriptRequestTimeoutForTesting(5_000_000_000)
        var pendingRequest: Task<Bool, Never>? = Task { @MainActor [weak richEditor] in
            guard let richEditor else { return false }
            do {
                try await richEditor.waitForNeverResolvingJavaScriptForTesting()
                return false
            } catch {
                return true
            }
        }
        try await waitUntil { richEditor?.pendingJavaScriptRequestCountForTesting == 1 }

        let didClose = await editor.closeForTesting()

        XCTAssertTrue(didClose)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertTrue(richEditor?.isInvalidatedForTesting == true)
        let pendingRequestDidFail = await pendingRequest?.value
        XCTAssertEqual(pendingRequestDidFail, true)
        pendingRequest = nil
        richEditor = nil
        try await waitUntil { weakRichEditor == nil }
        XCTAssertNil(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
    }

    func testControllerDeinitInvalidatesRichEditorWithPendingJavaScript() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
        let note = makeFloorpTestNote(
            id: "deinit-release",
            title: "Deinit",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        weak var weakRichEditor: FloorpRichTextWebEditorView?
        var editor: FloorpNoteEditorViewController? = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                weakRichEditor = richEditor
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editor?.loadViewIfNeeded()
        var richEditor: FloorpRichTextWebEditorView? = try XCTUnwrap(weakRichEditor)
        let session = try XCTUnwrap(editor?.currentRichTextSession)
        _ = try await richEditor?.snapshot(expectedSession: session)
        richEditor?.setJavaScriptRequestTimeoutForTesting(5_000_000_000)
        var pendingRequest: Task<Bool, Never>? = Task { @MainActor [weak richEditor] in
            guard let richEditor else { return false }
            do {
                try await richEditor.waitForNeverResolvingJavaScriptForTesting()
                return false
            } catch {
                return true
            }
        }
        try await waitUntil { richEditor?.pendingJavaScriptRequestCountForTesting == 1 }
        weak let weakEditor = editor

        editor = nil

        try await waitUntil { weakEditor == nil }
        try await waitUntil { richEditor?.isInvalidatedForTesting == true }
        let pendingRequestDidFail = await pendingRequest?.value
        XCTAssertEqual(pendingRequestDidFail, true)
        pendingRequest = nil
        richEditor = nil
        try await waitUntil { weakRichEditor == nil }
    }

    func testBridgeRecoveryInvalidatesAndReleasesReplacedRichEditor() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
        let note = makeFloorpTestNote(
            id: "recovery-release",
            title: "Recovery",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var factoryCount = 0
        weak var firstWeakEditor: FloorpRichTextWebEditorView?
        weak var secondWeakEditor: FloorpRichTextWebEditorView?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                let richEditor = FloorpRichTextWebEditorView()
                if factoryCount == 1 {
                    firstWeakEditor = richEditor
                } else if factoryCount == 2 {
                    secondWeakEditor = richEditor
                }
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editor.loadViewIfNeeded()
        var firstEditor: FloorpRichTextWebEditorView? = try XCTUnwrap(firstWeakEditor)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await firstEditor?.snapshot(expectedSession: initialSession)
        firstEditor?.setJavaScriptRequestTimeoutForTesting(5_000_000_000)
        var pendingRequest: Task<Bool, Never>? = Task { @MainActor [weak firstEditor] in
            guard let firstEditor else { return false }
            do {
                try await firstEditor.waitForNeverResolvingJavaScriptForTesting()
                return false
            } catch {
                return true
            }
        }
        try await waitUntil { firstEditor?.pendingJavaScriptRequestCountForTesting == 1 }

        firstEditor?.simulateWebContentProcessTerminationForTesting()
        try await waitUntil {
            factoryCount == 2 && editor.currentRichTextSession?.generation == 1
        }

        XCTAssertTrue(firstEditor?.isInvalidatedForTesting == true)
        let pendingRequestDidFail = await pendingRequest?.value
        XCTAssertEqual(pendingRequestDidFail, true)
        pendingRequest = nil
        firstEditor = nil
        try await waitUntil { firstWeakEditor == nil }
        let replacement = try XCTUnwrap(secondWeakEditor)
        let replacementSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await replacement.snapshot(expectedSession: replacementSession)
        XCTAssertFalse(replacement.isInvalidatedForTesting)
        let didClose = await editor.closeForTesting()
        XCTAssertTrue(didClose)
    }

    func testTerminatedPreflightCannotRecreateReleasedRichEditor() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
        let note = makeFloorpTestNote(
            id: "terminated-preflight",
            title: "Termination",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(
            blocksFirstPreflight: true,
            firstPreflightError: FloorpRichTextFlushError.updateRejected
        )
        var factoryCount = 0
        weak var weakRichEditor: FloorpRichTextWebEditorView?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                let richEditor = FloorpRichTextWebEditorView()
                weakRichEditor = richEditor
                return richEditor
            },
            persistence: persistence
        )
        editor.loadViewIfNeeded()
        var richEditor: FloorpRichTextWebEditorView? = try XCTUnwrap(weakRichEditor)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richEditor?.snapshot(expectedSession: session)
        let update = FloorpRichTextUpdateEnvelope(
            session: try session.advancing(to: 1),
            payload: FloorpRichTextEditorUpdate(
                source: #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"New"}]}]}"#
            )
        )
        editor.richTextEditor(try XCTUnwrap(richEditor), received: update)
        try await waitUntil { persistence.didStartFirstPreflight }

        editor.terminateEditorSessionForTesting()
        XCTAssertTrue(richEditor?.isInvalidatedForTesting == true)
        persistence.resumeFirstPreflight()
        try await waitUntil { !editor.hasPendingRichUpdateDrainForTesting }

        XCTAssertTrue(editor.hasTerminatedEditorSessionForTesting)
        XCTAssertEqual(factoryCount, 1)
        richEditor = nil
        try await waitUntil { weakRichEditor == nil }
        XCTAssertNil(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
    }

    func testOversizedDesktopNoteIdentityShowsRichBodyReadOnlyInsteadOfBlank() throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Visible desktop body"}]}
        ]}
        """
        let note = makeFloorpTestNote(
            id: String(repeating: "é", count: 600),
            title: "Long identity",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var factoryCount = 0
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                return FloorpRichTextWebEditorView()
            }
        ) { $0 }

        editor.loadViewIfNeeded()

        XCTAssertNil(editor.currentRichTextSession)
        XCTAssertEqual(factoryCount, 0)
        let richHost = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Host"
        ))
        XCTAssertTrue(richHost.isHidden)
        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertFalse(textView.isHidden)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.text, "Visible desktop body")
    }

    func testFirstRichSaveRebindsBridgeToPersistedIdentityWithoutRewritingSource() async throws {
        let source = """
          { "type" : "doc", "content" : [
            {"type":"paragraph","content":[{"type":"text","text":"Opaque spacing"}]}
          ] }
        """
        let note = makeFloorpTestNote(
            id: "temporary-rich-id",
            title: "New rich",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(savedNoteID: "persisted-rich-id")
        let editor = makeEditor(note: note, isPersisted: false, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: initialSession)

        let didSave = await editor.saveForExplicitRequest()

        XCTAssertTrue(didSave)
        let rebound = try XCTUnwrap(editor.currentRichTextSession)
        XCTAssertEqual(rebound.noteID, FloorpNoteID("persisted-rich-id"))
        XCTAssertNotEqual(rebound.documentID, initialSession.documentID)
        XCTAssertEqual(editor.currentDraftForTesting.content, source)
        let snapshot = try await richView.snapshot(expectedSession: rebound)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: snapshot.payload.source, contentFormat: .automatic),
            "Opaque spacing"
        )
    }

    func testLexicalSaveAsCopyRebindsUsingExistingDocumentAndPreservesOpaqueSource() async throws {
        let source = """
          { "root" : { "type" : "root", "version" : 1, "children" : [
            {"type":"paragraph","version":1,"children":[
              {"type":"text","text":"Lexical body","format":9,"version":1}
            ]}
          ] } }
        """
        let note = makeFloorpTestNote(
            id: "lexical-copy-source",
            title: "Lexical",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(copyNoteID: "lexical-copy-target")
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        _ = try await richView.snapshot(expectedSession: try XCTUnwrap(editor.currentRichTextSession))

        let didCopy = await editor.saveRecoveryDraftAsCopyForTesting()

        XCTAssertTrue(didCopy)
        let rebound = try XCTUnwrap(editor.currentRichTextSession)
        XCTAssertEqual(rebound.noteID, FloorpNoteID("lexical-copy-target"))
        XCTAssertEqual(editor.currentDraftForTesting.content, source)
        XCTAssertEqual(persistence.savedCopyDrafts.last?.content, source)
        let snapshot = try await richView.snapshot(expectedSession: rebound)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: snapshot.payload.source, contentFormat: .automatic),
            "Lexical body"
        )
    }

    func testPhotoEncoderDownsamplesOffMainActorAtOneToOneRendererScale() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2_400, height: 1_200),
            format: format
        ).image { context in
            UIColor.systemPurple.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_200))
        }
        let input = try XCTUnwrap(image.pngData())

        let encodedResult = await Task.detached {
            FloorpRichTextImageEncoder.encode(input)
        }.value
        let encoded = try XCTUnwrap(encodedResult)
        let payload = try XCTUnwrap(encoded.source.split(separator: ",", maxSplits: 1).last)
        let output = try XCTUnwrap(Data(base64Encoded: String(payload)))
        let outputImage = try XCTUnwrap(UIImage(data: output)?.cgImage)

        XCTAssertTrue(FloorpRichTextImagePolicy.isSafePersistedSource(encoded.source))
        XCTAssertLessThanOrEqual(
            encoded.source.utf8.count,
            FloorpRichTextImagePolicy.maximumPersistedSourceBytes
        )
        XCTAssertEqual(outputImage.width, 1_600)
        XCTAssertEqual(outputImage.height, 800)
        XCTAssertEqual(encoded.width, outputImage.width)
    }

    func testPhotoEncoderRejectsOversizedFileBeforeImageDecoding() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpOversizedImage-\(UUID().uuidString).dng")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FloorpRichTextImageEncoder.maximumSourceBytes + 1))
        try handle.close()

        let encoded = await Task.detached {
            FloorpRichTextImageEncoder.encodeFile(at: url)
        }.value

        XCTAssertNil(encoded)
        XCTAssertNil(
            FloorpRichTextImageEncoder.copyFileForEncoding(url, importID: UUID())
        )

        let smallURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpCancelableImage-\(UUID().uuidString).dng")
        try Data([0]).write(to: smallURL)
        defer { try? FileManager.default.removeItem(at: smallURL) }
        let cancellation = FloorpRichTextImageImportCancellation()
        cancellation.cancel()
        XCTAssertNil(
            FloorpRichTextImageEncoder.copyFileForEncoding(
                smallURL,
                importID: UUID(),
                isCancelled: { cancellation.isCancelled }
            )
        )
        let ownedURL = try XCTUnwrap(
            FloorpRichTextImageEncoder.copyFileForEncoding(smallURL, importID: UUID())
        )
        defer { try? FileManager.default.removeItem(at: ownedURL) }
        XCTAssertNotEqual(ownedURL, smallURL)
        XCTAssertEqual(try Data(contentsOf: ownedURL), Data([0]))
    }

    func testPhotoEncoderRejectsHugeDeclaredMetadataBeforeThumbnailDecode() async throws {
        let fixtures: [(dimensions: (width: UInt32, height: UInt32), data: Data)] = [
            (
                (UInt32(FloorpRichTextImageEncoder.maximumSourcePixelDimension + 1), 1),
                try solidPNGData(
                    width: Int(FloorpRichTextImageEncoder.maximumSourcePixelDimension + 1),
                    height: 1
                )
            ),
            ((8_193, 8_192), try oneBitGrayscalePNGData(width: 8_193, height: 8_192)),
        ]

        for fixture in fixtures {
            let data = fixture.data
            XCTAssertLessThan(data.count, 64 * 1_024)
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, options))
            XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
            )
            XCTAssertEqual(
                (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value,
                fixture.dimensions.width
            )
            XCTAssertEqual(
                (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value,
                fixture.dimensions.height
            )

            let encoded = await Task.detached {
                FloorpRichTextImageEncoder.encode(data)
            }.value
            XCTAssertNil(
                encoded,
                "\(fixture.dimensions.width)x\(fixture.dimensions.height)"
            )
        }
    }

    func testPlainNoteCanEnterRichEditorWithoutLosingItsText() async throws {
        let note = makeFloorpTestNote(
            id: "plain-to-rich",
            title: "Plain",
            content: "First\n\nThird",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        var savedDrafts = [FloorpNote]()
        let editor = makeEditor(note: note, isPersisted: true) {
            savedDrafts.append($0)
            return $0
        }
        editor.loadViewIfNeeded()
        let enable = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.EnableRichText"
        ) as? UIButton)

        enable.sendActions(for: .touchUpInside)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while editor.currentRichTextSession == nil,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertNotNil(editor.currentRichTextSession)
        let richEditor = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
        XCTAssertFalse(richEditor.isHidden)
        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)
        let saved = try XCTUnwrap(savedDrafts.last)
        XCTAssertEqual(saved.contentFormat, .automatic)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: saved.content, contentFormat: .automatic),
            "First\nThird"
        )
    }

    func testDelayedPlainToRichPreflightRebuildsFromTheNewestLockedBody() async throws {
        let note = makeFloorpTestNote(
            id: "delayed-conversion",
            title: "Plain",
            content: "First body",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        let persistence = FloorpRichTextTestPersistence(blocksFirstPreflight: true)
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        let enable = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.EnableRichText"
        ) as? UIButton)
        let status = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Status.Idle"
        ) as? UILabel)

        enable.sendActions(for: .touchUpInside)
        try await waitUntil { persistence.didStartFirstPreflight }

        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(enable.isEnabled)
        XCTAssertEqual(status.accessibilityIdentifier, "Floorp.Notes.Editor.Status.Saving")
        XCTAssertFalse(editor.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementText: "x"
        ))

        // Simulate a final delegate callback that was already queued when the
        // conversion button locked the UIKit control.
        textView.text = "Newest body"
        editor.textViewDidChange(textView)
        persistence.resumeFirstPreflight()

        try await waitUntil { editor.currentRichTextSession != nil }
        XCTAssertEqual(persistence.preflightDrafts.count, 2)
        XCTAssertEqual(
            FloorpNoteContent.plainText(
                from: persistence.preflightDrafts[0].content,
                contentFormat: .automatic
            ),
            "First body"
        )
        XCTAssertEqual(
            FloorpNoteContent.plainText(
                from: persistence.preflightDrafts[1].content,
                contentFormat: .automatic
            ),
            "Newest body"
        )

        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)
        XCTAssertEqual(
            FloorpNoteContent.plainText(
                from: try XCTUnwrap(persistence.savedDrafts.last).content,
                contentFormat: .automatic
            ),
            "Newest body"
        )
    }

    func testCloseCancelsPendingPlainToRichConversionBeforeDismissal() async throws {
        let note = makeFloorpTestNote(
            id: "cancel-conversion",
            title: "Plain",
            content: "Must remain plain",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        let persistence = FloorpRichTextTestPersistence(blocksFirstPreflight: true)
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let enable = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.EnableRichText"
        ) as? UIButton)

        enable.sendActions(for: .touchUpInside)
        try await waitUntil { persistence.didStartFirstPreflight }
        XCTAssertTrue(editor.isModalInPresentation)

        let didClose = await editor.closeForTesting()
        XCTAssertTrue(didClose)
        XCTAssertTrue(editor.hasTerminatedEditorSessionForTesting)
        persistence.resumeFirstPreflight()
        try await waitUntil { !editor.hasPendingPlainToRichConversionForTesting }

        XCTAssertNil(editor.currentRichTextSession)
        XCTAssertEqual(editor.currentDraftForTesting.content, "Must remain plain")
        XCTAssertEqual(editor.currentDraftForTesting.contentFormat, .plainText)
        XCTAssertTrue(persistence.savedDrafts.isEmpty)
    }

    func testImmediateSaveFlushesUnsentWebEditorInput() async throws {
        let originalSource = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let note = makeFloorpTestNote(
            id: "flush-before-save",
            title: "Flush",
            content: originalSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence()
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: session)

        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const paragraph = document.querySelector('#editor p');
            paragraph.textContent = 'Saved immediately';
            document.getElementById('editor').dispatchEvent(
              new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'Saved immediately' })
            );
            true;
            """
        )
        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)

        let saved = try XCTUnwrap(persistence.savedDrafts.last)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: saved.content, contentFormat: .automatic),
            "Saved immediately"
        )
    }

    func testRapidRichCommandsQuiesceBeforeImmediateCloseAndDoNotRunAfterFlush() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Format me"}]}]}"#
        let note = makeFloorpTestNote(
            id: "rapid-close",
            title: "Commands",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence()
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: session)
        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)
        let italic = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Italic"
        ) as? UIButton)

        bold.sendActions(for: .touchUpInside)
        italic.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.pendingRichCommandCountForTesting, 2)
        let didClose = await editor.closeForTesting()

        XCTAssertTrue(didClose)
        XCTAssertEqual(editor.pendingRichCommandCountForTesting, 0)
        let saved = try XCTUnwrap(persistence.savedDrafts.first)
        XCTAssertEqual(Set(try firstTextMarkTypes(saved.content)), Set(["bold", "italic"]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(persistence.savedDrafts, [saved])
    }

    func testCloseCommandFailureResumesWaiterAndRecoversOnlyAfterClosing() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Format me"}]}]}"#
        let note = makeFloorpTestNote(
            id: "failed-command-close",
            title: "Commands",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        var createdWhileClosing = false
        weak var editorForFactory: FloorpNoteEditorViewController?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                createdWhileClosing = createdWhileClosing
                    || editorForFactory?.isClosingForTesting == true
                let richEditor = FloorpRichTextWebEditorView()
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editorForFactory = editor
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(createdEditors.first)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: session)
        richView.setJavaScriptRequestTimeoutForTesting(200_000_000)
        _ = try await richView.evaluateJavaScriptForTesting(
            "window.floorpApplyCommand = () => new Promise(() => {}); true;"
        )
        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)

        bold.sendActions(for: .touchUpInside)
        try await waitUntil { editor.pendingRichCommandCountForTesting == 1 }
        let closeTask = Task { @MainActor in
            await editor.closeForTesting()
        }
        try await waitUntil {
            editor.isClosingForTesting
                && editor.hasRichCommandQuiescenceWaitersForTesting
        }
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !editor.isClosingForTesting
        }
        if editor.isClosingForTesting {
            editor.terminateEditorSessionForTesting()
        }
        let didClose = await closeTask.value

        XCTAssertFalse(didClose)
        XCTAssertFalse(editor.hasTerminatedEditorSessionForTesting)
        XCTAssertFalse(createdWhileClosing)
        XCTAssertEqual(createdEditors.count, 2)
        XCTAssertTrue(richView.isInvalidatedForTesting)
        XCTAssertEqual(editor.pendingRichCommandCountForTesting, 0)
        XCTAssertFalse(editor.hasRichCommandQuiescenceWaitersForTesting)
        let replacement = try XCTUnwrap(createdEditors.last)
        let replacementSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await replacement.snapshot(expectedSession: replacementSession)
    }

    func testCloseProcessTerminationDoesNotRestartWebContentWhileClosing() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Format me"}]}]}"#
        let note = makeFloorpTestNote(
            id: "terminated-command-close",
            title: "Commands",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        var createdWhileClosing = false
        weak var editorForFactory: FloorpNoteEditorViewController?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                createdWhileClosing = createdWhileClosing
                    || editorForFactory?.isClosingForTesting == true
                let richEditor = FloorpRichTextWebEditorView()
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editorForFactory = editor
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(createdEditors.first)
        _ = try await richView.snapshot(
            expectedSession: try XCTUnwrap(editor.currentRichTextSession)
        )
        richView.setJavaScriptRequestTimeoutForTesting(5_000_000_000)
        _ = try await richView.evaluateJavaScriptForTesting(
            "window.floorpApplyCommand = () => new Promise(() => {}); true;"
        )
        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)
        bold.sendActions(for: .touchUpInside)
        try await waitUntil { editor.pendingRichCommandCountForTesting == 1 }

        let closeTask = Task { @MainActor in await editor.closeForTesting() }
        try await waitUntil {
            editor.isClosingForTesting
                && editor.hasRichCommandQuiescenceWaitersForTesting
        }
        let navigationStarts = richView.startedInitialNavigationCountForTesting
        richView.simulateWebContentProcessTerminationForTesting()

        XCTAssertTrue(richView.isInvalidatedForTesting)
        XCTAssertFalse(richView.hasPendingInitialNavigationForTesting)
        XCTAssertEqual(richView.startedInitialNavigationCountForTesting, navigationStarts)
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !editor.isClosingForTesting
        }
        if editor.isClosingForTesting {
            editor.terminateEditorSessionForTesting()
        }
        let didClose = await closeTask.value

        XCTAssertFalse(didClose)
        XCTAssertFalse(createdWhileClosing)
        XCTAssertEqual(createdEditors.count, 2)
        XCTAssertFalse(editor.hasRichCommandQuiescenceWaitersForTesting)
        let replacement = try XCTUnwrap(createdEditors.last)
        _ = try await replacement.snapshot(
            expectedSession: try XCTUnwrap(editor.currentRichTextSession)
        )
        editor.terminateEditorSessionForTesting()
    }

    func testCloseInvalidatesTerminatedActiveRecoveryBeforeRestarting() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Recover"}]}]}"#
        let note = makeFloorpTestNote(
            id: "terminated-recovery-close",
            title: "Recovery",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        var createdWhileClosing = false
        weak var editorForFactory: FloorpNoteEditorViewController?
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                createdWhileClosing = createdWhileClosing
                    || editorForFactory?.isClosingForTesting == true
                let richEditor = FloorpRichTextWebEditorView()
                if createdEditors.count == 1 {
                    richEditor.stallNextInitialNavigationAttemptsForTesting(
                        attempts: 1,
                        timeoutNanoseconds: 5_000_000_000
                    )
                }
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editorForFactory = editor
        editor.loadViewIfNeeded()
        let initialEditor = try XCTUnwrap(createdEditors.first)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await initialEditor.snapshot(expectedSession: initialSession)

        initialEditor.simulateWebContentProcessTerminationForTesting()
        try await waitUntil {
            createdEditors.count == 2
                && editor.hasPendingRichBridgeRecoveryForTesting
        }
        let recoveryEditor = createdEditors[1]
        XCTAssertTrue(recoveryEditor.hasPendingInitialNavigationForTesting)
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)
        bold.sendActions(for: .touchUpInside)
        try await waitUntil { editor.pendingRichCommandCountForTesting == 1 }

        let closeTask = Task { @MainActor in await editor.closeForTesting() }
        try await waitUntil {
            editor.isClosingForTesting
                && editor.hasRichCommandQuiescenceWaitersForTesting
        }
        let navigationStarts = recoveryEditor.startedInitialNavigationCountForTesting
        recoveryEditor.simulateWebContentProcessTerminationForTesting()

        XCTAssertTrue(recoveryEditor.isInvalidatedForTesting)
        XCTAssertFalse(recoveryEditor.hasPendingInitialNavigationForTesting)
        XCTAssertEqual(
            recoveryEditor.startedInitialNavigationCountForTesting,
            navigationStarts
        )
        XCTAssertFalse(editor.hasPendingRichBridgeRecoveryForTesting)
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !editor.isClosingForTesting
        }
        if editor.isClosingForTesting {
            editor.terminateEditorSessionForTesting()
        }
        let didClose = await closeTask.value

        XCTAssertFalse(didClose)
        XCTAssertFalse(editor.hasTerminatedEditorSessionForTesting)
        XCTAssertFalse(createdWhileClosing)
        XCTAssertEqual(createdEditors.count, 3)
        XCTAssertFalse(editor.hasRichCommandQuiescenceWaitersForTesting)
        let replacement = createdEditors[2]
        let replacementSession = try XCTUnwrap(editor.currentRichTextSession)
        XCTAssertEqual(replacementSession.generation, initialSession.generation + 2)
        _ = try await replacement.snapshot(expectedSession: replacementSession)
        editor.terminateEditorSessionForTesting()
    }

    func testInputImmediatelyFollowedByBoldItalicAndCloseKeepsLatestDOM() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let note = makeFloorpTestNote(
            id: "input-command-close",
            title: "Immediate",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence()
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: initialSession)
        richView.setUpdateDeliverySuspendedForTesting(true)

        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            text.nodeValue = 'Latest DOM';
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            document.getElementById('editor').dispatchEvent(
              new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'Latest DOM' })
            );
            true;
            """
        )
        XCTAssertEqual(editor.currentRichTextSession, initialSession)
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)
        let italic = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Italic"
        ) as? UIButton)

        bold.sendActions(for: .touchUpInside)
        italic.sendActions(for: .touchUpInside)
        let didClose = await editor.closeForTesting()

        XCTAssertTrue(didClose)
        let saved = try XCTUnwrap(persistence.savedDrafts.last)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: saved.content, contentFormat: .automatic),
            "Latest DOM"
        )
        XCTAssertEqual(Set(try firstTextMarkTypes(saved.content)), Set(["bold", "italic"]))
    }

    func testCloseWaitsForSelectedImageInsteadOfSilentlyCancellingIt() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Image"}]}]}"#
        let note = makeFloorpTestNote(
            id: "image-close",
            title: "Image",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence()
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        _ = try await richView.snapshot(expectedSession: try XCTUnwrap(editor.currentRichTextSession))
        let importID = editor.beginImageImportForTesting()

        let closeTask = Task { @MainActor in await editor.closeForTesting() }
        try await waitUntil { editor.isClosingForTesting }
        editor.completeImageImportForTesting(
            importID: importID,
            image: FloorpRichTextImage(source: safePNGDataURL, alt: "selected")
        )
        let didClose = await closeTask.value

        XCTAssertTrue(didClose)
        let saved = try XCTUnwrap(persistence.savedDrafts.last)
        let root = try XCTUnwrap(FloorpRichTextCodec.decode(saved.content).root.objectValue)
        let content = try XCTUnwrap(root["content"]?.arrayValue)
        let images = content.filter { $0.objectValue?["type"]?.stringValue == "image" }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.objectValue?["attrs"]?.objectValue?["alt"]?.stringValue, "selected")
    }

    func testImageImportAggregateRejectionDoesNotMutateDOMOrSession() async throws {
        let imageSource = try solidPNGDataURL(width: 2_048, height: 2_048)
        let imageNode = #"{"type":"image","attrs":{"src":"\#(imageSource)"}}"#
        let source = "{\"type\":\"doc\",\"content\":["
            + Array(repeating: imageNode, count: 4).joined(separator: ",")
            + "]}"
        let note = makeFloorpTestNote(
            id: "image-aggregate-rejection",
            title: "Images",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        for closesEditor in [false, true] {
            var createdEditors = [FloorpRichTextWebEditorView]()
            let persistence = FloorpRichTextTestPersistence()
            let editor = makeEditor(
                note: note,
                isPersisted: true,
                richTextEditorFactory: {
                    let richEditor = FloorpRichTextWebEditorView()
                    createdEditors.append(richEditor)
                    return richEditor
                },
                persistence: persistence
            )
            editor.loadViewIfNeeded()
            let richView = try XCTUnwrap(createdEditors.first)
            let initialSession = try XCTUnwrap(editor.currentRichTextSession)
            let before = try await richView.snapshot(expectedSession: initialSession)

            let importID = editor.beginImageImportForTesting()
            let operationTask = Task { @MainActor in
                if closesEditor {
                    return await editor.closeForTesting()
                }
                return await editor.saveForExplicitRequest()
            }
            try await waitUntil { editor.hasImageImportWaitersForTesting }
            editor.completeImageImportForTesting(
                importID: importID,
                image: FloorpRichTextImage(source: safePNGDataURL, alt: "must-not-appear")
            )
            let didComplete = await operationTask.value
            let after = try await richView.snapshot(expectedSession: initialSession)

            XCTAssertFalse(didComplete, closesEditor ? "Close" : "Save")
            XCTAssertFalse(editor.hasTerminatedEditorSessionForTesting)
            XCTAssertTrue(persistence.savedDrafts.isEmpty)
            XCTAssertEqual(createdEditors.count, 1)
            XCTAssertFalse(richView.isInvalidatedForTesting)
            XCTAssertEqual(editor.currentRichTextSession, initialSession)
            XCTAssertEqual(after.session, initialSession)
            XCTAssertEqual(after.payload.source, before.payload.source)
            XCTAssertFalse(after.payload.isDirty)
            editor.terminateEditorSessionForTesting()
        }
    }

    func testImageImportTimeoutKeepsEditorOpenWithExplicitFailure() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Wait"}]}]}"#
        let note = makeFloorpTestNote(
            id: "image-timeout",
            title: "Image",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            persistence: FloorpRichTextTestPersistence()
        )
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        _ = try await richView.snapshot(expectedSession: try XCTUnwrap(editor.currentRichTextSession))
        editor.setImageImportTimeoutForTesting(40_000_000)
        _ = editor.beginImageImportForTesting()

        let didClose = await editor.closeForTesting()

        XCTAssertFalse(didClose)
        XCTAssertFalse(editor.hasTerminatedEditorSessionForTesting)
        XCTAssertFalse(editor.hasPendingImageImportForTesting)
        XCTAssertNotNil(editor.currentRichTextSession)
        let status = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Status.Error"
        ))
        XCTAssertFalse(status.isHidden)
    }

    func testStalledRecoveryLoadFailsClosedWithoutPermanentlyBlockingClose() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Recover"}]}]}"#
        let note = makeFloorpTestNote(
            id: "stalled-load",
            title: "Recovery",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence()
        var createdEditors = [FloorpRichTextWebEditorView]()
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                if !createdEditors.isEmpty {
                    richEditor.restartWithStalledInitialNavigationForTesting(
                        attempts: 1,
                        timeoutNanoseconds: 40_000_000
                    )
                }
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: persistence
        )
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: session)
        richView.setJavaScriptRequestTimeoutForTesting(40_000_000)
        _ = try await richView.evaluateJavaScriptForTesting(
            "window.floorpApplyCommand = () => new Promise(() => {});"
                + "window.floorpLoad = () => new Promise(() => {}); true;"
        )
        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)

        bold.sendActions(for: .touchUpInside)
        try await waitUntil { editor.currentRichTextSession == nil }

        XCTAssertEqual(createdEditors.count, 2)
        XCTAssertTrue(createdEditors.allSatisfy(\.isInvalidatedForTesting))
        XCTAssertEqual(editor.pendingRichCommandCountForTesting, 0)
        let didClose = await editor.closeForTesting()
        XCTAssertTrue(didClose)
        XCTAssertTrue(editor.hasTerminatedEditorSessionForTesting)
    }

    func testInitialHTMLNavigationStallRetriesOnceThenShowsReadOnlyBody() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Visible fallback"}]}
        ]}
        """
        let note = makeFloorpTestNote(
            id: "initial-navigation-stall",
            title: "Navigation",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                if !createdEditors.isEmpty {
                    richEditor.restartWithStalledInitialNavigationForTesting(
                        attempts: 1,
                        timeoutNanoseconds: 40_000_000
                    )
                }
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        let document = try FloorpRichTextCodec.decode(source)
        _ = try await richView.snapshot(expectedSession: session)

        richView.restartWithStalledInitialNavigationForTesting(
            attempts: 1,
            timeoutNanoseconds: 40_000_000
        )
        richView.load(document: document, session: session, isDirty: false)
        try await waitUntil { editor.currentRichTextSession == nil }

        XCTAssertEqual(createdEditors.count, 2)
        for createdEditor in createdEditors {
            XCTAssertTrue(createdEditor.isHidden)
            XCTAssertTrue(createdEditor.isInvalidatedForTesting)
            XCTAssertEqual(createdEditor.pendingJavaScriptRequestCountForTesting, 0)
        }
        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertFalse(textView.isHidden)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.text, "Visible fallback")
    }

    func testLateRichLoadCreatesEditorAfterConversionAndCanSaveAndClose() async throws {
        let note = makeFloorpTestNote(
            id: "late-rich-load",
            title: "Late navigation",
            content: "Body after navigation failure",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        let persistence = FloorpRichTextTestPersistence()
        var factoryCount = 0
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                return FloorpRichTextWebEditorView()
            },
            persistence: persistence
        )
        editor.loadViewIfNeeded()
        let enable = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.EnableRichText"
        ) as? UIButton)
        XCTAssertEqual(factoryCount, 0)
        XCTAssertNil(editor.currentRichTextSession)

        enable.sendActions(for: .touchUpInside)
        try await waitUntil { factoryCount == 1 && editor.currentRichTextSession != nil }
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let session = try XCTUnwrap(editor.currentRichTextSession)
        let snapshot = try await richView.snapshot(expectedSession: session)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: snapshot.payload.source, contentFormat: .automatic),
            "Body after navigation failure"
        )

        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)
        XCTAssertEqual(persistence.savedDrafts.last?.contentFormat, .automatic)
        let didClose = await editor.closeForTesting()
        XCTAssertTrue(didClose)
        XCTAssertTrue(editor.hasTerminatedEditorSessionForTesting)
    }

    func testLazyRichLoadBoundsTwoRecoveryNavigationFailuresWithoutLingeringWork() async throws {
        let note = makeFloorpTestNote(
            id: "bounded-late-rich-load",
            title: "Bounded navigation",
            content: "Visible bounded fallback",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                richEditor.restartWithStalledInitialNavigationForTesting(
                    attempts: 1,
                    timeoutNanoseconds: 40_000_000
                )
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: FloorpRichTextTestPersistence()
        )
        editor.loadViewIfNeeded()
        let enable = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.EnableRichText"
        ) as? UIButton)
        XCTAssertTrue(createdEditors.isEmpty)

        enable.sendActions(for: .touchUpInside)
        try await waitUntil {
            createdEditors.count == 2 && editor.currentRichTextSession == nil
        }

        XCTAssertEqual(createdEditors.count, 2)
        for richEditor in createdEditors {
            XCTAssertFalse(richEditor.isPageReadyForTesting)
            XCTAssertFalse(richEditor.hasPendingInitialNavigationForTesting)
            XCTAssertEqual(richEditor.pendingJavaScriptRequestCountForTesting, 0)
            XCTAssertTrue(richEditor.isHidden)
            XCTAssertTrue(richEditor.isInvalidatedForTesting)
        }
        XCTAssertNil(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ))
        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertFalse(textView.isHidden)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.text, "Visible bounded fallback")
    }

    func testOverflowAndDeletedNoteRecoveryKeepsNewestEnvelopeForReeditAndCopy() async throws {
        let originalSource = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let note = makeFloorpTestNote(
            id: "deleted-rich-note",
            title: "Recovery",
            content: originalSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(
            blocksFirstPreflight: true,
            firstPreflightError: FloorpNotesStoreError.noteNotFound(note.id)
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: persistence
        )
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        var newestSource = originalSource

        for revision in 1...130 {
            newestSource = """
            {"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Value \(revision)"}]}]}
            """
            editor.richTextEditor(
                richView,
                received: FloorpRichTextUpdateEnvelope(
                    session: try initialSession.advancing(to: revision),
                    payload: FloorpRichTextEditorUpdate(source: newestSource)
                )
            )
        }

        try await waitUntil { persistence.didStartFirstPreflight }
        persistence.resumeFirstPreflight()
        try await waitUntil {
            guard let current = editor.currentRichTextSession else { return false }
            return current.documentID != initialSession.documentID
        }

        let recovery = try XCTUnwrap(editor.currentRichTextRecoveryDraft)
        XCTAssertEqual(recovery.source, newestSource)
        XCTAssertTrue(richView.isHidden)
        XCTAssertTrue(richView.isInvalidatedForTesting)
        XCTAssertEqual(createdEditors.count, 2)
        let replacementView = try XCTUnwrap(createdEditors.last)
        XCTAssertFalse(replacementView.isHidden)
        let replacementSession = try XCTUnwrap(editor.currentRichTextSession)
        let reeditable = try await replacementView.snapshot(expectedSession: replacementSession)
        XCTAssertEqual(reeditable.payload.source, newestSource)
        XCTAssertTrue(reeditable.payload.isDirty)

        let didSaveCopy = await editor.saveRecoveryDraftAsCopyForTesting()
        XCTAssertTrue(didSaveCopy)
        XCTAssertEqual(persistence.preflightCopyDrafts.last?.content, newestSource)
        XCTAssertEqual(persistence.savedCopyDrafts.last?.content, newestSource)
        XCTAssertNil(editor.currentRichTextRecoveryDraft)
        XCTAssertEqual(editor.currentRichTextSession?.noteID, FloorpNoteID("recovery-copy"))
    }

    func testFailedRichSaveAsCopyDoesNotAdvanceWebRevision() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let note = makeFloorpTestNote(
            id: "copy-revision",
            title: "Copy",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(
            copyError: CocoaError(.fileWriteUnknown)
        )
        let editor = makeEditor(note: note, isPersisted: true, persistence: persistence)
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: initialSession)
        _ = try await richView.evaluateJavaScriptForTesting(
            """
            const paragraph = document.querySelector('#editor p');
            paragraph.textContent = 'After';
            paragraph.dispatchEvent(new InputEvent('input', { bubbles: true }));
            true;
            """
        )
        try await waitUntil { editor.currentRichTextSession?.revision == 1 }

        let didSaveCopy = await editor.saveRecoveryDraftAsCopyForTesting()
        XCTAssertFalse(didSaveCopy)
        let nativeSession = try XCTUnwrap(editor.currentRichTextSession)
        let webSnapshot = try await richView.snapshot(expectedSession: nativeSession)

        XCTAssertEqual(webSnapshot.session, nativeSession)
        XCTAssertEqual(
            FloorpNoteContent.plainText(
                from: webSnapshot.payload.source,
                contentFormat: .automatic
            ),
            "After"
        )
    }

    func testFailedCopyPrefersAndRetainsRecoveryOverDivergentDirtyWebSource() async throws {
        let originalSource = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let recoverySource = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Recovery"}]}
        ]}
        """
        let note = makeFloorpTestNote(
            id: "copy-recovery-precedence",
            title: "Recovery",
            content: originalSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        let persistence = FloorpRichTextTestPersistence(
            firstPreflightError: FloorpNotesStoreError.noteNotFound(note.id),
            copyError: CocoaError(.fileWriteUnknown)
        )
        var createdEditors = [FloorpRichTextWebEditorView]()
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                let richEditor = FloorpRichTextWebEditorView()
                createdEditors.append(richEditor)
                return richEditor
            },
            persistence: persistence
        )
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        _ = try await richView.snapshot(expectedSession: initialSession)
        editor.richTextEditor(
            richView,
            received: FloorpRichTextUpdateEnvelope(
                session: try initialSession.advancing(to: 1),
                payload: FloorpRichTextEditorUpdate(source: recoverySource)
            )
        )
        try await waitUntil {
            guard let current = editor.currentRichTextSession else { return false }
            return current.documentID != initialSession.documentID
        }
        let recoverySession = try XCTUnwrap(editor.currentRichTextSession)
        XCTAssertTrue(richView.isInvalidatedForTesting)
        XCTAssertEqual(createdEditors.count, 2)
        let replacementView = try XCTUnwrap(createdEditors.last)
        _ = try await replacementView.snapshot(expectedSession: recoverySession)
        _ = try await replacementView.evaluateJavaScriptForTesting(
            """
            document.querySelector('#editor p').textContent = 'Divergent Web';
            true;
            """
        )

        let didCopy = await editor.saveRecoveryDraftAsCopyForTesting()

        XCTAssertFalse(didCopy)
        XCTAssertEqual(persistence.preflightCopyDrafts.last?.content, recoverySource)
        XCTAssertEqual(persistence.savedCopyDrafts.last?.content, recoverySource)
        XCTAssertEqual(editor.currentRichTextRecoveryDraft?.source, recoverySource)
    }

    func testUnknownLexicalContentRemainsReadOnlyAndSourceIsNotRewritten() async throws {
        let source = """
          { "root" : { "children" : [
            {"type":"futureWidget","opaque":{"keep":"exactly"}}
          ] } }
        """
        let note = makeFloorpTestNote(
            id: "unknown-lexical",
            title: "Preserve",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var savedDrafts = [FloorpNote]()
        var factoryCount = 0
        let editor = makeEditor(
            note: note,
            isPersisted: true,
            richTextEditorFactory: {
                factoryCount += 1
                return FloorpRichTextWebEditorView()
            }
        ) {
            savedDrafts.append($0)
            return $0
        }
        editor.loadViewIfNeeded()

        let textView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Body"
        ) as? UITextView)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(factoryCount, 0)
        let richHost = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Host"
        ))
        XCTAssertTrue(richHost.isHidden)

        let title = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Title"
        ) as? UITextField)
        title.text = "Renamed"
        title.sendActions(for: .editingChanged)
        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)
        XCTAssertEqual(savedDrafts.last?.content, source)
        XCTAssertEqual(savedDrafts.last?.contentFormat, .automatic)
    }

    func testKnownLexicalTitleOnlyEditPreservesOriginalSourceUntilBodyChanges() async throws {
        let source = """
          { "root" : { "type" : "root", "version" : 1, "children" : [
            {"type":"paragraph","version":1,"children":[
              {"type":"text","text":"keep rich","format":9,"version":1}
            ]}
          ] } }
        """
        let note = makeFloorpTestNote(
            id: "known-lexical",
            title: "Before",
            content: source,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var savedDrafts = [FloorpNote]()
        let editor = makeEditor(note: note, isPersisted: true) {
            savedDrafts.append($0)
            return $0
        }
        editor.loadViewIfNeeded()
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        let title = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.Editor.Title"
        ) as? UITextField)

        title.text = "After"
        title.sendActions(for: .editingChanged)
        let didSave = await editor.saveForExplicitRequest()

        XCTAssertTrue(didSave)
        XCTAssertEqual(savedDrafts.last?.title, "After")
        XCTAssertEqual(savedDrafts.last?.content, source)
        XCTAssertEqual(savedDrafts.last?.contentFormat, .automatic)
        XCTAssertEqual(editor.currentRichTextSession, initialSession)
    }

    func testTitleOnlyProcessRecoveryPreservesLexicalAndTipTapSourceBytes() async throws {
        let fixtures = [
            """
              { "root" : { "type" : "root", "version" : 1, "children" : [
                {"type":"paragraph","version":1,"children":[
                  {"type":"text","text":"Lexical body","format":9,"version":1}
                ]}
              ] } }
            """,
            """
              { "type" : "doc", "content" : [
                {"type":"paragraph","content":[{"type":"text","text":"TipTap body"}]}
              ] }
            """,
        ]

        for (index, source) in fixtures.enumerated() {
            let note = makeFloorpTestNote(
                id: "title-recovery-\(index)",
                title: "Before",
                content: source,
                createdAt: 1,
                updatedAt: 1,
                contentFormat: .automatic
            )
            let persistence = FloorpRichTextTestPersistence()
            var createdEditors = [FloorpRichTextWebEditorView]()
            let editor = makeEditor(
                note: note,
                isPersisted: true,
                richTextEditorFactory: {
                    let richEditor = FloorpRichTextWebEditorView()
                    createdEditors.append(richEditor)
                    return richEditor
                },
                persistence: persistence
            )
            editor.loadViewIfNeeded()
            let firstEditor = try XCTUnwrap(createdEditors.first)
            _ = try await firstEditor.snapshot(
                expectedSession: try XCTUnwrap(editor.currentRichTextSession)
            )
            let title = try XCTUnwrap(editor.view.floorpNotesDescendant(
                withIdentifier: "Floorp.Notes.Editor.Title"
            ) as? UITextField)
            title.text = "After"
            title.sendActions(for: .editingChanged)

            firstEditor.simulateWebContentProcessTerminationForTesting()
            try await waitUntil {
                createdEditors.count == 2
                    && editor.currentRichTextSession?.generation == 1
            }
            let replacement = try XCTUnwrap(createdEditors.last)
            let replacementSnapshot = try await replacement.snapshot(
                expectedSession: try XCTUnwrap(editor.currentRichTextSession)
            )
            XCTAssertFalse(replacementSnapshot.payload.isDirty, source)

            let didSave = await editor.saveForExplicitRequest()
            XCTAssertTrue(didSave, source)
            XCTAssertEqual(persistence.savedDrafts.last?.title, "After", source)
            XCTAssertEqual(persistence.savedDrafts.last?.content, source, source)
            XCTAssertTrue(firstEditor.isInvalidatedForTesting, source)
            editor.terminateEditorSessionForTesting()
        }
    }

    func testBridgeQueuesConcurrentRichUpdatesAndReflectsAccessibleState() async throws {
        let originalSource = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Original"}]}
        ]}
        """
        let note = makeFloorpTestNote(
            id: "bridge-note",
            title: "Bridge",
            content: originalSource,
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .automatic
        )
        var savedDrafts = [FloorpNote]()
        let editor = makeEditor(note: note, isPersisted: true) {
            savedDrafts.append($0)
            return $0
        }
        editor.loadViewIfNeeded()
        let richView = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Container"
        ) as? FloorpRichTextWebEditorView)
        let initialSession = try XCTUnwrap(editor.currentRichTextSession)
        let firstSession = try initialSession.advancing(to: 1)
        let secondSession = try initialSession.advancing(to: 2)
        let firstSource = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":2,"textAlign":"center"},"content":[
            {"type":"text","text":"Heading","marks":[{"type":"bold"}]}
          ]}
        ]}
        """
        let imageSource = "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let secondSource = """
        {"type":"doc","content":[
          {"type":"orderedList","content":[
            {"type":"listItem","content":[
              {"type":"paragraph","attrs":{"textAlign":"right"},"content":[
                {"type":"text","text":"Final","marks":[{"type":"underline"}]}
              ]}
            ]}
          ]},
          {"type":"image","attrs":{"src":"\(imageSource)","alt":"pixel","width":40}}
        ]}
        """

        editor.richTextEditor(
            richView,
            received: FloorpRichTextUpdateEnvelope(
                session: firstSession,
                payload: FloorpRichTextEditorUpdate(source: firstSource)
            )
        )
        editor.richTextEditor(
            richView,
            received: FloorpRichTextUpdateEnvelope(
                session: secondSession,
                payload: FloorpRichTextEditorUpdate(source: secondSource)
            )
        )

        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while editor.currentRichTextSession?.revision != 2,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let currentSession = try XCTUnwrap(editor.currentRichTextSession)

        // Direct delegate delivery above models messages that the web editor
        // has already emitted. Keep the test double's DOM/session in the same
        // accepted state before exercising the authoritative save flush.
        richView.load(
            document: try FloorpRichTextCodec.decode(secondSource),
            session: currentSession,
            isDirty: false
        )
        _ = try await richView.snapshot(expectedSession: currentSession)
        // Let the state emitted by floorpLoad arrive before injecting the
        // newer synthetic selection/formatting state under test.
        try await Task.sleep(nanoseconds: 50_000_000)
        editor.richTextEditor(
            richView,
            received: FloorpRichTextStateEnvelope(
                session: currentSession,
                payload: FloorpRichTextEditorState(
                    isReady: true,
                    canUndo: true,
                    canRedo: false,
                    activeHeadingLevel: 2,
                    activeMarks: [.bold, .underline],
                    activeListKind: .ordered,
                    alignment: .right
                )
            )
        )
        let undo = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Undo"
        ) as? UIButton)
        let bold = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.Bold"
        ) as? UIButton)
        let ordered = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.OrderedList"
        ) as? UIButton)
        let right = try XCTUnwrap(editor.view.floorpNotesDescendant(
            withIdentifier: "Floorp.Notes.RichEditor.AlignRight"
        ) as? UIButton)
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(bold.accessibilityTraits.contains(.selected))
        XCTAssertTrue(ordered.accessibilityTraits.contains(.selected))
        XCTAssertTrue(right.accessibilityTraits.contains(.selected))

        let didSave = await editor.saveForExplicitRequest()
        XCTAssertTrue(didSave)
        XCTAssertEqual(savedDrafts.last?.content, secondSource)
        XCTAssertEqual(savedDrafts.last?.contentFormat, .automatic)
    }

    private func solidPNGDataURL(width: Int, height: Int) throws -> String {
        let data = try solidPNGData(width: width, height: height)
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private func solidPNGData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func oneBitGrayscalePNGData(width: Int, height: Int) throws -> Data {
        let bytesPerRow = (width + 7) / 8
        let pixels = Data(repeating: 0, count: bytesPerRow * height)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func firstTextMarkTypes(_ source: String) throws -> [String] {
        let document = try FloorpRichTextCodec.decode(source)
        let blocks = try XCTUnwrap(document.root.objectValue?["content"]?.arrayValue)
        let inline = try XCTUnwrap(blocks.first?.objectValue?["content"]?.arrayValue)
        let marks = try XCTUnwrap(inline.first?.objectValue?["marks"]?.arrayValue)
        return marks.compactMap { $0.objectValue?["type"]?.stringValue }
    }

    private func makeEditor(
        note: FloorpNote,
        isPersisted: Bool,
        richTextEditorFactory: @escaping @MainActor () -> FloorpRichTextWebEditorView = {
            FloorpRichTextWebEditorView()
        },
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote
    ) -> FloorpNoteEditorViewController {
        FloorpNoteEditorViewController(
            note: note,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPersisted: isPersisted,
            onSave: onSave,
            richTextEditorFactory: richTextEditorFactory
        )
    }

    private func makeEditor(
        note: FloorpNote,
        isPersisted: Bool,
        richTextEditorFactory: @escaping @MainActor () -> FloorpRichTextWebEditorView = {
            FloorpRichTextWebEditorView()
        },
        persistence: FloorpNotePersistence
    ) -> FloorpNoteEditorViewController {
        FloorpNoteEditorViewController(
            note: note,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPersisted: isPersisted,
            persistence: persistence,
            richTextEditorFactory: richTextEditorFactory
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeDraft() -> FloorpNote {
        makeFloorpTestNote(
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
private final class FloorpRichTextTestPersistence: FloorpNotePersistence {
    private let blocksFirstPreflight: Bool
    private let firstPreflightError: Error?
    private let copyError: Error?
    private let savedNoteID: String?
    private let copyNoteID: String
    private var firstPreflightContinuation: CheckedContinuation<Void, Never>?
    private(set) var didStartFirstPreflight = false
    private(set) var preflightDrafts = [FloorpNote]()
    private(set) var preflightCopyDrafts = [FloorpNote]()
    private(set) var savedDrafts = [FloorpNote]()
    private(set) var savedCopyDrafts = [FloorpNote]()

    init(
        blocksFirstPreflight: Bool = false,
        firstPreflightError: Error? = nil,
        copyError: Error? = nil,
        savedNoteID: String? = nil,
        copyNoteID: String = "recovery-copy"
    ) {
        self.blocksFirstPreflight = blocksFirstPreflight
        self.firstPreflightError = firstPreflightError
        self.copyError = copyError
        self.savedNoteID = savedNoteID
        self.copyNoteID = copyNoteID
    }

    func preflight(_ draft: FloorpNote) async throws {
        preflightDrafts.append(draft)
        if preflightDrafts.count == 1 {
            didStartFirstPreflight = true
            if blocksFirstPreflight {
                await withCheckedContinuation { continuation in
                    firstPreflightContinuation = continuation
                }
            }
            if let firstPreflightError { throw firstPreflightError }
        }
    }

    func preflightCopy(_ draft: FloorpNote) async throws {
        preflightCopyDrafts.append(draft)
    }

    func save(_ draft: FloorpNote) async throws -> FloorpNote {
        savedDrafts.append(draft)
        guard let savedNoteID else { return draft }
        return makeFloorpTestNote(
            id: savedNoteID,
            title: draft.title,
            content: draft.content,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            contentFormat: draft.contentFormat
        )
    }

    func reload() async throws -> FloorpNote? { nil }

    func acceptReloaded(_ note: FloorpNote) {}

    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote {
        savedCopyDrafts.append(draft)
        if let copyError { throw copyError }
        return makeFloorpTestNote(
            id: copyNoteID,
            title: draft.title,
            content: draft.content,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            contentFormat: draft.contentFormat
        )
    }

    func resumeFirstPreflight() {
        firstPreflightContinuation?.resume()
        firstPreflightContinuation = nil
    }
}

@MainActor
final class FloorpRichTextWebEditorViewTests: XCTestCase {
    private let safePNGDataURL = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    func testMarkedHardBreakAndWidthlessImageSurviveExecutableRoundTrip() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"A","marks":[{"type":"bold"}]},
            {"type":"hardBreak","marks":[{"type":"bold"},{"type":"italic"}]},
            {"type":"text","text":"B","marks":[{"type":"bold"}]}
          ]},
          {"type":"image","attrs":{"src":"\(safePNGDataURL)","alt":"pixel"}}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "round-trip")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)

        let snapshot = try await editor.snapshot(expectedSession: session)
        let content = try contentNodes(snapshot.payload.source)
        let paragraph = try XCTUnwrap(content.first)
        let inline = try XCTUnwrap(paragraph["content"] as? [[String: Any]])
        let hardBreak = try XCTUnwrap(inline.first { $0["type"] as? String == "hardBreak" })
        XCTAssertEqual(
            (hardBreak["marks"] as? [[String: Any]])?.compactMap { $0["type"] as? String },
            ["bold", "italic"]
        )
        let image = try XCTUnwrap(content.first { $0["type"] as? String == "image" })
        let imageAttrs = try XCTUnwrap(image["attrs"] as? [String: Any])
        XCTAssertEqual(imageAttrs["alt"] as? String, "pixel")
        XCTAssertNil(imageAttrs["width"])
        XCTAssertFalse(snapshot.payload.isDirty)
    }

    func testOrderedListSigned32BitBoundariesSurviveExecutableRoundTrip() async throws {
        let starts = [Int(Int32.min), Int(Int32.max)]
        let lists = starts.enumerated().map { index, start in
            """
            {"type":"orderedList","attrs":{"start":\(start)},"content":[
              {"type":"listItem","content":[{"type":"paragraph","content":[
                {"type":"text","text":"Boundary \(index)"}
              ]}]}
            ]}
            """
        }
        let source = "{\"type\":\"doc\",\"content\":[" + lists.joined(separator: ",") + "]}"
        let document = try FloorpRichTextCodec.decode(source)
        XCTAssertTrue(document.compatibility.isEditable)
        let session = try makeSession(noteID: "ordered-list-boundaries")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)

        let snapshot = try await editor.snapshot(expectedSession: session)
        let roundTrippedStarts = try contentNodes(snapshot.payload.source).compactMap { node in
            (node["attrs"] as? [String: Any])?["start"] as? NSNumber
        }.map(\.intValue)

        XCTAssertEqual(roundTrippedStarts, starts)
        XCTAssertFalse(snapshot.payload.isDirty)
        XCTAssertEqual(snapshot.session.revision, 0)
    }

    func testUnrelatedEditPreservesExactImageSourceAttribute() async throws {
        let remoteSource = "https://EXAMPLE.com/%7Easset.png?token=%2F"
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Before"}]},
          {"type":"image","attrs":{"src":"\(remoteSource)","alt":"remote"}}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "stable-image-source")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)

        _ = try await editor.evaluateJavaScriptForTesting(
            """
            const paragraph = document.querySelector('#editor p');
            paragraph.firstChild.nodeValue = 'After';
            paragraph.dispatchEvent(new InputEvent('input', { bubbles: true }));
            true;
            """
        )
        let snapshot = try await editor.snapshot(expectedSession: session)
        let image = try XCTUnwrap(
            try contentNodes(snapshot.payload.source).first { $0["type"] as? String == "image" }
        )
        let attributes = try XCTUnwrap(image["attrs"] as? [String: Any])

        XCTAssertEqual(attributes["src"] as? String, remoteSource)
    }

    func testPasteAndDropStayPlainTextOnlyAndNeverCreateImages() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Anchor"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "plain-transfer")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)

        let rawResult = try await editor.evaluateJavaScriptForTesting(
            """
            const body = document.getElementById('editor');
            const text = body.querySelector('p').firstChild;
            const selection = document.getSelection();
            const range = document.createRange();
            range.setStart(text, text.length);
            range.collapse(true);
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));

            const transferEvent = (type, transfer) => {
              const event = new Event(type, { bubbles: true, cancelable: true });
              Object.defineProperty(
                event,
                type === 'paste' ? 'clipboardData' : 'dataTransfer',
                { value: transfer }
              );
              body.dispatchEvent(event);
              return event.defaultPrevented;
            };
            const imagePaste = new DataTransfer();
            imagePaste.setData(
              'text/html',
              `<img src="data:image/png;base64,${'A'.repeat(180000)}">`
            );
            const didBlockDataImage = transferEvent('paste', imagePaste);

            const remoteURL = `https://images.invalid/floorp-drop-${Date.now()}.png`;
            const remoteDrop = new DataTransfer();
            remoteDrop.setData('text/html', `<img src="${remoteURL}">`);
            const didBlockRemoteImage = transferEvent('drop', remoteDrop);

            const imageFilePaste = new DataTransfer();
            imageFilePaste.setData('text/plain', ' must-not-insert');
            imageFilePaste.items.add(new File(['image'], 'unsafe.png', { type: 'image/png' }));
            const didBlockImageFile = transferEvent('paste', imageFilePaste);

            const plainPaste = new DataTransfer();
            plainPaste.setData('text/plain', ' Pasted');
            const didInsertPlainPaste = transferEvent('paste', plainPaste);
            const plainDrop = new DataTransfer();
            plainDrop.setData('text/plain', ' Dropped');
            const didInsertPlainDrop = transferEvent('drop', plainDrop);

            const beforePaste = new InputEvent('beforeinput', {
              bubbles: true,
              cancelable: true,
              inputType: 'insertFromPaste',
              data: '<img src="https://images.invalid/before-input.png">',
            });
            body.dispatchEvent(beforePaste);
            const beforeDrop = new InputEvent('beforeinput', {
              bubbles: true,
              cancelable: true,
              inputType: 'insertFromDrop',
            });
            body.dispatchEvent(beforeDrop);

            ({
              didBlockDataImage,
              didBlockRemoteImage,
              didBlockImageFile,
              didInsertPlainPaste,
              didInsertPlainDrop,
              didBlockBeforePaste: beforePaste.defaultPrevented,
              didBlockBeforeDrop: beforeDrop.defaultPrevented,
              imageCount: body.querySelectorAll('img').length,
              remoteRequestCount: performance.getEntriesByName(remoteURL).length,
              text: body.textContent,
            });
            """
        )
        let result = try XCTUnwrap(rawResult as? [String: Any])

        XCTAssertEqual(result["didBlockDataImage"] as? Bool, true)
        XCTAssertEqual(result["didBlockRemoteImage"] as? Bool, true)
        XCTAssertEqual(result["didBlockImageFile"] as? Bool, true)
        XCTAssertEqual(result["didInsertPlainPaste"] as? Bool, true)
        XCTAssertEqual(result["didInsertPlainDrop"] as? Bool, true)
        XCTAssertEqual(result["didBlockBeforePaste"] as? Bool, true)
        XCTAssertEqual(result["didBlockBeforeDrop"] as? Bool, true)
        XCTAssertEqual(result["imageCount"] as? Int, 0)
        XCTAssertEqual(result["remoteRequestCount"] as? Int, 0)
        let transferredText = try XCTUnwrap(result["text"] as? String)
        XCTAssertEqual(
            transferredText.split(separator: " ").sorted(),
            ["Anchor", "Dropped", "Pasted"]
        )

        let snapshot = try await editor.snapshot(expectedSession: session)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: snapshot.payload.source, contentFormat: .automatic),
            transferredText
        )
    }

    func testCommandQueuedBeforeEditorLoadExecutesAfterReady() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Ready"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "ready-command")
        let editor = FloorpRichTextWebEditorView()
        let command = try FloorpRichTextCommandPlanner.plan(
            .insertImage(FloorpRichTextImage(source: safePNGDataURL, alt: "queued")),
            for: document,
            session: session
        )

        let commandTask = Task { @MainActor in
            await send(command, to: editor)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        editor.load(document: document, session: session, isDirty: false)

        let didExecute = await commandTask.value
        XCTAssertTrue(didExecute)
        let snapshot = try await editor.snapshot(expectedSession: session)
        let images = try contentNodes(snapshot.payload.source).filter {
            $0["type"] as? String == "image"
        }
        XCTAssertEqual(
            images.compactMap { ($0["attrs"] as? [String: Any])?["alt"] as? String },
            ["queued"]
        )
    }

    func testCommandAppliesToLatestDOMWhenNativeRevisionLagsAndRejectsFutureRevision() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "lagging-native")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        _ = try await editor.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor p').firstChild;
            text.nodeValue = 'Latest DOM';
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            document.getElementById('editor').dispatchEvent(new InputEvent('input', { bubbles: true }));
            true;
            """
        )
        let laggingCommand = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.bold),
            for: document,
            session: session
        )

        let laggingResult = await sendResult(laggingCommand, to: editor)
        let update = try laggingResult.get()
        XCTAssertEqual(update.session.revision, 2)
        XCTAssertEqual(
            FloorpNoteContent.plainText(from: update.payload.source, contentFormat: .automatic),
            "Latest DOM"
        )
        let updatedDocument = try FloorpRichTextCodec.decode(update.payload.source)
        let futureSession = try update.session.advancing(to: update.session.revision + 1)
        let futureCommand = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.italic),
            for: updatedDocument,
            session: futureSession
        )

        let didSendFutureCommand = await send(futureCommand, to: editor)
        XCTAssertFalse(didSendFutureCommand)
        let snapshot = try await editor.snapshot(expectedSession: update.session)
        XCTAssertEqual(snapshot.session.revision, update.session.revision)
    }

    func testCollapsedCaretAtSecondParagraphStartSurvivesConsecutiveBoldItalic() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"First"}]},
          {"type":"paragraph","content":[{"type":"text","text":"Second"}]}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "paragraph-boundary-caret")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        _ = try await editor.evaluateJavaScriptForTesting(
            """
            const text = document.querySelectorAll('#editor p')[1].firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.collapse(true);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let bold = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.bold),
            for: document,
            session: session
        )
        let boldUpdate = try await sendResult(bold, to: editor).get()
        let italic = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.italic),
            for: try FloorpRichTextCodec.decode(boldUpdate.payload.source),
            session: boldUpdate.session
        )
        let italicUpdate = try await sendResult(italic, to: editor).get()
        _ = try await editor.evaluateJavaScriptForTesting(
            """
            document.execCommand('insertText', false, 'X');
            document.getElementById('editor').dispatchEvent(new InputEvent('input', { bubbles: true }));
            true;
            """
        )

        let snapshot = try await editor.snapshot(expectedSession: italicUpdate.session)
        let paragraphs = try contentNodes(snapshot.payload.source)
        let firstText = try XCTUnwrap((paragraphs[0]["content"] as? [[String: Any]])?.first)
        let secondText = try XCTUnwrap((paragraphs[1]["content"] as? [[String: Any]])?.first)
        let firstMarks = (firstText["marks"] as? [[String: Any]]) ?? []
        let secondMarks = (secondText["marks"] as? [[String: Any]]) ?? []

        XCTAssertEqual(firstText["text"] as? String, "First")
        XCTAssertTrue(firstMarks.isEmpty)
        XCTAssertEqual(secondText["text"] as? String, "X")
        XCTAssertEqual(
            Set(secondMarks.compactMap { $0["type"] as? String }),
            Set(["bold", "italic"])
        )
    }

    func testStalledJavaScriptRequestsTimeOutAndReleaseTheirTokens() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Timeout"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "request-timeout")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        editor.setJavaScriptRequestTimeoutForTesting(40_000_000)
        _ = try await editor.evaluateJavaScriptForTesting(
            "window.floorpOriginalApplyCommand = window.floorpApplyCommand;"
                + "window.floorpApplyCommand = () => new Promise(() => {}); true;"
        )
        let command = try FloorpRichTextCommandPlanner.plan(
            .insertImage(FloorpRichTextImage(source: safePNGDataURL, alt: "timeout")),
            for: document,
            session: session
        )

        let didSend = await send(command, to: editor)
        XCTAssertFalse(didSend)
        XCTAssertEqual(editor.pendingJavaScriptRequestCountForTesting, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(editor.pendingJavaScriptRequestCountForTesting, 0)

        _ = try await editor.evaluateJavaScriptForTesting(
            "window.floorpApplyCommand = window.floorpOriginalApplyCommand;"
                + "window.floorpOriginalSetEditable = window.floorpSetEditable;"
                + "window.floorpSetEditable = () => new Promise(() => {}); true;"
        )
        do {
            try await editor.setEditableAndWait(false)
            XCTFail("Expected setEditableAndWait to time out")
        } catch {}
        XCTAssertEqual(editor.pendingJavaScriptRequestCountForTesting, 0)

        _ = try await editor.evaluateJavaScriptForTesting(
            "window.floorpSetEditable = window.floorpOriginalSetEditable;"
                + "window.floorpOriginalSnapshot = window.floorpSnapshot;"
                + "window.floorpSnapshot = () => new Promise(() => {}); true;"
        )
        do {
            _ = try await editor.snapshot(expectedSession: session)
            XCTFail("Expected snapshot to time out")
        } catch {}
        XCTAssertEqual(editor.pendingJavaScriptRequestCountForTesting, 0)
    }

    func testWebContentProcessTerminationFailsPendingCommandImmediately() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Terminate"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "process-termination")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        editor.setJavaScriptRequestTimeoutForTesting(5_000_000_000)
        _ = try await editor.evaluateJavaScriptForTesting(
            "window.floorpApplyCommand = () => new Promise(() => {}); true;"
        )
        let command = try FloorpRichTextCommandPlanner.plan(
            .insertImage(FloorpRichTextImage(source: safePNGDataURL, alt: "terminated")),
            for: document,
            session: session
        )
        let sendTask = Task { @MainActor in await send(command, to: editor) }
        try await waitUntil { editor.pendingJavaScriptRequestCountForTesting == 1 }

        editor.simulateWebContentProcessTerminationForTesting()

        let didSend = await sendTask.value
        XCTAssertFalse(didSend)
        XCTAssertEqual(editor.pendingJavaScriptRequestCountForTesting, 0)
    }

    func testImageInsertionTargetsCursorAndFailureLeavesExistingImagesUntouched() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Anchor"}]},
          {"type":"image","attrs":{"src":"\(safePNGDataURL)","alt":"one","title":"keep","width":200}},
          {"type":"image","attrs":{"src":"\(safePNGDataURL)","alt":"two"}}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "image-insert")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        _ = try await editor.evaluateJavaScriptForTesting(
            """
            const editor = document.getElementById('editor');
            const range = document.createRange();
            range.setStart(editor, 1);
            range.collapse(true);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let command = try FloorpRichTextCommandPlanner.plan(
            .insertImage(
                FloorpRichTextImage(
                    source: safePNGDataURL,
                    alt: "new",
                    title: "",
                    width: 40
                )
            ),
            for: document,
            session: session
        )

        let didInsert = await send(command, to: editor)
        XCTAssertTrue(didInsert)
        let inserted = try await editor.snapshot(expectedSession: session)
        let images = try contentNodes(inserted.payload.source).filter {
            $0["type"] as? String == "image"
        }
        XCTAssertEqual(images.count, 3)
        let attrs = try images.map { try XCTUnwrap($0["attrs"] as? [String: Any]) }
        XCTAssertEqual(attrs.compactMap { $0["alt"] as? String }, ["new", "one", "two"])
        XCTAssertEqual(attrs[0]["title"] as? String, "")
        XCTAssertEqual(attrs[0]["width"] as? Int, 40)
        XCTAssertEqual(attrs[1]["title"] as? String, "keep")
        XCTAssertEqual(attrs[1]["width"] as? Int, 200)
        XCTAssertNil(attrs[2]["width"])

        let failureSession = try makeSession(noteID: "image-failure")
        let failureEditor = FloorpRichTextWebEditorView()
        failureEditor.load(document: document, session: failureSession, isDirty: false)
        _ = try await failureEditor.snapshot(expectedSession: failureSession)
        _ = try await failureEditor.evaluateJavaScriptForTesting(
            """
            const range = document.createRange();
            range.setStart(document.body, 0);
            range.collapse(true);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let failureCommand = try FloorpRichTextCommandPlanner.plan(
            .insertImage(FloorpRichTextImage(source: safePNGDataURL, alt: "must-not-appear", width: 40)),
            for: document,
            session: failureSession
        )
        let didInsertWithoutSelection = await send(failureCommand, to: failureEditor)
        XCTAssertFalse(didInsertWithoutSelection)
        let unchanged = try await failureEditor.snapshot(expectedSession: failureSession)
        let unchangedImages = try contentNodes(unchanged.payload.source).filter {
            $0["type"] as? String == "image"
        }
        XCTAssertEqual(
            unchangedImages.compactMap { ($0["attrs"] as? [String: Any])?["alt"] as? String },
            ["one", "two"]
        )
        XCTAssertFalse(unchanged.payload.isDirty)
    }

    func testTogglingActiveHeadingReturnsItToParagraph() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Heading"}]}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "heading-toggle")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        _ = try await editor.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor h2').firstChild;
            const range = document.createRange();
            range.setStart(text, 1);
            range.collapse(true);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            true;
            """
        )
        let command = try FloorpRichTextCommandPlanner.plan(
            .toggleHeading(level: 2),
            for: document,
            session: session
        )

        let didToggle = await send(command, to: editor)
        XCTAssertTrue(didToggle)
        let snapshot = try await editor.snapshot(expectedSession: session)
        XCTAssertEqual(try contentNodes(snapshot.payload.source).first?["type"] as? String, "paragraph")
    }

    func testExclusiveMarkRemovalStillEmitsUpdateWhenRequestedMarkFails() async throws {
        let source = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"Marked","marks":[{"type":"strike"}]}
          ]}
        ]}
        """
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "exclusive-mark-partial")
        let editor = FloorpRichTextWebEditorView()
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)
        let wasStrikeActive = try await editor.evaluateJavaScriptForTesting(
            """
            const text = document.querySelector('#editor s').firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, text.length);
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            window.floorpOriginalExecCommand = document.execCommand.bind(document);
            document.execCommand = (command, showUI, value) => command === 'underline'
              ? false
              : window.floorpOriginalExecCommand(command, showUI, value);
            document.queryCommandState('strikeThrough');
            """
        ) as? Bool
        XCTAssertEqual(wasStrikeActive, true)
        let command = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.underline),
            for: document,
            session: session
        )

        let didSend = await send(command, to: editor)
        XCTAssertTrue(didSend)
        let snapshot = try await editor.snapshot(expectedSession: session)
        let paragraph = try XCTUnwrap(try contentNodes(snapshot.payload.source).first)
        let text = try XCTUnwrap((paragraph["content"] as? [[String: Any]])?.first)
        let markTypes = (text["marks"] as? [[String: Any]])?.compactMap { $0["type"] as? String }

        XCTAssertEqual(markTypes ?? [], [])
        XCTAssertTrue(snapshot.payload.isDirty)
        XCTAssertEqual(snapshot.session.revision, 1)
    }

    func testLocalizedAccessiblePageAcceptsOnlyItsOwnedNavigationAndMainFrameBridge() async throws {
        let source = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Bridge"}]}]}"#
        let document = try FloorpRichTextCodec.decode(source)
        let session = try makeSession(noteID: "navigation")
        let editor = FloorpRichTextWebEditorView()
        let delegate = FloorpRichTextWebEditorDelegateSpy()
        editor.delegate = delegate
        editor.load(document: document, session: session, isDirty: false)
        _ = try await editor.snapshot(expectedSession: session)

        let accessibilityLabel = try await editor.evaluateJavaScriptForTesting(
            "document.getElementById('editor').getAttribute('aria-label')"
        ) as? String
        let placeholder = try await editor.evaluateJavaScriptForTesting(
            "document.getElementById('editor').dataset.placeholder"
        ) as? String
        let origin = try await editor.evaluateJavaScriptForTesting("window.location.origin") as? String
        XCTAssertEqual(accessibilityLabel, FloorpStrings.Notes.contentAccessibilityLabel)
        XCTAssertEqual(placeholder, FloorpStrings.Notes.contentPlaceholder)
        XCTAssertEqual(origin, "null")
        let viewport = try await editor.evaluateJavaScriptForTesting(
            "document.querySelector('meta[name=viewport]').content"
        ) as? String
        XCTAssertFalse(viewport?.contains("maximum-scale") == true)
        XCTAssertFalse(viewport?.contains("user-scalable") == true)

        _ = try await editor.evaluateJavaScriptForTesting(
            "document.getElementById('editor').dispatchEvent(new InputEvent('input', { bubbles: true })); true;"
        )
        try await waitUntil { !delegate.updates.isEmpty }
        XCTAssertEqual(delegate.updates.last?.session.noteID, session.noteID)

        let acceptedUpdateCount = delegate.updates.count
        let subframePosted = try await editor.evaluateJavaScriptForTesting(
            """
            const frame = document.createElement('iframe');
            document.body.appendChild(frame);
            const bridge = frame.contentWindow.webkit?.messageHandlers?.floorpRichTextUpdate;
            if (bridge) {
              bridge.postMessage({
                schemaVersion: 1,
                session: {
                  noteID: 'navigation',
                  documentID: '\(session.documentID)',
                  generation: 0,
                  revision: 2
                },
                payload: {
                  source: '{"type":"doc","content":[{"type":"paragraph"}]}',
                  isDirty: true
                }
              });
            }
            Boolean(bridge);
            """
        ) as? Bool
        XCTAssertEqual(subframePosted, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(delegate.updates.count, acceptedUpdateCount)

        _ = try? await editor.evaluateJavaScriptForTesting("window.location.href = 'about:blank'; true;")
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterRejectedNavigation = try await editor.snapshot(expectedSession: session)
        XCTAssertEqual(
            FloorpNoteContent.plainText(
                from: afterRejectedNavigation.payload.source,
                contentFormat: .automatic
            ),
            "Bridge"
        )
    }

    private func makeSession(noteID: String) throws -> FloorpRichTextEditorSessionCursor {
        try FloorpRichTextEditorSessionCursor(
            noteID: FloorpNoteID(noteID),
            documentID: UUID().uuidString,
            generation: 0,
            revision: 0
        )
    }

    private func send(
        _ command: FloorpRichTextCommandEnvelope,
        to editor: FloorpRichTextWebEditorView
    ) async -> Bool {
        guard case .success = await sendResult(command, to: editor) else { return false }
        return true
    }

    private func sendResult(
        _ command: FloorpRichTextCommandEnvelope,
        to editor: FloorpRichTextWebEditorView
    ) async -> Result<FloorpRichTextUpdateEnvelope, Error> {
        await withCheckedContinuation { continuation in
            editor.send(command, requestID: UUID().uuidString) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func contentNodes(_ source: String) throws -> [[String: Any]] {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(object["content"] as? [[String: Any]])
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class FloorpRichTextWebEditorDelegateSpy: FloorpRichTextWebEditorDelegate {
    private(set) var updates = [FloorpRichTextUpdateEnvelope]()
    private(set) var states = [FloorpRichTextStateEnvelope]()

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received update: FloorpRichTextUpdateEnvelope
    ) {
        updates.append(update)
    }

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received state: FloorpRichTextStateEnvelope
    ) {
        states.append(state)
    }
}

private extension UIView {
    func floorpNotesDescendant(withIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.floorpNotesDescendant(withIdentifier: identifier) {
                return match
            }
        }
        return nil
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
        XCTAssertEqual(created.id, FloorpNoteID("persisted-id"))

        draft.title = "Updated"
        draft.content = "New body"
        let updated = try await session.save(draft)
        let restartedStore = FloorpNotesStore(fileURL: location.archive)
        let notes = try await restartedStore.loadNotes()

        XCTAssertEqual(updated.id, created.id)
        XCTAssertGreaterThan(updated.updatedAt, created.updatedAt)
        XCTAssertEqual(notes, [updated])
    }

    func testCreationCallbackReportsInitialCreateAndSaveAsCopyOnly() async throws {
        let location = makeTemporaryArchiveLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = FloorpNotesStore(fileURL: location.archive)
        var reportedIDs = [FloorpNoteID]()
        let session = FloorpNotePersistenceSession(
            notesStore: store,
            persistedNote: nil,
            onCreatedNote: { reportedIDs.append($0.id) }
        )
        var draft = makeDraft(title: "First", content: "Body")

        let created = try await session.save(draft)
        draft.title = "Updated"
        let updated = try await session.save(draft)
        draft.title = "Copy"
        let copy = try await session.saveAsCopy(draft)

        XCTAssertEqual(updated.id, created.id)
        XCTAssertNotEqual(copy.id, created.id)
        XCTAssertEqual(reportedIDs, [created.id, copy.id])
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

        XCTAssertEqual(saved.id, FloorpNoteID("persisted-id"))
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
        makeFloorpTestNote(
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
            makeFloorpTestNote(
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
            operations.append("copy:\(draft.id.rawValue)")
            await withCheckedContinuation { continuation in
                copyContinuation = continuation
            }
            return makeFloorpTestNote(
                id: "copy",
                title: draft.title,
                content: draft.content,
                createdAt: 10,
                updatedAt: 10,
                contentFormat: draft.contentFormat
            )
        }
        persistence.saveHandler = { draft in
            operations.append("save:\(draft.id.rawValue)")
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
        XCTAssertEqual(coordinator.draft.id, FloorpNoteID("copy"))
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
        makeFloorpTestNote(
            id: id,
            title: title,
            content: "",
            createdAt: 1,
            updatedAt: updatedAt,
            contentFormat: .plainText
        )
    }

    // MARK: - Deterministic autosave scheduling (issue #21)

    /// Waits without fixed sub-second sleeps until `condition` becomes true.
    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    func testAutosaveFiresAfterScheduledDelayWithInjectedSleep() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        var fired = false
        coordinator.onAutosave = { fired = true }

        var sleepContinuation: CheckedContinuation<Void, Never>?
        var recordedDelay: UInt64?
        coordinator.scheduleAutosave(delayNanoseconds: 400_000_000) { delay in
            recordedDelay = delay
            await withCheckedContinuation { sleepContinuation = $0 }
        }
        await waitUntil { sleepContinuation != nil }
        sleepContinuation?.resume()
        await waitUntil { fired }

        XCTAssertEqual(recordedDelay, 400_000_000)
        XCTAssertTrue(fired)
    }

    func testReschedulingAutosaveCancelsThePriorPendingFire() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        var fireCount = 0
        coordinator.onAutosave = { fireCount += 1 }

        var firstSleep: CheckedContinuation<Void, Never>?
        var secondSleep: CheckedContinuation<Void, Never>?
        coordinator.scheduleAutosave(delayNanoseconds: 1) { _ in
            await withCheckedContinuation { firstSleep = $0 }
        }
        await waitUntil { firstSleep != nil }
        coordinator.scheduleAutosave(delayNanoseconds: 2) { _ in
            await withCheckedContinuation { secondSleep = $0 }
        }
        await waitUntil { secondSleep != nil }

        // The first schedule was cancelled by the second; resuming its sleep
        // must not fire the autosave callback.
        firstSleep?.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(fireCount, 0)

        secondSleep?.resume()
        await waitUntil { fireCount == 1 }
        XCTAssertEqual(fireCount, 1)
    }

    func testCancellingAutosavePreventsPendingFire() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        var fired = false
        coordinator.onAutosave = { fired = true }

        var sleepContinuation: CheckedContinuation<Void, Never>?
        coordinator.scheduleAutosave(delayNanoseconds: 1) { _ in
            await withCheckedContinuation { sleepContinuation = $0 }
        }
        await waitUntil { sleepContinuation != nil }
        coordinator.cancelAutosave()
        sleepContinuation?.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(fired)
    }

    func testAutosaveCallbackSavesTheDirtyDraft() async {
        let original = makeNote(id: "note", title: "Original", updatedAt: 1)
        let persistence = MockFloorpNotePersistence()
        var savedDrafts = [FloorpNote]()
        persistence.saveHandler = { draft in
            savedDrafts.append(draft)
            var saved = draft
            saved.updatedAt += 1
            return saved
        }
        let coordinator = FloorpNoteSaveCoordinator(
            draft: original,
            isPersisted: true,
            persistence: persistence
        )
        coordinator.onAutosave = {
            _ = await coordinator.saveLatest()
        }
        coordinator.updateTitle("Edited")

        var sleepContinuation: CheckedContinuation<Void, Never>?
        coordinator.scheduleAutosave(delayNanoseconds: 1) { _ in
            await withCheckedContinuation { sleepContinuation = $0 }
        }
        await waitUntil { sleepContinuation != nil }
        sleepContinuation?.resume()
        await waitUntil { !savedDrafts.isEmpty }

        XCTAssertEqual(savedDrafts.last?.title, "Edited")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
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
final class FloorpBrowserChromeLayoutTests: XCTestCase {
    func testDefaultGuidesPreserveOriginalFullWidthAndSafeAreaAnchors() {
        let parentView = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let headerView = UIView()
        let bottomContainer = BaseAlphaStackView()
        let overKeyboardContainer = BaseAlphaStackView()
        let bottomContentStackView = BaseAlphaStackView()
        let navigationToolbarContainer = UIView()
        [headerView, bottomContainer, overKeyboardContainer, bottomContentStackView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            parentView.addSubview($0)
        }
        let subject = BrowserViewControllerLayoutManager(
            parentView: parentView,
            headerView: headerView,
            bottomContainer: bottomContainer,
            overKeyboardContainer: overKeyboardContainer,
            bottomContentStackView: bottomContentStackView,
            navigationToolbarContainer: navigationToolbarContainer,
            toolbarHelper: MockToolbarHelper()
        )

        subject.setupHeaderConstraints(isBottomSearchBar: true)
        subject.setupBottomContentStackViewConstraints()

        XCTAssertTrue(parentView.constraints.contains { constraint in
            constraint.firstItem === headerView
                && constraint.firstAttribute == .leading
                && constraint.secondItem === parentView
                && constraint.secondAttribute == .leading
        })
        XCTAssertTrue(parentView.constraints.contains { constraint in
            constraint.firstItem === bottomContentStackView
                && constraint.firstAttribute == .leading
                && constraint.secondItem === parentView.safeAreaLayoutGuide
                && constraint.secondAttribute == .leading
        })
    }

    func testCustomGuidesReserveManagedBrowserChromeSurfacesInLTRAndRTL() {
        let parentView = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let headerView = UIView()
        let bottomContainer = BaseAlphaStackView()
        let overKeyboardContainer = BaseAlphaStackView()
        let bottomContentStackView = BaseAlphaStackView()
        let navigationToolbarContainer = UIView()
        let managedChromeViews = [
            headerView,
            bottomContainer,
            overKeyboardContainer,
            bottomContentStackView,
        ]
        managedChromeViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            parentView.addSubview($0)
        }
        let guides = FloorpBrowserContentLayoutGuides(parentView: parentView)
        let subject = BrowserViewControllerLayoutManager(
            parentView: parentView,
            headerView: headerView,
            bottomContainer: bottomContainer,
            overKeyboardContainer: overKeyboardContainer,
            bottomContentStackView: bottomContentStackView,
            navigationToolbarContainer: navigationToolbarContainer,
            contentLayoutGuide: guides.fullWidth,
            safeAreaContentLayoutGuide: guides.safeArea,
            toolbarHelper: MockToolbarHelper()
        )
        subject.setupHeaderConstraints(isBottomSearchBar: true)
        subject.setupBottomContainerConstraints()
        subject.setupOverKeyboardContainerConstraints()
        subject.setupBottomContentStackViewConstraints()

        XCTAssertTrue(guides.reserveSidebar(width: 100, layoutDirection: .leftToRight))
        parentView.layoutIfNeeded()
        assertChromeFrames(managedChromeViews, minX: 0, maxX: 275)

        parentView.semanticContentAttribute = .forceRightToLeft
        XCTAssertTrue(guides.reserveSidebar(width: 100, layoutDirection: .rightToLeft))
        parentView.layoutIfNeeded()
        assertChromeFrames(managedChromeViews, minX: 100, maxX: 375)
    }

    private func assertChromeFrames(
        _ views: [UIView],
        minX: CGFloat,
        maxX: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for view in views {
            XCTAssertEqual(view.frame.minX, minX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(view.frame.maxX, maxX, accuracy: 0.5, file: file, line: line)
        }
    }
}

@MainActor
final class FloorpOverlayDrawerPresentationTests: XCTestCase {
    func testWindowScopedPresentationStatesRemainIndependentAndFallback() throws {
        let panels = FloorpPanel.defaultPanels()
        let notes = try XCTUnwrap(panels.first(where: { $0.id == "floorp//notes" }))
        let history = try XCTUnwrap(panels.first(where: { $0.id == "floorp//history" }))
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        let firstWindowUUID = WindowUUID()
        let secondWindowUUID = WindowUUID()
        let firstWindowState = FloorpPanelPresentationStateAssociation.state(
            for: firstOwner,
            windowUUID: firstWindowUUID
        )
        let secondWindowState = FloorpPanelPresentationStateAssociation.state(
            for: secondOwner,
            windowUUID: secondWindowUUID
        )

        firstWindowState.select(notes)
        secondWindowState.select(history)

        XCTAssertEqual(firstWindowState.windowUUID, firstWindowUUID)
        XCTAssertEqual(secondWindowState.windowUUID, secondWindowUUID)
        XCTAssertFalse(firstWindowState === secondWindowState)
        XCTAssertTrue(
            firstWindowState === FloorpPanelPresentationStateAssociation.state(
                for: firstOwner,
                windowUUID: WindowUUID()
            )
        )
        XCTAssertEqual(firstWindowState.selectedPanel(in: panels)?.id, notes.id)
        XCTAssertEqual(secondWindowState.selectedPanel(in: panels)?.id, history.id)

        let panelsAfterDeletingNotes = panels.filter { $0.id != notes.id }
        XCTAssertEqual(
            firstWindowState.selectedPanel(in: panelsAfterDeletingNotes)?.id,
            "floorp//bookmarks"
        )
        XCTAssertEqual(firstWindowState.selectedPanelId, "floorp//bookmarks")
        XCTAssertEqual(secondWindowState.selectedPanel(in: panelsAfterDeletingNotes)?.id, history.id)
    }

    func testAdaptiveLayoutMetricsForCompactAndRegularWidths() {
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 390, horizontalSizeClass: .compact),
            346,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 430, horizontalSizeClass: .compact),
            386,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 844, horizontalSizeClass: .compact),
            420,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 768, horizontalSizeClass: .regular),
            360,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 1_024, horizontalSizeClass: .regular),
            430.08,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.drawerWidth(availableWidth: 1_366, horizontalSizeClass: .regular),
            480,
            accuracy: 0.001
        )
    }

    func testAdaptivePresentationResolverRequiresWideRegularIPadGeometry() {
        XCTAssertEqual(
            FloorpPanelPresentationModeResolver.resolve(
                availableWidth: 1_366,
                horizontalSizeClass: .regular,
                userInterfaceIdiom: .phone
            ),
            .overlay
        )
        XCTAssertEqual(
            FloorpPanelPresentationModeResolver.resolve(
                availableWidth: 1_024,
                horizontalSizeClass: .compact,
                userInterfaceIdiom: .pad
            ),
            .overlay
        )
        XCTAssertEqual(
            FloorpPanelPresentationModeResolver.resolve(
                availableWidth: 859,
                horizontalSizeClass: .regular,
                userInterfaceIdiom: .pad
            ),
            .overlay
        )
        XCTAssertEqual(
            FloorpPanelPresentationModeResolver.resolve(
                availableWidth: 860,
                horizontalSizeClass: .regular,
                userInterfaceIdiom: .pad
            ),
            .pinned
        )
        XCTAssertEqual(
            FloorpPanelPresentationModeResolver.resolve(
                availableWidth: 1_024,
                horizontalSizeClass: .regular,
                userInterfaceIdiom: .pad
            ),
            .pinned
        )
    }

    func testPinnedWidthClampsToBrowserGeometryAndUsesDirectionalResize() {
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.pinnedWidth(preferredWidth: 400, availableWidth: 1_024),
            400
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.pinnedWidth(preferredWidth: 480, availableWidth: 900),
            400
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.resizedPinnedWidth(
                initialWidth: 400,
                translationX: -30,
                availableWidth: 1_024,
                layoutDirection: .leftToRight
            ),
            430
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.resizedPinnedWidth(
                initialWidth: 400,
                translationX: 30,
                availableWidth: 1_024,
                layoutDirection: .rightToLeft
            ),
            430
        )
    }

    func testBrowserContentGuidesReserveThePhysicalSidebarEdge() {
        let parentView = UIView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        let guides = FloorpBrowserContentLayoutGuides(parentView: parentView)
        let browserContent = UIView()
        browserContent.translatesAutoresizingMaskIntoConstraints = false
        parentView.addSubview(browserContent)
        NSLayoutConstraint.activate([
            browserContent.leadingAnchor.constraint(equalTo: guides.fullWidth.leadingAnchor),
            browserContent.trailingAnchor.constraint(equalTo: guides.fullWidth.trailingAnchor),
            browserContent.topAnchor.constraint(equalTo: parentView.topAnchor),
            browserContent.heightAnchor.constraint(equalToConstant: 44),
        ])

        XCTAssertTrue(guides.reserveSidebar(width: 400, layoutDirection: .leftToRight))
        parentView.layoutIfNeeded()
        XCTAssertEqual(browserContent.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(browserContent.frame.maxX, 624, accuracy: 0.5)
        XCTAssertFalse(guides.reserveSidebar(width: 400, layoutDirection: .leftToRight))

        parentView.semanticContentAttribute = .forceRightToLeft
        XCTAssertTrue(guides.reserveSidebar(width: 400, layoutDirection: .rightToLeft))
        parentView.layoutIfNeeded()
        XCTAssertEqual(browserContent.frame.minX, 400, accuracy: 0.5)
        XCTAssertEqual(browserContent.frame.maxX, 1_024, accuracy: 0.5)

        XCTAssertTrue(guides.reserveSidebar(width: 0, layoutDirection: .rightToLeft))
        parentView.layoutIfNeeded()
        XCTAssertEqual(browserContent.frame.minX, parentView.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(browserContent.frame.maxX, parentView.bounds.maxX, accuracy: 0.5)
    }

    func testBrowserSafeAreaGuideIntersectsReservedBrowserGeometry() {
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        parent.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        parent.view.layoutIfNeeded()

        let guides = FloorpBrowserContentLayoutGuides(parentView: parent.view)
        let safeContent = UIView()
        safeContent.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(safeContent)
        NSLayoutConstraint.activate([
            safeContent.leftAnchor.constraint(equalTo: guides.safeArea.leftAnchor),
            safeContent.rightAnchor.constraint(equalTo: guides.safeArea.rightAnchor),
            safeContent.topAnchor.constraint(equalTo: parent.view.topAnchor),
            safeContent.heightAnchor.constraint(equalToConstant: 44),
        ])

        XCTAssertTrue(guides.reserveSidebar(width: 400, layoutDirection: .leftToRight))
        parent.view.layoutIfNeeded()
        XCTAssertEqual(
            safeContent.frame.minX,
            parent.view.safeAreaLayoutGuide.layoutFrame.minX,
            accuracy: 0.5
        )
        XCTAssertEqual(safeContent.frame.maxX, guides.fullWidth.layoutFrame.maxX, accuracy: 0.5)

        parent.view.semanticContentAttribute = .forceRightToLeft
        XCTAssertTrue(guides.reserveSidebar(width: 400, layoutDirection: .rightToLeft))
        parent.view.layoutIfNeeded()
        XCTAssertEqual(safeContent.frame.minX, guides.fullWidth.layoutFrame.minX, accuracy: 0.5)
        XCTAssertEqual(
            safeContent.frame.maxX,
            parent.view.safeAreaLayoutGuide.layoutFrame.maxX,
            accuracy: 0.5
        )
    }

    func testWideRegularPresentationPinsBesideBrowserChromeAndResetsLayoutOnClose() async throws {
        let suiteName = "FloorpPinnedDrawerPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpPinnedDrawerPresentationTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in .pinned }
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let guides = state.contentLayoutGuides(in: parent.view)
        let simulatedAddressBar = UIView()
        simulatedAddressBar.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(simulatedAddressBar)
        NSLayoutConstraint.activate([
            simulatedAddressBar.leadingAnchor.constraint(equalTo: guides.fullWidth.leadingAnchor),
            simulatedAddressBar.trailingAnchor.constraint(equalTo: guides.fullWidth.trailingAnchor),
            simulatedAddressBar.topAnchor.constraint(equalTo: parent.view.topAnchor),
            simulatedAddressBar.heightAnchor.constraint(equalToConstant: 80),
        ])
        drawer.onPinnedLayoutChanged = { width, direction in
            _ = guides.reserveSidebar(width: width, layoutDirection: direction)
        }

        let presented = expectation(description: "Pinned drawer presentation completed")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        parent.view.layoutIfNeeded()

        let dimmingView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Dimming" })
        )
        let containerView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Container" })
        )
        let resizeHandle = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.ResizeHandle" })
        )
        XCTAssertEqual(drawer.presentationMode, .pinned)
        XCTAssertTrue(drawer.parent === parent)
        XCTAssertNil(parent.presentedViewController)
        XCTAssertFalse(drawer.view.accessibilityViewIsModal)
        XCTAssertTrue(dimmingView.isHidden)
        XCTAssertFalse(resizeHandle.isHidden)
        XCTAssertEqual(containerView.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(simulatedAddressBar.frame.maxX, containerView.frame.minX, accuracy: 0.5)
        XCTAssertNil(drawer.view.hitTest(CGPoint(x: 100, y: 384), with: nil))
        parent.view.bringSubviewToFront(simulatedAddressBar)
        drawer.ensurePinnedPresentationZOrder()
        XCTAssertGreaterThan(drawer.view.layer.zPosition, simulatedAddressBar.layer.zPosition)
        XCTAssertTrue(
            parent.view.hitTest(
                CGPoint(x: resizeHandle.frame.midX, y: simulatedAddressBar.frame.midY),
                with: nil
            ) === resizeHandle
        )
        XCTAssertTrue(
            parent.view.hitTest(
                CGPoint(x: 100, y: simulatedAddressBar.frame.midY),
                with: nil
            ) === simulatedAddressBar
        )

        let dismissed = expectation(description: "Pinned drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        parent.view.layoutIfNeeded()
        XCTAssertNil(drawer.parent)
        XCTAssertNil(state.activeDrawer)
        XCTAssertEqual(simulatedAddressBar.frame, CGRect(x: 0, y: 0, width: 1_024, height: 80))
    }

    func testPinnedRTLReservesLeftEdgeAndKeepsResizeHandleInteractive() async throws {
        let suiteName = "FloorpPinnedRTLPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpPinnedRTLPresentationTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in .pinned }
        )
        let parent = UIViewController()
        parent.loadViewIfNeeded()
        parent.view.semanticContentAttribute = .forceRightToLeft
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.semanticContentAttribute = .forceRightToLeft
        window.rootViewController = parent
        window.makeKeyAndVisible()
        drawer.loadViewIfNeeded()
        drawer.view.semanticContentAttribute = .forceRightToLeft
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let guides = state.contentLayoutGuides(in: parent.view)
        let simulatedAddressBar = UIView()
        simulatedAddressBar.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(simulatedAddressBar)
        NSLayoutConstraint.activate([
            simulatedAddressBar.leadingAnchor.constraint(equalTo: guides.fullWidth.leadingAnchor),
            simulatedAddressBar.trailingAnchor.constraint(equalTo: guides.fullWidth.trailingAnchor),
            simulatedAddressBar.topAnchor.constraint(equalTo: parent.view.topAnchor),
            simulatedAddressBar.heightAnchor.constraint(equalToConstant: 80),
        ])
        drawer.onPinnedLayoutChanged = { width, direction in
            _ = guides.reserveSidebar(width: width, layoutDirection: direction)
        }

        let presented = expectation(description: "RTL pinned drawer presentation completed")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        parent.view.layoutIfNeeded()

        let containerView = try XCTUnwrap(
            descendant(in: drawer.view, withIdentifier: "Floorp.Drawer.Container")
        )
        let resizeHandle = try XCTUnwrap(
            descendant(in: drawer.view, withIdentifier: "Floorp.Drawer.ResizeHandle")
        )
        XCTAssertEqual(drawer.view.effectiveUserInterfaceLayoutDirection, .rightToLeft)
        XCTAssertEqual(containerView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(containerView.frame.maxX, 400, accuracy: 0.5)
        XCTAssertEqual(simulatedAddressBar.frame.minX, containerView.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(simulatedAddressBar.frame.maxX, 1_024, accuracy: 0.5)
        XCTAssertEqual(resizeHandle.frame.minX, containerView.frame.maxX, accuracy: 0.5)

        parent.view.bringSubviewToFront(simulatedAddressBar)
        drawer.ensurePinnedPresentationZOrder()
        XCTAssertTrue(
            parent.view.hitTest(
                CGPoint(x: resizeHandle.frame.midX, y: simulatedAddressBar.frame.midY),
                with: nil
            ) === resizeHandle
        )
        XCTAssertTrue(
            parent.view.hitTest(
                CGPoint(x: 900, y: simulatedAddressBar.frame.midY),
                with: nil
            ) === simulatedAddressBar
        )

        let dismissed = expectation(description: "RTL pinned drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
    }

    func testPinnedWebPanelResizePersistsWithoutReplacingWideWindowPreference() async throws {
        let suiteName = "FloorpPinnedResizePersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpPinnedResizePersistenceTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let notificationCenter = NotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let panel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Resizable", urlText: "example.com")
        )
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(panel)
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            presentationModeProvider: { _, _ in .pinned }
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let presented = expectation(description: "Resizable pinned drawer presented")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        parent.view.layoutIfNeeded()
        let containerView = try XCTUnwrap(
            descendant(in: drawer.view, withIdentifier: "Floorp.Drawer.Container")
        )
        let resizeHandle = try XCTUnwrap(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.ResizeHandle"
            ) as? FloorpPanelResizeHandleView
        )
        XCTAssertEqual(containerView.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).revision, 0)

        resizeHandle.accessibilityIncrement()
        parent.view.layoutIfNeeded()
        XCTAssertEqual(containerView.frame.width, 420, accuracy: 0.5)
        XCTAssertEqual(resizeHandle.accessibilityValue, "420 pt")
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).contentWidth, 420)
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).revision, 1)
        XCTAssertEqual(
            try FloorpPanelManager(defaults: defaults)
                .webPanelPreferences(for: panel.id)
                .contentWidth,
            420
        )

        window.frame.size.width = 880
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        parent.view.layoutIfNeeded()
        XCTAssertEqual(containerView.frame.width, 380, accuracy: 0.5)
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).contentWidth, 420)
        resizeHandle.accessibilityIncrement()
        XCTAssertEqual(containerView.frame.width, 380, accuracy: 0.5)
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).contentWidth, 420)
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).revision, 1)

        window.frame.size.width = 1_024
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        parent.view.layoutIfNeeded()
        XCTAssertEqual(containerView.frame.width, 420, accuracy: 0.5)

        let dismissed = expectation(description: "Resizable pinned drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
    }

    func testPresentationModeMigrationPreservesDrawerAndLoadedContentIdentity() async throws {
        let suiteName = "FloorpDrawerMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpDrawerMigrationTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//notes")))
        let mode = FloorpMutablePanelPresentationMode(.pinned)
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in mode.value }
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let presented = expectation(description: "Pinned drawer presented before migration")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let contentView = try XCTUnwrap(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.Content"
            )
        )
        let dimmingView = try XCTUnwrap(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.Dimming"
            )
        )
        let resizeHandle = try XCTUnwrap(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.ResizeHandle"
            )
        )
        XCTAssertTrue(dimmingView.isHidden)
        XCTAssertFalse(resizeHandle.isHidden)
        XCTAssertFalse(drawer.view.accessibilityViewIsModal)

        mode.value = .overlay
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becameOverlay = await waitForPresentationState {
            drawer.presentationMode == .overlay
                && drawer.isPresentationTransitionSettled
                && parent.presentedViewController === drawer
        }
        XCTAssertTrue(becameOverlay)
        XCTAssertTrue(state.activeDrawer === drawer)
        XCTAssertFalse(dimmingView.isHidden)
        XCTAssertTrue(resizeHandle.isHidden)
        XCTAssertTrue(drawer.view.accessibilityViewIsModal)
        XCTAssertTrue(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.Content"
            ) === contentView
        )

        mode.value = .pinned
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becamePinned = await waitForPresentationState {
            drawer.presentationMode == .pinned
                && drawer.isPresentationTransitionSettled
                && drawer.parent === parent
        }
        XCTAssertTrue(becamePinned)
        XCTAssertNil(parent.presentedViewController)
        XCTAssertTrue(state.activeDrawer === drawer)
        XCTAssertTrue(dimmingView.isHidden)
        XCTAssertFalse(resizeHandle.isHidden)
        XCTAssertFalse(drawer.view.accessibilityViewIsModal)
        XCTAssertTrue(
            descendant(
                in: drawer.view,
                withIdentifier: "Floorp.Drawer.Content"
            ) === contentView
        )

        let dismissed = expectation(description: "Migrated drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
    }

    // swiftlint:disable:next function_body_length
    func testPinnedLibraryAppearanceLifecycleStaysBalancedAcrossMigrationAndClose() async throws {
        let suiteName = "FloorpPinnedAppearanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpPinnedAppearanceTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//bookmarks")))
        let mode = FloorpMutablePanelPresentationMode(.pinned)
        let libraryHost = FloorpAppearanceLibraryHost()
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            libraryPanelHost: libraryHost,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in mode.value }
        )
        let parent = FloorpAppearanceRecordingViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }
        let parentDidAppear = await waitForPresentationState {
            parent.events.contains(.didAppear)
        }
        XCTAssertTrue(parentDidAppear)

        let presented = expectation(description: "Pinned library drawer presented")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        XCTAssertEqual(libraryHost.recorder.events, [.willAppear, .didAppear])

        mode.value = .overlay
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becameOverlay = await waitForPresentationState {
            drawer.presentationMode == .overlay
                && drawer.isPresentationTransitionSettled
                && parent.presentedViewController === drawer
        }
        XCTAssertTrue(becameOverlay)
        XCTAssertEqual(
            libraryHost.recorder.events,
            [
                .willAppear, .didAppear,
                .willDisappear, .didDisappear,
                .willAppear, .didAppear
            ]
        )

        mode.value = .pinned
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becamePinned = await waitForPresentationState {
            drawer.presentationMode == .pinned
                && drawer.isPresentationTransitionSettled
                && drawer.parent === parent
        }
        XCTAssertTrue(becamePinned)
        XCTAssertEqual(
            libraryHost.recorder.events,
            [
                .willAppear, .didAppear,
                .willDisappear, .didDisappear,
                .willAppear, .didAppear,
                .willDisappear, .didDisappear,
                .willAppear, .didAppear
            ]
        )

        let dismissed = expectation(description: "Pinned library drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(
            libraryHost.recorder.events,
            [
                .willAppear, .didAppear,
                .willDisappear, .didDisappear,
                .willAppear, .didAppear,
                .willDisappear, .didDisappear,
                .willAppear, .didAppear,
                .willDisappear, .didDisappear
            ]
        )
    }

    // swiftlint:disable:next function_body_length
    func testPinnedDrawerPresentsAndAcknowledgesPendingNotesOperationError() async throws {
        let suiteName = "FloorpPinnedNotesErrorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpPinnedNotesErrorTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//notes")))
        state.recordPendingNotesOperationError()
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in .pinned }
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let presented = expectation(description: "Pinned Notes drawer presented")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let presentedError = await waitForPresentationState {
            drawer.presentedViewController is UIAlertController
        }
        XCTAssertTrue(presentedError)

        let alert = try XCTUnwrap(drawer.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, FloorpStrings.Notes.operationFailedTitle)
        XCTAssertEqual(alert.actions.count, 1)
        XCTAssertEqual(alert.actions.first?.title, FloorpStrings.Notes.close)
        XCTAssertTrue(state.hasPendingNotesOperationError)
        XCTAssertTrue(drawer.acknowledgePendingNotesOperationError())
        XCTAssertFalse(state.hasPendingNotesOperationError)

        let alertDismissed = expectation(description: "Pinned Notes error dismissed")
        alert.dismiss(animated: false) { alertDismissed.fulfill() }
        await fulfillment(of: [alertDismissed], timeout: 1)
        let drawerDismissed = expectation(description: "Pinned Notes drawer dismissed")
        drawer.onDismissed = { drawerDismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [drawerDismissed], timeout: 1)
    }

    private func waitForPresentationState(
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

    private func descendant(
        in view: UIView,
        withIdentifier identifier: String
    ) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(in: subview, withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }

    func testDirectionalLayoutMetricsAndSidebarClamp() {
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.dismissalTranslation(
                drawerWidth: 346,
                layoutDirection: .leftToRight
            ),
            346
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.dismissalTranslation(
                drawerWidth: 346,
                layoutDirection: .rightToLeft
            ),
            -346
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.dismissalSwipeDirection(layoutDirection: .leftToRight),
            .right
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.dismissalSwipeDirection(layoutDirection: .rightToLeft),
            .left
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.exposedCornerMask(layoutDirection: .leftToRight),
            [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        )
        XCTAssertEqual(
            FloorpDrawerLayoutMetrics.exposedCornerMask(layoutDirection: .rightToLeft),
            [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        )
        XCTAssertEqual(FloorpDrawerLayoutMetrics.sidebarWidth(configuredWidth: -1), 44)
        XCTAssertEqual(FloorpDrawerLayoutMetrics.sidebarWidth(configuredWidth: 50), 50)
        XCTAssertEqual(FloorpDrawerLayoutMetrics.sidebarWidth(configuredWidth: 100), 72)
    }

    func testRegularRTLDrawerResizesWithoutLosingOutsideHitRegion() throws {
        let suiteName = "FloorpOverlayDrawerRegularRTLTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpOverlayDrawerRegularRTLTests-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }

        let manager = FloorpPanelManager(defaults: defaults)
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(manager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            presentationState: state,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        host.addChild(drawer)
        host.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .regular),
            forChild: drawer
        )
        drawer.view.frame = host.view.bounds
        drawer.view.semanticContentAttribute = .forceRightToLeft
        host.view.addSubview(drawer.view)
        drawer.didMove(toParent: host)
        drawer.view.layoutIfNeeded()

        let dimmingView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Dimming" })
        )
        let containerView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Container" })
        )
        let contentView = try XCTUnwrap(
            containerView.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Content" })
        )
        dimmingView.alpha = 1
        XCTAssertEqual(containerView.frame.width, 430.08, accuracy: 0.5)
        XCTAssertEqual(containerView.frame.minX, 0, accuracy: 0.5)
        XCTAssertTrue(drawer.view.hitTest(CGPoint(x: 900, y: 384), with: nil) === dimmingView)
        XCTAssertFalse(drawer.view.hitTest(CGPoint(x: 100, y: 384), with: nil) === dimmingView)
        XCTAssertEqual(
            containerView.layer.maskedCorners,
            [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        )
        XCTAssertFalse(containerView.hasAmbiguousLayout)
        XCTAssertLessThanOrEqual(
            contentView.frame.maxY,
            containerView.safeAreaLayoutGuide.layoutFrame.maxY + 0.5
        )

        host.view.frame.size.width = 768
        drawer.view.frame = host.view.bounds
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        XCTAssertEqual(containerView.frame.width, 360, accuracy: 0.5)
        XCTAssertEqual(containerView.frame.minX, 0, accuracy: 0.5)
        XCTAssertTrue(drawer.view.hitTest(CGPoint(x: 700, y: 384), with: nil) === dimmingView)
    }

    func testDrawerUsesModalOverlayOutsideBrowserSubviewZOrder() async throws {
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
        let presentationState = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        presentationState.select(try XCTUnwrap(panelManager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: panelManager,
            notesStore: FloorpNotesStore(fileURL: archiveDirectory.appendingPathComponent("notes.json")),
            presentationState: presentationState,
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

        drawer.view.semanticContentAttribute = .forceLeftToRight
        XCTAssertEqual(drawer.modalPresentationStyle, .overFullScreen)
        XCTAssertTrue(parent.presentedViewController === drawer)
        XCTAssertFalse(parent.view.subviews.contains(where: { $0 === drawer.view }))
        XCTAssertTrue(presentationState.activeDrawer === drawer)

        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let dimmingView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Dimming" })
        )
        let containerView = try XCTUnwrap(
            drawer.view.subviews.first(where: { $0.accessibilityIdentifier == "Floorp.Drawer.Container" })
        )
        XCTAssertTrue(dimmingView is UIControl)
        XCTAssertEqual(containerView.frame.width, 346, accuracy: 0.5)
        XCTAssertEqual(containerView.frame.minX, FloorpDrawerLayoutMetrics.outsideDismissWidth, accuracy: 0.5)
        XCTAssertTrue(drawer.view.hitTest(CGPoint(x: 22, y: 422), with: nil) === dimmingView)
        XCTAssertFalse(drawer.view.hitTest(CGPoint(x: 100, y: 422), with: nil) === dimmingView)
        XCTAssertLessThan(
            try XCTUnwrap(drawer.view.subviews.firstIndex(where: { $0 === dimmingView })),
            try XCTUnwrap(drawer.view.subviews.firstIndex(where: { $0 === containerView }))
        )

        let simulatedAddressBar = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        parent.view.addSubview(simulatedAddressBar)
        parent.view.bringSubviewToFront(simulatedAddressBar)
        XCTAssertTrue(parent.presentedViewController === drawer)

        drawer.dismissDrawer()
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(dismissalCount, 1)
        XCTAssertNil(presentationState.activeDrawer)
    }

    func testOverlayRemainsDismissibleWhenUIKitPromotesPresenterToNavigationController() async throws {
        let suiteName = "FloorpOverlayDrawerPromotedPresenterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpOverlayDrawerPromotedPresenterTests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveDirectory)
        }

        let panelManager = FloorpPanelManager(defaults: defaults)
        let presentationState = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        presentationState.select(try XCTUnwrap(panelManager.panel(for: "floorp//notes")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: panelManager,
            notesStore: FloorpNotesStore(fileURL: archiveDirectory.appendingPathComponent("notes.json")),
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            presentationModeProvider: { _, _ in .overlay }
        )
        let browser = UIViewController()
        let navigationController = UINavigationController(rootViewController: browser)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        navigationController.loadViewIfNeeded()
        browser.loadViewIfNeeded()
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let presented = expectation(description: "Promoted overlay presentation completed")
        XCTAssertTrue(drawer.show(from: browser) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)

        XCTAssertTrue(drawer.presentingViewController === navigationController)
        XCTAssertEqual(drawer.presentationMode, .overlay)
        XCTAssertTrue(presentationState.activeDrawer === drawer)

        let dismissed = expectation(description: "Promoted overlay dismissal completed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)

        XCTAssertNil(navigationController.presentedViewController)
        XCTAssertNil(presentationState.activeDrawer)
    }

    func testExternalDismissalFinishesOnceAndAllowsReplacementDrawer() async throws {
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

        let presentationState = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        let initialManager = FloorpPanelManager(defaults: defaults)
        presentationState.select(try XCTUnwrap(initialManager.panel(for: "floorp//notes")))
        let makeDrawer = {
            let manager = FloorpPanelManager(defaults: defaults)
            return FloorpOverlayDrawerViewController(
                panelManager: manager,
                notesStore: FloorpNotesStore(
                    fileURL: archiveDirectory.appendingPathComponent("notes.json")
                ),
                presentationState: presentationState,
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
        XCTAssertTrue(presentationState.activeDrawer === drawer)

        parent.dismiss(animated: false)
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(dismissalCount, 1)
        XCTAssertNil(presentationState.activeDrawer)

        let replacement = makeDrawer()
        let replacementPresented = expectation(description: "Replacement drawer presented")
        let replacementDismissed = expectation(description: "Replacement drawer dismissed")
        replacement.onDismissed = { replacementDismissed.fulfill() }
        XCTAssertTrue(replacement.show(from: parent) { replacementPresented.fulfill() })
        await fulfillment(of: [replacementPresented], timeout: 1)
        XCTAssertTrue(presentationState.activeDrawer === replacement)
        XCTAssertEqual(presentationState.selectedPanelId, "floorp//notes")
        replacement.dismissDrawer()
        await fulfillment(of: [replacementDismissed], timeout: 1)
        XCTAssertNil(presentationState.activeDrawer)
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
        let presentationState = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        if let notesPanel = manager.panel(for: "floorp//notes") {
            presentationState.select(notesPanel)
        } else {
            XCTFail("Expected the default Notes panel")
        }
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: FloorpNotesStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("unused-\(UUID().uuidString).json")
            ),
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )

        XCTAssertFalse(drawer.show(from: parent))
        XCTAssertNil(drawer.presentingViewController)
        XCTAssertNil(presentationState.activeDrawer)

        let blockerDismissed = expectation(description: "Blocking modal dismissed")
        parent.dismiss(animated: false) { blockerDismissed.fulfill() }
        await fulfillment(of: [blockerDismissed], timeout: 1)
    }
}

@MainActor
private final class FloorpMutablePanelPresentationMode {
    var value: FloorpPanelPresentationMode

    init(_ value: FloorpPanelPresentationMode) {
        self.value = value
    }
}

@MainActor
private final class FloorpAppearanceRecordingViewController: UIViewController {
    enum Event: Equatable {
        case willAppear
        case didAppear
        case willDisappear
        case didDisappear
    }

    private(set) var events = [Event]()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        events.append(.willAppear)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        events.append(.didAppear)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        events.append(.willDisappear)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        events.append(.didDisappear)
    }
}

@MainActor
private final class FloorpAppearanceLibraryHost: FloorpLibraryPanelHosting {
    let recorder = FloorpAppearanceRecordingViewController()
    var selectedPanelType: FloorpPanelType?
    var allowsPanelSwitching = true
    var onRequestDrawerDismiss: (() -> Void)?

    var viewController: UIViewController {
        recorder
    }

    func select(panelType: FloorpPanelType) -> Bool {
        selectedPanelType = panelType
        return true
    }

    func prepareForDrawerDismissal() -> FloorpLibraryPanelDismissalDisposition {
        .allow
    }
}

private struct LegacyFloorpOverlayDrawerConfig: Encodable {
    let selectedPanelId: String?
    let panelOrder: [String]
    let isDisplayed: Bool
    let isEnabled: Bool
    let sidebarWidth: Int
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
        let legacyConfig = LegacyFloorpOverlayDrawerConfig(
            selectedPanelId: "floorp//history",
            panelOrder: legacyPanels.map(\.id),
            isDisplayed: true,
            isEnabled: false,
            sidebarWidth: 61
        )
        defaults.set(try JSONEncoder().encode(legacyPanels), forKey: "floorp.overlayDrawer.panels")
        defaults.set(try JSONEncoder().encode(legacyConfig), forKey: "floorp.overlayDrawer.config")
        XCTAssertEqual(defaults.integer(forKey: "floorp.overlayDrawer.schemaVersion"), 0)

        let migrated = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(migrated.panels.filter { $0.type == .notes }.count, 1)
        XCTAssertFalse(migrated.config.isEnabled)
        XCTAssertEqual(migrated.config.sidebarWidth, 61)
        XCTAssertEqual(defaults.integer(forKey: "floorp.overlayDrawer.schemaVersion"), 3)
        let migratedConfigData = try XCTUnwrap(
            defaults.data(forKey: "floorp.overlayDrawer.config")
        )
        let migratedConfig = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedConfigData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(migratedConfig.keys),
            ["isEnabled", "sidebarWidth", "autoUnload", "revision"]
        )
        XCTAssertEqual(migratedConfig["autoUnload"] as? Bool, false)
        XCTAssertEqual((migratedConfig["revision"] as? NSNumber)?.uint64Value, 0)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(restarted.panels.filter { $0.type == .notes }.count, 1)
    }

    func testSchemaOneMigrationPreservesUserDeletedNotes() throws {
        let suiteName = "FloorpPanelNotesSchemaOneMigrationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let panelsAfterDeletingNotes = Array(FloorpPanel.defaultPanels().filter { $0.type != .notes })
        defaults.set(
            try JSONEncoder().encode(panelsAfterDeletingNotes),
            forKey: "floorp.overlayDrawer.panels"
        )
        defaults.set(1, forKey: "floorp.overlayDrawer.schemaVersion")

        let migrated = FloorpPanelManager(defaults: defaults)
        XCTAssertFalse(migrated.panels.contains(where: { $0.type == .notes }))
        XCTAssertEqual(defaults.integer(forKey: "floorp.overlayDrawer.schemaVersion"), 3)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertFalse(restarted.panels.contains(where: { $0.type == .notes }))
    }

    func testReorderPreservesPanelsMissingFromOlderOrderList() throws {
        let suiteName = "FloorpPanelNotesReorderTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = FloorpPanelManager(defaults: defaults)
        try manager.reorderPanels(
            orderedIds: ["floorp//history", "floorp//bookmarks", "floorp//downloads"]
        )

        let expectedOrder = [
            "floorp//history",
            "floorp//bookmarks",
            "floorp//downloads",
            "floorp//notes",
        ]
        XCTAssertEqual(manager.panels.map(\.id), expectedOrder)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(restarted.panels.map(\.id), expectedOrder)
        XCTAssertEqual(restarted.panels.map(\.sortOrder), Array(restarted.panels.indices))
    }

    func testNoteSearchUsesContentBeyondDisplayedPreview() {
        let fullContent = String(repeating: "a", count: 200) + " deep needle"
        let item = DrawerItem(
            id: "note-id",
            title: "Title",
            subtitle: String(fullContent.prefix(160)),
            searchText: fullContent,
            source: .note(id: FloorpNoteID("note-id"))
        )

        XCTAssertTrue(item.matchesSearchQuery("DEEP NEEDLE"))
        XCTAssertTrue(item.matchesSearchQuery("  needle   title "))
        XCTAssertFalse(item.matchesSearchQuery("not present"))

        let localizedItem = DrawerItem(id: "localized", title: "Café Ｆｌｏｏｒｐ")
        XCTAssertTrue(localizedItem.matchesSearchQuery("cafe floorp"))
    }
}

final class FloorpWebPanelValidatorTests: XCTestCase {
    func testCanonicalizesTitleAndHTTPURL() throws {
        let validated = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(
                title: "  Floorp Portal  ",
                urlText: "HTTP://Example.COM:8080/path?q=1#section",
                iconName: "star"
            )
        )

        XCTAssertEqual(validated.title, "Floorp Portal")
        XCTAssertEqual(validated.url.absoluteString, "http://example.com:8080/path?q=1#section")
        XCTAssertEqual(validated.iconName, "star")
    }

    func testCompletesSchemeForHostAndProtocolRelativeURL() throws {
        let host = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "Local", urlText: "localhost:8080/status")
        )
        let protocolRelative = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "Floorp", urlText: "//Floorp.APP/notes")
        )

        XCTAssertEqual(host.url.absoluteString, "https://localhost:8080/status")
        XCTAssertEqual(protocolRelative.url.absoluteString, "https://floorp.app/notes")
    }

    func testRejectsUnsupportedOrUnsafeURLs() {
        let invalidURLs = [
            ("javascript:alert(1)", FloorpWebPanelValidationError.unsupportedScheme),
            ("javascript:1", .unsupportedScheme),
            ("file:///tmp/panel", .unsupportedScheme),
            ("about:config", .unsupportedScheme),
            ("data:text/plain,panel", .unsupportedScheme),
            ("data:123", .unsupportedScheme),
            ("https://user:secret@example.com", .credentialsNotAllowed),
            ("https://%75ser@example.com", .credentialsNotAllowed),
            ("https://user%40name@example.com", .credentialsNotAllowed),
            ("https://example.com%40evil.com", .credentialsNotAllowed),
            ("https:///path-only", .missingHost),
            ("https://example.com/\u{0000}panel", .urlContainsControlCharacters),
            ("https://example.com:0", .invalidURL),
            ("https://example.com:65536", .invalidURL),
            ("https://example.com:999999999999999999999", .invalidURL),
            ("https://example.com:", .invalidURL),
        ]

        for (urlText, expectedError) in invalidURLs {
            XCTAssertThrowsError(
                try FloorpWebPanelValidator.validate(
                    FloorpWebPanelDraft(title: "Panel", urlText: urlText)
                ),
                "Expected rejection for \(urlText)"
            ) { error in
                XCTAssertEqual(error as? FloorpWebPanelValidationError, expectedError)
            }
        }
    }

    func testEnforcesTitleAndIconPolicy() throws {
        let validTitle = String(repeating: "a", count: FloorpWebPanelValidator.maximumTitleLength)
        XCTAssertNoThrow(
            try FloorpWebPanelValidator.validate(
                FloorpWebPanelDraft(title: validTitle, urlText: "example.com")
            )
        )

        let cases: [(FloorpWebPanelDraft, FloorpWebPanelValidationError)] = [
            (FloorpWebPanelDraft(title: "   ", urlText: "example.com"), .emptyTitle),
            (
                FloorpWebPanelDraft(title: validTitle + "a", urlText: "example.com"),
                .titleTooLong(maximum: FloorpWebPanelValidator.maximumTitleLength)
            ),
            (
                FloorpWebPanelDraft(title: "Panel\u{0007}", urlText: "example.com"),
                .titleContainsControlCharacters
            ),
            (
                FloorpWebPanelDraft(title: "Panel\u{0085}Title", urlText: "example.com"),
                .titleContainsControlCharacters
            ),
            (
                FloorpWebPanelDraft(title: "Panel\u{202E}Title", urlText: "example.com"),
                .titleContainsControlCharacters
            ),
            (
                FloorpWebPanelDraft(title: "Panel", urlText: "example.com", iconName: "lock.fill"),
                .unsupportedIcon
            ),
        ]
        for (draft, expectedError) in cases {
            XCTAssertThrowsError(try FloorpWebPanelValidator.validate(draft)) { error in
                XCTAssertEqual(error as? FloorpWebPanelValidationError, expectedError)
            }
        }

        let normalized = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "Cafe\u{0301}", urlText: "example.com")
        )
        let joiners = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "A\u{200C}B\u{200D}C", urlText: "example.com")
        )
        XCTAssertEqual(normalized.title, "Café")
        XCTAssertEqual(joiners.title, "A\u{200C}B\u{200D}C")

        for invisibleTitle in ["\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{200C}\u{200D}"] {
            XCTAssertThrowsError(
                try FloorpWebPanelValidator.validate(
                    FloorpWebPanelDraft(title: invisibleTitle, urlText: "example.com")
                )
            ) { error in
                XCTAssertEqual(error as? FloorpWebPanelValidationError, .emptyTitle)
            }
            XCTAssertNil(FloorpWebPanelValidator.safeDisplayTitle(invisibleTitle))
        }

        let oversizedSingleCharacter = "a" + String(repeating: "\u{0300}", count: 4_096)
        XCTAssertThrowsError(
            try FloorpWebPanelValidator.validate(
                FloorpWebPanelDraft(title: oversizedSingleCharacter, urlText: "example.com")
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebPanelValidationError,
                .titleTooLong(maximum: FloorpWebPanelValidator.maximumTitleLength)
            )
        }
    }

    func testEnforcesLimitAfterAddingDefaultScheme() {
        let schemelessURL = String(repeating: "a", count: FloorpWebPanelValidator.maximumURLLength - 4) + ".com"

        XCTAssertThrowsError(
            try FloorpWebPanelValidator.validate(
                FloorpWebPanelDraft(title: "Panel", urlText: schemelessURL)
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebPanelValidationError,
                .urlTooLong(maximum: FloorpWebPanelValidator.maximumURLLength)
            )
        }
    }

    func testAcceptsPortBoundariesIDNAndIPv6() throws {
        let minimumPort = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "Minimum", urlText: "example.com:1")
        )
        let maximumPort = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "Maximum", urlText: "https://example.com:65535")
        )
        let idn = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "IDN", urlText: "https://例え.テスト/path")
        )
        let ipv6 = try FloorpWebPanelValidator.validate(
            FloorpWebPanelDraft(title: "IPv6", urlText: "https://[2001:db8::1]:443/path")
        )

        XCTAssertEqual(minimumPort.url.port, 1)
        XCTAssertEqual(maximumPort.url.port, 65_535)
        XCTAssertNotNil(idn.url.host)
        XCTAssertEqual(ipv6.url.host, "2001:db8::1")
        XCTAssertEqual(ipv6.url.port, 443)
    }

    func testSafeDisplayTitleNeverReturnsUnboundedOrUnsafeLegacyContent() {
        let safePanel = FloorpPanel(
            id: "safe-display",
            type: .web,
            title: "  Cafe\u{0301}  ",
            url: "javascript:1",
            iconName: "legacy-icon",
            sortOrder: 0
        )
        let unsafePanel = FloorpPanel(
            id: "unsafe-display",
            type: .web,
            title: "Spoof\u{202E}Title",
            url: "https://example.com",
            iconName: "globe",
            sortOrder: 1
        )

        XCTAssertEqual(safePanel.safeDisplayTitle, "Café")
        XCTAssertNil(unsafePanel.safeDisplayTitle)
        XCTAssertEqual(
            FloorpPanel.defaultPanels().first?.safeDisplayTitle,
            FloorpPanelType.bookmarks.localizedBuiltInTitle
        )
    }
}

@MainActor
final class FloorpPanelManagerRegistryTests: XCTestCase {
    private let panelsKey = "floorp.overlayDrawer.panels"
    private let schemaVersionKey = "floorp.overlayDrawer.schemaVersion"

    func testAddUpdateMoveAndPersistenceUseSafeValuesAndNotify() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let added = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(
                title: "  Portal  ",
                urlText: "Example.COM/path",
                iconName: "link"
            )
        )
        XCTAssertEqual(added.type, .web)
        XCTAssertFalse(FloorpPanel.isReservedIdentifier(added.id))
        XCTAssertNotNil(UUID(uuidString: added.id))
        XCTAssertEqual(added.title, "Portal")
        XCTAssertEqual(added.url, "https://example.com/path")
        XCTAssertEqual(added.sortOrder, 4)
        XCTAssertEqual(notificationCenter.postCallCount, 1)
        XCTAssertEqual(notificationCenter.savePostName, .FloorpPanelRegistryDidChange)
        XCTAssertTrue((notificationCenter.savePostObject as? FloorpPanelManager) === manager)
        XCTAssertNil(notificationCenter.saveUserInfo)

        try manager.updateWebPanel(
            id: added.id,
            draft: FloorpWebPanelDraft(
                title: "Updated",
                urlText: "http://floorp.app/updated",
                iconName: "star"
            ),
            expectedRevision: FloorpWebPanelRevision(panel: added)
        )
        let updated = try XCTUnwrap(manager.panel(for: added.id))
        XCTAssertEqual(updated.id, added.id)
        XCTAssertEqual(updated.type, .web)
        XCTAssertEqual(updated.sortOrder, added.sortOrder)
        XCTAssertEqual(updated.title, "Updated")
        XCTAssertEqual(updated.url, "http://floorp.app/updated")
        XCTAssertEqual(notificationCenter.postCallCount, 2)
        XCTAssertEqual(try manager.validatedWebURL(for: added.id).absoluteString, updated.url)

        try manager.movePanel(id: added.id, to: 0)
        XCTAssertEqual(manager.panels.first?.id, added.id)
        XCTAssertEqual(manager.panels.map(\.sortOrder), Array(manager.panels.indices))
        XCTAssertEqual(notificationCenter.postCallCount, 3)
        try manager.movePanel(id: added.id, to: 0)
        XCTAssertEqual(notificationCenter.postCallCount, 3)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(restarted.panels.first?.id, added.id)
        XCTAssertEqual(restarted.panel(for: added.id)?.title, "Updated")
        XCTAssertEqual(restarted.panel(for: added.id)?.url, "http://floorp.app/updated")
    }

    func testConcurrentWebPanelEditCannotOverwriteNewerValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let added = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Original", urlText: "example.com")
        )
        let staleRevision = FloorpWebPanelRevision(panel: added)

        try manager.updateWebPanel(
            id: added.id,
            draft: FloorpWebPanelDraft(title: "First Window", urlText: "first.example.com"),
            expectedRevision: staleRevision
        )
        XCTAssertThrowsError(
            try manager.updateWebPanel(
                id: added.id,
                draft: FloorpWebPanelDraft(title: "Second Window", urlText: "second.example.com"),
                expectedRevision: staleRevision
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .editConflict(id: added.id))
        }

        XCTAssertEqual(manager.panel(for: added.id)?.title, "First Window")
        XCTAssertEqual(manager.panel(for: added.id)?.url, "https://first.example.com")
        XCTAssertEqual(notificationCenter.postCallCount, 2)

        let latestPanel = try XCTUnwrap(manager.panel(for: added.id))
        try manager.removePanel(id: added.id)
        XCTAssertThrowsError(
            try manager.updateWebPanel(
                id: added.id,
                draft: FloorpWebPanelDraft(title: "Deleted Elsewhere", urlText: "deleted.example.com"),
                expectedRevision: FloorpWebPanelRevision(panel: latestPanel)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .editConflict(id: added.id))
        }
        XCTAssertNil(manager.panel(for: added.id))
    }

    func testReservedUpdateAndInvalidMoveFailWithoutNotification() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        XCTAssertThrowsError(
            try manager.updateWebPanel(
                id: "floorp//bookmarks",
                draft: FloorpWebPanelDraft(title: "Spoof", urlText: "example.com"),
                expectedRevision: FloorpWebPanelRevision(
                    panel: try XCTUnwrap(manager.panel(for: "floorp//bookmarks"))
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpPanelError,
                .reservedIdentifier(id: "floorp//bookmarks")
            )
        }
        XCTAssertThrowsError(try manager.movePanel(id: "floorp//bookmarks", to: -1)) { error in
            XCTAssertEqual(error as? FloorpPanelError, .invalidMoveDestination(index: -1))
        }
        XCTAssertThrowsError(try manager.movePanel(id: "missing", to: 0)) { error in
            XCTAssertEqual(error as? FloorpPanelError, .panelNotFound(id: "missing"))
        }
        XCTAssertEqual(notificationCenter.postCallCount, 0)
    }

    func testRemoveLastPanelFailsAndRestoreBuiltInsIsIdempotent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customPanel = FloorpPanel(
            id: "custom-only",
            type: .web,
            title: "Only Panel",
            url: "https://example.com",
            iconName: "globe",
            sortOrder: 0
        )
        try store([customPanel], in: defaults)
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        XCTAssertThrowsError(try manager.removePanel(id: customPanel.id)) { error in
            XCTAssertEqual(error as? FloorpPanelError, .cannotRemoveLastPanel)
        }
        XCTAssertEqual(notificationCenter.postCallCount, 0)

        let restored = try manager.restoreMissingBuiltIns()
        XCTAssertEqual(restored.map(\.id), FloorpPanel.defaultPanels().map(\.id))
        XCTAssertEqual(notificationCenter.postCallCount, 1)
        XCTAssertEqual(try manager.restoreMissingBuiltIns(), [])
        XCTAssertEqual(notificationCenter.postCallCount, 1)

        try manager.removePanel(id: "floorp//history")
        XCTAssertNil(manager.panel(for: "floorp//history"))
        XCTAssertEqual(notificationCenter.postCallCount, 2)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertNil(restarted.panel(for: "floorp//history"))
        XCTAssertEqual(restarted.panels.map(\.sortOrder), Array(restarted.panels.indices))
    }

    func testPanelLimitRejectsAddWithoutMutationOrNotification() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fullRegistry = (0..<FloorpPanelManager.maximumPanelCount).map { index in
            FloorpPanel(
                id: "custom-\(index)",
                type: .web,
                title: "Panel \(index)",
                url: "https://example.com/\(index)",
                iconName: "globe",
                sortOrder: index
            )
        }
        try store(fullRegistry, in: defaults)
        let notificationCenter = MockNotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        XCTAssertThrowsError(
            try manager.addWebPanel(
                draft: FloorpWebPanelDraft(title: "Overflow", urlText: "example.com")
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpPanelError,
                .panelLimitReached(maximum: FloorpPanelManager.maximumPanelCount)
            )
        }
        XCTAssertEqual(manager.panels.map(\.id), fullRegistry.map(\.id))
        XCTAssertTrue(manager.panels.allSatisfy { $0.webPreferences == FloorpWebPanelPreferences() })
        XCTAssertEqual(notificationCenter.postCallCount, 0)
    }

    func testLoadSanitizesStructureButPreservesInvalidWebPanelsForRepair() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let canonicalBookmark = try XCTUnwrap(
            FloorpPanel.defaultPanels().first(where: { $0.type == .bookmarks })
        )
        let persisted = [
            FloorpPanel(
                id: canonicalBookmark.id,
                type: .web,
                title: "Spoof",
                url: "https://attacker.example",
                iconName: "globe",
                sortOrder: 0
            ),
            FloorpPanel(
                id: canonicalBookmark.id,
                type: canonicalBookmark.type,
                title: "Tampered built-in",
                url: "https://attacker.example",
                iconName: "star",
                sortOrder: 1
            ),
            canonicalBookmark,
            FloorpPanel(
                id: "floorp//unknown",
                type: .web,
                title: "Unknown reserved",
                url: "https://example.com",
                iconName: "globe",
                sortOrder: 3
            ),
            FloorpPanel(
                id: "safe-custom",
                type: .web,
                title: "  Safe  ",
                url: "Example.COM/panel",
                iconName: "star",
                sortOrder: 4
            ),
            FloorpPanel(
                id: "safe-custom",
                type: .web,
                title: "Duplicate",
                url: "https://duplicate.example",
                iconName: "globe",
                sortOrder: 5
            ),
            FloorpPanel(
                id: "unsafe-custom",
                type: .web,
                title: "Unsafe",
                url: "javascript:alert(1)",
                iconName: "globe",
                sortOrder: 6
            ),
            FloorpPanel(
                id: "non-reserved-built-in",
                type: .history,
                title: "History spoof",
                url: nil,
                iconName: "clock.arrow.circlepath",
                sortOrder: 7
            ),
        ]
        try store(persisted, in: defaults)
        let notificationCenter = MockNotificationCenter()

        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(
            manager.panels.map(\.id),
            [canonicalBookmark.id, "safe-custom", "unsafe-custom"]
        )
        XCTAssertEqual(manager.panel(for: canonicalBookmark.id)?.title, canonicalBookmark.title)
        XCTAssertNil(manager.panel(for: canonicalBookmark.id)?.url)
        XCTAssertEqual(manager.panel(for: "safe-custom")?.title, "  Safe  ")
        XCTAssertEqual(manager.panel(for: "safe-custom")?.url, "Example.COM/panel")
        XCTAssertEqual(
            try manager.validatedWebURL(for: "safe-custom").absoluteString,
            "https://example.com/panel"
        )
        XCTAssertEqual(manager.panel(for: "unsafe-custom")?.url, "javascript:alert(1)")
        XCTAssertThrowsError(try manager.validatedWebURL(for: "unsafe-custom")) { error in
            XCTAssertEqual(error as? FloorpWebPanelValidationError, .unsupportedScheme)
        }
        XCTAssertEqual(manager.panels.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(notificationCenter.postCallCount, 0)

        try manager.movePanel(id: "unsafe-custom", to: 0)
        let added = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Added", urlText: "floorp.app")
        )
        try manager.removePanel(id: "safe-custom")
        XCTAssertEqual(notificationCenter.postCallCount, 3)

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(restarted.panels.map(\.id), ["unsafe-custom", canonicalBookmark.id, added.id])
        XCTAssertEqual(restarted.panel(for: "unsafe-custom")?.url, "javascript:alert(1)")
        XCTAssertThrowsError(try restarted.validatedWebURL(for: "unsafe-custom"))
    }

    func testLoadFallsBackToDefaultsWhenEveryPersistedPanelIsStructurallyInvalid() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try store(
            [
                FloorpPanel(
                    id: "floorp//bookmarks",
                    type: .web,
                    title: "Spoof",
                    url: "https://example.com",
                    iconName: "globe",
                    sortOrder: 0
                ),
                FloorpPanel(
                    id: "non-reserved-built-in",
                    type: .history,
                    title: "Invalid structure",
                    url: nil,
                    iconName: "clock.arrow.circlepath",
                    sortOrder: 1
                ),
            ],
            in: defaults
        )

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertEqual(manager.panels, FloorpPanel.defaultPanels())
        XCTAssertFalse(manager.panels.isEmpty)
    }

    func testLoadKeepsDecodablePanelsWhenAnotherElementUsesFutureSchema() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bookmark = try XCTUnwrap(
            FloorpPanel.defaultPanels().first(where: { $0.type == .bookmarks })
        )
        let invalidLegacyWebPanel = FloorpPanel(
            id: "legacy-invalid-web",
            type: .web,
            title: "",
            url: "javascript:alert(1)",
            iconName: "legacy-icon",
            sortOrder: 1
        )
        let bookmarkObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bookmark)) as? [String: Any]
        )
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(invalidLegacyWebPanel)) as? [String: Any]
        )
        let futurePanel: [String: Any] = [
            "id": "future-panel",
            "type": "future-native-panel",
            "title": "Future",
            "iconName": "sparkles",
            "sortOrder": 2,
        ]
        let missingRequiredFields: [String: Any] = [
            "id": "malformed-panel",
            "type": "web",
        ]
        let rawData = try JSONSerialization.data(
            withJSONObject: [bookmarkObject, legacyObject, futurePanel, missingRequiredFields]
        )
        defaults.set(rawData, forKey: panelsKey)

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertEqual(manager.panels.map(\.id), [bookmark.id, invalidLegacyWebPanel.id])
        XCTAssertEqual(manager.panel(for: invalidLegacyWebPanel.id), invalidLegacyWebPanel)
        XCTAssertTrue(manager.isRegistryReadOnly)
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        XCTAssertThrowsError(try manager.validatedWebURL(for: invalidLegacyWebPanel.id)) { error in
            XCTAssertEqual(error as? FloorpWebPanelValidationError, .emptyTitle)
        }

        let mutationAttempts: [() throws -> Void] = [
            {
                _ = try manager.addWebPanel(
                    draft: FloorpWebPanelDraft(title: "Added", urlText: "example.com")
                )
            },
            {
                try manager.updateWebPanel(
                    id: invalidLegacyWebPanel.id,
                    draft: FloorpWebPanelDraft(title: "Repaired", urlText: "example.com"),
                    expectedRevision: FloorpWebPanelRevision(panel: invalidLegacyWebPanel)
                )
            },
            { try manager.movePanel(id: bookmark.id, to: 1) },
            { try manager.removePanel(id: bookmark.id) },
            { _ = try manager.restoreMissingBuiltIns() },
            { try manager.reorderPanels(orderedIds: [invalidLegacyWebPanel.id, bookmark.id]) },
        ]
        for mutation in mutationAttempts {
            XCTAssertThrowsError(try mutation()) { error in
                XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
            }
            XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        }

        let restarted = FloorpPanelManager(defaults: defaults)
        XCTAssertEqual(restarted.panels, manager.panels)
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
    }

    func testLoadDoesNotRewriteRegistryFromNewerSchema() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let panel = FloorpPanel(
            id: "future-schema-web",
            type: .web,
            title: "Future schema",
            url: "https://example.com",
            iconName: "globe",
            sortOrder: 42
        )
        let rawData = try JSONEncoder().encode([panel])
        defaults.set(rawData, forKey: panelsKey)
        defaults.set(99, forKey: schemaVersionKey)

        let manager = FloorpPanelManager(defaults: defaults)

        XCTAssertEqual(manager.panels.first?.sortOrder, 0)
        XCTAssertTrue(manager.isRegistryReadOnly)
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
        XCTAssertEqual(defaults.integer(forKey: schemaVersionKey), 99)
        XCTAssertThrowsError(
            try manager.addWebPanel(
                draft: FloorpWebPanelDraft(title: "Added", urlText: "example.com")
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPanelError, .registryReadOnly)
        }
        XCTAssertEqual(defaults.data(forKey: panelsKey), rawData)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "FloorpPanelManagerRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(2, forKey: schemaVersionKey)
        return (defaults, suiteName)
    }

    private func store(_ panels: [FloorpPanel], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(panels), forKey: panelsKey)
    }
}

@MainActor
final class FloorpPanelRegistryUIHelperTests: XCTestCase {
    func testReorderMapsSingleDragToOneMove() {
        let initial: [FloorpPanelRegistryItem] = [
            .panel("first"),
            .panel("second"),
            .panel("third"),
            .restoreBuiltIns,
        ]
        let final: [FloorpPanelRegistryItem] = [
            .panel("second"),
            .panel("third"),
            .panel("first"),
            .restoreBuiltIns,
        ]
        let difference = final.difference(from: initial).inferringMoves()

        XCTAssertEqual(
            FloorpPanelRegistryReorder.move(
                in: difference,
                finalPanelIDs: ["second", "third", "first"]
            ),
            FloorpPanelRegistryMove(panelID: "first", destinationIndex: 2)
        )
    }

    func testReorderRejectsNoOpAndMultipleMoves() {
        let unchanged: [FloorpPanelRegistryItem] = [
            .panel("first"),
            .panel("second"),
            .restoreBuiltIns,
        ]
        XCTAssertNil(
            FloorpPanelRegistryReorder.move(
                in: unchanged.difference(from: unchanged).inferringMoves(),
                finalPanelIDs: ["first", "second"]
            )
        )

        let initial: [FloorpPanelRegistryItem] = [
            .panel("first"),
            .panel("second"),
            .panel("third"),
            .panel("fourth"),
        ]
        let multipleMoves: [FloorpPanelRegistryItem] = [
            .panel("second"),
            .panel("first"),
            .panel("fourth"),
            .panel("third"),
        ]
        XCTAssertNil(
            FloorpPanelRegistryReorder.move(
                in: multipleMoves.difference(from: initial).inferringMoves(),
                finalPanelIDs: ["second", "first", "fourth", "third"]
            )
        )
    }

    func testWebPanelAddressSummaryDistinguishesHTTPSHTTPAndInvalidInput() {
        XCTAssertEqual(
            FloorpWebPanelAddressSummary.make(urlText: "https://Example.COM/path"),
            FloorpWebPanelAddressSummary(host: "example.com", status: .secure)
        )
        XCTAssertEqual(
            FloorpWebPanelAddressSummary.make(urlText: "http://Example.COM/path"),
            FloorpWebPanelAddressSummary(host: "example.com", status: .insecureHTTP)
        )
        XCTAssertEqual(
            FloorpWebPanelAddressSummary.make(urlText: "javascript:alert(1)"),
            FloorpWebPanelAddressSummary(host: nil, status: .needsAttention)
        )
    }

    func testIconPickerUsesHumanReadableLocalizedNames() {
        for systemName in FloorpWebPanelValidator.curatedIconNames {
            let displayName = FloorpStrings.PanelRegistry.iconDisplayName(for: systemName)
            XCTAssertFalse(displayName.isEmpty)
            XCTAssertNotEqual(displayName, systemName)
        }
    }

    func testPanelRegistryErrorMapperUsesLocalizedSpecificMessages() {
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(
                for: FloorpPanelError.panelLimitReached(maximum: FloorpPanelManager.maximumPanelCount)
            ),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.panelLimitTitle,
                message: FloorpStrings.PanelRegistry.panelLimitMessage
            )
        )
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(for: FloorpPanelError.cannotRemoveLastPanel),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.lastPanelTitle,
                message: FloorpStrings.PanelRegistry.lastPanelMessage
            )
        )
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(for: FloorpPanelError.registryReadOnly),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.registryReadOnlyTitle,
                message: FloorpStrings.PanelRegistry.registryReadOnlyMessage
            )
        )
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(for: FloorpPanelError.editConflict(id: "panel")),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.editConflictTitle,
                message: FloorpStrings.PanelRegistry.editConflictMessage
            )
        )
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(
                for: FloorpWebPanelValidationError.unsupportedScheme
            ),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.validationFailedTitle,
                message: FloorpStrings.PanelRegistry.unsupportedSchemeMessage
            )
        )
        XCTAssertEqual(
            FloorpPanelRegistryErrorMapper.presentation(for: FloorpWebPanelValidationError.emptyTitle),
            FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.validationFailedTitle,
                message: FloorpStrings.PanelRegistry.invalidTitleMessage
            )
        )
    }
}
