// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import Client

final class FloorpNotesSyncMergeTests: XCTestCase, @unchecked Sendable {
    func testFirstSyncPreservesLocalOrderAndAppendsRemoteNewNotes() throws {
        let local = [note("local-b"), note("local-a")]
        let remote = [note("remote-c")]

        let result = try FloorpNotesSyncMerger.merge(base: [], local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id), ["local-b", "local-a", "remote-c"])
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

        XCTAssertEqual(result.notes.map(\.id), ["local-edit", "remote-edit"])
        XCTAssertEqual(result.notes.first?.content, "local")
        XCTAssertEqual(result.notes.last?.content, "remote")
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testDeleteVersusEditKeepsTheEdit() throws {
        let base = [note("local-deleted", content: "base"), note("remote-deleted", content: "base")]
        let local = [note("remote-deleted", content: "local edit", updatedAt: 20)]
        let remote = [note("local-deleted", content: "remote edit", updatedAt: 30)]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id), ["remote-deleted", "local-deleted"])
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
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.notes[1].id, result.conflicts[0].conflictCopyID)
        XCTAssertTrue(result.notes[1].id.hasPrefix("floorp-sync-conflict-"))
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
            sharedFirst.conflicts.first(where: { $0.originalNoteID == "shared" })
        )

        XCTAssertEqual(sharedFirstByID, candidateFirstByID)
        XCTAssertEqual(sharedFirst.conflicts, candidateFirst.conflicts)
        XCTAssertEqual(sharedFirst.notes.count, 4)
        XCTAssertNotEqual(sharedConflict.conflictCopyID, collidingID)
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

    func testOneSidedRemoteReorderWins() throws {
        let base = [note("a"), note("b"), note("c")]
        let remote = [base[2], base[0], base[1]]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: base, remote: remote)

        XCTAssertEqual(result.notes.map(\.id), ["c", "a", "b"])
    }

    func testConcurrentReorderPrefersLocalAndAppendsRemoteNew() throws {
        let base = [note("a"), note("b"), note("c")]
        let local = [base[1], base[0], base[2], note("local-new")]
        let remote = [base[2], base[1], base[0], note("remote-new")]

        let result = try FloorpNotesSyncMerger.merge(base: base, local: local, remote: remote)

        XCTAssertEqual(result.notes.map(\.id), ["b", "a", "c", "local-new", "remote-new"])
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
                .duplicateNoteID(source: .base, id: "duplicate")
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
                .duplicateNoteID(source: .remote, id: "duplicate")
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
        XCTAssertEqual(payload.ids, first.mergedNotes.map(\.id))
        XCTAssertEqual(payload.titles, ["One", "Two"])
        XCTAssertEqual(payload.contents, ["First", "Second"])
        XCTAssertEqual(payload.createdAts, [100, 100])
        XCTAssertEqual(payload.updatedAts, [100, 100])
        XCTAssertTrue(first.requiresUpload)
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

        XCTAssertEqual(plan.mergedNotes.map(\.id), ["one"])
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
                .duplicateNoteID(source: .remote, id: "same")
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

        XCTAssertEqual(plan.mergedNotes.map(\.id), [exactID])
        XCTAssertFalse(plan.requiresUpload)
        XCTAssertNil(plan.uploadPayloadData)
    }

    func testPlannerRejectsUnknownRemoteFields() {
        let record = FloorpNotesSyncRemoteRecord(
            payloadData: Data(#"{"titles":[],"contents":[],"future":true}"#.utf8),
            revision: "remote-1",
            maximumPayloadBytes: FloorpNotesStore.maximumArchiveBytes
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
        let payload = try remoteRecord(FloorpNotesDesktopPayload(notes: []))
        let bytesWithoutRevision = FloorpNotesSyncRemoteRecord(
            payloadData: payload.payloadData,
            revision: nil,
            maximumPayloadBytes: payload.maximumPayloadBytes
        )
        let revisionWithoutBytes = FloorpNotesSyncRemoteRecord(
            payloadData: nil,
            revision: "remote-1",
            maximumPayloadBytes: payload.maximumPayloadBytes
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
            payloadData: emptyRemoteRecord.payloadData,
            revision: nil,
            maximumPayloadBytes: 0
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
        let actualBytes = payloadData.count
        let record = FloorpNotesSyncRemoteRecord(
            payloadData: payloadData,
            revision: "remote-oversized",
            maximumPayloadBytes: actualBytes - 1
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
            maximumPayloadBytes: FloorpNotesStore.maximumArchiveBytes
        )

        XCTAssertEqual(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumPayloadBytes: data.count
            ),
            data
        )
        XCTAssertThrowsError(
            try FloorpNotesSyncPlanner.encodedPayload(
                notes: notes,
                maximumPayloadBytes: data.count - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpNotesSyncError,
                .recordTooLarge(actualBytes: data.count, maximumBytes: data.count - 1)
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
            payloadData: payloadData,
            revision: "remote-1",
            maximumPayloadBytes: payloadData.count
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
            payloadData: nil,
            revision: nil,
            maximumPayloadBytes: FloorpNotesStore.maximumArchiveBytes
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
        XCTAssertEqual(candidate.notes.map(\.id), ["local"])
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
        maximumPayloadBytes: Int = FloorpNotesStore.maximumArchiveBytes
    ) throws -> FloorpNotesSyncRemoteRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return FloorpNotesSyncRemoteRecord(
            payloadData: try encoder.encode(payload),
            revision: revision,
            maximumPayloadBytes: maximumPayloadBytes
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
        FloorpNote(
            id: id,
            title: title,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            contentFormat: contentFormat
        )
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
