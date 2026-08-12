// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation

// MARK: - Note model

/// The byte-exact identity of a Floorp note.
///
/// Swift `String` equality treats canonically equivalent Unicode sequences as
/// equal. Notes Sync instead follows the desktop wire contract, where IDs are
/// opaque UTF-8 bytes. Keeping that policy in one value type prevents a
/// `Set<String>` or `[String: Value]` from silently merging two distinct IDs.
struct FloorpNoteID: Codable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.utf8.count)
        for byte in rawValue.utf8 {
            hasher.combine(byte)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A Floorp note as it is represented inside the iOS application.
///
/// `content` is intentionally kept as an opaque string. Floorp desktop stores
/// either plain text, legacy Lexical JSON, or TipTap JSON in this field. Keeping
/// the original value avoids destroying editor nodes that this client does not
/// understand yet.
enum FloorpNoteContentFormat: String, Codable, Equatable, Sendable {
    /// Content created by the native iOS editor. JSON-looking text remains
    /// editable instead of being mistaken for an unsupported rich document.
    case plainText

    /// Content whose shape must be detected without changing its source. This
    /// is used for desktop payloads and archives written before format metadata
    /// was introduced.
    case automatic
}

struct FloorpNote: Codable, Equatable, Identifiable, Sendable {
    let id: FloorpNoteID
    var title: String
    var content: String
    let createdAt: Int64
    var updatedAt: Int64
    var contentFormat: FloorpNoteContentFormat

    init(
        id: FloorpNoteID,
        title: String,
        content: String,
        createdAt: Int64,
        updatedAt: Int64,
        contentFormat: FloorpNoteContentFormat = .automatic
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentFormat = contentFormat
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case createdAt
        case updatedAt
        case contentFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FloorpNoteID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        contentFormat = try container.decodeIfPresent(
            FloorpNoteContentFormat.self,
            forKey: .contentFormat
        ) ?? .plainText
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        // Plain text is the native iOS/default representation. Omitting that
        // common value keeps a boundary-sized v1 archive migratable without
        // adding metadata for every note; rich desktop content explicitly
        // carries `.automatic` so its source remains opaque.
        if contentFormat != .plainText {
            try container.encode(contentFormat, forKey: .contentFormat)
        }
    }
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
        ids = notes.map(\.id.rawValue)
        titles = notes.map(\.title)
        contents = notes.map(\.content)
        createdAts = notes.map(\.createdAt)
        updatedAts = notes.map(\.updatedAt)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        byteExactIDsEqual(lhs.ids, rhs.ids)
            && lhs.titles == rhs.titles
            && lhs.contents == rhs.contents
            && lhs.createdAts == rhs.createdAts
            && lhs.updatedAts == rhs.updatedAts
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

        var usedIDs = Set<FloorpNoteID>()
        var notes = [FloorpNote]()
        notes.reserveCapacity(count)

        for index in 0..<count {
            let candidateID = value(at: index, in: ids)
            var id = candidateID.flatMap { rawValue -> FloorpNoteID? in
                guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return FloorpNoteID(rawValue)
            } ?? FloorpNoteID(makeID())
            while id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || usedIDs.contains(id) {
                id = FloorpNoteID(makeID())
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
                    updatedAt: updatedAt,
                    contentFormat: .automatic
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

    private static func byteExactIDsEqual(_ lhs: [String]?, _ rhs: [String]?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let lhs), .some(let rhs)):
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { left, right in
                left.utf8.elementsEqual(right.utf8)
            }
        default:
            return false
        }
    }
}

enum FloorpNotesListOrderError: Error, Equatable, Sendable {
    case duplicateID(FloorpNoteID)
    case mismatchedVisibleIDs
    case staleVisibleIDs([FloorpNoteID])
}

enum FloorpNotesListOrder {
    static func merge(
        latestFullIDs: [FloorpNoteID],
        originalVisibleIDs: [FloorpNoteID],
        orderedVisibleIDs: [FloorpNoteID]
    ) throws -> [FloorpNoteID] {
        try validateUnique(originalVisibleIDs)
        try validateUnique(orderedVisibleIDs)

        guard Set(originalVisibleIDs) == Set(orderedVisibleIDs) else {
            throw FloorpNotesListOrderError.mismatchedVisibleIDs
        }

        let latestIDs = Set(latestFullIDs)
        let missingIDs = originalVisibleIDs.filter { !latestIDs.contains($0) }
        guard missingIDs.isEmpty else {
            throw FloorpNotesListOrderError.staleVisibleIDs(missingIDs)
        }

        let visibleIDs = Set(originalVisibleIDs)
        var orderedIterator = orderedVisibleIDs.makeIterator()
        return latestFullIDs.map { id in
            guard visibleIDs.contains(id) else { return id }
            return orderedIterator.next() ?? id
        }
    }

