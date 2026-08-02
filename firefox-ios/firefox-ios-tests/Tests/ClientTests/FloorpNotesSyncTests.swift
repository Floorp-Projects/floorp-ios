// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import XCTest
@testable import Client

final class FloorpNotesSyncMergeTests: XCTestCase, @unchecked Sendable {
    func testFirstSyncPreservesLocalOrderAndAppendsRemoteNewNotes() throws {
        let local = [note("local-b"), note("local-a")]
        let remote = [note("remote-c")]

        let result = try FloorpNotesSyncMerger.merge(base: [], local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id.rawValue), ["local-b", "local-a", "remote-c"])
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testOneSidedEditsAndDeletesMergeWithoutConflicts() throws {
        let base = [
            note("local-edit", content: "base"),
            note("local-delete", content: "base"),
            note("remote-edit", content: "base"),
            note("remote-delete", content: "base"),
        ]
        let local = [
            note("local-edit", content: "local", updatedAt: 20),
            note("remote-edit", content: "base"),
            note("remote-delete", content: "base"),
        ]
        let remote = [
            note("local-edit", content: "base"),
            note("local-delete", content: "base"),
            note("remote-edit", content: "remote", updatedAt: 30),
        ]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id.rawValue), ["local-edit", "remote-edit"])
        XCTAssertEqual(result.notes.first?.content, "local")
        XCTAssertEqual(result.notes.last?.content, "remote")
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testDeleteVersusEditKeepsTheEdit() throws {
        let base = [note("local-deleted", content: "base"), note("remote-deleted", content: "base")]
        let local = [note("remote-deleted", content: "local edit", updatedAt: 20)]
        let remote = [note("local-deleted", content: "remote edit", updatedAt: 30)]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id.rawValue), ["remote-deleted", "local-deleted"])
        XCTAssertEqual(result.notes.map(\.content), ["local edit", "remote edit"])
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testConcurrentEditsKeepDeterministicWinnerAndConflictCopy() throws {
        let base = [note("shared", title: "Base", content: "base", updatedAt: 10)]
        let local = [note("shared", title: "Local", content: "local", updatedAt: 20)]
        let remote = [note("shared", title: "Remote", content: "remote", updatedAt: 30)]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(result.notes[0], remote[0])
        XCTAssertEqual(result.notes[1].title, "Local (Conflict)")
        XCTAssertEqual(result.notes[1].content, "local")
        XCTAssertEqual(result.notes[1].updatedAt, local[0].updatedAt)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.notes[1].id, result.conflicts[0].conflictCopyID)
        XCTAssertTrue(result.notes[1].id.rawValue.hasPrefix("floorp-sync-conflict-"))
    }

    func testConflictCopyIDCollisionPreservesBothNotesWithDeterministicProbe() throws {
        let base = [note("shared", title: "Base", content: "base", updatedAt: 10)]
        let local = [note("shared", title: "Local", content: "local", updatedAt: 20)]
        let remote = [note("shared", title: "Remote", content: "remote", updatedAt: 30)]
        let initial = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)
        let collidingID = try XCTUnwrap(initial.conflicts.first?.conflictCopyID)
        let unrelated = note(
            collidingID,
            title: "Unrelated",
            content: "must survive",
            updatedAt: 40
        )

        let result = try FloorpNotesSyncMerger.merge(
            base: base + [unrelated],
            local: local + [unrelated],
            remote: remote + [unrelated]
        )

        XCTAssertEqual(result.notes.count, 3)
        XCTAssertEqual(result.notes.first(where: { $0.id == collidingID }), unrelated)
        XCTAssertTrue(result.notes.contains(where: { $0.content == "local" }))
        XCTAssertNotEqual(result.conflicts.first?.conflictCopyID, collidingID)
    }

    func testNestedConflictCollisionIsIndependentOfInputTraversalOrder() throws {
        let sharedBase = note("shared", title: "Base", content: "base", updatedAt: 10)
        let sharedLocal = note("shared", title: "Local", content: "local", updatedAt: 20)
        let sharedRemote = note("shared", title: "Remote", content: "remote", updatedAt: 30)
        let initial = try FloorpNotesSyncMerger.merge(
            base: [sharedBase],
            local: [sharedLocal],
            remote: [sharedRemote]
        )
        let collidingID = try XCTUnwrap(initial.conflicts.first?.conflictCopyID)
        let candidateWinner = try XCTUnwrap(initial.notes.first(where: { $0.id == collidingID }))
        let candidateBase = note(
            collidingID,
            title: "Candidate Base",
            content: "candidate base",
            updatedAt: 5
        )
        let candidateLoser = note(
            collidingID,
            title: "Candidate Remote",
            content: "candidate remote",
            updatedAt: 25
        )

        let sharedFirst = try FloorpNotesSyncMerger.merge(
            base: [sharedBase, candidateBase],
            local: [sharedLocal, candidateWinner],
            remote: [sharedRemote, candidateLoser]
        )
        let candidateFirst = try FloorpNotesSyncMerger.merge(
            base: [candidateBase, sharedBase],
            local: [candidateWinner, sharedLocal],
            remote: [candidateLoser, sharedRemote]
        )
        let sharedFirstByID = Dictionary(uniqueKeysWithValues: sharedFirst.notes.map { ($0.id, $0) })
        let candidateFirstByID = Dictionary(uniqueKeysWithValues: candidateFirst.notes.map { ($0.id, $0) })
        let sharedConflict = try XCTUnwrap(
            sharedFirst.conflicts.first(where: { $0.originalNoteID == FloorpNoteID("shared") })
        )

        XCTAssertEqual(sharedFirstByID, candidateFirstByID)
        XCTAssertEqual(sharedFirst.conflicts, candidateFirst.conflicts)
        XCTAssertEqual(sharedFirst.notes.count, 4)
        XCTAssertNotEqual(sharedConflict.conflictCopyID, collidingID)
    }

    func testNestedConflictWinnerReusesCandidateNearLimit() throws {
        let sharedBase = note("shared", title: "Base", content: "base", updatedAt: 10)
        let sharedLocal = note("shared", title: "Local", content: "local", updatedAt: 20)
        let sharedRemote = note("shared", title: "Remote", content: "remote", updatedAt: 30)
        let initial = try FloorpNotesSyncMerger.merge(
            base: [sharedBase],
            local: [sharedLocal],
            remote: [sharedRemote]
        )
        let collidingID = try XCTUnwrap(initial.conflicts.first?.conflictCopyID)
        let candidateWinner = try XCTUnwrap(initial.notes.first { $0.id == collidingID })
        let candidateBase = note(
            collidingID,
            title: "Candidate Base",
            content: "candidate base",
            updatedAt: 5
        )
        let candidateLoser = note(
            collidingID,
            title: "Candidate Remote",
            content: "candidate remote",
            updatedAt: 15
        )
        let filler = (0..<(FloorpNotesStore.maximumNoteCount - 3)).map { index in
            note("nested-filler-\(index)")
        }

        let result = try FloorpNotesSyncMerger.merge(
            base: [sharedBase, candidateBase] + filler,
            local: [sharedLocal, candidateWinner] + filler,
            remote: [sharedRemote, candidateLoser] + filler
        )

        XCTAssertEqual(result.notes.count, FloorpNotesStore.maximumNoteCount)
        XCTAssertEqual(result.notes.filter { $0.id == collidingID }, [candidateWinner])
        XCTAssertEqual(
            result.conflicts.first { $0.originalNoteID == FloorpNoteID("shared") }?.conflictCopyID,
            collidingID
        )
        XCTAssertNotNil(result.conflicts.first { $0.originalNoteID == collidingID })
    }

    func testTimestampTieIsCommutative() throws {
        let base = [note("shared", content: "base", updatedAt: 10)]
        let first = [note("shared", title: "Alpha", content: "first", updatedAt: 20)]
        let second = [note("shared", title: "Zulu", content: "second", updatedAt: 20)]

        let forward = try FloorpNotesSyncMerger.merge(base: base, local: first, remote: second)
        let reversed = try FloorpNotesSyncMerger.merge(base: base, local: second, remote: first)

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.notes.count, 2)
    }

    func testWireInvisibleContentFormatDoesNotChangeConflictIdentity() throws {
        let base = [note("shared", content: "base", updatedAt: 10)]
        let remote = [note("shared", content: "remote", updatedAt: 30)]
        let plainLocal = [
            note("shared", content: "local", updatedAt: 20, contentFormat: .plainText),
        ]
        let automaticLocal = [
            note("shared", content: "local", updatedAt: 20, contentFormat: .automatic),
        ]

        let plainResult = try FloorpNotesSyncMerger.merge(
            base: base,
            local: plainLocal,
            remote: remote
        )
        let automaticResult = try FloorpNotesSyncMerger.merge(
            base: base,
            local: automaticLocal,
            remote: remote
        )

        XCTAssertEqual(
            plainResult.conflicts.first?.conflictCopyID,
            automaticResult.conflicts.first?.conflictCopyID
        )
    }

    func testCanonicallyEquivalentRichSourcesRemainByteDistinctDuringMerge() throws {
        let prefix = #"{"root":{"children":[{"type":"future-node","text":""#
        let suffix = #""}],"type":"root","version":1}}"#
        let composed = prefix + "é" + suffix
        let decomposed = prefix + "e\u{301}" + suffix
        let composedTitle = "Café"
        let decomposedTitle = "Cafe\u{301}"
        let base = [
            note(
                "rich",
                title: composedTitle,
                content: composed,
                updatedAt: 10,
                contentFormat: .automatic
            ),
        ]
        let remote = [
            note(
                "rich",
                title: decomposedTitle,
                content: decomposed,
                updatedAt: 20,
                contentFormat: .automatic
            ),
        ]

        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertEqual(composedTitle, decomposedTitle)
        XCTAssertNotEqual(Data(composedTitle.utf8), Data(decomposedTitle.utf8))

        let result = try FloorpNotesSyncMerger.merge(base: base, local: base, remote: remote)
        let merged = try XCTUnwrap(result.notes.first)

        XCTAssertEqual(Data(merged.title.utf8), Data(decomposedTitle.utf8))
        XCTAssertEqual(Data(merged.content.utf8), Data(decomposed.utf8))
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testCanonicalEquivalentNoteIDsRemainDistinctAcrossRemoteNormalizationAndMerge() throws {
        let composedID = "note-\u{00E9}"
        let decomposedID = "note-e\u{0301}"
        let remotePayload = FloorpNotesDesktopPayload(
            ids: [composedID, decomposedID],
            titles: ["Composed", "Decomposed"],
            contents: ["A", "B"],
            createdAts: [1, 2],
            updatedAts: [1, 2]
        )

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: try remoteRecord(remotePayload),
            now: 100
        )
        XCTAssertEqual(
            plan.mergedNotes.map(\.id),
            [FloorpNoteID(composedID), FloorpNoteID(decomposedID)]
        )
        XCTAssertFalse(plan.requiresUpload)

        let directMerge = try FloorpNotesSyncMerger.merge(
            base: [],
            local: [note(composedID)],
            remote: [note(decomposedID)]
        )
        XCTAssertEqual(
            directMerge.notes.map(\.id),
            [FloorpNoteID(composedID), FloorpNoteID(decomposedID)]
        )
        XCTAssertTrue(directMerge.conflicts.isEmpty)
    }

    func testCanonicallyEquivalentLocalRichEditStillRequiresUpload() throws {
        let prefix = #"{"type":"doc","content":[{"type":"text","text":""#
        let suffix = #""}]}"#
        let composed = prefix + "é" + suffix
        let decomposed = prefix + "e\u{301}" + suffix
        let base = [
            note("rich", content: composed, updatedAt: 10, contentFormat: .automatic),
        ]
        let local = [
            note("rich", content: decomposed, updatedAt: 10, contentFormat: .automatic),
        ]
        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: base),
            localNotes: local,
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(notes: base)),
            now: 100
        )

        XCTAssertTrue(plan.requiresUpload)
        let payload = try JSONDecoder().decode(
            FloorpNotesDesktopPayload.self,
            from: try XCTUnwrap(plan.uploadPayloadData)
        )
        let uploaded = try XCTUnwrap(payload.contents.first)
        XCTAssertEqual(Data(uploaded.utf8), Data(decomposed.utf8))
    }

    func testRetryDoesNotDuplicateConflictCopy() throws {
        let base = [note("shared", content: "base", updatedAt: 10)]
        let local = [note("shared", content: "local", updatedAt: 20)]
        let remote = [note("shared", content: "remote", updatedAt: 30)]
        let first = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        let retry = try FloorpNotesSyncMerger.merge(
            base: base,
            local: first.notes,
            remote: remote
        )

        XCTAssertEqual(retry.notes, first.notes)
        XCTAssertTrue(retry.conflicts.isEmpty)
    }

    func testRetryAfterUploadedConflictAndFailedLocalCommitReusesCopyNearLimit() throws {
        let filler = (1..<(FloorpNotesStore.maximumNoteCount - 1)).map { index in
            note("note-\(index)")
        }
        let base = [note("shared", content: "base", updatedAt: 10)] + filler
        let localBeforeUpload = [note("shared", content: "local", updatedAt: 20)] + filler
        let firstRemote = [note("shared", content: "remote", updatedAt: 30)] + filler
        let first = try FloorpNotesSyncMerger.merge(
            base: base,
            local: localBeforeUpload,
            remote: firstRemote
        )
        let conflictID = try XCTUnwrap(first.conflicts.first?.conflictCopyID)
        let uploadedConflict = try XCTUnwrap(first.notes.first { $0.id == conflictID })
        let remoteAfterWinnerEdit = first.notes.map { candidate in
            candidate.id == FloorpNoteID("shared")
                ? note("shared", content: "remote edited again", updatedAt: 40)
                : candidate
        }

        // The upload succeeded but the local atomic commit failed, so the old
        // base/local snapshot is retried against the uploaded result. A later
        // edit to only the winner must not change any conflict-copy wire field.
        let retry = try FloorpNotesSyncMerger.merge(
            base: base,
            local: localBeforeUpload,
            remote: remoteAfterWinnerEdit
        )

        XCTAssertEqual(first.notes.count, FloorpNotesStore.maximumNoteCount)
        XCTAssertEqual(retry.notes.count, FloorpNotesStore.maximumNoteCount)
        XCTAssertEqual(retry.notes.filter { $0.id == conflictID }, [uploadedConflict])
        XCTAssertEqual(retry.conflicts.first?.conflictCopyID, conflictID)
    }

    func testOneSidedRemoteReorderWins() throws {
        let base = [note("a"), note("b"), note("c")]
        let remote = [base[2], base[0], base[1]]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: base, remote: remote)

        XCTAssertEqual(result.notes.map(\.id.rawValue), ["c", "a", "b"])
    }

    func testConcurrentReorderPrefersLocalAndAppendsRemoteNew() throws {
        let base = [note("a"), note("b"), note("c")]
        let local = [base[1], base[0], base[2], note("local-new")]
        let remote = [base[2], base[1], base[0], note("remote-new")]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id.rawValue), ["b", "a", "c", "local-new", "remote-new"])
    }

    func testDuplicateAndBlankIDsAreRejectedBySource() {
        XCTAssertThrowsError(
            try FloorpNotesSyncMerger.merge(
                base: [note("duplicate"), note("duplicate")],
                local: [],
                remote: []
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .duplicateNoteID(source: .base, id: FloorpNoteID("duplicate"))
            )
        }
        XCTAssertThrowsError(
            try FloorpNotesSyncMerger.merge(
                base: [],
                local: [note("  ")],
                remote: []
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .invalidNoteID(source: .local, index: 0)
            )
        }
        XCTAssertThrowsError(
            try FloorpNotesSyncMerger.merge(
                base: [],
                local: [],
                remote: [note("duplicate"), note("duplicate")]
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .duplicateNoteID(source: .remote, id: FloorpNoteID("duplicate"))
            )
        }
    }

    func testConflictAtMaximumCountIsRejected() {
        let base = (0..<FloorpNotesStore.maximumNoteCount).map { note("note-\($0)") }
        var local = base
        var remote = base
        local[0] = note("note-0", content: "local", updatedAt: 20)
        remote[0] = note("note-0", content: "remote", updatedAt: 30)

        XCTAssertThrowsError(
            try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .tooManyNotes(FloorpNotesStore.maximumNoteCount + 1)
            )
        }
    }

    func testPlannerNormalizesLegacyPayloadDeterministicallyAndRoundTripsArrays() throws {
        let record = try remoteRecord(
            FloorpNotesDesktopPayload(
                titles: ["One", "Two"],
                contents: ["First", "Second"]
            )
        )

        let first = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: record,
            now: 100
        )
        let second = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: record,
            now: 100
        )
        let payload = try JSONDecoder().decode(
            FloorpNotesDesktopPayload.self,
            from: try XCTUnwrap(first.uploadPayloadData)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(payload.ids, first.mergedNotes.map(\.id.rawValue))
        XCTAssertEqual(payload.titles, ["One", "Two"])
        XCTAssertEqual(payload.contents, ["First", "Second"])
        XCTAssertEqual(payload.createdAts, [100, 100])
        XCTAssertEqual(payload.updatedAts, [100, 100])
        XCTAssertTrue(first.requiresUpload)
    }

    func testPlannerPreservesOpaqueLexicalAndTipTapSourcesByteForByte() throws {
        let lexical = """
        {"root":{"children":[{"type":"future-lexical","version":9,"text":"雪"}],"type":"root","version":1}}
        """
        let tipTap = """
        {"type":"doc","content":[{"type":"futureBlock","attrs":{"opaque":true},"content":[]}]}
        """
        let remoteNotes = [
            note("lexical", content: lexical, contentFormat: .automatic),
            note("tiptap", content: tipTap, contentFormat: .automatic),
        ]
        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(notes: remoteNotes)),
            now: 100
        )

        XCTAssertFalse(plan.requiresUpload)
        XCTAssertNil(plan.uploadPayloadData)
        XCTAssertEqual(
            plan.mergedNotes.map { Data($0.content.utf8) },
            remoteNotes.map { Data($0.content.utf8) }
        )
    }

    func testPlannerRejectsMissingRemoteIDsAfterInitialSync() throws {
        let existing = [note("stable", title: "One", content: "First")]
        let legacyRecord = try remoteRecord(
            FloorpNotesDesktopPayload(titles: ["One"], contents: ["First"])
        )

        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: FloorpNotesSyncBaseState(accountID: "account", notes: existing),
                localNotes: existing,
                remoteRecord: legacyRecord,
                now: 100
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .missingRemoteIDsAfterInitialSync
            )
        }
    }

    func testLegacyEmptyRemotePayloadCanExplicitlyDeleteEstablishedNotes() throws {
        let existing = [note("stable", title: "One", content: "First")]
        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: existing),
            localNotes: existing,
            remoteRecord: try remoteRecord(
                FloorpNotesDesktopPayload(titles: [], contents: [])
            ),
            now: 100
        )

        XCTAssertEqual(plan.mergedNotes, [])
        XCTAssertTrue(plan.requiresUpload)
        XCTAssertNotNil(plan.uploadPayloadData)
    }

    func testPlannerUsesTitlesAsCanonicalCountAndIgnoresSurplusArrays() throws {
        let record = try remoteRecord(
            FloorpNotesDesktopPayload(
                ids: ["one"],
                titles: ["One"],
                contents: ["Body", "Ghost body"],
                createdAts: [10, 20],
                updatedAts: [11, 21]
            )
        )

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: record,
            now: 100
        )

        XCTAssertEqual(plan.mergedNotes.map(\.id.rawValue), ["one"])
        XCTAssertEqual(plan.mergedNotes.map(\.content), ["Body"])
        XCTAssertEqual(plan.mergedNotes.map(\.createdAt), [10])
        XCTAssertEqual(plan.mergedNotes.map(\.updatedAt), [11])
        XCTAssertTrue(plan.requiresUpload)
    }

    func testPlannerFillsShortContentAndTimestampArrays() throws {
        let record = try remoteRecord(
            FloorpNotesDesktopPayload(
                ids: ["one", "two"],
                titles: ["One", "Two"],
                contents: ["Body"],
                createdAts: [10],
                updatedAts: []
            )
        )

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: [],
            remoteRecord: record,
            now: 100
        )

        XCTAssertEqual(plan.mergedNotes.map(\.content), ["Body", ""])
        XCTAssertEqual(plan.mergedNotes.map(\.createdAt), [10, 100])
        XCTAssertEqual(plan.mergedNotes.map(\.updatedAt), [10, 100])
    }

    func testPlannerRejectsMalformedExplicitRemoteIDs() throws {
        let mismatched = try remoteRecord(
            FloorpNotesDesktopPayload(
                ids: ["one"],
                titles: ["One", "Two"],
                contents: ["First", "Second"]
            )
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: mismatched
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesSyncError, .invalidRemotePayload)
        }

        let blank = try remoteRecord(
            FloorpNotesDesktopPayload(ids: ["  "], titles: ["One"], contents: ["Body"])
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: blank
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .invalidNoteID(source: .remote, index: 0)
            )
        }

        let duplicate = try remoteRecord(
            FloorpNotesDesktopPayload(
                ids: ["same", "same"],
                titles: ["One", "Two"],
                contents: ["First", "Second"]
            )
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: duplicate
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .duplicateNoteID(source: .remote, id: FloorpNoteID("same"))
            )
        }
    }

    func testPlannerPreservesExactWhitespaceInNonblankRemoteID() throws {
        let exactID = " note-id "
        let local = [note(exactID, contentFormat: .automatic)]
        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: local),
            localNotes: local,
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(notes: local)),
            now: 100
        )

        XCTAssertEqual(plan.mergedNotes.map(\.id.rawValue), [exactID])
        XCTAssertFalse(plan.requiresUpload)
        XCTAssertNil(plan.uploadPayloadData)
    }

    func testPlannerRejectsUnknownRemoteFields() {
        let record = FloorpNotesSyncRemoteRecord(
            remoteNotes: .notesString(
                Data(#"{"titles":[],"contents":[],"future":true}"#.utf8)
            ),
            revision: "remote-1",
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )

        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: record
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .unsupportedRemoteFields(["future"])
            )
        }
    }

    func testPlannerRejectsInconsistentMissingRecordRepresentation() throws {
        let payloadData = try JSONEncoder().encode(FloorpNotesDesktopPayload(notes: []))
        let bytesWithoutRevision = FloorpNotesSyncRemoteRecord(
            remoteNotes: .notesString(payloadData),
            revision: nil,
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )
        let revisionWithoutBytes = FloorpNotesSyncRemoteRecord(
            remoteNotes: .recordMissing,
            revision: "remote-1",
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )

        for record in [bytesWithoutRevision, revisionWithoutBytes] {
            XCTAssertThrowsError(
                try FloorpNotesSyncPlanner.makePlan(
                    accountID: "account",
                    baseState: nil,
                    localNotes: [],
                    remoteRecord: record
                )
            ) { error in
                XCTAssertEqual(error as? FloorpNotesSyncError, .invalidRemotePayload)
            }
        }
    }

    func testPlannerRejectsAccountSchemaAndLimitErrors() throws {
        let emptyRemoteRecord = try remoteRecord(
            FloorpNotesDesktopPayload(titles: [], contents: [])
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: " ",
                baseState: nil,
                localNotes: [],
                remoteRecord: emptyRemoteRecord
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesSyncError, .emptyAccountID)
        }

        let future = FloorpNotesSyncBaseState(
            schemaVersion: 99,
            accountID: "account",
            notes: []
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: future,
                localNotes: [],
                remoteRecord: emptyRemoteRecord
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesSyncError, .unsupportedBaseSchema(99))
        }

        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "new-account",
                baseState: FloorpNotesSyncBaseState(accountID: "old-account", notes: []),
                localNotes: [],
                remoteRecord: emptyRemoteRecord
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .baseAccountMismatch(expected: "new-account", actual: "old-account")
            )
        }

        let invalidLimit = FloorpNotesSyncRemoteRecord(
            remoteNotes: emptyRemoteRecord.remoteNotes,
            revision: emptyRemoteRecord.revision,
            maximumEncodedNotesValueBytes: 0
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: invalidLimit
            )
        ) { error in
            XCTAssertEqual(error as? FloorpNotesSyncError, .invalidRecordLimit(0))
        }
    }

    func testPlannerRejectsOversizedIncomingRecordBeforeMerge() throws {
        let payload = FloorpNotesDesktopPayload(
            titles: ["Title"],
            contents: [String(repeating: "x", count: 100)]
        )
        let encoded = try JSONEncoder().encode(payload)
        let payloadData = Data(" \n".utf8) + encoded
        let actualBytes = try FloorpNotesSyncPlanner.encodedNotesValueByteCount(
            payloadData: payloadData
        )
        let record = FloorpNotesSyncRemoteRecord(
            remoteNotes: .notesString(payloadData),
            revision: "remote-oversized",
            maximumEncodedNotesValueBytes: actualBytes - 1
        )

        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: record,
                now: 100
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .recordTooLarge(actualBytes: actualBytes, maximumBytes: actualBytes - 1)
            )
        }
    }

    func testEncodedPayloadHonorsExactRecordBoundary() throws {
        let notes = [note("boundary", title: "Title", content: "Body")]
        let data = try FloorpNotesSyncPlanner.encodedPayload(
            notes: notes,
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )
        let encodedValueBytes = try FloorpNotesSyncPlanner.encodedNotesValueByteCount(
            payloadData: data
        )

        XCTAssertEqual(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumEncodedNotesValueBytes: encodedValueBytes
            ),
            data
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumEncodedNotesValueBytes: encodedValueBytes - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .recordTooLarge(
                    actualBytes: encodedValueBytes,
                    maximumBytes: encodedValueBytes - 1
                )
            )
        }
    }

    func testNoOpPlanDoesNotRequireCanonicalPayloadToFitUploadBudget() throws {
        let timestamp: Int64 = 1_000_000_000_000_000_000
        let note = note(
            "same",
            title: "T",
            content: "B",
            createdAt: timestamp,
            updatedAt: timestamp,
            contentFormat: .automatic
        )
        let payloadData = Data(
            #"{"ids":["same"],"titles":["T"],"contents":["B"],"createdAts":[1e18],"updatedAts":[1e18]}"#.utf8
        )
        let record = FloorpNotesSyncRemoteRecord(
            remoteNotes: .notesString(payloadData),
            revision: "remote-1",
            maximumEncodedNotesValueBytes: try FloorpNotesSyncPlanner
                .encodedNotesValueByteCount(payloadData: payloadData)
        )

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: [note]),
            localNotes: [note],
            remoteRecord: record,
            now: timestamp
        )

        XCTAssertFalse(plan.requiresUpload)
        XCTAssertNil(plan.uploadPayloadData)
    }

    func testMissingRemoteRecordRetainsLocalNotesAndInvalidatesOldBase() throws {
        let local = [note("local", content: "keep")]
        let record = FloorpNotesSyncRemoteRecord(
            remoteNotes: .recordMissing,
            revision: nil,
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: local),
            localNotes: local,
            remoteRecord: record,
            now: 100
        )

        XCTAssertEqual(plan.mergedNotes, local)
        XCTAssertEqual(plan.nextBaseState.notes, local)
        XCTAssertTrue(plan.requiresUpload)
    }

    func testPresentAggregateWithoutNotesAppliesRemoteDeletionWithoutResettingBase() throws {
        let existing = [note("established", content: "unchanged")]

        for remoteNotes in [
            FloorpNotesSyncRemoteNotes.notesKeyMissing,
            .notesNull,
        ] {
            let plan = try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: FloorpNotesSyncBaseState(accountID: "account", notes: existing),
                localNotes: existing,
                remoteRecord: FloorpNotesSyncRemoteRecord(
                    remoteNotes: remoteNotes,
                    revision: "42",
                    maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
                ),
                now: 100
            )

            XCTAssertEqual(plan.mergedNotes, [])
            XCTAssertFalse(plan.requiresUpload)
        }
    }

    func testRunnerDoesNotAdvanceBaseWhenUploadFails() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .failure(TestSyncFailure.upload)
        )
        let commitStore = TestNotesSyncCommitStore()

        do {
            try await FloorpNotesSyncRunner.run(
                accountID: "account",
                baseState: nil,
                localSnapshot: FloorpNotesSnapshot(revision: 7, notes: [note("local")]),
                transport: transport,
                commitStore: commitStore,
                now: 100
            )
            XCTFail("Expected upload failure")
        } catch {
            XCTAssertEqual(error as? TestSyncFailure, .upload)
        }
        let commits = await commitStore.commits()
        XCTAssertEqual(commits, [])
    }

    func testRunnerPreflightsLocalPersistenceBeforeUpload() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .success(FloorpNotesSyncUploadReceipt(revision: "must-not-upload"))
        )
        let commitStore = TestNotesSyncCommitStore(prepareFailure: .prepare)

        do {
            try await FloorpNotesSyncRunner.run(
                accountID: "account",
                baseState: nil,
                localSnapshot: FloorpNotesSnapshot(revision: 8, notes: [note("local")]),
                transport: transport,
                commitStore: commitStore,
                now: 100
            )
            XCTFail("Expected prepare failure")
        } catch {
            XCTAssertEqual(error as? TestSyncFailure, .prepare)
        }

        let uploadCount = await transport.uploadCount()
        let commits = await commitStore.commits()
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(commits, [])
    }

    func testRunnerCommitsNotesAndBaseOnlyAfterConfirmedUpload() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .success(FloorpNotesSyncUploadReceipt(revision: "uploaded-2"))
        )
        let commitStore = TestNotesSyncCommitStore()

        let result = try await FloorpNotesSyncRunner.run(
            accountID: " account ",
            baseState: nil,
            localSnapshot: FloorpNotesSnapshot(revision: 42, notes: [note("local")]),
            transport: transport,
            commitStore: commitStore,
            now: 100
        )
        let commits = await commitStore.commits()
        let fetchedAccountIDs = await transport.fetchedAccountIDs()
        let expectedRevisions = await transport.uploadedExpectedRevisions()

        XCTAssertEqual(result, FloorpNotesSyncRunResult(remoteRevision: "uploaded-2", didUpload: true))
        XCTAssertEqual(fetchedAccountIDs, ["account"])
        XCTAssertEqual(expectedRevisions, ["remote-1"])
        XCTAssertEqual(commits.count, 1)
        let candidate = commits[0].prepared.candidate
        XCTAssertEqual(candidate.accountID, "account")
        XCTAssertEqual(candidate.expectedLocalRevision, 42)
        XCTAssertEqual(candidate.notes.map(\.id.rawValue), ["local"])
        XCTAssertEqual(candidate.baseState.notes, candidate.notes)
        XCTAssertEqual(commits[0].confirmedRemoteRevision, "uploaded-2")
        XCTAssertTrue(commits[0].didUpload)
    }

    func testNoOpSyncDoesNotUploadButAdvancesBase() async throws {
        let local = [note("same", contentFormat: .automatic)]
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(notes: local)),
            uploadResult: .failure(TestSyncFailure.upload)
        )
        let commitStore = TestNotesSyncCommitStore()

        let result = try await FloorpNotesSyncRunner.run(
            accountID: "account",
            baseState: FloorpNotesSyncBaseState(accountID: "account", notes: local),
            localSnapshot: FloorpNotesSnapshot(revision: 9, notes: local),
            transport: transport,
            commitStore: commitStore,
            now: 100
        )

        XCTAssertEqual(result, FloorpNotesSyncRunResult(remoteRevision: "remote-1", didUpload: false))
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 0)
        let commits = await commitStore.commits()
        XCTAssertEqual(commits.count, 1)
        XCTAssertFalse(commits[0].didUpload)
        XCTAssertEqual(commits[0].prepared.candidate.baseState.notes, local)
    }

    func testFinalCASFailureDoesNotRecordLocalCommit() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .success(FloorpNotesSyncUploadReceipt(revision: "uploaded"))
        )
        let commitStore = TestNotesSyncCommitStore(commitFailure: .commit)

        do {
            try await FloorpNotesSyncRunner.run(
                accountID: "account",
                baseState: nil,
                localSnapshot: FloorpNotesSnapshot(revision: 11, notes: [note("local")]),
                transport: transport,
                commitStore: commitStore,
                now: 100
            )
            XCTFail("Expected final CAS failure")
        } catch {
            XCTAssertEqual(error as? TestSyncFailure, .commit)
        }

        let uploadCount = await transport.uploadCount()
        let commitAttemptCount = await commitStore.commitAttemptCount()
        let commits = await commitStore.commits()
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(commitAttemptCount, 1)
        XCTAssertEqual(commits, [])
    }

    func testCancellationDuringFetchPreventsPrepareUploadAndCommit() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .success(FloorpNotesSyncUploadReceipt(revision: "unused")),
            cancelDuringFetch: true
        )
        let commitStore = TestNotesSyncCommitStore()
        let operation = Task {
            try await FloorpNotesSyncRunner.run(
                accountID: "account",
                baseState: nil,
                localSnapshot: FloorpNotesSnapshot(revision: 1, notes: []),
                transport: transport,
                commitStore: commitStore,
                now: 100
            )
        }

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let preparationCount = await commitStore.preparationCount()
        let uploadCount = await transport.uploadCount()
        let commits = await commitStore.commits()
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(commits, [])
    }

    func testCancellationDuringUploadPreventsCommit() async throws {
        let transport = TestNotesSyncTransport(
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(titles: [], contents: [])),
            uploadResult: .success(FloorpNotesSyncUploadReceipt(revision: "uploaded")),
            cancelDuringUpload: true
        )
        let commitStore = TestNotesSyncCommitStore()
        let operation = Task {
            try await FloorpNotesSyncRunner.run(
                accountID: "account",
                baseState: nil,
                localSnapshot: FloorpNotesSnapshot(revision: 1, notes: [note("local")]),
                transport: transport,
                commitStore: commitStore,
                now: 100
            )
        }

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let preparationCount = await commitStore.preparationCount()
        let uploadCount = await transport.uploadCount()
        let commits = await commitStore.commits()
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(commits, [])
    }

    private func remoteRecord(
        _ payload: FloorpNotesDesktopPayload,
        revision: String? = "remote-1",
        maximumEncodedNotesValueBytes: Int = FloorpNotesStore.maximumArchiveBytes
    ) throws -> FloorpNotesSyncRemoteRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return FloorpNotesSyncRemoteRecord(
            remoteNotes: .notesString(try encoder.encode(payload)),
            revision: revision,
            maximumEncodedNotesValueBytes: maximumEncodedNotesValueBytes
        )
    }

    private func note(
        _ id: String,
        title: String = "Title",
        content: String = "Body",
        createdAt: Int64 = 1,
        updatedAt: Int64 = 1,
        contentFormat: FloorpNoteContentFormat = .plainText
    ) -> FloorpNote {
        note(
            FloorpNoteID(id),
            title: title,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            contentFormat: contentFormat
        )
    }

    private func note(
        _ id: FloorpNoteID,
        title: String = "Title",
        content: String = "Body",
        createdAt: Int64 = 1,
        updatedAt: Int64 = 1,
        contentFormat: FloorpNoteContentFormat = .plainText
    ) -> FloorpNote {
        makeFloorpTestNote(
            id: id,
            title: title,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            contentFormat: contentFormat
        )
    }
}

