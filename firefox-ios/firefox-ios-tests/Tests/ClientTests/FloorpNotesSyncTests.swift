// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import MozillaAppServices
import Sync
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

    func testInitialPlannerUnionsDisjointIOSAndDesktopNotesBeforeUpload() throws {
        let local = [note("ios-local", title: "iPhone")]
        let remote = [
            note("desktop-one", title: "Desktop 1"),
            note("desktop-two", title: "Desktop 2"),
        ]

        let plan = try FloorpNotesSyncPlanner.makePlan(
            accountID: "account",
            baseState: nil,
            localNotes: local,
            remoteRecord: try remoteRecord(FloorpNotesDesktopPayload(notes: remote)),
            now: 100
        )

        XCTAssertEqual(
            plan.mergedNotes.map(\.id.rawValue),
            ["ios-local", "desktop-one", "desktop-two"]
        )
        XCTAssertTrue(plan.requiresUpload)
        let payload = try JSONDecoder().decode(
            FloorpNotesDesktopPayload.self,
            from: try XCTUnwrap(plan.uploadPayloadData)
        )
        XCTAssertEqual(payload.ids, ["ios-local", "desktop-one", "desktop-two"])
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

    func testDefaultReleaseConfigurationEnablesSyncWithoutEvidenceResource() {
        let configuration = FloorpNotesSyncCompiledConfiguration(
            buildMode: "release-default",
            sourceSHA: nil,
            buildNumber: "4",
            requested: "YES",
            effective: "YES",
            registrationAllowed: "YES",
            engineRequestsAllowed: "YES",
            uiExposureAllowed: "YES",
            endpointAuthority: "production",
            wireProtocol: "sync15",
            endpointMatrixSHA256:
                "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
            evidenceDigest: nil,
            evidenceResourceSHA256: nil
        )

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsDefaultReleaseConfiguration(
                configuration
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsDefaultReleaseConfiguration(
                FloorpNotesSyncCompiledConfiguration(
                    buildMode: "release-disabled",
                    sourceSHA: configuration.sourceSHA,
                    buildNumber: configuration.buildNumber,
                    requested: configuration.requested,
                    effective: configuration.effective,
                    registrationAllowed: configuration.registrationAllowed,
                    engineRequestsAllowed: configuration.engineRequestsAllowed,
                    uiExposureAllowed: configuration.uiExposureAllowed,
                    endpointAuthority: configuration.endpointAuthority,
                    wireProtocol: configuration.wireProtocol,
                    endpointMatrixSHA256: configuration.endpointMatrixSHA256,
                    evidenceDigest: configuration.evidenceDigest,
                    evidenceResourceSHA256: configuration.evidenceResourceSHA256
                )
            )
        )

        let wrongEndpoint = FloorpNotesSyncCompiledConfiguration(
            buildMode: configuration.buildMode,
            sourceSHA: configuration.sourceSHA,
            buildNumber: configuration.buildNumber,
            requested: configuration.requested,
            effective: configuration.effective,
            registrationAllowed: configuration.registrationAllowed,
            engineRequestsAllowed: configuration.engineRequestsAllowed,
            uiExposureAllowed: configuration.uiExposureAllowed,
            endpointAuthority: "stage",
            wireProtocol: configuration.wireProtocol,
            endpointMatrixSHA256: configuration.endpointMatrixSHA256,
            evidenceDigest: configuration.evidenceDigest,
            evidenceResourceSHA256: configuration.evidenceResourceSHA256
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsDefaultReleaseConfiguration(
                wrongEndpoint
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

final class FloorpNotesPrefsSyncDelegateTests: XCTestCase, @unchecked Sendable {
    func testEngineProviderRegistersExactlyOnceAndRetainsGeneratedStore() throws {
        let archiveURL = try makeArchiveURL()
        let statusCenter = FloorpNotesSyncStatusCenter()
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            networkSyncEnabled: { true },
            statusCenter: statusCenter
        )

        XCTAssertEqual(statusCenter.status, .localOnly)
        XCTAssertTrue(provider.allowsSync(accountID: "account-a"))
        try provider.register(accountID: "account-a")
        try provider.register(accountID: "account-a")

        XCTAssertEqual(provider.registrationCount, 1)
        XCTAssertTrue(provider.retainsRegisteredStore)
        XCTAssertEqual(statusCenter.status, .syncEnabled)
        provider.didFinishSync(successful: false)
        XCTAssertEqual(statusCenter.status, .syncError)
        provider.didFinishSync(successful: true)
        XCTAssertEqual(statusCenter.status, .syncEnabled)
        provider.invalidate()
        XCTAssertFalse(provider.retainsRegisteredStore)
        XCTAssertEqual(statusCenter.status, .localOnly)
    }

    func testPendingDisconnectResumeWithoutMarkerRetainsRegisteredStore() throws {
        let archiveURL = try makeArchiveURL()
        let statusCenter = FloorpNotesSyncStatusCenter()
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            networkSyncEnabled: { true },
            statusCenter: statusCenter
        )
        try provider.register(accountID: "account-a")
        XCTAssertEqual(statusCenter.status, .syncEnabled)

        try provider.resumePendingDisconnectCleanup()

        XCTAssertTrue(provider.retainsRegisteredStore)
        XCTAssertEqual(provider.registrationCount, 1)
        XCTAssertEqual(statusCenter.status, .syncEnabled)
    }

    func testEngineProviderInvalidationLeavesNotesAndBaseByteIdentical() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(from: delegate.prepare(input: missingRecordInput()))
        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try delegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { true }
        )
        try provider.register(accountID: "account-a")
        let before = try Data(contentsOf: archiveURL)

        provider.invalidate()

        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        let restarted = FloorpNotesStore(fileURL: archiveURL)
        let notes = try await restarted.loadNotes()
        XCTAssertEqual(notes, [local])
        let context = try await restarted.loadSyncContext()
        XCTAssertNotNil(context.baseState)
    }

    func testInvalidationCannotReturnBeforeAtomicStateCommitFinishes() async throws {
        let archiveURL = try makeArchiveURL()
        let seed = FloorpNotesStore(fileURL: archiveURL)
        try await seed.replaceAllNotes(
            with: [makeNote(id: "local", title: "Local")]
        )
        try assertInvalidationWaitsForCommit(archiveURL: archiveURL)
    }

    private func assertInvalidationWaitsForCommit(archiveURL: URL) throws {
        let writeStarted = DispatchSemaphore(value: 0)
        let allowWrite = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        let errorBox = TestThreadSafeErrorBox()
        let blockingStore = FloorpNotesStore(
            fileURL: archiveURL,
            writeData: { data, url in
                writeStarted.signal()
                guard allowWrite.wait(timeout: .now() + 5) == .success else {
                    throw TestPersistenceFailure.write
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: blockingStore
        )
        let token = try uploadToken(from: delegate.prepare(input: missingRecordInput()))
        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )

        DispatchQueue.global(qos: .utility).async {
            do {
                try delegate.syncStateChanged(
                    state: FloorpPrefsSyncState(
                        globalSyncId: "global-a",
                        collectionSyncId: "collection-a",
                        lastModifiedMillis: 12
                    )
                )
            } catch {
                errorBox.store(error)
            }
            commitFinished.signal()
        }
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 5), .success)

        DispatchQueue.global(qos: .utility).async {
            delegate.invalidate()
            invalidationFinished.signal()
        }
        let invalidationBeforeCommit = invalidationFinished.wait(
            timeout: .now() + 0.2
        )
        allowWrite.signal()

        XCTAssertEqual(invalidationBeforeCommit, .timedOut)
        XCTAssertEqual(commitFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(errorBox.error)
    }

    func testRegistrationClaimsOwnerBeforeFirstCommitAndRejectsAnotherAccount() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        try await store.replaceAllNotes(with: [makeNote(id: "local", title: "Local")])
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { true }
        )

        try provider.register(accountID: "account-a")

        let restarted = FloorpNotesStore(fileURL: archiveURL)
        let context = try await restarted.loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNil(context.baseState)
        XCTAssertEqual(
            try restarted.syncAccountAvailability(accountID: "account-b"),
            .accountMismatch
        )
    }

    func testCheckedDisconnectRegistersWithNetworkGateOffAndRetainsLocalOwner() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let initialDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(from: initialDelegate.prepare(input: missingRecordInput()))
        try initialDelegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try initialDelegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )

        let statusCenter = FloorpNotesSyncStatusCenter()
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { false },
            statusCenter: statusCenter
        )
        XCTAssertFalse(provider.allowsSync(accountID: "account-a"))
        XCTAssertEqual(
            try provider.prepareForDisconnect(accountID: "account-a"),
            .available
        )
        XCTAssertTrue(provider.retainsRegisteredStore)
        XCTAssertEqual(statusCenter.status, .localOnly)

        try SyncManagerComponent().disconnectChecked()

        let stagedContext = try await store.loadSyncContext()
        XCTAssertNotNil(stagedContext.baseState)
        XCTAssertEqual(stagedContext.applicationServicesState?.globalSyncID, "global-a")

        try provider.finalizeDisconnect()
        let context = try await store.loadSyncContext()
        let notes = try await store.loadNotes()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNil(context.baseState)
        XCTAssertNil(context.applicationServicesState?.globalSyncID)
        XCTAssertNil(context.applicationServicesState?.collectionSyncID)
        XCTAssertEqual(context.applicationServicesState?.lastModifiedMillis, 0)
        XCTAssertEqual(notes, [local])
        provider.invalidate()
    }

    func testFinalizeFailureResumesPendingAssociationCleanupAfterRestart() async throws {
        let archiveURL = try makeArchiveURL()
        let seedStore = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await seedStore.replaceAllNotes(with: [local])
        let seedDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: seedStore
        )
        let token = try uploadToken(
            from: seedDelegate.prepare(input: missingRecordInput())
        )
        try seedDelegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try seedDelegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )

        let failingStore = FloorpNotesStore(
            fileURL: archiveURL,
            writeData: { data, url in
                if url == archiveURL {
                    throw TestPersistenceFailure.write
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let failingProvider = FloorpNotesSyncEngineProvider(
            notesStore: failingStore,
            networkSyncEnabled: { false }
        )
        XCTAssertEqual(
            try failingProvider.prepareForDisconnect(accountID: "account-a"),
            .available
        )
        try SyncManagerComponent().disconnectChecked()

        XCTAssertThrowsError(try failingProvider.finalizeDisconnect())
        failingProvider.invalidate()

        let recoveringStore = FloorpNotesStore(fileURL: archiveURL)
        let recoveringProvider = FloorpNotesSyncEngineProvider(
            notesStore: recoveringStore,
            networkSyncEnabled: { false }
        )
        try recoveringProvider.resumePendingDisconnectCleanup()

        let context = try await recoveringStore.loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNil(context.baseState)
        XCTAssertNil(context.applicationServicesState?.globalSyncID)
        XCTAssertNil(context.applicationServicesState?.collectionSyncID)
        XCTAssertEqual(context.applicationServicesState?.lastModifiedMillis, 0)
        let recoveredNotes = try await recoveringStore.loadNotes()
        XCTAssertEqual(recoveredNotes, [local])
    }

    func testPendingCleanupRecoveryIsIdempotentAfterArchiveCommit() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let seedDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(
            from: seedDelegate.prepare(input: missingRecordInput())
        )
        try seedDelegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try seedDelegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { false }
        )
        XCTAssertEqual(
            try provider.prepareForDisconnect(accountID: "account-a"),
            .available
        )
        try SyncManagerComponent().disconnectChecked()
        let resetState = FloorpNotesApplicationServicesState(
            globalSyncID: nil,
            collectionSyncID: nil,
            lastModifiedMillis: 0
        )

        try store.syncPersistenceCore.resetSyncAssociation(
            accountID: "account-a",
            state: resetState
        )
        provider.invalidate()

        let recoveringStore = FloorpNotesStore(fileURL: archiveURL)
        let recoveringProvider = FloorpNotesSyncEngineProvider(
            notesStore: recoveringStore,
            networkSyncEnabled: { false }
        )
        try recoveringProvider.resumePendingDisconnectCleanup()
        try recoveringProvider.resumePendingDisconnectCleanup()

        let context = try await recoveringStore.loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNil(context.baseState)
        XCTAssertEqual(context.applicationServicesState, resetState)
        let recoveredNotes = try await recoveringStore.loadNotes()
        XCTAssertEqual(recoveredNotes, [local])
    }

    func testCorruptPendingCleanupMarkerFailsClosedWithoutChangingArchive() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        try await store.replaceAllNotes(
            with: [makeNote(id: "local", title: "Local")]
        )
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(from: delegate.prepare(input: missingRecordInput()))
        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try delegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { false }
        )
        _ = try provider.prepareForDisconnect(accountID: "account-a")
        try SyncManagerComponent().disconnectChecked()
        provider.invalidate()
        let markerURL = archiveURL.appendingPathExtension(
            "pending-sync-association-reset"
        )
        try Data("{".utf8).write(to: markerURL, options: .atomic)
        let before = try Data(contentsOf: archiveURL)

        let recoveringProvider = FloorpNotesSyncEngineProvider(
            notesStore: FloorpNotesStore(fileURL: archiveURL),
            networkSyncEnabled: { false }
        )
        XCTAssertThrowsError(
            try recoveringProvider.resumePendingDisconnectCleanup()
        )

        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        let context = try await store.loadSyncContext()
        XCTAssertNotNil(context.baseState)
        XCTAssertEqual(context.applicationServicesState?.globalSyncID, "global-a")
    }

    func testCancelledCheckedDisconnectRetainsBaseAndOwner() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let delegate = FloorpNotesPrefsSyncDelegate(accountID: "account-a", notesStore: store)
        let token = try uploadToken(from: delegate.prepare(input: missingRecordInput()))
        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try delegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { false }
        )
        XCTAssertEqual(
            try provider.prepareForDisconnect(accountID: "account-a"),
            .available
        )
        XCTAssertEqual(provider.registeredSyncState?.globalSyncId, "global-a")

        try SyncManagerComponent().disconnectChecked()
        XCTAssertNil(provider.registeredSyncState?.globalSyncId)
        provider.cancelDisconnect()
        XCTAssertEqual(provider.registeredSyncState?.globalSyncId, "global-a")

        let context = try await FloorpNotesStore(fileURL: archiveURL).loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNotNil(context.baseState)
        XCTAssertEqual(context.applicationServicesState?.globalSyncID, "global-a")
        XCTAssertEqual(
            try store.syncAccountAvailability(accountID: "account-b"),
            .accountMismatch
        )
    }

    func testCancelledDisconnectRebuildFailureReturnsFalseAndFailsClosed() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        try await store.replaceAllNotes(
            with: [makeNote(id: "local", title: "Local")]
        )
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(from: delegate.prepare(input: missingRecordInput()))
        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try delegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )
        let factory = TestFloorpPrefsSyncStoreFactory(failingCall: 2)
        let provider = FloorpNotesSyncEngineProvider(
            notesStore: store,
            networkSyncEnabled: { false },
            makeApplicationServicesStore: factory.make
        )
        XCTAssertEqual(
            try provider.prepareForDisconnect(accountID: "account-a"),
            .available
        )
        try SyncManagerComponent().disconnectChecked()

        XCTAssertFalse(provider.cancelDisconnect())
        XCTAssertFalse(provider.retainsRegisteredStore)
        let context = try await store.loadSyncContext()
        XCTAssertEqual(context.applicationServicesState?.globalSyncID, "global-a")
        XCTAssertNotNil(context.baseState)
    }

    func testConfirmedUploadAtomicallyAssignsOwnerAndAdvancesBase() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let delegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )

        let plan = try delegate.prepare(
            input: FloorpPrefsSyncPrepareInput(
                remoteNotes: .recordMissing,
                remoteRecordModifiedMillis: nil,
                collectionModifiedMillis: 0,
                maximumNotesValueBytes: 164 * 1_024
            )
        )
        let token: Data
        switch plan {
        case .upload(let transactionToken, let notesValue):
            token = transactionToken
            XCTAssertFalse(notesValue.isEmpty)
        case .noUpload:
            return XCTFail("A first sync with local Notes must prepare an upload")
        }

        let before = try await store.loadSyncContext()
        XCTAssertNil(before.ownerAccountID)
        XCTAssertNil(before.baseState)

        try delegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 42
            )
        )
        let stagedOnly = try await FloorpNotesStore(fileURL: archiveURL).loadSyncContext()
        XCTAssertNil(stagedOnly.ownerAccountID)
        XCTAssertNil(stagedOnly.baseState)
        try delegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 42
            )
        )

        let restarted = FloorpNotesStore(fileURL: archiveURL)
        let context = try await restarted.loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertEqual(context.baseState, FloorpNotesSyncBaseState(accountID: "account-a", notes: [local]))
        XCTAssertEqual(context.applicationServicesState?.lastModifiedMillis, 42)
        let evidence = try await restarted.loadSyncEvidenceSnapshot()
        XCTAssertTrue(evidence.hasSyncOwner)
        XCTAssertTrue(evidence.hasSyncBaseState)
        XCTAssertTrue(evidence.hasApplicationServicesAssociation)
        XCTAssertEqual(evidence.noteCount, 1)
        let restartedNotes = try await restarted.loadNotes()
        XCTAssertEqual(restartedNotes, [local])
    }

    func testWriteFailureAndCancellationLeaveOwnerAndBaseUnchanged() async throws {
        let archiveURL = try makeArchiveURL()
        let seed = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await seed.replaceAllNotes(with: [local])

        let failing = FloorpNotesStore(
            fileURL: archiveURL,
            writeData: { _, _ in throw TestPersistenceFailure.write }
        )
        let failingDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: failing
        )
        let failedToken = try uploadToken(
            from: failingDelegate.prepare(input: missingRecordInput())
        )
        try failingDelegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: failedToken,
                didUpload: true,
                serverModifiedMillis: 10
            )
        )
        XCTAssertThrowsError(
            try failingDelegate.syncStateChanged(
                state: FloorpPrefsSyncState(
                    globalSyncId: "global-a",
                    collectionSyncId: "collection-a",
                    lastModifiedMillis: 10
                )
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPrefsSyncError, .DelegateRejected)
        }

        let cancelledDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: FloorpNotesStore(fileURL: archiveURL)
        )
        let cancelledToken = try uploadToken(
            from: cancelledDelegate.prepare(input: missingRecordInput())
        )
        cancelledDelegate.invalidate()
        XCTAssertThrowsError(
            try cancelledDelegate.syncFinished(
                finish: FloorpPrefsSyncFinish(
                    transactionToken: cancelledToken,
                    didUpload: true,
                    serverModifiedMillis: 11
                )
            )
        ) { error in
            XCTAssertEqual(error as? FloorpPrefsSyncError, .UnexpectedSyncState)
        }

        let restarted = FloorpNotesStore(fileURL: archiveURL)
        let context = try await restarted.loadSyncContext()
        XCTAssertNil(context.ownerAccountID)
        XCTAssertNil(context.baseState)
        let restartedNotes = try await restarted.loadNotes()
        XCTAssertEqual(restartedNotes, [local])
    }

    func testAssociationResetKeepsOwnerAndLocalNotesButRejectsAnotherAccount() async throws {
        let archiveURL = try makeArchiveURL()
        let store = FloorpNotesStore(fileURL: archiveURL)
        let local = makeNote(id: "local", title: "Local")
        try await store.replaceAllNotes(with: [local])
        let ownerDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-a",
            notesStore: store
        )
        let token = try uploadToken(from: ownerDelegate.prepare(input: missingRecordInput()))
        try ownerDelegate.syncFinished(
            finish: FloorpPrefsSyncFinish(
                transactionToken: token,
                didUpload: true,
                serverModifiedMillis: 12
            )
        )
        try ownerDelegate.syncStateChanged(
            state: FloorpPrefsSyncState(
                globalSyncId: "global-a",
                collectionSyncId: "collection-a",
                lastModifiedMillis: 12
            )
        )

        try ownerDelegate.associationReset(
            state: FloorpPrefsSyncState(
                globalSyncId: nil,
                collectionSyncId: nil,
                lastModifiedMillis: 0
            )
        )

        let context = try await store.loadSyncContext()
        XCTAssertEqual(context.ownerAccountID, "account-a")
        XCTAssertNil(context.baseState)
        let storedNotes = try await store.loadNotes()
        XCTAssertEqual(storedNotes, [local])

        let otherDelegate = FloorpNotesPrefsSyncDelegate(
            accountID: "account-b",
            notesStore: store
        )
        XCTAssertThrowsError(try otherDelegate.prepare(input: missingRecordInput())) { error in
            XCTAssertEqual(error as? FloorpPrefsSyncError, .DelegateRejected)
        }
    }

    private func makeArchiveURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNotesPrefsSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("notes.json")
    }

    private func makeNote(id: String, title: String) -> FloorpNote {
        FloorpNote(
            id: FloorpNoteID(id),
            title: title,
            content: "content",
            createdAt: 1,
            updatedAt: 1,
            contentFormat: .plainText
        )
    }

    private func missingRecordInput() -> FloorpPrefsSyncPrepareInput {
        FloorpPrefsSyncPrepareInput(
            remoteNotes: .recordMissing,
            remoteRecordModifiedMillis: nil,
            collectionModifiedMillis: 0,
            maximumNotesValueBytes: 164 * 1_024
        )
    }

    private func uploadToken(from plan: FloorpPrefsSyncPlan) throws -> Data {
        guard case .upload(let token, _) = plan else {
            throw TestPersistenceFailure.expectedUpload
        }
        return token
    }
}

