// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Owns the Floorp Notes editor save state: change versions, in-flight
/// save coalescing, retry state, and autosave scheduling. Extracted from
/// the editor view controller so all of it is testable without UIKit or
/// real timers (issue #21).
@MainActor
final class FloorpNoteSaveCoordinator {
    enum FailureKind: Equatable, Hashable {
        case conflict
        case noteDeleted
        case archiveTooLarge
        case damagedArchive
        case newerSchema
        case storage
    }

    struct Failure {
        let kind: FailureKind
        let underlyingError: Error
    }

    enum SaveOutcome {
        case noChanges
        case saved(FloorpNote)
        case failed(Failure)
    }

    private let persistence: FloorpNotePersistence
    private(set) var draft: FloorpNote
    private(set) var changeVersion = 0
    private(set) var savedVersion = 0
    private(set) var contentChangeVersion = 0
    private(set) var savedContentVersion = 0
    private(set) var hasPersistedNote: Bool
    private(set) var lastFailure: Failure?
    private var isSaving = false
    private var saveWaiters = [CheckedContinuation<Void, Never>]()

    var hasUnsavedChanges: Bool { savedVersion != changeVersion }
    var hasUnsavedContentChanges: Bool { savedContentVersion != contentChangeVersion }

    init(draft: FloorpNote, isPersisted: Bool, persistence: FloorpNotePersistence) {
        self.draft = draft
        self.hasPersistedNote = isPersisted
        self.persistence = persistence
    }

    @discardableResult
    func updateTitle(_ title: String) -> Bool {
        guard draft.title != title else { return false }
        draft.title = title
        markChanged()
        return true
    }

    @discardableResult
    func updateContent(
        _ content: String,
        contentFormat: FloorpNoteContentFormat? = nil
    ) -> Bool {
        let nextFormat = contentFormat ?? draft.contentFormat
        guard draft.content != content || draft.contentFormat != nextFormat else { return false }
        draft.content = content
        draft.contentFormat = nextFormat
        contentChangeVersion += 1
        markChanged()
        return true
    }

    func requestExplicitSave() {
        if !hasPersistedNote && !hasUnsavedChanges {
            markChanged()
        }
    }

    func preflightContentUpdate(
        _ content: String,
        contentFormat: FloorpNoteContentFormat
    ) async throws {
        while true {
            let candidateVersion = changeVersion
            var candidate = draft
            candidate.content = content
            candidate.contentFormat = contentFormat
            try await persistence.preflight(candidate)
            guard changeVersion != candidateVersion else { return }
        }
    }