    private static func validateUnique(_ ids: [FloorpNoteID]) throws {
        var seen = Set<FloorpNoteID>()
        for id in ids where !seen.insert(id).inserted {
            throw FloorpNotesListOrderError.duplicateID(id)
        }
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
    static func analyze(
        _ content: String,
        contentFormat: FloorpNoteContentFormat = .automatic
    ) -> Analysis {
        if contentFormat == .plainText {
            return Analysis(
                format: .plainText,
                previewText: content,
                editorText: content,
                losses: [],
                isComplete: true
            )
        }

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

    static func isRichText(
        _ content: String,
        contentFormat: FloorpNoteContentFormat = .automatic
    ) -> Bool {
        switch analyze(content, contentFormat: contentFormat).format {
        case .tipTap, .lexical:
            return true
        case .plainText, .unknownJSON:
            return false
        }
    }

    static func plainText(
        from content: String,
        contentFormat: FloorpNoteContentFormat = .automatic
    ) -> String {
        analyze(content, contentFormat: contentFormat).previewText
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

// MARK: - Import and export

/// The deterministic conflict policy applied when importing a validated
/// payload into the local archive.
enum FloorpNotesImportPolicy: Sendable {
    /// Replaces the entire local archive with the imported notes.
    case replace

    /// Merges by exact ID. When a local and an imported note share an ID, the
    /// version with the newer `updatedAt` wins; ties keep the local version.
    /// Imported IDs that do not exist locally are appended in payload order.
    case merge
}

struct FloorpNotesImportResult: Equatable, Sendable {
    let revision: UInt64
    let importedCount: Int
    /// Number of existing local notes whose value changed (merge policy).
    let mergedCount: Int
    /// Number of local notes replaced (replace policy).
    let replacedCount: Int
}

/// Validates an import document before any store mutation. The only accepted
/// format is the desktop payload produced by
/// `FloorpNotesStore.desktopPayloadData()` (parallel `ids`/`titles`/
/// `contents`/`createdAts`/`updatedAts` arrays). Validation is strict: invalid
/// identifiers, byte-exact duplicates, inconsistent arrays, invalid
/// timestamps, oversized input, and over-limit note counts all reject the
/// document without touching the archive. Content bytes are never rewritten,
/// so unknown rich-text source stays byte-for-byte preserved.
enum FloorpNotesImportValidator {
    static func validate(data: Data) throws -> [FloorpNote] {
        guard data.count <= FloorpNotesStore.maximumArchiveBytes else {
            throw FloorpNotesStoreError.archiveTooLarge(
                actualBytes: data.count,
                maximumBytes: FloorpNotesStore.maximumArchiveBytes
            )
        }

        let payload: FloorpNotesDesktopPayload
        do {
            payload = try JSONDecoder().decode(FloorpNotesDesktopPayload.self, from: data)
        } catch {
            throw FloorpNotesStoreError.invalidImportPayload
        }

        guard let ids = payload.ids else {
            throw FloorpNotesStoreError.invalidImportPayload
        }
        let count = ids.count
        guard count == payload.titles.count, count == payload.contents.count else {
            throw FloorpNotesStoreError.invalidImportPayload
        }
        if let createdAts = payload.createdAts, createdAts.count != count {
            throw FloorpNotesStoreError.invalidImportPayload
        }
        if let updatedAts = payload.updatedAts, updatedAts.count != count {
            throw FloorpNotesStoreError.invalidImportPayload
        }
        guard count <= FloorpNotesStore.maximumNoteCount else {
            throw FloorpNotesStoreError.tooManyNotes(count)
        }

        var seenIDs = Set<FloorpNoteID>()
        var notes = [FloorpNote]()
        notes.reserveCapacity(count)
        for index in ids.indices {
            let id = FloorpNoteID(ids[index])
            guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloorpNotesStoreError.invalidNoteID
            }
            guard seenIDs.insert(id).inserted else {
                throw FloorpNotesStoreError.duplicateNoteID(id)
            }
            let createdAt = payload.createdAts?[index] ?? 0
            let updatedAt = payload.updatedAts?[index] ?? createdAt
            guard createdAt > 0, updatedAt >= createdAt else {
                throw FloorpNotesStoreError.invalidTimestamp(id)
            }
            notes.append(
                FloorpNote(
                    id: id,
                    title: payload.titles[index],
                    content: payload.contents[index],
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    contentFormat: .automatic
                )
            )
        }
        return notes
    }
}

// MARK: - Store

enum FloorpNotesStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case corruptArchive(recoveryURL: URL)
    case corruptArchiveCouldNotBePreserved
    case writesBlockedByCorruption(recoveryURL: URL)
    case invalidNoteID
    case duplicateNoteID(FloorpNoteID)
    case invalidTimestamp(FloorpNoteID)
    case invalidImportPayload
    case noteNotFound(FloorpNoteID)
    case editConflict(FloorpNoteID)
    case reorderConflict(expectedRevision: UInt64, actualRevision: UInt64)
    case timestampExhausted(FloorpNoteID)
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
        case .invalidTimestamp(let id):
            return "A note has an invalid timestamp (\(id.rawValue))."
        case .invalidImportPayload:
            return "The imported JSON payload is not a valid Floorp Notes document."
        case .noteNotFound:
            return "The note no longer exists."
        case .editConflict:
            return "The note changed in another window."
        case .reorderConflict:
            return "The notes list changed while it was being reordered."
        case .timestampExhausted:
            return "The note timestamp cannot be advanced."
        case .tooManyNotes(let count):
            return "The notes archive contains too many notes (\(count))."
        case .archiveTooLarge(let actualBytes, let maximumBytes):
            return "The notes archive is too large (\(actualBytes) bytes; maximum \(maximumBytes))."
        }
    }
}

struct FloorpNotesSnapshot: Equatable, Sendable {
    let revision: UInt64
    let notes: [FloorpNote]
}

struct FloorpNotesApplicationServicesState: Codable, Equatable, Sendable {
    let globalSyncID: String?
    let collectionSyncID: String?
    let lastModifiedMillis: Int64
}