final class FloorpNotesApplicationServicesAdapterTests: XCTestCase {
    func testTypedRemoteStatesMapWithoutConflation() throws {
        let notesValue = #"{"ids":[],"titles":[],"contents":[],"createdAts":[],"updatedAts":[]}"#
        let cases = [
            ApplicationServicesRemoteStateCase(
                remoteNotes: .recordMissing,
                modified: nil,
                expectedNotes: .recordMissing,
                expectedRevision: nil
            ),
            ApplicationServicesRemoteStateCase(
                remoteNotes: .notesKeyMissing,
                modified: 41,
                expectedNotes: .notesKeyMissing,
                expectedRevision: "41"
            ),
            ApplicationServicesRemoteStateCase(
                remoteNotes: .notesNull,
                modified: 42,
                expectedNotes: .notesNull,
                expectedRevision: "42"
            ),
            ApplicationServicesRemoteStateCase(
                remoteNotes: .notesString(value: notesValue),
                modified: 43,
                expectedNotes: .notesString(Data(notesValue.utf8)),
                expectedRevision: "43"
            ),
        ]

        for testCase in cases {
            let record = try FloorpNotesApplicationServicesAdapter.remoteRecord(
                from: FloorpNotesApplicationServicesPrepareInput(
                    remoteNotes: testCase.remoteNotes,
                    remoteRecordModifiedMillis: testCase.modified,
                    collectionModifiedMillis: 99,
                    maximumNotesValueBytes: 4_096
                )
            )

            XCTAssertEqual(record.remoteNotes, testCase.expectedNotes)
            XCTAssertEqual(record.revision, testCase.expectedRevision)
            XCTAssertEqual(record.maximumEncodedNotesValueBytes, 4_096)
        }
    }