    /// Replaces a plain-text body only if it is still the body that was
    /// converted. Title edits can race the asynchronous preflight and are
    /// retried, while a newer body makes the caller rebuild the rich document.
    func preflightAndReplaceContent(
        expectedContent: String,
        expectedContentFormat: FloorpNoteContentFormat,
        content: String,
        contentFormat: FloorpNoteContentFormat
    ) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            guard draft.content == expectedContent,
                  draft.contentFormat == expectedContentFormat else {
                return false
            }
            let candidateVersion = changeVersion
            var candidate = draft
            candidate.content = content
            candidate.contentFormat = contentFormat
            try await persistence.preflight(candidate)
            try Task.checkCancellation()
            guard draft.content == expectedContent,
                  draft.contentFormat == expectedContentFormat else {
                return false
            }
            guard changeVersion == candidateVersion else { continue }
            _ = updateContent(content, contentFormat: contentFormat)
            return true
        }
    }

    func preflightCopyContent(
        _ content: String,
        contentFormat: FloorpNoteContentFormat
    ) async throws {
        var candidate = draft
        candidate.content = content
        candidate.contentFormat = contentFormat
        try await persistence.preflightCopy(candidate)
    }

    func saveLatest() async -> SaveOutcome {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            if let lastFailure { return .failed(lastFailure) }
            return hasUnsavedChanges ? await saveLatest() : .noChanges
        }
        guard hasUnsavedChanges else { return .noChanges }

        isSaving = true
        var lastSavedNote: FloorpNote?

        repeat {
            let versionToSave = changeVersion
            let contentVersionToSave = contentChangeVersion
            let noteToSave = draft
            do {
                let persistedNote = try await persistence.save(noteToSave)
                savedVersion = versionToSave
                savedContentVersion = contentVersionToSave
                hasPersistedNote = true
                lastFailure = nil
                adoptPersistenceIdentity(from: persistedNote)
                lastSavedNote = persistedNote
            } catch {
                let failure = Failure(kind: Self.failureKind(for: error), underlyingError: error)
                lastFailure = failure
                finishSaving()
                return .failed(failure)
            }
        } while hasUnsavedChanges

        finishSaving()
        return lastSavedNote.map(SaveOutcome.saved) ?? .noChanges
    }

    func reload() async throws -> FloorpNote {
        let requestedVersion = changeVersion
        let requestedNoteID = draft.id
        await waitUntilIdle()
        isSaving = true
        defer { finishSaving() }
        guard changeVersion == requestedVersion, draft.id == requestedNoteID else {
            throw FloorpNotesStoreError.editConflict(requestedNoteID)
        }
        guard let note = try await persistence.reload() else {
            throw FloorpNotesStoreError.noteNotFound(draft.id)
        }
        guard changeVersion == requestedVersion, draft.id == requestedNoteID else {
            throw FloorpNotesStoreError.editConflict(requestedNoteID)
        }
        persistence.acceptReloaded(note)
        draft = note
        changeVersion = 0
        savedVersion = 0
        contentChangeVersion = 0
        savedContentVersion = 0
        hasPersistedNote = true
        lastFailure = nil
        return note
    }

    func saveAsCopy() async -> SaveOutcome {
        await waitUntilIdle()
        isSaving = true
        let versionToSave = changeVersion
        let contentVersionToSave = contentChangeVersion
        let noteToSave = draft
        do {
            let persistedNote = try await persistence.saveAsCopy(noteToSave)
            savedVersion = versionToSave
            savedContentVersion = contentVersionToSave
            hasPersistedNote = true
            lastFailure = nil
            adoptPersistenceIdentity(from: persistedNote)
            finishSaving()
            if hasUnsavedChanges {
                return await saveLatest()
            }
            return .saved(persistedNote)
        } catch {
            let failure = Failure(kind: Self.failureKind(for: error), underlyingError: error)
            lastFailure = failure
            finishSaving()
            return .failed(failure)
        }
    }

    private func markChanged() {
        changeVersion += 1
        lastFailure = nil
    }

    private func adoptPersistenceIdentity(from persistedNote: FloorpNote) {
        draft = FloorpNote(
            id: persistedNote.id,
            title: draft.title,
            content: draft.content,
            createdAt: persistedNote.createdAt,
            updatedAt: persistedNote.updatedAt,
            contentFormat: draft.contentFormat
        )
    }

    private func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitUntilIdle() async {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            await waitUntilIdle()
        }
    }

    static func failureKind(for error: Error) -> FailureKind {
        switch error {
        case FloorpNotesStoreError.editConflict:
            return .conflict
        case FloorpNotesStoreError.noteNotFound:
            return .noteDeleted
        case FloorpNotesStoreError.archiveTooLarge, FloorpNotesStoreError.tooManyNotes:
            return .archiveTooLarge
        case FloorpNotesStoreError.corruptArchive,
             FloorpNotesStoreError.corruptArchiveCouldNotBePreserved,
             FloorpNotesStoreError.writesBlockedByCorruption:
            return .damagedArchive
        case FloorpNotesStoreError.unsupportedSchema:
            return .newerSchema
        default:
            return .storage
        }
    }

    // MARK: - Autosave scheduling (deterministic, injectable sleep)

    /// Invoked when a scheduled autosave fires. The editor wires this to its
    /// save path; tests drive it without real timers.
    var onAutosave: (@MainActor () async -> Void)?

    nonisolated(unsafe) private var autosaveTask: Task<Void, Never>?

    /// Schedules an autosave after `delayNanoseconds`, replacing any pending
    /// schedule. `sleep` is injectable so tests control time deterministically;
    /// the default is the real task sleep.
    func scheduleAutosave(
        delayNanoseconds: UInt64,
        sleep: @escaping (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.onAutosave?()
        }
    }

    /// Cancels any pending autosave. Safe from any isolation domain (the
    /// editor calls this from `deinit`).
    nonisolated func cancelAutosave() {
        autosaveTask?.cancel()
    }
}