private enum TestPersistenceFailure: Error {
    case write
    case expectedUpload
}

private final class TestThreadSafeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class TestFloorpPrefsSyncStoreFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int
    private var callCount = 0

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func make(
        delegate: FloorpPrefsSyncDelegate,
        initialState: FloorpPrefsSyncState?
    ) throws -> FloorpPrefsSyncStore {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failingCall
        lock.unlock()
        if shouldFail { throw TestPersistenceFailure.write }
        return try FloorpPrefsSyncStore(
            delegate: delegate,
            initialState: initialState
        )
    }
}

final class FloorpNotesSyncEngineSelectionTests: XCTestCase {
    func testG4AttestationBindsTask18Evidence() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let attestationURL = repositoryRoot
            .appendingPathComponent("docs/floorp-notes-sync-g4-attestation.json")
        let attestation = try Data(contentsOf: attestationURL)
        let expected: [String: Any] = [
            "desktop": [
                "merged_sha": "fc244eed70248796fa92ff5821c6046ecd576e7e",
                "run_head_sha": "17b47fcb837272040a6231963b5221aaec80fa42",
                "run_id": 31_338_438_952,
                "workflow_path": ".github/workflows/colocated_runner_test.yml",
            ],
            "floorpci_test": (
                "ClientTests/FloorpNotesSyncEngineSelectionTests/"
                    + "testG4AttestationBindsTask18Evidence()"
            ),
            "runtime": [
                "merged_sha": "3bf9399564e59be32f92dcc1b044094881b4fb6a",
                "run_head_sha": "515da7cf9c7fc258eacd56902448eb10989d17b0",
                "run_id": 31_330_766_054,
                "tree_sha": "533f9fdca9bdccb7f3d2a13842be7e2375160ae5",
                "workflow_path": ".github/workflows/wrapper-mac-build.yml",
            ],
            "schema_version": 1,
            "summaries": [
                "execution_verdict_sha256": "0d1606797281d525924f0ff85b15b9697b6bb11de91196704a6d334591baf689",
                "task_manifest_sha256": "d55a01faf3755658cca48750e40370aac72e83b87eb9a8fec9ce5f6bb5f77e84",
                "tps_sha256": "f173c9c7113539c3e46eb7b4cb6a8359c7ffbfc749ff0a64325b524ffa551424",
                "xpcshell_sha256": "70d3fcf4d6116bb37330a3c5c13b4da819716378d39e54f9bb1cd2702351860b",
            ],
            "task_id": 18,
        ]
        XCTAssertEqual(attestation, try canonicalEvidenceData(expected))
    }

    func testStatusCenterPostsUIRefreshOnMainThread() {
        let notificationCenter = NotificationCenter()
        let statusCenter = FloorpNotesSyncStatusCenter(
            notificationCenter: notificationCenter
        )
        let posted = expectation(description: "Notes Sync status posted on main thread")
        let observer = notificationCenter.addObserver(
            forName: .FloorpNotesSyncStatusDidChange,
            object: statusCenter,
            queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            posted.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        DispatchQueue.global(qos: .utility).async {
            statusCenter.setStatus(.syncEnabled)
        }

        wait(for: [posted], timeout: 1)
        XCTAssertEqual(statusCenter.status, .syncEnabled)
    }

    func testFloorpPrefsSelectionIsExplicitAndNeverToggleDriven() {
        let selection = FloorpNotesSyncEngineSelection.partition(
            requested: ["tabs", "prefs", "history", "prefs"]
        )

        XCTAssertEqual(selection.togglable, [.tabs, .history])
        XCTAssertTrue(selection.requestsFloorpPrefs)
        XCTAssertFalse(
            RustSyncManagerAPI.TogglableEngine.allCases.contains { $0.rawValue == "prefs" }
        )
    }

    func testFloorpPrefsIsAddedOnlyWhenAllRuntimePoliciesAllowIt() {
        let allowed = FloorpNotesSyncRequestPolicy(
            compiledEvidenceAllows: true,
            runtimeKillSwitchAllows: true,
            productionEndpointAllows: true,
            accountAvailability: .available
        )
        XCTAssertEqual(
            FloorpNotesSyncEngineSelection.syncEverythingEngines(policy: allowed).last,
            "prefs"
        )

        let deniedPolicies: [FloorpNotesSyncRequestPolicy] = [
            FloorpNotesSyncRequestPolicy(
                compiledEvidenceAllows: false,
                runtimeKillSwitchAllows: true,
                productionEndpointAllows: true,
                accountAvailability: .available
            ),
            FloorpNotesSyncRequestPolicy(
                compiledEvidenceAllows: true,
                runtimeKillSwitchAllows: false,
                productionEndpointAllows: true,
                accountAvailability: .available
            ),
            FloorpNotesSyncRequestPolicy(
                compiledEvidenceAllows: true,
                runtimeKillSwitchAllows: true,
                productionEndpointAllows: false,
                accountAvailability: .available
            ),
            FloorpNotesSyncRequestPolicy(
                compiledEvidenceAllows: true,
                runtimeKillSwitchAllows: true,
                productionEndpointAllows: true,
                accountAvailability: .accountMismatch
            ),
        ]
        for policy in deniedPolicies {
            XCTAssertFalse(
                FloorpNotesSyncEngineSelection.syncEverythingEngines(policy: policy)
                    .contains("prefs")
            )
        }
    }

    func testProductionEndpointAuthorityRejectsEveryOverride() {
        XCTAssertTrue(
            FloorpNotesSyncEndpointAuthority.allowsProduction(
                FloorpNotesSyncEndpointSettings(
                    usesStage: false,
                    usesChina: false,
                    usesCustomFxAContent: false,
                    usesCustomTokenServer: false
                )
            )
        )
        let denied: [FloorpNotesSyncEndpointSettings] = [
            FloorpNotesSyncEndpointSettings(
                usesStage: true,
                usesChina: false,
                usesCustomFxAContent: false,
                usesCustomTokenServer: false
            ),
            FloorpNotesSyncEndpointSettings(
                usesStage: false,
                usesChina: true,
                usesCustomFxAContent: false,
                usesCustomTokenServer: false
            ),
            FloorpNotesSyncEndpointSettings(
                usesStage: false,
                usesChina: false,
                usesCustomFxAContent: true,
                usesCustomTokenServer: false
            ),
            FloorpNotesSyncEndpointSettings(
                usesStage: false,
                usesChina: false,
                usesCustomFxAContent: false,
                usesCustomTokenServer: true
            ),
        ]
        XCTAssertTrue(denied.allSatisfy { !FloorpNotesSyncEndpointAuthority.allowsProduction($0) })
    }

    func testProductionEndpointAuthorityRequiresConcreteReleaseTokenServer() throws {
        XCTAssertTrue(
            FloorpNotesSyncEndpointAuthority.allowsProductionTokenServer(
                try XCTUnwrap(
                    URL(string: "https://token.services.mozilla.com/1.0/sync/1.5")
                )
            )
        )
        let denied = [
            "https://stage-token.services.mozilla.com/1.0/sync/1.5",
            "https://token.services.mozilla.com:444/1.0/sync/1.5",
            "http://token.services.mozilla.com/1.0/sync/1.5",
            "https://token.services.mozilla.com/other",
            "https://token.services.mozilla.com/1.0/sync/1.5?override=true",
        ]
        for rawURL in denied {
            XCTAssertFalse(
                FloorpNotesSyncEndpointAuthority.allowsProductionTokenServer(
                    try XCTUnwrap(URL(string: rawURL))
                )
            )
        }
    }

    func testRetryUsesServerDeadlineThenBoundedExponentialDelay() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            FloorpNotesSyncRetryPolicy.delay(
                status: .backedOff,
                nextSyncAllowedAt: now.addingTimeInterval(600),
                now: now,
                attempt: 0
            ),
            600
        )
        XCTAssertEqual(
            FloorpNotesSyncRetryPolicy.delay(
                status: .backedOff,
                nextSyncAllowedAt: now.addingTimeInterval(86_400),
                now: now,
                attempt: 99
            ),
            86_400
        )
        XCTAssertEqual(
            FloorpNotesSyncRetryPolicy.delay(
                status: .networkError,
                nextSyncAllowedAt: nil,
                now: now,
                attempt: 2
            ),
            720
        )
        XCTAssertEqual(
            FloorpNotesSyncRetryPolicy.delay(
                status: .serviceError,
                nextSyncAllowedAt: nil,
                now: now,
                attempt: 99
            ),
            3_600
        )
        XCTAssertNil(
            FloorpNotesSyncRetryPolicy.delay(
                status: .ok,
                nextSyncAllowedAt: nil,
                now: now,
                attempt: 0
            )
        )
        XCTAssertNil(
            FloorpNotesSyncRetryPolicy.delay(
                status: .authError,
                nextSyncAllowedAt: nil,
                now: now,
                attempt: 0
            )
        )
    }

    func testCompiledEvidenceRequiresEveryBuildAndResourceBinding() throws {
        let (evidence, root) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        let configuration = try compiledConfiguration(evidence: evidence, root: root)
        let trustedNow = try releaseEvidenceTrustedNow()

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: evidence,
                now: trustedNow
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(
                    evidence: evidence,
                    root: root,
                    evidenceDigest: String(repeating: "a", count: 64),
                ),
                evidenceData: evidence,
                now: trustedNow
            )
        )
        var tampered = evidence
        tampered.append(0x20)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: tampered,
                now: trustedNow
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(
                    evidence: evidence,
                    root: root,
                    sourceSHA: String(repeating: "4", count: 40)
                ),
                evidenceData: evidence,
                now: trustedNow
            )
        )
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(
                    evidence: evidence,
                    root: root,
                    buildNumber: "different-build",
                    requested: "NO"
                ),
                evidenceData: evidence,
                now: trustedNow
            )
        )
    }

    func testRescopedProductionQACapabilityBindsOnlyTheProtectedIntegrityRun() throws {
        let root: [String: Any] = [
            "accounts": 2,
            "build_contract_mode": "production-qa",
            "clients": ["desktop", "mobile"],
            "contract_sha256": "e935ab08c60cd7fcdbe66699764cd2805410f90bb0e3651d97b2c65c58f98764",
            "desktop": [
                "repository": "Floorp-Projects/Floorp",
                "source_sha": String(repeating: "b", count: 40),
            ],
            "endpoint": [
                "endpoint_policy_sha256": "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
                "fxa_configuration": "FxAConfig.Server.release",
                "fxa_hosts": [
                    "accounts.firefox.com",
                    "api.accounts.firefox.com",
                    "oauth.accounts.firefox.com",
                    "profile.accounts.firefox.com",
                    "static.accounts.firefox.com",
                ],
                "sync_hosts": [
                    "event-sync.services.mozilla.com",
                    "sync.services.mozilla.com",
                    "token.services.mozilla.com",
                ],
                "wire_protocol": "sync15",
            ],
            "integrity_matrix_sha256": "53828225b7ae183212df954e7076e577879a74acac73e5cbaf50389d7dd0df45",
            "ios_build_number": "4",
            "public_release": false,
            "schema_version": 1,
            "self_attestation": [
                "approved": true,
                "environment": "floorp-notes-sync-production-qa",
                "operator_id": "operator",
                "roles": ["owner", "operations", "executor"],
            ],
            "source": [
                "event": "workflow_dispatch",
                "head_sha": String(repeating: "d", count: 40),
                "job_name": "notes-sync-production-qa",
                "repository": "Floorp-Projects/floorp-ios",
                "workflow_path": ".github/workflows/floorp-notes-sync-production-qa.yml",
                "workflow_run_attempt": 1,
                "workflow_run_id": 123,
            ],
            "todo20_contract_version": "todo20-production-sync-integrity-v1",
        ]
        let evidence = try canonicalEvidenceData(root)
        let configuration = FloorpNotesSyncCompiledConfiguration(
            buildMode: "production-qa",
            sourceSHA: String(repeating: "d", count: 40),
            buildNumber: "4",
            requested: "YES",
            effective: "YES",
            registrationAllowed: "YES",
            engineRequestsAllowed: "YES",
            uiExposureAllowed: "YES",
            endpointAuthority: "production",
            wireProtocol: "sync15",
            endpointMatrixSHA256: "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
            evidenceDigest: sha256(evidence),
            evidenceResourceSHA256: sha256(evidence)
        )

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: evidence
            )
        )

        var publicRelease = root
        publicRelease["public_release"] = true
        let publicReleaseEvidence = try canonicalEvidenceData(publicRelease)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: publicReleaseEvidence
            )
        )

        for key in ["contract_sha256", "integrity_matrix_sha256"] {
            var altered = root
            altered[key] = String(repeating: "e", count: 64)
            let alteredEvidence = try canonicalEvidenceData(altered)
            XCTAssertFalse(
                FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                    configuration,
                    evidenceData: alteredEvidence
                )
            )
        }
    }

    func testPublicBetaEvidenceBindsProtectedQAAndExplicitApproval() throws {
        let sourceSHA = String(repeating: "d", count: 40)
        let endpointPolicySHA = "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca"
        let workflowPath = ".github/workflows/floorp-notes-sync-public-beta-qa.yml"
        let source: [String: Any] = [
            "event": "workflow_dispatch",
            "head_sha": sourceSHA,
            "job_name": "notes-sync-public-beta-qa",
            "repository": "Floorp-Projects/floorp-ios",
            "workflow_path": workflowPath,
            "workflow_run_attempt": 1,
            "workflow_run_id": 123,
        ]
        let root: [String: Any] = [
            "approval": [
                "approved": true,
                "operator_id": "Ryosuke-Asano",
                "purpose": "external-testflight",
            ],
            "build_contract_mode": "public-beta",
            "endpoint": [
                "endpoint_policy_sha256": endpointPolicySHA,
                "fxa_configuration": "FxAConfig.Server.release",
                "fxa_hosts": [
                    "accounts.firefox.com",
                    "api.accounts.firefox.com",
                    "oauth.accounts.firefox.com",
                    "profile.accounts.firefox.com",
                    "static.accounts.firefox.com",
                ],
                "sync_hosts": [
                    "event-sync.services.mozilla.com",
                    "sync.services.mozilla.com",
                    "token.services.mozilla.com",
                ],
                "wire_protocol": "sync15",
            ],
            "ios": [
                "build_number": "4",
                "configuration": "FloorpRelease",
                "repository": "Floorp-Projects/floorp-ios",
                "source_sha": sourceSHA,
            ],
            "public_release": true,
            "qa": [
                "capability_sha256": String(repeating: "a", count: 64),
                "summary_sha256": String(repeating: "b", count: 64),
                "workflow_path": workflowPath,
                "workflow_run_attempt": 1,
                "workflow_run_id": 123,
            ],
            "schema_version": 1,
            "source": source,
        ]
        let evidence = try canonicalEvidenceData(root)
        let configuration = FloorpNotesSyncCompiledConfiguration(
            buildMode: "public-beta",
            sourceSHA: sourceSHA,
            buildNumber: "4",
            requested: "YES",
            effective: "YES",
            registrationAllowed: "YES",
            engineRequestsAllowed: "YES",
            uiExposureAllowed: "YES",
            endpointAuthority: "production",
            wireProtocol: "sync15",
            endpointMatrixSHA256: endpointPolicySHA,
            evidenceDigest: sha256(evidence),
            evidenceResourceSHA256: sha256(evidence)
        )

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: evidence
            )
        )

        var unapproved = root
        unapproved["approval"] = [
            "approved": false,
            "operator_id": "Ryosuke-Asano",
            "purpose": "external-testflight",
        ]
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                configuration,
                evidenceData: try canonicalEvidenceData(unapproved)
            )
        )
    }

    func testProductionQAEvidenceRequiresExactlyG1ThroughG4() throws {
        let (g1G4, root) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g4-production-qa-valid"
        )
        let trustedNow = try releaseEvidenceTrustedNow()

        XCTAssertTrue(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: g1G4, root: root),
                evidenceData: g1G4,
                now: trustedNow
            )
        )

        var terminalManifestRoot = root
        var terminalManifestGates = try XCTUnwrap(
            terminalManifestRoot["gates"] as? [String: Any]
        )
        var terminalManifestG3 = try XCTUnwrap(
            terminalManifestGates["g3"] as? [String: Any]
        )
        var terminalManifestArtifact = try XCTUnwrap(
            terminalManifestG3["artifact"] as? [String: Any]
        )
        var terminalManifestSources = try XCTUnwrap(
            terminalManifestArtifact["sources"] as? [[String: Any]]
        )
        terminalManifestSources[0]["role"] = "task-manifest"
        terminalManifestArtifact["sources"] = terminalManifestSources
        terminalManifestArtifact["sha256"] = sha256(
            try canonicalEvidenceData(["sources": terminalManifestSources])
        )
        terminalManifestG3["artifact"] = terminalManifestArtifact
        terminalManifestGates["g3"] = terminalManifestG3
        terminalManifestRoot["gates"] = terminalManifestGates
        try rebindEvidenceDigests(&terminalManifestRoot)
        let terminalManifestEvidence = try canonicalEvidenceData(terminalManifestRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(
                    evidence: terminalManifestEvidence,
                    root: terminalManifestRoot
                ),
                evidenceData: terminalManifestEvidence,
                now: trustedNow
            )
        )

        let (_, releaseRoot) = try compiledEvidenceFixture(named: "floorp-notes-sync-g1-g5-valid")
        var mixedRoot = root
        var mixedGates = try XCTUnwrap(mixedRoot["gates"] as? [String: Any])
        let releaseGates = try XCTUnwrap(releaseRoot["gates"] as? [String: Any])
        mixedGates["g5"] = releaseGates["g5"]
        mixedRoot["gates"] = mixedGates
        let mixed = try canonicalEvidenceData(mixedRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: mixed, root: mixedRoot),
                evidenceData: mixed,
                now: trustedNow
            )
        )
    }

    func testCompiledEvidenceRejectsSchemaInvalidUnexpectedRootField() throws {
        let (_, root) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        var schemaInvalidRoot = root
        schemaInvalidRoot["unexpected_runtime_bypass"] = true
        let schemaInvalidEvidence = try canonicalEvidenceData(schemaInvalidRoot)

        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: schemaInvalidEvidence, root: schemaInvalidRoot),
                evidenceData: schemaInvalidEvidence,
                now: try releaseEvidenceTrustedNow()
            )
        )
    }

    func testCompiledEvidenceRejectsLegacyAndReboundMalformedArtifactProvenance() throws {
        let (_, fixtureRoot) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        let trustedNow = try releaseEvidenceTrustedNow()

        var legacyRoot = fixtureRoot
        var legacyGates = try XCTUnwrap(legacyRoot["gates"] as? [String: Any])
        var legacyG1 = try XCTUnwrap(legacyGates["g1"] as? [String: Any])
        legacyG1["artifact"] = [
            "uri": "evidence://legacy-self-claim",
            "sha256": String(repeating: "1", count: 64),
        ]
        legacyGates["g1"] = legacyG1
        legacyRoot["gates"] = legacyGates
        try rebindEvidenceDigests(&legacyRoot)
        let legacyEvidence = try canonicalEvidenceData(legacyRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: legacyEvidence, root: legacyRoot),
                evidenceData: legacyEvidence,
                now: trustedNow
            )
        )

        var malformedRoot = fixtureRoot
        var malformedGates = try XCTUnwrap(malformedRoot["gates"] as? [String: Any])
        var malformedG1 = try XCTUnwrap(malformedGates["g1"] as? [String: Any])
        var artifact = try XCTUnwrap(malformedG1["artifact"] as? [String: Any])
        var sources = try XCTUnwrap(artifact["sources"] as? [[String: Any]])
        sources[0]["role"] = "attacker-manifest"
        artifact["sources"] = sources
        artifact["sha256"] = sha256(
            try canonicalEvidenceData(["sources": sources])
        )
        malformedG1["artifact"] = artifact
        malformedGates["g1"] = malformedG1
        malformedRoot["gates"] = malformedGates
        try rebindEvidenceDigests(&malformedRoot)
        let malformedEvidence = try canonicalEvidenceData(malformedRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: malformedEvidence, root: malformedRoot),
                evidenceData: malformedEvidence,
                now: trustedNow
            )
        )
    }

    func testCompiledEvidenceRejectsMissingOrFalsePinnedReleaseMetadata() throws {
        let (_, fixtureRoot) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        let trustedNow = try releaseEvidenceTrustedNow()

        var missingRoot = fixtureRoot
        try mutateFirstReleaseSource(in: &missingRoot) { source in
            source.removeValue(forKey: "release_immutable")
            source.removeValue(forKey: "release_prerelease")
            source.removeValue(forKey: "release_published_at")
        }
        let missingEvidence = try canonicalEvidenceData(missingRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: missingEvidence, root: missingRoot),
                evidenceData: missingEvidence,
                now: trustedNow
            )
        )

        for field in ["release_immutable", "release_prerelease", "release_published_at"] {
            var falseRoot = fixtureRoot
            try mutateFirstReleaseSource(in: &falseRoot) { source in
                source[field] = false
            }
            let falseEvidence = try canonicalEvidenceData(falseRoot)
            XCTAssertFalse(
                FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                    try compiledConfiguration(evidence: falseEvidence, root: falseRoot),
                    evidenceData: falseEvidence,
                    now: trustedNow
                )
            )
        }

        var malformedTimestampRoot = fixtureRoot
        try mutateFirstReleaseSource(in: &malformedTimestampRoot) { source in
            source["release_published_at"] = "not-a-timestamp"
        }
        let malformedTimestampEvidence = try canonicalEvidenceData(malformedTimestampRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(
                    evidence: malformedTimestampEvidence,
                    root: malformedTimestampRoot
                ),
                evidenceData: malformedTimestampEvidence,
                now: trustedNow
            )
        )
    }

    func testCompiledEvidenceRejectsUnverifiedEmbeddedG6() throws {
        let (_, fixtureRoot) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        var root = fixtureRoot
        var gates = try XCTUnwrap(root["gates"] as? [String: Any])
        gates["g6"] = [
            "status": "passed",
            "issued_at": "2026-08-10T00:00:00Z",
            "artifact": [
                "uri": "evidence://unverified-g6",
                "sha256": String(repeating: "6", count: 64),
            ],
        ]
        root["gates"] = gates
        let evidence = try canonicalEvidenceData(root)

        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: evidence, root: root),
                evidenceData: evidence,
                now: try releaseEvidenceTrustedNow()
            )
        )
    }

    func testCompiledEvidenceRejectsReboundWrongPinAndExpiredGate() throws {
        let (_, fixtureRoot) = try compiledEvidenceFixture(
            named: "floorp-notes-sync-g1-g5-valid"
        )
        let trustedNow = try releaseEvidenceTrustedNow()

        var wrongPinRoot = fixtureRoot
        var wrongPinInputs = try XCTUnwrap(wrongPinRoot["release_inputs"] as? [String: Any])
        var wrongPinAS = try XCTUnwrap(wrongPinInputs["application_services"] as? [String: Any])
        wrongPinAS["source_sha"] = String(repeating: "9", count: 40)
        wrongPinInputs["application_services"] = wrongPinAS
        wrongPinRoot["release_inputs"] = wrongPinInputs
        var wrongPinGates = try XCTUnwrap(wrongPinRoot["gates"] as? [String: Any])
        var g2 = try XCTUnwrap(wrongPinGates["g2"] as? [String: Any])
        g2["application_services"] = wrongPinAS
        wrongPinGates["g2"] = g2
        var g5 = try XCTUnwrap(wrongPinGates["g5"] as? [String: Any])
        var g5AS = try XCTUnwrap(g5["application_services"] as? [String: Any])
        g5AS["source_sha"] = String(repeating: "9", count: 40)
        g5["application_services"] = g5AS
        wrongPinGates["g5"] = g5
        wrongPinRoot["gates"] = wrongPinGates
        try rebindEvidenceDigests(&wrongPinRoot)
        let wrongPinEvidence = try canonicalEvidenceData(wrongPinRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: wrongPinEvidence, root: wrongPinRoot),
                evidenceData: wrongPinEvidence,
                now: trustedNow
            )
        )

        var expiredRoot = fixtureRoot
        var expiredGates = try XCTUnwrap(expiredRoot["gates"] as? [String: Any])
        var expiredG5 = try XCTUnwrap(expiredGates["g5"] as? [String: Any])
        expiredG5["expires_at"] = "2026-08-09T23:59:59Z"
        expiredGates["g5"] = expiredG5
        expiredRoot["gates"] = expiredGates
        try rebindEvidenceDigests(&expiredRoot)
        let expiredEvidence = try canonicalEvidenceData(expiredRoot)
        XCTAssertFalse(
            FloorpNotesSyncReleaseGate.allowsCompiledEvidence(
                try compiledConfiguration(evidence: expiredEvidence, root: expiredRoot),
                evidenceData: expiredEvidence,
                now: trustedNow
            )
        )
    }

    private func compiledConfiguration(
        evidence: Data,
        root: [String: Any],
        sourceSHA: String? = nil,
        buildNumber: String? = nil,
        evidenceDigest: String? = nil,
        requested: Any = "YES"
    ) throws -> FloorpNotesSyncCompiledConfiguration {
        let mode = try XCTUnwrap(root["build_contract_mode"] as? String)
        let inputs = try XCTUnwrap(root["release_inputs"] as? [String: Any])
        let ios = try XCTUnwrap(inputs["ios"] as? [String: Any])
        let contract = try XCTUnwrap(inputs["contract"] as? [String: Any])
        let digestKey = mode == "production-qa"
            ? "g1_g4_digest_sha256"
            : "g1_g5_digest_sha256"
        return FloorpNotesSyncCompiledConfiguration(
            buildMode: mode,
            sourceSHA: sourceSHA ?? (ios["source_sha"] as? String),
            buildNumber: buildNumber ?? (ios["build_number"] as? String),
            requested: requested,
            effective: "YES",
            registrationAllowed: "YES",
            engineRequestsAllowed: "YES",
            uiExposureAllowed: "YES",
            endpointAuthority: "production",
            wireProtocol: "sync15",
            endpointMatrixSHA256: contract["endpoint_policy_sha256"] as? String,
            evidenceDigest: evidenceDigest ?? (root[digestKey] as? String),
            evidenceResourceSHA256: SHA256.hash(data: evidence)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func compiledEvidenceFixture(
        named name: String
    ) throws -> (Data, [String: Any]) {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let url = repositoryRoot
            .appendingPathComponent("scripts/ci/fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("json")
        let fixtureData = try Data(contentsOf: url)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        )
        XCTAssertEqual(fixtureData, try canonicalEvidenceData(root))
        try bindSyntheticArtifactProvenance(&root)
        let evidence = try canonicalEvidenceData(root)
        return (evidence, root)
    }

    private func bindSyntheticArtifactProvenance(
        _ root: inout [String: Any]
    ) throws {
        let inputs = try XCTUnwrap(root["release_inputs"] as? [String: Any])
        let ios = try XCTUnwrap(inputs["ios"] as? [String: Any])
        let desktop = try XCTUnwrap(inputs["desktop"] as? [String: Any])
        let runtime = try XCTUnwrap(inputs["runtime"] as? [String: Any])
        let services = try XCTUnwrap(inputs["application_services"] as? [String: Any])
        let iosRepository = try XCTUnwrap(ios["repository"] as? String)
        let iosSHA = try XCTUnwrap(ios["source_sha"] as? String)
        let desktopRepository = try XCTUnwrap(desktop["repository"] as? String)
        let desktopSHA = try XCTUnwrap(desktop["source_sha"] as? String)
        let runtimeRepository = try XCTUnwrap(runtime["repository"] as? String)
        let runtimeSHA = try XCTUnwrap(runtime["source_sha"] as? String)
        let servicesRepository = try XCTUnwrap(services["repository"] as? String)
        let servicesSHA = try XCTUnwrap(services["source_sha"] as? String)
        let servicesTag = try XCTUnwrap(services["release_tag"] as? String)
        let syntheticG3Sources = g3Sources(repository: iosRepository, headSHA: iosSHA)
        let sourceSets: [String: [[String: Any]]] = [
            "g1": g1Sources(
                iosRepository: iosRepository,
                iosSHA: iosSHA,
                desktopRepository: desktopRepository,
                desktopSHA: desktopSHA
            ),
            "g2": g2Sources(
                repository: servicesRepository,
                sourceSHA: servicesSHA,
                tag: servicesTag
            ),
            "g3": syntheticG3Sources,
            "g4": g4Sources(
                iosRepository: iosRepository,
                iosSHA: iosSHA,
                desktopRepository: desktopRepository,
                desktopSHA: desktopSHA,
                runtimeRepository: runtimeRepository,
                runtimeSHA: runtimeSHA,
                attestationRun: syntheticG3Sources[1],
                attestationXCResult: syntheticG3Sources[2]
            ),
            "g5": g5Sources(repository: iosRepository, headSHA: iosSHA),
        ]
        var gates = try XCTUnwrap(root["gates"] as? [String: Any])
        for (name, sources) in sourceSets where gates[name] != nil {
            var gate = try XCTUnwrap(gates[name] as? [String: Any])
            gate["artifact"] = [
                "sources": sources,
                "sha256": sha256(
                    try canonicalEvidenceData(["sources": sources])
                ),
            ]
            gates[name] = gate
        }
        root["gates"] = gates
        try rebindEvidenceDigests(&root)
    }

    private func g1Sources(
        iosRepository: String,
        iosSHA: String,
        desktopRepository: String,
        desktopSHA: String
    ) -> [[String: Any]] {
        [
            localSource("task-manifest", policy: "metadata-json"),
            repositorySource(
                "todo16-contract",
                repository: desktopRepository,
                commit: desktopSHA,
                path: "docs/development/floorp-notes-sync/prerequisites.json",
                policy: "metadata-json"
            ),
            repositorySource(
                "ios-contract-source",
                repository: iosRepository,
                commit: iosSHA,
                path: "docs/floorp-notes-sync-architecture.md",
                policy: "source-code"
            ),
            repositorySource(
                "desktop-contract-source",
                repository: desktopRepository,
                commit: desktopSHA,
                path: "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
                policy: "source-code"
            ),
            repositorySource(
                "merge-fixture",
                repository: iosRepository,
                commit: iosSHA,
                path: "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
                policy: "metadata-json"
            ),
        ]
    }

    private func g2Sources(
        repository: String,
        sourceSHA: String,
        tag: String
    ) -> [[String: Any]] {
        let roles = [
            "focus-xcframework", "mozilla-xcframework", "release-manifest",
            "sha256sums", "swift-components",
        ]
        return [
            localSource("task-manifest", policy: "metadata-json"),
            localSource("fake-server-run", policy: "metadata-json"),
        ] + roles.enumerated().map { index, role in
            releaseAssetSource(
                role,
                repository: repository,
                sourceSHA: sourceSHA,
                tag: tag,
                assetID: index + 1
            )
        }
    }

    private func g3Sources(
        repository: String,
        headSHA: String
    ) -> [[String: Any]] {
        [
            localSource("integration-receipt", policy: "metadata-json"),
            actionsRunSource(
                "ci-run",
                repository: repository,
                headSHA: headSHA,
                runID: 3
            ),
            actionsArtifactSource(
                "xcresult",
                repository: repository,
                headSHA: headSHA,
                runID: 3,
                artifactID: 3
            ),
        ]
    }

    private func g4Sources(
        iosRepository: String,
        iosSHA: String,
        desktopRepository: String,
        desktopSHA: String,
        runtimeRepository: String,
        runtimeSHA: String,
        attestationRun: [String: Any],
        attestationXCResult: [String: Any]
    ) -> [[String: Any]] {
        var reboundRun = attestationRun
        reboundRun["role"] = "g4-attestation-ci-run"
        var reboundXCResult = attestationXCResult
        reboundXCResult["role"] = "g4-attestation-xcresult"
        return [
            localSource("task-manifest", policy: "metadata-json"),
            localSource("task18-execution-verdict", policy: "metadata-json"),
            actionsRunSource(
                "desktop-ci-run",
                repository: desktopRepository,
                headSHA: desktopSHA,
                runID: 4
            ),
            actionsRunSource(
                "runtime-ci-run",
                repository: runtimeRepository,
                headSHA: runtimeSHA,
                runID: 5
            ),
            repositorySource(
                "g4-attestation-source",
                repository: iosRepository,
                commit: iosSHA,
                path: "docs/floorp-notes-sync-g4-attestation.json",
                policy: "metadata-json"
            ),
            reboundRun,
            reboundXCResult,
            localSource("xpcshell-run", policy: "metadata-json"),
            localSource("tps-run", policy: "metadata-json"),
        ]
    }

    private func g5Sources(
        repository: String,
        headSHA: String
    ) -> [[String: Any]] {
        [
            localSource("task-manifest", policy: "metadata-json"),
            actionsRunSource(
                "ci-run",
                repository: repository,
                headSHA: headSHA,
                runID: 6
            ),
            actionsArtifactSource(
                "xcresult",
                repository: repository,
                headSHA: headSHA,
                runID: 6,
                artifactID: 6
            ),
            localSource("account-isolation-run", policy: "metadata-json"),
            localSource("proxy-trace", policy: "network-metadata-json"),
        ]
    }

    private func localSource(
        _ role: String,
        policy: String
    ) -> [String: Any] {
        [
            "kind": "local-file",
            "role": role,
            "content_policy": policy,
            "path": "artifacts/\(role).json",
            "sha256": sha256(Data("local:\(role)".utf8)),
        ]
    }

    private func repositorySource(
        _ role: String,
        repository: String,
        commit: String,
        path: String,
        policy: String
    ) -> [String: Any] {
        [
            "kind": "github-repository-file",
            "role": role,
            "content_policy": policy,
            "repository": repository,
            "commit_sha": commit,
            "path": path,
            "blob_sha": String(repeating: "a", count: 40),
            "sha256": sha256(Data("repository:\(role)".utf8)),
        ]
    }

    private func actionsRunSource(
        _ role: String,
        repository: String,
        headSHA: String,
        runID: Int
    ) -> [String: Any] {
        [
            "kind": "github-actions-run",
            "role": role,
            "content_policy": "metadata-json",
            "repository": repository,
            "run_id": runID,
            "workflow_path": ".github/workflows/ci.yml",
            "head_sha": headSHA,
            "sha256": sha256(Data("run:\(role)".utf8)),
        ]
    }

    private func actionsArtifactSource(
        _ role: String,
        repository: String,
        headSHA: String,
        runID: Int,
        artifactID: Int
    ) -> [String: Any] {
        [
            "kind": "github-actions-artifact",
            "role": role,
            "content_policy": "test-result-bundle",
            "repository": repository,
            "run_id": runID,
            "artifact_id": artifactID,
            "artifact_name": "floorp-notes-sync-xcresult",
            "artifact_created_at": "2026-08-09T23:31:00Z",
            "artifact_expires_at": "2026-08-16T23:31:00Z",
            "head_sha": headSHA,
            "sha256": sha256(Data("artifact:\(role)".utf8)),
        ]
    }

    private func releaseAssetSource(
        _ role: String,
        repository: String,
        sourceSHA: String,
        tag: String,
        assetID: Int
    ) -> [String: Any] {
        [
            "kind": "github-release-asset",
            "role": role,
            "content_policy": "release-binary",
            "repository": repository,
            "release_id": 1,
            "release_tag": tag,
            "release_immutable": true,
            "release_prerelease": true,
            "release_published_at": "2026-08-08T05:41:30Z",
            "asset_id": assetID,
            "asset_name": "\(role).artifact",
            "source_sha": sourceSHA,
            "sha256": sha256(Data("release:\(role)".utf8)),
        ]
    }

    private func mutateFirstReleaseSource(
        in root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) throws {
        var gates = try XCTUnwrap(root["gates"] as? [String: Any])
        var g2 = try XCTUnwrap(gates["g2"] as? [String: Any])
        var artifact = try XCTUnwrap(g2["artifact"] as? [String: Any])
        var sources = try XCTUnwrap(artifact["sources"] as? [[String: Any]])
        let index = try XCTUnwrap(
            sources.firstIndex { $0["kind"] as? String == "github-release-asset" }
        )
        mutation(&sources[index])
        artifact["sources"] = sources
        artifact["sha256"] = sha256(
            try canonicalEvidenceData(["sources": sources])
        )
        g2["artifact"] = artifact
        gates["g2"] = g2
        root["gates"] = gates
        try rebindEvidenceDigests(&root)
    }

    private func canonicalEvidenceData(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func rebindEvidenceDigests(_ root: inout [String: Any]) throws {
        let mode = try XCTUnwrap(root["build_contract_mode"] as? String)
        let inputs = try XCTUnwrap(root["release_inputs"] as? [String: Any])
        let gates = try XCTUnwrap(root["gates"] as? [String: Any])
        let names = mode == "production-qa"
            ? ["g1", "g2", "g3", "g4"]
            : ["g1", "g2", "g3", "g4", "g5"]
        let boundGates = Dictionary(uniqueKeysWithValues: try names.map { name in
            (name, try XCTUnwrap(gates[name]))
        })
        let digestKey = mode == "production-qa"
            ? "g1_g4_digest_sha256"
            : "g1_g5_digest_sha256"
        root[digestKey] = sha256(
            try canonicalEvidenceData(
                ["gates": boundGates, "release_inputs": inputs]
            )
        )
        let gateDigests = Dictionary(uniqueKeysWithValues: try gates.map { name, value in
            let gate = try XCTUnwrap(value as? [String: Any])
            let artifact = try XCTUnwrap(gate["artifact"] as? [String: Any])
            return (name, try XCTUnwrap(artifact["sha256"] as? String))
        })
        root["same_release_key_sha256"] = sha256(
            try canonicalEvidenceData(
                ["gate_artifact_digests": gateDigests, "release_inputs": inputs]
            )
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func releaseEvidenceTrustedNow() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T00:00:00Z"))
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