    func testTypedRemoteStateRejectsInconsistentRecordModification() {
        let invalidInputs = [
            FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: .recordMissing,
                remoteRecordModifiedMillis: 1,
                collectionModifiedMillis: 1,
                maximumNotesValueBytes: 100
            ),
            FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: .notesKeyMissing,
                remoteRecordModifiedMillis: nil,
                collectionModifiedMillis: 1,
                maximumNotesValueBytes: 100
            ),
            FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: .notesNull,
                remoteRecordModifiedMillis: nil,
                collectionModifiedMillis: 1,
                maximumNotesValueBytes: 100
            ),
            FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: .notesString(value: "{}"),
                remoteRecordModifiedMillis: nil,
                collectionModifiedMillis: 1,
                maximumNotesValueBytes: 100
            ),
        ]

        for input in invalidInputs {
            XCTAssertThrowsError(
                try FloorpNotesApplicationServicesAdapter.remoteRecord(from: input)
            ) { error in
                XCTAssertEqual(
                    error as? FloorpNotesSyncError,
                    .invalidApplicationServicesBoundary
                )
            }
        }
    }

    func testOuterJSONStringEscapingDefinesApplicationServicesBudget() throws {
        let notes = [
            makeFloorpTestNote(
                id: "escaped",
                title: "Quote \" slash / backslash \\",
                content: "first\nsecond\t\"quoted\"\\tail",
                createdAt: 1,
                updatedAt: 2,
                contentFormat: .plainText
            ),
        ]
        let roomyPayload = try FloorpNotesSyncPlanner.encodedPayload(
            notes: notes,
            maximumEncodedNotesValueBytes: FloorpNotesStore.maximumArchiveBytes
        )
        let outerBytes = try FloorpNotesSyncPlanner.encodedNotesValueByteCount(
            payloadData: roomyPayload
        )

        XCTAssertGreaterThan(outerBytes, roomyPayload.count + 2)
        XCTAssertEqual(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumEncodedNotesValueBytes: outerBytes
            ),
            roomyPayload
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumEncodedNotesValueBytes: outerBytes - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .recordTooLarge(actualBytes: outerBytes, maximumBytes: outerBytes - 1)
            )
        }

        let incomingRecord = try FloorpNotesApplicationServicesAdapter.remoteRecord(
            from: FloorpNotesApplicationServicesPrepareInput(
                remoteNotes: .notesString(value: String(decoding: roomyPayload, as: UTF8.self)),
                remoteRecordModifiedMillis: 7,
                collectionModifiedMillis: 8,
                maximumNotesValueBytes: UInt64(outerBytes - 1)
            )
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.makePlan(
                accountID: "account",
                baseState: nil,
                localNotes: [],
                remoteRecord: incomingRecord,
                now: 100
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .recordTooLarge(actualBytes: outerBytes, maximumBytes: outerBytes - 1)
            )
        }
    }

    func testCurrentRuntimeEvidenceCannotEnableNetworkSync() {
        XCTAssertFalse(FloorpNotesSyncReleaseGate.isNetworkSyncEnabled)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: FloorpNotesSyncReleaseGate.mergeContractVersion,
                    fixtureSHA256: FloorpNotesSyncReleaseGate.mergeFixtureSHA256,
                    currentDesktopContractVersion: nil,
                    coordinatedDesktopMigrationVersion: nil,
                    linkedApplicationServicesContractVersion:
                        FloorpNotesApplicationServicesAdapter.transportContractVersion
                )
            )
        )
    }

    func testReleaseGateAcceptsOnlyExactDesktopOrCoordinatedMigrationContract() {
        let baseEvidence = FloorpNotesSyncReleaseEvidence(
            fixtureContractVersion: FloorpNotesSyncReleaseGate.mergeContractVersion,
            fixtureSHA256: FloorpNotesSyncReleaseGate.mergeFixtureSHA256,
            currentDesktopContractVersion: nil,
            coordinatedDesktopMigrationVersion: nil,
            linkedApplicationServicesContractVersion:
                FloorpNotesApplicationServicesAdapter.transportContractVersion
        )

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: baseEvidence.fixtureContractVersion,
                    fixtureSHA256: baseEvidence.fixtureSHA256,
                    currentDesktopContractVersion: FloorpNotesSyncReleaseGate.mergeContractVersion,
                    coordinatedDesktopMigrationVersion: nil,
                    linkedApplicationServicesContractVersion:
                        baseEvidence.linkedApplicationServicesContractVersion
                )
            )
        )
        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: baseEvidence.fixtureContractVersion,
                    fixtureSHA256: baseEvidence.fixtureSHA256,
                    currentDesktopContractVersion: nil,
                    coordinatedDesktopMigrationVersion:
                        FloorpNotesSyncReleaseGate.mergeContractVersion,
                    linkedApplicationServicesContractVersion:
                        baseEvidence.linkedApplicationServicesContractVersion
                )
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: "other-fixtures",
                    fixtureSHA256: baseEvidence.fixtureSHA256,
                    currentDesktopContractVersion: FloorpNotesSyncReleaseGate.mergeContractVersion,
                    coordinatedDesktopMigrationVersion: nil,
                    linkedApplicationServicesContractVersion:
                        baseEvidence.linkedApplicationServicesContractVersion
                )
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: baseEvidence.fixtureContractVersion,
                    fixtureSHA256: "partial-desktop-fixture",
                    currentDesktopContractVersion: FloorpNotesSyncReleaseGate.mergeContractVersion,
                    coordinatedDesktopMigrationVersion: nil,
                    linkedApplicationServicesContractVersion:
                        baseEvidence.linkedApplicationServicesContractVersion
                )
            )
        )
    }
}

