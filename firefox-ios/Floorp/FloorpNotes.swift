// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

// MARK: - Note model

/// A Floorp note as it is represented inside the iOS application.
///
/// `content` is intentionally kept as an opaque string. Floorp desktop stores
/// either plain text, legacy Lexical JSON, or TipTap JSON in this field. Keeping
/// the original value avoids destroying editor nodes that this client does not
/// understand yet.
struct FloorpNote: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var content: String
    let createdAt: Int64
    var updatedAt: Int64
}

// MARK: - Desktop wire format

/// The parallel-array payload currently used by Floorp desktop's
/// `floorp.browser.note.memos` preference.
///
/// iOS does not persist this shape internally. It is isolated here so a future
/// sync adapter can interoperate without coupling the editor to desktop's
/// legacy storage layout.
struct FloorpNotesDesktopPayload: Codable, Equatable, Sendable {
    var ids: [String]?
    var titles: [String]
    var contents: [String]
    var createdAts: [Int64]?
    var updatedAts: [Int64]?

    init(
        ids: [String]? = nil,
        titles: [String],
        contents: [String],
        createdAts: [Int64]? = nil,
        updatedAts: [Int64]? = nil
    ) {
        self.ids = ids
        self.titles = titles
        self.contents = contents
        self.createdAts = createdAts
        self.updatedAts = updatedAts
    }

    init(notes: [FloorpNote]) {
        ids = notes.map(\.id)
        titles = notes.map(\.title)
        contents = notes.map(\.content)
        createdAts = notes.map(\.createdAt)
        updatedAts = notes.map(\.updatedAt)
    }