struct FloorpNotesSyncContext: Equatable, Sendable {
    let ownerAccountID: String?
    let baseState: FloorpNotesSyncBaseState?
    let applicationServicesState: FloorpNotesApplicationServicesState?
}

/// Content-free local persistence state for two-client QA evidence.
///
/// This is an observation of one device's archive only. It does not establish
/// network activity, cross-client equality, or a successful Sync operation.
struct FloorpNotesSyncEvidenceSnapshot: Equatable, Sendable {
    let archiveSHA256: String
    let noteCount: Int
    let revision: UInt64
    let hasSyncOwner: Bool
    let hasSyncBaseState: Bool
    let hasApplicationServicesAssociation: Bool
}

enum FloorpNotesPersistenceAccountAvailability: Equatable, Sendable {
    case available
    case accountMismatch
}

struct FloorpNotesPreparedPersistence: Sendable {
    let plan: FloorpNotesSyncPlan
    fileprivate let accountID: String
    fileprivate let expectedRevision: UInt64
    fileprivate let nextArchive: FloorpNotesPersistenceCore.Archive
}

enum FloorpNotesPersistenceError: Error, Equatable, Sendable {
    case emptyAccountID
    case accountMismatch
    case staleRevision
    case invalidApplicationServicesState
}

/// Thread-safe, crash-safe persistence shared by the async Notes facade and
/// the synchronous Application Services delegate callbacks.
final class FloorpNotesPersistenceCore: @unchecked Sendable {
    static let currentSchemaVersion = 3
    static let maximumNoteCount = 1_000
    static let legacyMaximumArchiveBytes = 1_000_000
    // v2 explicitly marks rich/desktop notes as `automatic`. It also writes
    // decoded timestamps in canonical decimal form. Reserve both worst-case
    // per-note expansions plus the archive-level revision so a boundary-sized
    // v1 archive can migrate atomically without becoming unreadable.
    static let maximumArchiveBytes = legacyMaximumArchiveBytes + (maximumNoteCount * 60) + 65_600
    private static let pendingAssociationResetSchemaVersion = 1
    private static let maximumPendingAssociationResetBytes = 16 * 1_024

    fileprivate struct Archive: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let revision: UInt64
        let notes: [FloorpNote]
        let syncOwnerAccountID: String?
        let syncBaseState: FloorpNotesSyncBaseState?
        let applicationServicesState: FloorpNotesApplicationServicesState?