private struct ApplicationServicesRemoteStateCase {
    let remoteNotes: FloorpNotesApplicationServicesRemoteNotes
    let modified: Int64?
    let expectedNotes: FloorpNotesSyncRemoteNotes
    let expectedRevision: String?
}

final class FloorpNotesSyncCompatibilityFixtureTests: XCTestCase {
    func testSharedMergeFixturesMatchIOSAndKeepProductionDesktopGated() throws {
        let resourceURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "floorp-notes-merge-v1",
                withExtension: "json"
            )
        )
        let fixtureData = try Data(contentsOf: resourceURL)
        let fixtureSHA256 = SHA256.hash(data: fixtureData)
            .map { String(format: "%02x", $0) }
            .joined()
        let fixture = try JSONDecoder().decode(
            FloorpNotesMergeFixture.self,
            from: fixtureData
        )

        XCTAssertEqual(fixture.fixtureSchemaVersion, 2)
        XCTAssertEqual(
            fixture.contractVersion,
            FloorpNotesSyncReleaseGate.mergeContractVersion
        )
        XCTAssertEqual(fixtureSHA256, FloorpNotesSyncReleaseGate.mergeFixtureSHA256)
        XCTAssertEqual(fixture.wirePayloadVersion, 1)
        XCTAssertEqual(
            fixture.productionDesktopObservation.commit,
            FloorpNotesSyncReleaseGate.observedProductionDesktopCommit
        )
        XCTAssertNil(fixture.productionDesktopObservation.declaredContractVersion)
        XCTAssertFalse(fixture.productionDesktopObservation.matchesFixtureContract)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsNetworkSync(
                FloorpNotesSyncReleaseEvidence(
                    fixtureContractVersion: fixture.contractVersion,
                    fixtureSHA256: fixtureSHA256,
                    currentDesktopContractVersion:
                        fixture.productionDesktopObservation.declaredContractVersion,
                    coordinatedDesktopMigrationVersion: nil,
                    linkedApplicationServicesContractVersion:
                        FloorpNotesApplicationServicesAdapter.transportContractVersion
                )
            )
        )

        let mergeCaseNames = fixture.mergeCases.map { $0.name }
        let sequenceCaseNames = fixture.sequenceCases.map { $0.name }
        let errorCaseNames = fixture.errorCases.map { $0.name }
        let actualCaseNames = mergeCaseNames + sequenceCaseNames + errorCaseNames
        XCTAssertEqual(actualCaseNames.count, Set(actualCaseNames).count)
        XCTAssertEqual(
            fixture.requiredCaseNames.count,
            Set(fixture.requiredCaseNames).count
        )
        XCTAssertEqual(Set(actualCaseNames), Set(fixture.requiredCaseNames))

        for fixtureCase in fixture.mergeCases {
            _ = try run(fixtureCase)
        }

        for sequence in fixture.sequenceCases {
            var resultsByStep = [String: FloorpNotesSyncMergeResult]()
            for (index, step) in sequence.steps.enumerated() {
                if index == 0 {
                    XCTAssertNil(step.transitionFromPrevious, sequence.name)
                } else {
                    XCTAssertNotNil(step.transitionFromPrevious, sequence.name)
                }
                resultsByStep[step.name] = try run(step)
            }

            for invariant in sequence.invariants {
                switch invariant.kind {
                case .sameConflictCopy:
                    let fromResult = try XCTUnwrap(resultsByStep[invariant.fromStep])
                    let toResult = try XCTUnwrap(resultsByStep[invariant.toStep])
                    let fromID = try XCTUnwrap(
                        fromResult.conflicts.first {
                            $0.originalNoteID == FloorpNoteID(invariant.originalNoteID)
                        }?.conflictCopyID
                    )
                    let toID = try XCTUnwrap(
                        toResult.conflicts.first {
                            $0.originalNoteID == FloorpNoteID(invariant.originalNoteID)
                        }?.conflictCopyID
                    )
                    XCTAssertEqual(fromID, toID, sequence.name)
                    let fromNote = try XCTUnwrap(
                        fromResult.notes.first { $0.id == fromID }
                    )
                    let toNote = try XCTUnwrap(toResult.notes.first { $0.id == toID })
                    assertWireNotesEqual([fromNote], [toNote], sequence.name)
                }
            }
        }

        for errorCase in fixture.errorCases {
            XCTAssertThrowsError(
                try FloorpNotesSyncMerger.merge(
                    base: errorCase.base.map { $0.note },
                    local: errorCase.local.map { $0.note },
                    remote: errorCase.remote.map { $0.note }
                ),
                errorCase.name
            ) { error in
                XCTAssertEqual(
                    observedFixtureError(error),
                    errorCase.expectedError,
                    errorCase.name
                )
            }
        }
    }

    private func run(
        _ fixtureCase: FloorpNotesMergeFixture.MergeVector
    ) throws -> FloorpNotesSyncMergeResult {
        let result = try FloorpNotesSyncMerger.merge(
            base: fixtureCase.base.map(\.note),
            local: fixtureCase.local.map(\.note),
            remote: fixtureCase.remote.map(\.note)
        )
        let expectedConflicts = fixtureCase.expectedConflicts.map {
            FloorpNotesSyncConflict(
                originalNoteID: FloorpNoteID($0.originalNoteID),
                conflictCopyID: FloorpNoteID($0.conflictCopyID)
            )
        }

        assertWireNotesEqual(
            result.notes,
            fixtureCase.expectedNotes.map(\.note),
            fixtureCase.name
        )
        XCTAssertEqual(result.conflicts, expectedConflicts, fixtureCase.name)
        return result
    }

    private func assertWireNotesEqual(
        _ actual: [FloorpNote],
        _ expected: [FloorpNote],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(
                Data(actual.id.rawValue.utf8),
                Data(expected.id.rawValue.utf8),
                message,
                file: file,
                line: line
            )
            XCTAssertEqual(Data(actual.title.utf8), Data(expected.title.utf8), message, file: file, line: line)
            XCTAssertEqual(Data(actual.content.utf8), Data(expected.content.utf8), message, file: file, line: line)
            XCTAssertEqual(actual.createdAt, expected.createdAt, message, file: file, line: line)
            XCTAssertEqual(actual.updatedAt, expected.updatedAt, message, file: file, line: line)
            XCTAssertEqual(actual.contentFormat, expected.contentFormat, message, file: file, line: line)
        }
    }

    private func observedFixtureError(
        _ error: Error
    ) -> FloorpNotesMergeFixture.ExpectedError? {
        guard let error = error as? FloorpNotesSyncError else { return nil }
        switch error {
        case .duplicateNoteID(let source, let id):
            return FloorpNotesMergeFixture.ExpectedError(
                code: .duplicateNoteID,
                source: source,
                id: id.rawValue
            )
        default:
            return nil
        }
    }
}