    func normalizedNotes(
        now: Int64 = FloorpNotesStore.currentTimeInMilliseconds(),
        makeID: () -> String = { UUID().uuidString }
    ) throws -> [FloorpNote] {
        let count = [
            titles.count,
            contents.count,
            ids?.count ?? 0,
            createdAts?.count ?? 0,
            updatedAts?.count ?? 0
        ].max() ?? 0
        guard count <= FloorpNotesStore.maximumNoteCount else {
            throw FloorpNotesStoreError.tooManyNotes(count)
        }

        var usedIDs = Set<String>()
        var notes = [FloorpNote]()
        notes.reserveCapacity(count)

        for index in 0..<count {
            let candidateID = value(at: index, in: ids)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = candidateID.flatMap { $0.isEmpty ? nil : $0 } ?? makeID()
            while usedIDs.contains(id) {
                id = makeID()
            }
            usedIDs.insert(id)

            let createdAt = validTimestamp(value(at: index, in: createdAts)) ?? now
            let updatedAt = max(validTimestamp(value(at: index, in: updatedAts)) ?? createdAt, createdAt)
            notes.append(
                FloorpNote(
                    id: id,
                    title: value(at: index, in: titles) ?? "",
                    content: value(at: index, in: contents) ?? "",
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return notes
    }

    private func value<T>(at index: Int, in values: [T]?) -> T? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func validTimestamp(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

// MARK: - Safe plain-text projection

enum FloorpNoteContent {
    private static let maximumInputBytes = FloorpNotesStore.maximumArchiveBytes
    private static let maximumDepth = 64
    private static let maximumNodeCount = 10_000
    private static let maximumOutputCharacters = FloorpNotesStore.maximumArchiveBytes
    private static let supportedContainerNodeTypes: Set<String> = [
        "doc", "root", "paragraph", "heading", "blockquote", "quote",
        "codeblock", "bulletlist", "orderedlist", "list", "listitem",
        "link", "autolink"
    ]
    private static let blockNodeTypes: Set<String> = [
        "paragraph", "heading", "blockquote", "quote", "codeblock", "listitem"
    ]

    struct Analysis: Equatable, Sendable {
        enum Format: Equatable, Sendable {
            case plainText
            case tipTap
            case lexical
            case unknownJSON
        }

        enum EditPolicy: Equatable, Sendable {
            case direct
            case requiresConversion
            case readOnly
        }

        enum Loss: Hashable, Sendable {
            case formattingAndStructure
            case embeddedMedia
            case unsupportedContent
            case projectionLimit
            case unknownJSON
        }

        let format: Format
        /// Text used for list previews and full-content search.
        let previewText: String
        /// Untrimmed text shown by the editor.
        let editorText: String
        let losses: Set<Loss>
        let isComplete: Bool

        var editPolicy: EditPolicy {
            switch format {
            case .plainText:
                return .direct
            case .unknownJSON:
                return .readOnly
            case .tipTap, .lexical:
                if !isComplete || losses.contains(.embeddedMedia) || losses.contains(.unsupportedContent) {
                    return .readOnly
                }
                return .requiresConversion
            }
        }
    }

    /// Parses the content once so preview and edit safety cannot disagree.
    /// Unknown JSON is deliberately preserved as its original string, matching
    /// Floorp desktop's migration behavior.
    static func analyze(_ content: String) -> Analysis {
        guard content.utf8.count <= maximumInputBytes,
              let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Analysis(
                format: .plainText,
                previewText: content,
                editorText: content,
                losses: [],
                isComplete: true
            )
        }

        guard let dictionary = object as? [String: Any] else {
            return Analysis(
                format: .unknownJSON,
                previewText: limited(content),
                editorText: content,
                losses: [.unknownJSON],
                isComplete: content.count <= maximumOutputCharacters
            )
        }

        let format: Analysis.Format
        let root: Any
        if dictionary["type"] as? String == "doc" {
            format = .tipTap
            root = dictionary
        } else if let lexicalRoot = dictionary["root"] as? [String: Any],
                  lexicalRoot["children"] is [Any] {
            format = .lexical
            root = lexicalRoot
        } else {
            let original = limited(content)
            return Analysis(
                format: .unknownJSON,
                previewText: original,
                editorText: content,
                losses: [.unknownJSON],
                isComplete: content.count <= maximumOutputCharacters
            )
        }

        var projection = Projection(format: format)
        return projection.analyze(root)
    }

    static func isRichText(_ content: String) -> Bool {
        switch analyze(content).format {
        case .tipTap, .lexical:
            return true
        case .plainText, .unknownJSON:
            return false
        }
    }

    static func plainText(from content: String) -> String {
        analyze(content).previewText
    }

    private struct Projection {
        let format: Analysis.Format
        var output = ""
        var visitedNodes = 0
        var isComplete = true
        var losses: Set<Analysis.Loss> = [.formattingAndStructure]
        var lastAppendWasStructuralSeparator = false

        mutating func analyze(_ root: Any) -> Analysis {
            walk(root, depth: 0)
            if lastAppendWasStructuralSeparator {
                output.removeLast()
            }
            return Analysis(
                format: format,
                previewText: output.trimmingCharacters(in: .whitespacesAndNewlines),
                editorText: output,
                losses: losses,
                isComplete: isComplete
            )
        }

        mutating func walk(_ value: Any, depth: Int) {
            guard depth <= FloorpNoteContent.maximumDepth,
                  visitedNodes < FloorpNoteContent.maximumNodeCount else {
                markProjectionLimit()
                return
            }
            visitedNodes += 1

            guard let node = value as? [String: Any] else {
                losses.insert(.unsupportedContent)
                return
            }

            let declaredType = (node["type"] as? String)?.lowercased()
            let normalizedType = declaredType ?? (depth == 0 && format == .lexical ? "root" : nil)
            if handleLeaf(node, type: normalizedType) { return }

            if let normalizedType,
               !FloorpNoteContent.supportedContainerNodeTypes.contains(normalizedType) {
                losses.insert(.unsupportedContent)
                if let text = node["text"] as? String {
                    appendText(text)
                }
            } else if normalizedType == nil {
                losses.insert(.unsupportedContent)
            }

            let childValue = node["content"] ?? node["children"]
            if let children = childValue as? [Any] {
                for child in children {
                    walk(child, depth: depth + 1)
                }
            } else if childValue != nil {
                losses.insert(.unsupportedContent)
            }

            if normalizedType.map(FloorpNoteContent.blockNodeTypes.contains) == true {
                appendBlockSeparator()
            }
        }

        private mutating func handleLeaf(_ node: [String: Any], type: String?) -> Bool {
            switch type {
            case "text":
                if let text = node["text"] as? String {
                    appendText(text)
                } else {
                    losses.insert(.unsupportedContent)
                }
            case "hardbreak", "linebreak":
                appendText("\n")
            case "tab":
                appendText("\t")
            case "image":
                // Never traverse attrs.src: it can contain a base64 image or URL.
                losses.insert(.embeddedMedia)
            case "horizontalrule":
                losses.insert(.unsupportedContent)
            default:
                return false
            }
            return true
        }

        private mutating func appendText(_ text: String, structuralSeparator: Bool = false) {
            let available = FloorpNoteContent.maximumOutputCharacters - output.count
            guard available > 0 else {
                markProjectionLimit()
                return
            }
            let prefix = text.prefix(available)
            output.append(contentsOf: prefix)
            if prefix.count != text.count {
                markProjectionLimit()
            }
            lastAppendWasStructuralSeparator = structuralSeparator
        }

        private mutating func appendBlockSeparator() {
            guard !output.isEmpty, !output.hasSuffix("\n") else { return }
            appendText("\n", structuralSeparator: true)
        }

        private mutating func markProjectionLimit() {
            isComplete = false
            losses.insert(.projectionLimit)
        }
    }

    private static func limited(_ string: String) -> String {
        String(string.prefix(maximumOutputCharacters))
    }
}

// MARK: - Store

enum FloorpNotesStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case corruptArchive(recoveryURL: URL)
    case corruptArchiveCouldNotBePreserved
    case writesBlockedByCorruption(recoveryURL: URL)
    case invalidNoteID
    case duplicateNoteID(String)
    case noteNotFound(String)
    case editConflict(String)
    case timestampExhausted(String)
    case tooManyNotes(Int)
    case archiveTooLarge(actualBytes: Int, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported Floorp Notes schema version: \(version)"
        case .corruptArchive:
            return "Floorp Notes data is damaged. A recovery copy was preserved."
        case .corruptArchiveCouldNotBePreserved:
            return "Floorp Notes data is damaged and could not be copied for recovery."
        case .writesBlockedByCorruption:
            return "Floorp Notes cannot be changed until the damaged archive is reset."
        case .invalidNoteID:
            return "A note has an invalid identifier."
        case .duplicateNoteID:
            return "Two notes have the same identifier."
        case .noteNotFound:
            return "The note no longer exists."
        case .editConflict:
            return "The note changed in another window."
        case .timestampExhausted:
            return "The note timestamp cannot be advanced."
        case .tooManyNotes(let count):
            return "The notes archive contains too many notes (\(count))."
        case .archiveTooLarge(let actualBytes, let maximumBytes):
            return "The notes archive is too large (\(actualBytes) bytes; maximum \(maximumBytes))."
        }
    }
}

/// Serial, crash-safe persistence for local Floorp Notes.
///
/// This is deliberately local-only. Firefox iOS currently has no preferences
/// sync engine compatible with desktop's `services.sync.prefs` record. A
/// future sync layer should use the desktop adapter above and the archive
/// revision for conflict detection rather than bypassing this actor.
actor FloorpNotesStore {
    static let shared = FloorpNotesStore(fileURL: defaultArchiveURL())

    static let currentSchemaVersion = 1
    static let maximumNoteCount = 1_000
    static let maximumArchiveBytes = 1_000_000

    private struct Archive: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let revision: UInt64
        let notes: [FloorpNote]
    }

    private enum CorruptionState: Sendable {
        case preserved(recoveryURL: URL)
        case couldNotPreserve
    }

    private let fileURL: URL
    private let now: @Sendable () -> Int64
    private let makeID: @Sendable () -> String
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private var cachedArchive: Archive?
    private var corruptionState: CorruptionState?

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Int64 = FloorpNotesStore.currentTimeInMilliseconds,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString },
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.makeID = makeID
        self.copyItem = copyItem
    }

    func loadNotes() throws -> [FloorpNote] {
        try loadArchive().notes
    }

    @discardableResult
    func createNote(title: String, content: String = "") throws -> FloorpNote {
        let archive = try loadArchiveForWriting()
        let timestamp = now()
        var id = makeID()
        let existingIDs = Set(archive.notes.map(\.id))
        while id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || existingIDs.contains(id) {
            id = makeID()
        }

        let note = FloorpNote(
            id: id,
            title: title,
            content: content,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var notes = archive.notes
        notes.insert(note, at: 0)
        try commit(notes: notes, replacing: archive)
        return note
    }

    @discardableResult
    func updateNote(
        id: String,
        title: String,
        content: String,
        expectedUpdatedAt: Int64? = nil
    ) throws -> FloorpNote {
        let archive = try loadArchiveForWriting()
        guard let index = archive.notes.firstIndex(where: { $0.id == id }) else {
            throw FloorpNotesStoreError.noteNotFound(id)
        }

        var notes = archive.notes
        var note = notes[index]
        if let expectedUpdatedAt, note.updatedAt != expectedUpdatedAt {
            throw FloorpNotesStoreError.editConflict(id)
        }
        guard note.updatedAt < Int64.max else {
            throw FloorpNotesStoreError.timestampExhausted(id)
        }
        note.title = title
        note.content = content
        note.updatedAt = [now(), note.createdAt, note.updatedAt + 1].max() ?? note.updatedAt + 1
        notes[index] = note
        try commit(notes: notes, replacing: archive)
        return note
    }

    func deleteNote(id: String) throws {
        let archive = try loadArchiveForWriting()
        guard archive.notes.contains(where: { $0.id == id }) else {
            throw FloorpNotesStoreError.noteNotFound(id)
        }
        try commit(notes: archive.notes.filter { $0.id != id }, replacing: archive)
    }

    /// Reorders known IDs and preserves all omitted notes at the end. This is
    /// important when an older client submits an order that predates new data.
    func reorderNotes(orderedIDs: [String]) throws {
        let archive = try loadArchiveForWriting()
        let notesByID = Dictionary(uniqueKeysWithValues: archive.notes.map { ($0.id, $0) })
        var seen = Set<String>()
        var reordered = orderedIDs.compactMap { id -> FloorpNote? in
            guard seen.insert(id).inserted else { return nil }
            return notesByID[id]
        }
        reordered.append(contentsOf: archive.notes.filter { !seen.contains($0.id) })
        try commit(notes: reordered, replacing: archive)
    }

    /// Replaces local notes with an explicitly imported set.
    func replaceAllNotes(with notes: [FloorpNote]) throws {
        let archive = try loadArchiveForWriting()
        try commit(notes: notes, replacing: archive)
    }

    func desktopPayloadData() throws -> Data {
        let notes = try loadArchive().notes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FloorpNotesDesktopPayload(notes: notes))
        try validateSize(data)
        return data
    }

    /// Allows the UI to recover only after an explicit destructive decision
    /// and only when a separate recovery copy was successfully created.
    func resetAfterCorruption() throws {
        guard let corruptionState else { return }
        guard case .preserved = corruptionState else {
            throw FloorpNotesStoreError.corruptArchiveCouldNotBePreserved
        }
        let emptyArchive = Archive(schemaVersion: Self.currentSchemaVersion, revision: 1, notes: [])
        try persist(emptyArchive)
        cachedArchive = emptyArchive
        self.corruptionState = nil
        postChangeNotification(revision: emptyArchive.revision)
    }

    private func loadArchiveForWriting() throws -> Archive {
        if let corruptionState {
            switch corruptionState {
            case .preserved(let recoveryURL):
                throw FloorpNotesStoreError.writesBlockedByCorruption(recoveryURL: recoveryURL)
            case .couldNotPreserve:
                throw FloorpNotesStoreError.corruptArchiveCouldNotBePreserved
            }
        }
        return try loadArchive()
    }

    private func loadArchive() throws -> Archive {
        if let corruptionState {
            switch corruptionState {
            case .preserved(let recoveryURL):
                throw FloorpNotesStoreError.corruptArchive(recoveryURL: recoveryURL)
            case .couldNotPreserve:
                throw FloorpNotesStoreError.corruptArchiveCouldNotBePreserved
            }
        }
        if let cachedArchive {
            return cachedArchive
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let archive = Archive(schemaVersion: Self.currentSchemaVersion, revision: 0, notes: [])
            cachedArchive = archive
            return archive
        }

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            try validateSize(data)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == Self.currentSchemaVersion else {
                throw FloorpNotesStoreError.unsupportedSchema(archive.schemaVersion)
            }
            try validate(archive.notes)
            cachedArchive = archive
            return archive
        } catch let error as FloorpNotesStoreError {
            if case .unsupportedSchema = error { throw error }
            if case .archiveTooLarge = error { throw error }
            throw preserveCorruptArchive()
        } catch {
            throw preserveCorruptArchive()
        }
    }

    private func commit(notes: [FloorpNote], replacing archive: Archive) throws {
        try validate(notes)
        let nextRevision = archive.revision == UInt64.max ? archive.revision : archive.revision + 1
        let nextArchive = Archive(
            schemaVersion: Self.currentSchemaVersion,
            revision: nextRevision,
            notes: notes
        )
        try persist(nextArchive)
        cachedArchive = nextArchive
        postChangeNotification(revision: nextArchive.revision)
    }

    private func persist(_ archive: Archive) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        try validateSize(data)

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func validate(_ notes: [FloorpNote]) throws {
        guard notes.count <= Self.maximumNoteCount else {
            throw FloorpNotesStoreError.tooManyNotes(notes.count)
        }
        var ids = Set<String>()
        for note in notes {
            guard !note.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloorpNotesStoreError.invalidNoteID
            }
            guard ids.insert(note.id).inserted else {
                throw FloorpNotesStoreError.duplicateNoteID(note.id)
            }
            guard note.createdAt > 0, note.updatedAt >= note.createdAt else {
                throw FloorpNotesStoreError.invalidNoteID
            }
        }
    }

    private func validateSize(_ data: Data) throws {
        guard data.count <= Self.maximumArchiveBytes else {
            throw FloorpNotesStoreError.archiveTooLarge(
                actualBytes: data.count,
                maximumBytes: Self.maximumArchiveBytes
            )
        }
    }

    private func preserveCorruptArchive() -> FloorpNotesStoreError {
        if let recoveryURL = matchingRecoveryURL() {
            corruptionState = .preserved(recoveryURL: recoveryURL)
            return .corruptArchive(recoveryURL: recoveryURL)
        }

        let timestamp = now()
        var recoveryURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            recoveryURL = fileURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(timestamp)-\(UUID().uuidString).json")
        }
        do {
            // Copy first and leave the source untouched. An explicit reset can
            // then replace the source while this recovery copy remains intact.
            try copyItem(fileURL, recoveryURL)
            corruptionState = .preserved(recoveryURL: recoveryURL)
            return .corruptArchive(recoveryURL: recoveryURL)
        } catch {
            // Do not offer reset when preservation failed: the source is the
            // only remaining copy and every write must stay blocked.
            corruptionState = .couldNotPreserve
            return .corruptArchiveCouldNotBePreserved
        }
    }

    /// Reuses a byte-for-byte recovery copy created during an earlier launch.
    /// This prevents an unchanged corrupt source from producing an unbounded
    /// number of backups while still refusing to trust names alone.
    private func matchingRecoveryURL() -> URL? {
        let directoryURL = fileURL.deletingLastPathComponent()
        let archiveName = fileURL.deletingPathExtension().lastPathComponent
        let recoveryPrefix = "\(archiveName).corrupt-"
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidates
            .filter {
                $0.lastPathComponent.hasPrefix(recoveryPrefix) && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { candidate in
                guard let values = try? candidate.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    return false
                }
                return FileManager.default.contentsEqual(
                    atPath: fileURL.path,
                    andPath: candidate.path
                )
            }
    }

    private func postChangeNotification(revision: UInt64) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .FloorpNotesDidChange,
                object: nil,
                userInfo: ["revision": revision]
            )
        }
    }

    nonisolated static func currentTimeInMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    nonisolated private static func defaultArchiveURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Floorp", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("notes-v1.json", isDirectory: false)
    }
}