        init(
            schemaVersion: Int,
            revision: UInt64,
            notes: [FloorpNote],
            syncOwnerAccountID: String? = nil,
            syncBaseState: FloorpNotesSyncBaseState? = nil,
            applicationServicesState: FloorpNotesApplicationServicesState? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.revision = revision
            self.notes = notes
            self.syncOwnerAccountID = syncOwnerAccountID
            self.syncBaseState = syncBaseState
            self.applicationServicesState = applicationServicesState
        }
    }

    private struct ArchiveHeader: Decodable {
        let schemaVersion: Int
    }

    private struct PendingAssociationReset: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let accountID: String
        let state: FloorpNotesApplicationServicesState
    }

    private struct LegacyArchiveV1: Decodable {
        struct Note: Decodable {
            let id: String
            let title: String
            let content: String
            let createdAt: Int64
            let updatedAt: Int64
        }

        let schemaVersion: Int
        let revision: UInt64
        let notes: [Note]
    }

    private struct LegacyArchiveV2: Decodable {
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
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let lock = NSRecursiveLock()
    private var cachedArchive: Archive?
    private var corruptionState: CorruptionState?

    private var pendingAssociationResetURL: URL {
        fileURL.appendingPathExtension("pending-sync-association-reset")
    }

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Int64 = FloorpNotesStore.currentTimeInMilliseconds,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString },
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        },
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.makeID = makeID
        self.copyItem = copyItem
        self.writeData = writeData
    }

    func loadNotes() throws -> [FloorpNote] {
        try loadArchive().notes
    }

    func loadSnapshot() throws -> FloorpNotesSnapshot {
        let archive = try loadArchive()
        return FloorpNotesSnapshot(revision: archive.revision, notes: archive.notes)
    }

    func preflightCreateNote(
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat,
        candidateID: FloorpNoteID = FloorpNoteID(UUID().uuidString)
    ) throws {
        let archive = try loadArchiveForWriting()
        var id = candidateID
        let existingIDs = Set(archive.notes.map(\.id))
        if id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            id = FloorpNoteID(UUID().uuidString)
        }
        while existingIDs.contains(id) { id = FloorpNoteID(UUID().uuidString) }
        let note = FloorpNote(
            id: id,
            title: title,
            content: content,
            createdAt: Int64.max,
            updatedAt: Int64.max,
            contentFormat: contentFormat
        )
        try preflightCommit(notes: [note] + archive.notes, replacing: archive)
    }

    func preflightUpdateNote(
        id: FloorpNoteID,
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat
    ) throws {
        let archive = try loadArchiveForWriting()
        guard let index = archive.notes.firstIndex(where: { $0.id == id }) else {
            throw FloorpNotesStoreError.noteNotFound(id)
        }
        var notes = archive.notes
        var note = notes[index]
        guard note.updatedAt < Int64.max else {
            throw FloorpNotesStoreError.timestampExhausted(id)
        }
        note.title = title
        note.content = content
        note.contentFormat = contentFormat
        note.updatedAt = Int64.max
        notes[index] = note
        try preflightCommit(notes: notes, replacing: archive)
    }

    @discardableResult
    func createNote(
        title: String,
        content: String = "",
        contentFormat: FloorpNoteContentFormat = .plainText
    ) throws -> FloorpNote {
        let archive = try loadArchiveForWriting()
        let timestamp = now()
        var id = FloorpNoteID(makeID())
        let existingIDs = Set(archive.notes.map(\.id))
        while id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || existingIDs.contains(id) {
            id = FloorpNoteID(makeID())
        }

        let note = FloorpNote(
            id: id,
            title: title,
            content: content,
            createdAt: timestamp,
            updatedAt: timestamp,
            contentFormat: contentFormat
        )
        var notes = archive.notes
        notes.insert(note, at: 0)
        try commit(notes: notes, replacing: archive)
        return note
    }

    @discardableResult
    func updateNote(
        id: FloorpNoteID,
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat? = nil,
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
        note.contentFormat = contentFormat ?? note.contentFormat
        note.updatedAt = [now(), note.createdAt, note.updatedAt + 1].max() ?? note.updatedAt + 1
        notes[index] = note
        try commit(notes: notes, replacing: archive)
        return note
    }

    func deleteNote(id: FloorpNoteID) throws {
        let archive = try loadArchiveForWriting()
        guard archive.notes.contains(where: { $0.id == id }) else {
            throw FloorpNotesStoreError.noteNotFound(id)
        }
        try commit(notes: archive.notes.filter { $0.id != id }, replacing: archive)
    }

    /// Reorders known IDs and preserves all omitted notes at the end. This is
    /// important when an older client submits an order that predates new data.
    func reorderNotes(orderedIDs: [FloorpNoteID]) throws {
        let archive = try loadArchiveForWriting()
        let notesByID = Dictionary(uniqueKeysWithValues: archive.notes.map { ($0.id, $0) })
        var seen = Set<FloorpNoteID>()
        var reordered = orderedIDs.compactMap { id -> FloorpNote? in
            guard seen.insert(id).inserted else { return nil }
            return notesByID[id]
        }
        reordered.append(contentsOf: archive.notes.filter { !seen.contains($0.id) })
        try commit(notes: reordered, replacing: archive)
    }

    @discardableResult
    func reorderVisibleNotes(
        originalVisibleIDs: [FloorpNoteID],
        orderedVisibleIDs: [FloorpNoteID],
        expectedRevision: UInt64
    ) throws -> Bool {
        let archive = try loadArchiveForWriting()
        guard archive.revision == expectedRevision else {
            throw FloorpNotesStoreError.reorderConflict(
                expectedRevision: expectedRevision,
                actualRevision: archive.revision
            )
        }

        let latestIDs = archive.notes.map(\.id)
        let orderedIDs = try FloorpNotesListOrder.merge(
            latestFullIDs: latestIDs,
            originalVisibleIDs: originalVisibleIDs,
            orderedVisibleIDs: orderedVisibleIDs
        )
        guard orderedIDs != latestIDs else { return false }

        let notesByID = Dictionary(uniqueKeysWithValues: archive.notes.map { ($0.id, $0) })
        let notes = orderedIDs.compactMap { notesByID[$0] }
        try commit(notes: notes, replacing: archive)
        return true
    }

    /// Replaces local notes with an explicitly imported set.
    func replaceAllNotes(with notes: [FloorpNote]) throws {
        let archive = try loadArchiveForWriting()
        try commit(notes: notes, replacing: archive)
    }

    func desktopPayloadData() throws -> Data {
        let notes = try loadArchive().notes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FloorpNotesDesktopPayload(notes: notes))
        try validateSize(data)
        return data
    }

    /// Imports a validated JSON document produced by `desktopPayloadData()`.
    ///
    /// Validation happens entirely before mutation: malformed, oversized,
    /// duplicate, or timestamp-invalid input leaves the archive and revision
    /// unchanged. The subsequent commit is atomic, so an injected write,
    /// rename, or commit failure leaves the last-good archive intact with no
    /// partial or temporary file behind.
    @discardableResult
    func importNotes(
        from data: Data,
        policy: FloorpNotesImportPolicy = .replace
    ) throws -> FloorpNotesImportResult {
        let archive = try loadArchiveForWriting()
        let imported = try FloorpNotesImportValidator.validate(data: data)
        let local = archive.notes
        let notes: [FloorpNote]
        var mergedCount = 0
        var replacedCount = 0
        switch policy {
        case .replace:
            notes = imported
            replacedCount = local.count
        case .merge:
            (notes, mergedCount) = Self.mergedImport(imported, into: local)
        }
        try commit(notes: notes, replacing: archive)
        return FloorpNotesImportResult(
            revision: archiveByAdvancingRevision(of: archive, notes: notes).revision,
            importedCount: imported.count,
            mergedCount: mergedCount,
            replacedCount: replacedCount
        )
    }

    /// Returns the URL of the preserved corruption backup, if the current
    /// store instance has one. The backup is untrusted data and is never
    /// auto-imported.
    func preservedCorruptionBackupURL() -> URL? {
        if case .preserved(let recoveryURL) = corruptionState {
            return recoveryURL
        }
        return nil
    }

    /// Returns the preserved corruption backup as raw untrusted data, or nil
    /// when no recovery copy is currently preserved. Callers must never treat
    /// this data as trusted Notes content.
    func preservedCorruptionBackupData() throws -> Data? {
        guard let recoveryURL = preservedCorruptionBackupURL() else { return nil }
        return try Data(contentsOf: recoveryURL)
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

    func loadSyncContext() throws -> FloorpNotesSyncContext {
        let archive = try loadArchive()
        return FloorpNotesSyncContext(
            ownerAccountID: archive.syncOwnerAccountID,
            baseState: archive.syncBaseState,
            applicationServicesState: archive.applicationServicesState
        )
    }

    func loadSyncEvidenceSnapshot() throws -> FloorpNotesSyncEvidenceSnapshot {
        let archive = try loadArchive()
        let archiveSHA256 = SHA256.hash(data: try encodedArchiveData(archive))
            .map { String(format: "%02x", $0) }
            .joined()
        let applicationServicesState = archive.applicationServicesState
        let hasApplicationServicesAssociation = applicationServicesState?.globalSyncID != nil
            && applicationServicesState?.collectionSyncID != nil

        return FloorpNotesSyncEvidenceSnapshot(
            archiveSHA256: archiveSHA256,
            noteCount: archive.notes.count,
            revision: archive.revision,
            hasSyncOwner: archive.syncOwnerAccountID != nil,
            hasSyncBaseState: archive.syncBaseState != nil,
            hasApplicationServicesAssociation: hasApplicationServicesAssociation
        )
    }

    func syncAvailability(accountID: String) throws -> FloorpNotesPersistenceAccountAvailability {
        try withLock {
            let accountID = try normalizedAccountID(accountID)
            let owner = try loadArchive().syncOwnerAccountID
            return owner == nil || owner == accountID ? .available : .accountMismatch
        }
    }

    func claimSyncOwnership(accountID: String) throws {
        try withLock {
            let accountID = try normalizedAccountID(accountID)
            let archive = try loadArchiveForWriting()
            if let owner = archive.syncOwnerAccountID {
                guard owner == accountID else {
                    throw FloorpNotesPersistenceError.accountMismatch
                }
                return
            }
            let claimed = Archive(
                schemaVersion: Self.currentSchemaVersion,
                revision: archive.revision,
                notes: archive.notes,
                syncOwnerAccountID: accountID,
                syncBaseState: nil,
                applicationServicesState: archive.applicationServicesState
            )
            try persist(claimed)
            cachedArchive = claimed
        }
    }

    func syncContext(accountID: String) throws -> FloorpNotesSyncContext {
        try withLock {
            let accountID = try normalizedAccountID(accountID)
            let context = try loadSyncContext()
            if let owner = context.ownerAccountID, owner != accountID {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            return context
        }
    }

    func prepareSyncPersistence(
        accountID: String,
        remoteRecord: FloorpNotesSyncRemoteRecord,
        now: Int64
    ) throws -> FloorpNotesPreparedPersistence {
        try withLock {
            let accountID = try normalizedAccountID(accountID)
            let archive = try loadArchiveForWriting()
            if let owner = archive.syncOwnerAccountID, owner != accountID {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            let baseState = archive.syncOwnerAccountID == accountID
                ? archive.syncBaseState
                : nil
            let plan = try FloorpNotesSyncPlanner.makePlan(
                accountID: accountID,
                baseState: baseState,
                localNotes: archive.notes,
                remoteRecord: remoteRecord,
                now: now
            )
            try validate(plan.mergedNotes)
            let nextRevision = archive.revision == UInt64.max
                ? archive.revision
                : archive.revision + 1
            let nextArchive = Archive(
                schemaVersion: Self.currentSchemaVersion,
                revision: nextRevision,
                notes: plan.mergedNotes,
                syncOwnerAccountID: archive.syncOwnerAccountID ?? accountID,
                syncBaseState: plan.nextBaseState,
                applicationServicesState: archive.applicationServicesState
            )
            _ = try encodedArchiveData(nextArchive)
            return FloorpNotesPreparedPersistence(
                plan: plan,
                accountID: accountID,
                expectedRevision: archive.revision,
                nextArchive: nextArchive
            )
        }
    }

    func commitSyncPersistence(
        _ prepared: FloorpNotesPreparedPersistence,
        applicationServicesState: FloorpNotesApplicationServicesState
    ) throws {
        try withLock {
            try validateApplicationServicesState(applicationServicesState)
            let archive = try loadArchiveForWriting()
            guard archive.revision == prepared.expectedRevision else {
                throw FloorpNotesPersistenceError.staleRevision
            }
            guard archive.syncOwnerAccountID == nil
                    || archive.syncOwnerAccountID == prepared.accountID else {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            let committedArchive = Archive(
                schemaVersion: prepared.nextArchive.schemaVersion,
                revision: prepared.nextArchive.revision,
                notes: prepared.nextArchive.notes,
                syncOwnerAccountID: prepared.nextArchive.syncOwnerAccountID,
                syncBaseState: prepared.nextArchive.syncBaseState,
                applicationServicesState: applicationServicesState
            )
            try persist(try encodedArchiveData(committedArchive))
            cachedArchive = committedArchive
            postChangeNotification(revision: committedArchive.revision)
        }
    }

    func resetSyncAssociation(
        accountID: String,
        state: FloorpNotesApplicationServicesState
    ) throws {
        try withLock {
            let accountID = try normalizedAccountID(accountID)
            try validateApplicationServicesState(state)
            let archive = try loadArchiveForWriting()
            guard archive.syncOwnerAccountID == nil
                    || archive.syncOwnerAccountID == accountID else {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            guard archive.syncOwnerAccountID != nil else { return }
            let nextArchive = Archive(
                schemaVersion: Self.currentSchemaVersion,
                revision: archive.revision,
                notes: archive.notes,
                syncOwnerAccountID: archive.syncOwnerAccountID,
                syncBaseState: nil,
                applicationServicesState: state
            )
            guard nextArchive != archive else { return }
            try persist(nextArchive)
            cachedArchive = nextArchive
        }
    }

    func stagePendingSyncAssociationReset(
        accountID: String,
        state: FloorpNotesApplicationServicesState
    ) throws {
        try withLock {
            let marker = PendingAssociationReset(
                schemaVersion: Self.pendingAssociationResetSchemaVersion,
                accountID: try normalizedAccountID(accountID),
                state: state
            )
            try validateApplicationServicesState(state)
            if let existing = try loadPendingSyncAssociationReset(),
               existing != marker {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(marker)
            guard data.count <= Self.maximumPendingAssociationResetBytes else {
                throw FloorpNotesPersistenceError.invalidApplicationServicesState
            }
            try writeData(data, pendingAssociationResetURL)
        }
    }

    func finalizePendingSyncAssociationReset(
        accountID: String,
        state: FloorpNotesApplicationServicesState
    ) throws {
        try withLock {
            let normalizedAccountID = try normalizedAccountID(accountID)
            guard let marker = try loadPendingSyncAssociationReset(),
                  marker.accountID == normalizedAccountID,
                  marker.state == state else {
                throw FloorpNotesPersistenceError.invalidApplicationServicesState
            }
            try resetSyncAssociation(accountID: normalizedAccountID, state: state)
            try removePendingSyncAssociationReset()
        }
    }

    func cancelPendingSyncAssociationReset(accountID: String) throws {
        try withLock {
            guard let marker = try loadPendingSyncAssociationReset() else { return }
            guard marker.accountID == (try normalizedAccountID(accountID)) else {
                throw FloorpNotesPersistenceError.accountMismatch
            }
            try removePendingSyncAssociationReset()
        }
    }

    @discardableResult
    func resumePendingSyncAssociationReset() throws -> Bool {
        try withLock {
            guard let marker = try loadPendingSyncAssociationReset() else {
                return false
            }
            try resetSyncAssociation(
                accountID: marker.accountID,
                state: marker.state
            )
            try removePendingSyncAssociationReset()
            return true
        }
    }

    func hasPendingSyncAssociationReset() throws -> Bool {
        try withLock { try loadPendingSyncAssociationReset() != nil }
    }

    private func loadPendingSyncAssociationReset() throws -> PendingAssociationReset? {
        guard FileManager.default.fileExists(
            atPath: pendingAssociationResetURL.path
        ) else {
            return nil
        }
        let values = try pendingAssociationResetURL.resourceValues(
            forKeys: [.fileSizeKey]
        )
        guard let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumPendingAssociationResetBytes else {
            throw FloorpNotesPersistenceError.invalidApplicationServicesState
        }
        let data = try Data(contentsOf: pendingAssociationResetURL)
        guard data.count == fileSize,
              let marker = try? JSONDecoder().decode(
                PendingAssociationReset.self,
                from: data
              ),
              marker.schemaVersion == Self.pendingAssociationResetSchemaVersion else {
            throw FloorpNotesPersistenceError.invalidApplicationServicesState
        }
        guard marker.accountID == (try normalizedAccountID(marker.accountID)) else {
            throw FloorpNotesPersistenceError.invalidApplicationServicesState
        }
        try validateApplicationServicesState(marker.state)
        return marker
    }

    private func removePendingSyncAssociationReset() throws {
        guard FileManager.default.fileExists(
            atPath: pendingAssociationResetURL.path
        ) else {
            return
        }
        try FileManager.default.removeItem(at: pendingAssociationResetURL)
    }

    fileprivate func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func normalizedAccountID(_ accountID: String) throws -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw FloorpNotesPersistenceError.emptyAccountID
        }
        return normalized
    }

    private func validateApplicationServicesState(
        _ state: FloorpNotesApplicationServicesState
    ) throws {
        let hasGlobal = state.globalSyncID != nil
        let hasCollection = state.collectionSyncID != nil
        guard hasGlobal == hasCollection, state.lastModifiedMillis >= 0 else {
            throw FloorpNotesPersistenceError.invalidApplicationServicesState
        }
    }

    /// Deterministic merge: newer `updatedAt` wins for a shared ID, ties keep
    /// the local version, and imported IDs missing locally are appended in
    /// payload order.
    private static func mergedImport(
        _ imported: [FloorpNote],
        into local: [FloorpNote]
    ) -> (notes: [FloorpNote], mergedCount: Int) {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var mergedCount = 0
        for note in imported {
            if let existing = byID[note.id] {
                if note.updatedAt > existing.updatedAt {
                    byID[note.id] = note
                    mergedCount += 1
                }
            } else {
                byID[note.id] = note
            }
        }
        var notes = local.map { byID[$0.id] ?? $0 }
        var seen = Set(local.map(\.id))
        for note in imported where !seen.contains(note.id) {
            notes.append(note)
            seen.insert(note.id)
        }
        return (notes, mergedCount)
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

        let data = try readArchiveData()
        let header: ArchiveHeader
        do {
            header = try JSONDecoder().decode(ArchiveHeader.self, from: data)
        } catch {
            throw preserveCorruptArchive()
        }
        if header.schemaVersion == 1, data.count > Self.legacyMaximumArchiveBytes {
            throw FloorpNotesStoreError.archiveTooLarge(
                actualBytes: data.count,
                maximumBytes: Self.legacyMaximumArchiveBytes
            )
        }

        let archive: Archive
        do {
            switch header.schemaVersion {
            case Self.currentSchemaVersion:
                archive = try JSONDecoder().decode(Archive.self, from: data)
            case 2:
                let legacy = try JSONDecoder().decode(LegacyArchiveV2.self, from: data)
                archive = Archive(
                    schemaVersion: Self.currentSchemaVersion,
                    revision: legacy.revision,
                    notes: legacy.notes
                )
            case 1:
                let legacy = try JSONDecoder().decode(LegacyArchiveV1.self, from: data)
                archive = Archive(
                    schemaVersion: Self.currentSchemaVersion,
                    revision: legacy.revision,
                    notes: legacy.notes.map {
                        let analysis = FloorpNoteContent.analyze(
                            $0.content,
                            contentFormat: .automatic
                        )
                        let migratedFormat: FloorpNoteContentFormat
                        switch analysis.format {
                        case .tipTap, .lexical:
                            migratedFormat = .automatic
                        case .plainText, .unknownJSON:
                            // v1 was written by the native plain-text editor.
                            // Unknown JSON must stay editable rather than being
                            // reinterpreted as an unsupported rich document.
                            migratedFormat = .plainText
                        }
                        return FloorpNote(
                            id: FloorpNoteID($0.id),
                            title: $0.title,
                            content: $0.content,
                            createdAt: $0.createdAt,
                            updatedAt: $0.updatedAt,
                            contentFormat: migratedFormat
                        )
                    }
                )
            default:
                throw FloorpNotesStoreError.unsupportedSchema(header.schemaVersion)
            }
            try validate(archive.notes)
        } catch let error as FloorpNotesStoreError {
            if case .unsupportedSchema = error { throw error }
            throw preserveCorruptArchive()
        } catch {
            throw preserveCorruptArchive()
        }

        if header.schemaVersion != Self.currentSchemaVersion {
            // Atomic persistence means a failed migration leaves the v1 source
            // intact and retryable on the next launch.
            try persist(archive)
        }
        cachedArchive = archive
        return archive
    }

    private func readArchiveData() throws -> Data {
        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize,
           fileSize > Self.maximumArchiveBytes {
            throw FloorpNotesStoreError.archiveTooLarge(
                actualBytes: fileSize,
                maximumBytes: Self.maximumArchiveBytes
            )
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try validateSize(data)
        return data
    }

    private func commit(notes: [FloorpNote], replacing archive: Archive) throws {
        try validate(notes)
        let nextArchive = archiveByAdvancingRevision(of: archive, notes: notes)
        try persist(nextArchive)
        cachedArchive = nextArchive
        postChangeNotification(revision: nextArchive.revision)
    }

    private func preflightCommit(notes: [FloorpNote], replacing archive: Archive) throws {
        try validate(notes)
        _ = try encodedArchiveData(archiveByAdvancingRevision(of: archive, notes: notes))
    }

    private func archiveByAdvancingRevision(
        of archive: Archive,
        notes: [FloorpNote]
    ) -> Archive {
        let nextRevision = archive.revision == UInt64.max ? archive.revision : archive.revision + 1
        return Archive(
            schemaVersion: Self.currentSchemaVersion,
            revision: nextRevision,
            notes: notes,
            syncOwnerAccountID: archive.syncOwnerAccountID,
            syncBaseState: archive.syncBaseState,
            applicationServicesState: archive.applicationServicesState
        )
    }

    private func persist(_ archive: Archive) throws {
        try persist(encodedArchiveData(archive))
    }

    private func persist(_ data: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try writeData(data, fileURL)
    }

    private func encodedArchiveData(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        // Escaping every solidus can nearly double a valid legacy archive and
        // make an otherwise lossless migration exceed the v2 size limit.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        try validateSize(data)
        return data
    }

    private func validate(_ notes: [FloorpNote]) throws {
        guard notes.count <= Self.maximumNoteCount else {
            throw FloorpNotesStoreError.tooManyNotes(notes.count)
        }
        var ids = Set<FloorpNoteID>()
        for note in notes {
            guard !note.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            let recoveryValues = try recoveryURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard recoveryValues.isRegularFile == true,
                  recoveryValues.isSymbolicLink != true,
                  FileManager.default.contentsEqual(
                atPath: fileURL.path,
                andPath: recoveryURL.path
                  ) else {
                try? FileManager.default.removeItem(at: recoveryURL)
                corruptionState = .couldNotPreserve
                return .corruptArchiveCouldNotBePreserved
            }
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

    static func currentTimeInMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private static func defaultArchiveURL() -> URL {
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

/// Async facade for UI/editor callers. Application Services uses the same
/// persistence core directly because its delegate callbacks are synchronous.
actor FloorpNotesStore {
    static let shared = FloorpNotesStore(fileURL: defaultArchiveURL())

    nonisolated static let currentSchemaVersion = FloorpNotesPersistenceCore.currentSchemaVersion
    nonisolated static let maximumNoteCount = FloorpNotesPersistenceCore.maximumNoteCount
    nonisolated static let legacyMaximumArchiveBytes =
        FloorpNotesPersistenceCore.legacyMaximumArchiveBytes
    nonisolated static let maximumArchiveBytes = FloorpNotesPersistenceCore.maximumArchiveBytes

    nonisolated let syncPersistenceCore: FloorpNotesPersistenceCore

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Int64 = FloorpNotesStore.currentTimeInMilliseconds,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString },
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        },
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    ) {
        syncPersistenceCore = FloorpNotesPersistenceCore(
            fileURL: fileURL,
            now: now,
            makeID: makeID,
            copyItem: copyItem,
            writeData: writeData
        )
    }

    func loadNotes() throws -> [FloorpNote] {
        try syncPersistenceCore.withLock { try syncPersistenceCore.loadNotes() }
    }

    func loadSnapshot() throws -> FloorpNotesSnapshot {
        try syncPersistenceCore.withLock { try syncPersistenceCore.loadSnapshot() }
    }

    func preflightCreateNote(
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat,
        candidateID: FloorpNoteID = FloorpNoteID(UUID().uuidString)
    ) throws {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.preflightCreateNote(
                title: title,
                content: content,
                contentFormat: contentFormat,
                candidateID: candidateID
            )
        }
    }

    func preflightUpdateNote(
        id: FloorpNoteID,
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat
    ) throws {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.preflightUpdateNote(
                id: id,
                title: title,
                content: content,
                contentFormat: contentFormat
            )
        }
    }

    @discardableResult
    func createNote(
        title: String,
        content: String = "",
        contentFormat: FloorpNoteContentFormat = .plainText
    ) throws -> FloorpNote {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.createNote(
                title: title,
                content: content,
                contentFormat: contentFormat
            )
        }
    }

    @discardableResult
    func updateNote(
        id: FloorpNoteID,
        title: String,
        content: String,
        contentFormat: FloorpNoteContentFormat? = nil,
        expectedUpdatedAt: Int64? = nil
    ) throws -> FloorpNote {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.updateNote(
                id: id,
                title: title,
                content: content,
                contentFormat: contentFormat,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }
    }

    func deleteNote(id: FloorpNoteID) throws {
        try syncPersistenceCore.withLock { try syncPersistenceCore.deleteNote(id: id) }
    }

    func reorderNotes(orderedIDs: [FloorpNoteID]) throws {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.reorderNotes(orderedIDs: orderedIDs)
        }
    }

    @discardableResult
    func reorderVisibleNotes(
        originalVisibleIDs: [FloorpNoteID],
        orderedVisibleIDs: [FloorpNoteID],
        expectedRevision: UInt64
    ) throws -> Bool {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.reorderVisibleNotes(
                originalVisibleIDs: originalVisibleIDs,
                orderedVisibleIDs: orderedVisibleIDs,
                expectedRevision: expectedRevision
            )
        }
    }

    func replaceAllNotes(with notes: [FloorpNote]) throws {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.replaceAllNotes(with: notes)
        }
    }

    func desktopPayloadData() throws -> Data {
        try syncPersistenceCore.withLock { try syncPersistenceCore.desktopPayloadData() }
    }

    @discardableResult
    func importNotes(
        from data: Data,
        policy: FloorpNotesImportPolicy = .replace
    ) throws -> FloorpNotesImportResult {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.importNotes(from: data, policy: policy)
        }
    }

    func preservedCorruptionBackupURL() -> URL? {
        syncPersistenceCore.withLock { syncPersistenceCore.preservedCorruptionBackupURL() }
    }

    func preservedCorruptionBackupData() throws -> Data? {
        try syncPersistenceCore.withLock {
            try syncPersistenceCore.preservedCorruptionBackupData()
        }
    }

    func resetAfterCorruption() throws {
        try syncPersistenceCore.withLock { try syncPersistenceCore.resetAfterCorruption() }
    }

    func loadSyncContext() throws -> FloorpNotesSyncContext {
        try syncPersistenceCore.withLock { try syncPersistenceCore.loadSyncContext() }
    }

    func loadSyncEvidenceSnapshot() throws -> FloorpNotesSyncEvidenceSnapshot {
        try syncPersistenceCore.withLock { try syncPersistenceCore.loadSyncEvidenceSnapshot() }
    }

    nonisolated func syncAccountAvailability(
        accountID: String
    ) throws -> FloorpNotesPersistenceAccountAvailability {
        try syncPersistenceCore.syncAvailability(accountID: accountID)
    }

    nonisolated func claimSyncOwnership(accountID: String) throws {
        try syncPersistenceCore.claimSyncOwnership(accountID: accountID)
    }

    nonisolated static func currentTimeInMilliseconds() -> Int64 {
        FloorpNotesPersistenceCore.currentTimeInMilliseconds()
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

// MARK: - Recoverable editor draft

/// The recoverable snapshot of an in-progress Floorp note editor draft.
/// Persisted to disk so unsaved text can survive a force termination or a
/// relaunch (issue #22).
struct FloorpNoteRecoveryDraft: Codable, Equatable, Sendable {
    let id: FloorpNoteID
    let title: String
    let content: String
    let contentFormat: FloorpNoteContentFormat
    let updatedAt: Int64
}

/// Owns the on-disk recovery copy of an unsaved editor draft. Writes are
/// atomic and injectable so a failed write never destroys the newest
/// recoverable draft nor leaves a partial file behind.
final class FloorpNoteRecoveryDraftStore {
    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Floorp", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("unsaved-draft.json", isDirectory: false)
    }

    let fileURL: URL
    private let writeData: (Data, URL) throws -> Void

    init(
        fileURL: URL = FloorpNoteRecoveryDraftStore.defaultFileURL(),
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.fileURL = fileURL
        self.writeData = writeData
    }

    func saveDraft(_ draft: FloorpNoteRecoveryDraft) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(draft)
        try writeData(data, fileURL)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func loadRecoverableDraft() throws -> FloorpNoteRecoveryDraft? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(FloorpNoteRecoveryDraft.self, from: data)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