private struct FloorpNotesMergeFixture: Decodable {
    let fixtureSchemaVersion: Int
    let contractVersion: String
    let wirePayloadVersion: Int
    let requiredCaseNames: [String]
    let productionDesktopObservation: ProductionDesktopObservation
    let mergeCases: [MergeVector]
    let sequenceCases: [SequenceCase]
    let errorCases: [ErrorCase]

    struct ProductionDesktopObservation: Decodable {
        let commit: String
        let declaredContractVersion: String?
        let matchesFixtureContract: Bool
    }

    struct MergeVector: Decodable {
        let name: String
        let transitionFromPrevious: Transition?
        let base: [FixtureNote]
        let local: [FixtureNote]
        let remote: [FixtureNote]
        let expectedNotes: [FixtureNote]
        let expectedConflicts: [FixtureConflict]
    }

    enum Transition: String, Decodable {
        case uploadedWithoutLocalCommitAndRemoteWinnerEdited =
            "previous-upload-succeeded-local-commit-failed-then-remote-winner-edited"
    }

    struct SequenceCase: Decodable {
        let name: String
        let steps: [MergeVector]
        let invariants: [Invariant]
    }

    struct Invariant: Decodable {
        let kind: Kind
        let originalNoteID: String
        let fromStep: String
        let toStep: String

        enum Kind: String, Decodable {
            case sameConflictCopy = "same-conflict-copy"
        }
    }

    struct ErrorCase: Decodable {
        let name: String
        let base: [FixtureNote]
        let local: [FixtureNote]
        let remote: [FixtureNote]
        let expectedError: ExpectedError
    }

    struct ExpectedError: Decodable, Equatable {
        let code: Code
        let source: FloorpNotesSyncSource?
        let id: String?

        enum Code: String, Decodable, Equatable {
            case duplicateNoteID = "duplicate-note-id"
        }
    }

    struct FixtureNote: Decodable {
        let id: String
        let title: String
        let content: String
        let createdAt: Int64
        let updatedAt: Int64

        var note: FloorpNote {
            makeFloorpTestNote(
                id: id,
                title: title,
                content: content,
                createdAt: createdAt,
                updatedAt: updatedAt,
                contentFormat: .automatic
            )
        }
    }

    struct FixtureConflict: Decodable {
        let originalNoteID: String
        let conflictCopyID: String
    }
}

private enum TestSyncFailure: Error, Equatable, Sendable {
    case upload
    case prepare
    case commit
}

private actor TestNotesSyncTransport: FloorpNotesSyncTransport {
    private let remoteRecord: FloorpNotesSyncRemoteRecord
    private let uploadResult: Result<FloorpNotesSyncUploadReceipt, TestSyncFailure>
    private let cancelDuringFetch: Bool
    private let cancelDuringUpload: Bool
    private var fetchedAccounts = [String]()
    private var expectedRevisions = [String?]()
    private var uploadedPayloads = [Data]()

    init(
        remoteRecord: FloorpNotesSyncRemoteRecord,
        uploadResult: Result<FloorpNotesSyncUploadReceipt, TestSyncFailure>,
        cancelDuringFetch: Bool = false,
        cancelDuringUpload: Bool = false
    ) {
        self.remoteRecord = remoteRecord
        self.uploadResult = uploadResult
        self.cancelDuringFetch = cancelDuringFetch
        self.cancelDuringUpload = cancelDuringUpload
    }

    func fetchNotesRecord(accountID: String) async throws -> FloorpNotesSyncRemoteRecord {
        fetchedAccounts.append(accountID)
        if cancelDuringFetch {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return remoteRecord
    }

    func uploadNotesRecord(
        _ payloadData: Data,
        accountID: String,
        expectedRevision: String?
    ) async throws -> FloorpNotesSyncUploadReceipt {
        expectedRevisions.append(expectedRevision)
        uploadedPayloads.append(payloadData)
        if cancelDuringUpload {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return try uploadResult.get()
    }

    func fetchedAccountIDs() -> [String] {
        fetchedAccounts
    }

    func uploadedExpectedRevisions() -> [String?] {
        expectedRevisions
    }

    func uploadCount() -> Int {
        uploadedPayloads.count
    }
}

private actor TestNotesSyncCommitStore: FloorpNotesSyncCommitStore {
    private let prepareFailure: TestSyncFailure?
    private let commitFailure: TestSyncFailure?
    private var preparedCandidates = [FloorpNotesSyncCommitCandidate]()
    private var commitAttempts = [FloorpNotesSyncCommit]()
    private var recordedCommits = [FloorpNotesSyncCommit]()

    init(
        prepareFailure: TestSyncFailure? = nil,
        commitFailure: TestSyncFailure? = nil
    ) {
        self.prepareFailure = prepareFailure
        self.commitFailure = commitFailure
    }

    func prepareSuccessfulSync(
        _ candidate: FloorpNotesSyncCommitCandidate
    ) async throws -> FloorpNotesSyncPreparedCommit {
        if let prepareFailure { throw prepareFailure }
        preparedCandidates.append(candidate)
        return FloorpNotesSyncPreparedCommit(
            candidate: candidate,
            storeToken: Data("prepared-\(preparedCandidates.count)".utf8)
        )
    }

    func commitSuccessfulSync(_ commit: FloorpNotesSyncCommit) async throws {
        commitAttempts.append(commit)
        if let commitFailure { throw commitFailure }
        recordedCommits.append(commit)
    }

    func commits() -> [FloorpNotesSyncCommit] {
        recordedCommits
    }

    func preparationCount() -> Int {
        preparedCandidates.count
    }

    func commitAttemptCount() -> Int {
        commitAttempts.count
    }
}
