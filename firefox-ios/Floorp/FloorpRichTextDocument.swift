// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CoreFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

indirect enum FloorpRichTextJSONValue: Equatable, Sendable {
    case object([String: FloorpRichTextJSONValue])
    case array([FloorpRichTextJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    init(foundationObject value: Any) throws {
        switch value {
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues(Self.init(foundationObject:)))
        case let values as [Any]:
            self = .array(try values.map(Self.init(foundationObject:)))
        case let value as String:
            self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber:
            let representation = value.stringValue.lowercased()
            guard JSONSerialization.isValidJSONObject([value]),
                  !representation.contains("nan"),
                  !representation.contains("inf") else {
                throw FloorpRichTextCodecError.invalidJSON
            }
            self = .number(representation)
        case _ as NSNull:
            self = .null
        default:
            throw FloorpRichTextCodecError.invalidJSON
        }
    }

    var objectValue: [String: FloorpRichTextJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [FloorpRichTextJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .number(let value) = self,
              !value.contains("."),
              !value.contains("e") else {
            return nil
        }
        return Int(value)
    }
}

struct FloorpRichTextCompatibilityIssue: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case unsupportedNode(String)
        case unsupportedMark(String)
        case unsupportedField(String)
        case invalidShape(String)
        case unsafeImageSource
        case resourceLimit
    }

    let kind: Kind
    let path: String
}

struct FloorpRichTextCompatibility: Equatable, Sendable {
    let issues: [FloorpRichTextCompatibilityIssue]

    var isEditable: Bool { issues.isEmpty }
}

struct FloorpRichTextDocument: Equatable, Sendable {
    static let currentModelVersion = 1

    let modelVersion: Int
    let root: FloorpRichTextJSONValue
    let compatibility: FloorpRichTextCompatibility

    private let originalSource: String?
    private let originalRoot: FloorpRichTextJSONValue?

    init(
        modelVersion: Int = currentModelVersion,
        root: FloorpRichTextJSONValue,
        compatibility: FloorpRichTextCompatibility,
        originalSource: String? = nil,
        originalRoot: FloorpRichTextJSONValue? = nil
    ) {
        self.modelVersion = modelVersion
        self.root = root
        self.compatibility = compatibility
        self.originalSource = originalSource
        self.originalRoot = originalRoot
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelVersion == rhs.modelVersion
            && lhs.root == rhs.root
            && lhs.compatibility == rhs.compatibility
    }

    fileprivate var unchangedOriginalSource: String? {
        guard root == originalRoot else { return nil }
        return originalSource
    }
}

enum FloorpRichTextCodecError: Error, Equatable, Sendable {
    case inputTooLarge(actualBytes: Int, maximumBytes: Int)
    case resourceLimitExceeded
    case invalidJSON
    case rootIsNotTipTapDocument
    case unsupportedModelVersion(Int)
    case encodingFailed
}

enum FloorpRichTextCodec {
    static let maximumInputBytes = FloorpNotesStore.maximumArchiveBytes
    static let maximumDepth = 64
    static let maximumNodeCount = 10_000
    static let maximumJSONDepth = 128
    static let maximumJSONValueCount = 50_000

    static func decode(
        _ source: String,
        modelVersion: Int = FloorpRichTextDocument.currentModelVersion
    ) throws -> FloorpRichTextDocument {
        guard modelVersion == FloorpRichTextDocument.currentModelVersion else {
            throw FloorpRichTextCodecError.unsupportedModelVersion(modelVersion)
        }
        let byteCount = source.utf8.count
        guard byteCount <= maximumInputBytes else {
            throw FloorpRichTextCodecError.inputTooLarge(
                actualBytes: byteCount,
                maximumBytes: maximumInputBytes
            )
        }
        guard let data = source.data(using: .utf8) else {
            throw FloorpRichTextCodecError.invalidJSON
        }
        let object: Any
        let value: FloorpRichTextJSONValue
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            try validateJSONResources(object)
            value = try FloorpRichTextJSONValue(foundationObject: object)
        } catch let error as FloorpRichTextCodecError {
            throw error
        } catch {
            throw FloorpRichTextCodecError.invalidJSON
        }
        guard let root = value.objectValue,
              root["type"]?.stringValue == "doc" else {
            throw FloorpRichTextCodecError.rootIsNotTipTapDocument
        }

        let compatibility = FloorpRichTextSchema.analyze(value)
        return FloorpRichTextDocument(
            modelVersion: modelVersion,
            root: value,
            compatibility: compatibility,
            originalSource: source,
            originalRoot: value
        )
    }

    static func encode(_ document: FloorpRichTextDocument) throws -> String {
        guard document.modelVersion == FloorpRichTextDocument.currentModelVersion else {
            throw FloorpRichTextCodecError.unsupportedModelVersion(document.modelVersion)
        }
        if let source = document.unchangedOriginalSource {
            return source
        }

        var writer = FloorpRichTextJSONWriter(maximumBytes: maximumInputBytes)
        do {
            try writer.write(document.root)
        } catch let error as FloorpRichTextCodecError {
            throw error
        } catch {
            throw FloorpRichTextCodecError.encodingFailed
        }
        return writer.output
    }

    static func document(fromPlainText text: String) throws -> FloorpRichTextDocument {
        let lines = try preflightPlainText(text)
        let paragraphs = lines.map { line in
            let content: [FloorpRichTextJSONValue]
            if line.isEmpty {
                content = []
            } else {
                content = [
                    .object([
                        "type": .string("text"),
                        "text": .string(String(line)),
                    ]),
                ]
            }
            return FloorpRichTextJSONValue.object([
                "type": .string("paragraph"),
                "content": .array(content),
            ])
        }
        let root: FloorpRichTextJSONValue = .object([
            "type": .string("doc"),
            "content": .array(paragraphs),
        ])
        let document = FloorpRichTextDocument(
            root: root,
            compatibility: FloorpRichTextSchema.analyze(root)
        )
        guard document.compatibility.isEditable else {
            throw FloorpRichTextCodecError.resourceLimitExceeded
        }
        return document
    }

    private static func preflightPlainText(_ text: String) throws -> [Substring] {
        let inputBytes = text.utf8.count
        guard inputBytes <= maximumInputBytes else {
            throw FloorpRichTextCodecError.inputTooLarge(
                actualBytes: inputBytes,
                maximumBytes: maximumInputBytes
            )
        }

        var lineCount = 1
        var nonEmptyLineCount = 0
        var currentLineIsEmpty = true
        for character in text {
            if character.isNewline {
                if !currentLineIsEmpty { nonEmptyLineCount += 1 }
                lineCount += 1
                currentLineIsEmpty = true
            } else {
                currentLineIsEmpty = false
            }
        }
        if !currentLineIsEmpty { nonEmptyLineCount += 1 }

        let estimatedNodeCount = 1 + lineCount + nonEmptyLineCount
        guard estimatedNodeCount <= maximumNodeCount else {
            throw FloorpRichTextCodecError.resourceLimitExceeded
        }

        let lines = text.isEmpty
            ? [text[text.startIndex..<text.endIndex]]
            : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var estimatedOutputBytes = 12 + 15 + max(0, lineCount - 1)
        for line in lines {
            if line.isEmpty {
                estimatedOutputBytes += 33
            } else {
                estimatedOutputBytes += 20
                    + FloorpRichTextJSONWriter.encodedStringByteCount(line)
                    + 36
            }
        }
        guard estimatedOutputBytes <= maximumInputBytes else {
            throw FloorpRichTextCodecError.inputTooLarge(
                actualBytes: estimatedOutputBytes,
                maximumBytes: maximumInputBytes
            )
        }
        return lines
    }

    fileprivate static func validateJSONResources(_ root: Any) throws {
        var pending: [(value: Any, depth: Int)] = [(root, 0)]
        var valueCount = 0

        while let current = pending.popLast() {
            valueCount += 1
            guard current.depth <= maximumJSONDepth,
                  valueCount <= maximumJSONValueCount else {
                throw FloorpRichTextCodecError.resourceLimitExceeded
            }

            if let dictionary = current.value as? [String: Any] {
                pending.append(contentsOf: dictionary.values.map { ($0, current.depth + 1) })
            } else if let values = current.value as? [Any] {
                pending.append(contentsOf: values.map { ($0, current.depth + 1) })
            }
        }
    }
}

struct FloorpLexicalMigrationResult: Equatable, Sendable {
    let originalSource: String
    let document: FloorpRichTextDocument?
    let compatibility: FloorpRichTextCompatibility

    var isEditable: Bool {
        document != nil && compatibility.isEditable
    }
}

enum FloorpRichTextEditorPreparation: Equatable, Sendable {
    case plainText
    case editable(document: FloorpRichTextDocument, migratedFromLexical: Bool)
    case readOnly(compatibility: FloorpRichTextCompatibility)

    static func prepare(_ note: FloorpNote) -> Self {
        guard note.contentFormat == .automatic else { return .plainText }
        let analysis = FloorpNoteContent.analyze(
            note.content,
            contentFormat: note.contentFormat
        )
        do {
            switch analysis.format {
            case .tipTap:
                let document = try FloorpRichTextCodec.decode(note.content)
                return document.compatibility.isEditable
                    ? .editable(document: document, migratedFromLexical: false)
                    : .readOnly(compatibility: document.compatibility)
            case .lexical:
                let migration = try FloorpLexicalMigrator.migrate(note.content)
                if let document = migration.document, migration.isEditable {
                    return .editable(document: document, migratedFromLexical: true)
                }
                return .readOnly(compatibility: migration.compatibility)
            case .unknownJSON:
                return .readOnly(
                    compatibility: FloorpRichTextCompatibility(
                        issues: [
                            FloorpRichTextCompatibilityIssue(
                                kind: .invalidShape("Unknown JSON note content"),
                                path: "/"
                            ),
                        ]
                    )
                )
            case .plainText:
                return .plainText
            }
        } catch {
            return .readOnly(
                compatibility: FloorpRichTextCompatibility(
                    issues: [
                        FloorpRichTextCompatibilityIssue(
                            kind: .invalidShape("Rich note could not be decoded safely"),
                            path: "/"
                        ),
                    ]
                )
            )
        }
    }
}

/// Preservation-first implementation of Floorp desktop's legacy Lexical to
/// TipTap mapping. The supported node mapping intentionally follows the
/// desktop editor, while any field or node whose semantics are not known to
/// this client prevents migration so the original source remains untouched.
enum FloorpLexicalMigrator {
    static func migrate(_ source: String) throws -> FloorpLexicalMigrationResult {
        let byteCount = source.utf8.count
        guard byteCount <= FloorpRichTextCodec.maximumInputBytes else {
            throw FloorpRichTextCodecError.inputTooLarge(
                actualBytes: byteCount,
                maximumBytes: FloorpRichTextCodec.maximumInputBytes
            )
        }
        guard let data = source.data(using: .utf8) else {
            throw FloorpRichTextCodecError.invalidJSON
        }

        let object: Any
        let value: FloorpRichTextJSONValue
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            try FloorpRichTextCodec.validateJSONResources(object)
            value = try FloorpRichTextJSONValue(foundationObject: object)
        } catch let error as FloorpRichTextCodecError {
            throw error
        } catch {
            throw FloorpRichTextCodecError.invalidJSON
        }

        var converter = Converter()
        guard let tipTapRoot = converter.convertEnvelope(value) else {
            let compatibility = FloorpRichTextCompatibility(issues: converter.issues)
            return FloorpLexicalMigrationResult(
                originalSource: source,
                document: nil,
                compatibility: compatibility
            )
        }
        guard converter.issues.isEmpty else {
            let compatibility = FloorpRichTextCompatibility(issues: converter.issues)
            return FloorpLexicalMigrationResult(
                originalSource: source,
                document: nil,
                compatibility: compatibility
            )
        }

        let provisional = FloorpRichTextDocument(
            root: tipTapRoot,
            compatibility: FloorpRichTextCompatibility(issues: [])
        )
        let migrated = try FloorpRichTextCodec.decode(FloorpRichTextCodec.encode(provisional))
        guard migrated.compatibility.isEditable else {
            return FloorpLexicalMigrationResult(
                originalSource: source,
                document: nil,
                compatibility: migrated.compatibility
            )
        }
        return FloorpLexicalMigrationResult(
            originalSource: source,
            document: migrated,
            compatibility: migrated.compatibility
        )
    }

    private struct Converter {
        private static let commonElementFields: Set<String> = [
            "children", "direction", "format", "indent", "type", "version",
            "textFormat", "textStyle",
        ]
        private static let textFields: Set<String> = [
            "detail", "format", "mode", "style", "text", "type", "version",
        ]
        private static let supportedTextFormatMask = 1 | 2 | 4 | 8

        var issues = [FloorpRichTextCompatibilityIssue]()
        private var nodeCount = 0

        mutating func convertEnvelope(_ value: FloorpRichTextJSONValue) -> FloorpRichTextJSONValue? {
            guard let envelope = value.objectValue,
                  let rootValue = envelope["root"],
                  let root = rootValue.objectValue else {
                append(.invalidShape("Lexical document requires a root object"), path: "/root")
                return nil
            }
            for key in envelope.keys where key != "root" {
                append(.unsupportedField(key), path: "/\(key)")
            }
            validateFields(
                root,
                allowed: Self.commonElementFields,
                path: "/root"
            )
            validateElementMetadata(root, permitsAlignment: false, path: "/root")
            validateVersion(root["version"], path: "/root")
            if root["type"]?.stringValue != "root" {
                append(.invalidShape("Lexical root type must be root"), path: "/root/type")
            }
            guard let children = root["children"]?.arrayValue else {
                append(.invalidShape("Lexical root requires children"), path: "/root/children")
                return nil
            }

            let content = convertChildren(children, path: "/root/children", depth: 1)
            let blocks = content.isEmpty ? [paragraph(content: [])] : content
            return .object([
                "type": .string("doc"),
                "content": .array(blocks),
            ])
        }

        private mutating func convertChildren(
            _ children: [FloorpRichTextJSONValue],
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            children.enumerated().flatMap { index, child in
                convertNode(
                    child,
                    path: "\(path)/\(index)",
                    depth: depth,
                    expectedListItemValue: nil
                )
            }
        }

        private mutating func convertNode(
            _ value: FloorpRichTextJSONValue,
            path: String,
            depth: Int,
            expectedListItemValue: Int?
        ) -> [FloorpRichTextJSONValue] {
            guard depth <= FloorpRichTextCodec.maximumDepth,
                  nodeCount < FloorpRichTextCodec.maximumNodeCount else {
                append(.resourceLimit, path: path)
                return []
            }
            nodeCount += 1
            guard let node = value.objectValue,
                  let type = node["type"]?.stringValue else {
                append(.invalidShape("Lexical node requires a string type"), path: path)
                return []
            }
            validateVersion(node["version"], path: path)

            switch type {
            case "text":
                return convertText(node, path: path).map { [$0] } ?? []
            case "linebreak":
                validateFields(node, allowed: ["type", "version"], path: path)
                return [.object(["type": .string("hardBreak")])]
            case "paragraph":
                validateFields(node, allowed: Self.commonElementFields, path: path)
                validateElementMetadata(node, permitsAlignment: true, path: path)
                let content = convertNodeChildren(node, path: path, depth: depth)
                return [paragraph(content: content, alignment: alignment(node["format"], path: path))]
            case "heading":
                return convertHeading(node, path: path, depth: depth)
            case "list":
                return convertList(node, path: path, depth: depth)
            case "listitem":
                return convertListItem(
                    node,
                    path: path,
                    depth: depth,
                    expectedValue: expectedListItemValue
                )
            case "quote":
                return convertQuote(node, path: path, depth: depth)
            default:
                append(.unsupportedNode(type), path: path)
                return []
            }
        }

        private mutating func convertHeading(
            _ node: [String: FloorpRichTextJSONValue],
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            validateFields(
                node,
                allowed: Self.commonElementFields.union(["tag"]),
                path: path
            )
            validateElementMetadata(node, permitsAlignment: true, path: path)
            guard let tag = node["tag"]?.stringValue else {
                append(.invalidShape("Lexical heading tag must be a string"), path: path + "/tag")
                return []
            }
            guard tag.count == 2,
                  tag.first == "h",
                  let level = Int(tag.dropFirst()),
                  (1...6).contains(level) else {
                append(.invalidShape("Lexical heading tag must be h1 through h6"), path: path + "/tag")
                return []
            }
            var attributes: [String: FloorpRichTextJSONValue] = ["level": .number(String(level))]
            if let textAlignment = alignment(node["format"], path: path) {
                attributes["textAlign"] = .string(textAlignment)
            }
            var result: [String: FloorpRichTextJSONValue] = [
                "type": .string("heading"),
                "attrs": .object(attributes),
            ]
            let content = convertNodeChildren(node, path: path, depth: depth)
            if !content.isEmpty { result["content"] = .array(content) }
            return [.object(result)]
        }

        private mutating func convertList(
            _ node: [String: FloorpRichTextJSONValue],
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            validateFields(
                node,
                allowed: Self.commonElementFields.union(["listType", "start", "tag"]),
                path: path
            )
            validateElementMetadata(node, permitsAlignment: false, path: path)
            guard let listType = node["listType"]?.stringValue else {
                append(.invalidShape("Lexical list type must be a string"), path: path + "/listType")
                return []
            }
            guard ["bullet", "number"].contains(listType) else {
                append(.invalidShape("Unsupported Lexical list type"), path: path + "/listType")
                return []
            }
            let start = validatedListStart(node, listType: listType, path: path)
            validateListTag(node["tag"], listType: listType, path: path + "/tag")
            guard let children = node["children"]?.arrayValue else {
                append(.invalidShape("Lexical list requires children"), path: path + "/children")
                return []
            }
            let content = children.enumerated().flatMap { index, child in
                convertListChild(
                    child,
                    index: index,
                    start: start,
                    path: path,
                    depth: depth
                )
            }
            guard !content.isEmpty else {
                append(.invalidShape("Lexical list requires an item"), path: path + "/children")
                return []
            }
            var result: [String: FloorpRichTextJSONValue] = [
                "type": .string(listType == "number" ? "orderedList" : "bulletList"),
                "content": .array(content),
            ]
            if listType == "number", let start {
                result["attrs"] = .object(["start": .number(String(start))])
            }
            return [.object(result)]
        }

        private mutating func convertListChild(
            _ child: FloorpRichTextJSONValue,
            index: Int,
            start: Int?,
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            let expectedValue: Int?
            if let start {
                let addition = start.addingReportingOverflow(index)
                if addition.overflow {
                    append(.resourceLimit, path: path + "/children/\(index)/value")
                    expectedValue = nil
                } else {
                    expectedValue = addition.partialValue
                }
            } else {
                expectedValue = nil
            }
            return convertNode(
                child,
                path: path + "/children/\(index)",
                depth: depth + 1,
                expectedListItemValue: expectedValue
            )
        }

        private mutating func convertListItem(
            _ node: [String: FloorpRichTextJSONValue],
            path: String,
            depth: Int,
            expectedValue: Int?
        ) -> [FloorpRichTextJSONValue] {
            validateFields(
                node,
                allowed: Self.commonElementFields.union(["value"]),
                path: path
            )
            validateElementMetadata(node, permitsAlignment: false, path: path)
            validateListItemValue(
                node["value"],
                expected: expectedValue,
                path: path + "/value"
            )
            let converted = convertNodeChildren(node, path: path, depth: depth)
            let itemContent: [FloorpRichTextJSONValue]
            if converted.allSatisfy(Self.isInlineNode) {
                itemContent = [paragraph(content: converted)]
            } else if converted.first.flatMap(Self.nodeType) == "paragraph" {
                itemContent = converted
            } else {
                append(
                    .invalidShape("Lexical list item cannot be represented without loss"),
                    path: path + "/children"
                )
                return []
            }
            return [.object([
                "type": .string("listItem"),
                "content": .array(itemContent),
            ])]
        }

        private mutating func convertQuote(
            _ node: [String: FloorpRichTextJSONValue],
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            validateFields(node, allowed: Self.commonElementFields, path: path)
            validateElementMetadata(node, permitsAlignment: false, path: path)
            let converted = convertNodeChildren(node, path: path, depth: depth)
            let blocks = converted.allSatisfy(Self.isInlineNode)
                ? [paragraph(content: converted)]
                : converted
            guard !blocks.isEmpty else {
                append(.invalidShape("Lexical quote requires content"), path: path + "/children")
                return []
            }
            return [.object([
                "type": .string("blockquote"),
                "content": .array(blocks),
            ])]
        }

        private mutating func convertText(
            _ node: [String: FloorpRichTextJSONValue],
            path: String
        ) -> FloorpRichTextJSONValue? {
            validateFields(node, allowed: Self.textFields, path: path)
            validateTextMetadata(node, path: path)
            guard let text = node["text"]?.stringValue else {
                append(.invalidShape("Lexical text node requires text"), path: path + "/text")
                return nil
            }
            guard !text.isEmpty else { return nil }
            guard let format = node["format"]?.integerValue else {
                append(.invalidShape("Lexical text format must be an integer"), path: path + "/format")
                return nil
            }
            guard format >= 0, format & ~Self.supportedTextFormatMask == 0 else {
                append(.unsupportedField("format"), path: path + "/format")
                return nil
            }
            let markTypes: [(Int, String)] = [
                (1, "bold"),
                (2, "italic"),
                (4, "strike"),
                (8, "underline"),
            ]
            let marks = markTypes.compactMap { mask, type -> FloorpRichTextJSONValue? in
                format & mask == 0 ? nil : .object(["type": .string(type)])
            }
            var result: [String: FloorpRichTextJSONValue] = [
                "type": .string("text"),
                "text": .string(text),
            ]
            if !marks.isEmpty { result["marks"] = .array(marks) }
            return .object(result)
        }

        private mutating func convertNodeChildren(
            _ node: [String: FloorpRichTextJSONValue],
            path: String,
            depth: Int
        ) -> [FloorpRichTextJSONValue] {
            guard let childrenValue = node["children"] else { return [] }
            guard let children = childrenValue.arrayValue else {
                append(.invalidShape("Lexical children must be an array"), path: path + "/children")
                return []
            }
            return convertChildren(children, path: path + "/children", depth: depth + 1)
        }

        private mutating func alignment(
            _ value: FloorpRichTextJSONValue?,
            path: String
        ) -> String? {
            guard let value else { return nil }
            if value.integerValue == 0 { return nil }
            if value.stringValue?.isEmpty == true { return nil }
            guard let alignment = value.stringValue,
                  ["left", "center", "right"].contains(alignment) else {
                append(.invalidShape("Unsupported Lexical text alignment"), path: path + "/format")
                return nil
            }
            return alignment
        }

        private mutating func validateElementMetadata(
            _ node: [String: FloorpRichTextJSONValue],
            permitsAlignment: Bool,
            path: String
        ) {
            validateDefaultInteger(node["indent"], key: "indent", path: path)
            validateDefaultInteger(node["textFormat"], key: "textFormat", path: path)
            validateDefaultString(node["textStyle"], key: "textStyle", path: path)
            if let direction = node["direction"],
               direction != .null,
               direction.stringValue?.isEmpty != true,
               direction.stringValue != "ltr" {
                append(.unsupportedField("direction"), path: path + "/direction")
            }
            if !permitsAlignment,
               let format = node["format"],
               format.integerValue != 0,
               format.stringValue?.isEmpty != true {
                append(.unsupportedField("format"), path: path + "/format")
            }
        }

        private mutating func validateTextMetadata(
            _ node: [String: FloorpRichTextJSONValue],
            path: String
        ) {
            validateDefaultInteger(node["detail"], key: "detail", path: path)
            validateDefaultString(node["style"], key: "style", path: path)
            if let mode = node["mode"],
               mode.stringValue != "normal" {
                append(.unsupportedField("mode"), path: path + "/mode")
            }
        }

        private mutating func validateDefaultInteger(
            _ value: FloorpRichTextJSONValue?,
            key: String,
            path: String
        ) {
            guard let value else { return }
            guard value.integerValue == 0 else {
                append(.unsupportedField(key), path: path + "/" + key)
                return
            }
        }

        private mutating func validateDefaultString(
            _ value: FloorpRichTextJSONValue?,
            key: String,
            path: String
        ) {
            guard let value else { return }
            guard value.stringValue?.isEmpty == true else {
                append(.unsupportedField(key), path: path + "/" + key)
                return
            }
        }

        private mutating func validatedListStart(
            _ node: [String: FloorpRichTextJSONValue],
            listType: String,
            path: String
        ) -> Int? {
            guard let value = node["start"] else { return 1 }
            guard let start = value.integerValue else {
                append(.invalidShape("Lexical list start must be an integer"), path: path + "/start")
                return nil
            }
            guard FloorpRichTextListPolicy.allowedStartRange.contains(start) else {
                append(.unsupportedField("start"), path: path + "/start")
                return nil
            }
            if listType != "number", start != 1 {
                append(.unsupportedField("start"), path: path + "/start")
                return nil
            }
            return start
        }

        private mutating func validateListTag(
            _ value: FloorpRichTextJSONValue?,
            listType: String,
            path: String
        ) {
            guard let value else { return }
            let expected = listType == "number" ? "ol" : "ul"
            guard value.stringValue == expected else {
                append(.unsupportedField("tag"), path: path)
                return
            }
        }

        private mutating func validateListItemValue(
            _ value: FloorpRichTextJSONValue?,
            expected: Int?,
            path: String
        ) {
            guard let value else { return }
            guard let expected, value.integerValue == expected else {
                append(.unsupportedField("value"), path: path)
                return
            }
        }

        private mutating func validateFields(
            _ node: [String: FloorpRichTextJSONValue],
            allowed: Set<String>,
            path: String
        ) {
            for key in node.keys where !allowed.contains(key) {
                append(.unsupportedField(key), path: path + "/" + key)
            }
        }

        private mutating func validateVersion(
            _ value: FloorpRichTextJSONValue?,
            path: String
        ) {
            guard value?.integerValue == 1 else {
                append(.unsupportedField("version"), path: path + "/version")
                return
            }
        }

        private func paragraph(
            content: [FloorpRichTextJSONValue],
            alignment: String? = nil
        ) -> FloorpRichTextJSONValue {
            var result: [String: FloorpRichTextJSONValue] = ["type": .string("paragraph")]
            if !content.isEmpty { result["content"] = .array(content) }
            if let alignment { result["attrs"] = .object(["textAlign": .string(alignment)]) }
            return .object(result)
        }

        private static func nodeType(_ value: FloorpRichTextJSONValue) -> String? {
            value.objectValue?["type"]?.stringValue
        }

        private static func isInlineNode(_ value: FloorpRichTextJSONValue) -> Bool {
            guard let type = nodeType(value) else { return false }
            return type == "text" || type == "hardBreak"
        }

        private mutating func append(
            _ kind: FloorpRichTextCompatibilityIssue.Kind,
            path: String
        ) {
            issues.append(FloorpRichTextCompatibilityIssue(kind: kind, path: path))
        }
    }
}

private struct FloorpRichTextJSONWriter {
    let maximumBytes: Int
    private(set) var output = ""
    private var byteCount = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func write(_ value: FloorpRichTextJSONValue) throws {
        switch value {
        case .object(let dictionary):
            try append("{")
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 { try append(",") }
                try writeString(key)
                try append(":")
                guard let value = dictionary[key] else {
                    throw FloorpRichTextCodecError.encodingFailed
                }
                try write(value)
            }
            try append("}")
        case .array(let values):
            try append("[")
            for (index, value) in values.enumerated() {
                if index > 0 { try append(",") }
                try write(value)
            }
            try append("]")
        case .string(let value):
            try writeString(value)
        case .number(let value):
            guard !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }),
                  let data = value.data(using: .utf8),
                  let number = try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  ) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw FloorpRichTextCodecError.encodingFailed
            }
            try append(value)
        case .bool(let value):
            try append(value ? "true" : "false")
        case .null:
            try append("null")
        }
    }

    static func encodedStringByteCount<Value: StringProtocol>(_ value: Value) -> Int {
        value.unicodeScalars.reduce(into: 2) { count, scalar in
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                count += 2
            case 0x00...0x1F:
                count += 6
            default:
                count += String(scalar).utf8.count
            }
        }
    }

    private mutating func writeString<Value: StringProtocol>(_ value: Value) throws {
        try append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                try append("\\b")
            case 0x09:
                try append("\\t")
            case 0x0A:
                try append("\\n")
            case 0x0C:
                try append("\\f")
            case 0x0D:
                try append("\\r")
            case 0x22:
                try append("\\\"")
            case 0x5C:
                try append("\\\\")
            case 0x00...0x1F:
                try append(String(format: "\\u%04x", scalar.value))
            default:
                try append(String(scalar))
            }
        }
        try append("\"")
    }

    private mutating func append(_ value: String) throws {
        let addedBytes = value.utf8.count
        guard addedBytes <= maximumBytes - byteCount else {
            throw FloorpRichTextCodecError.inputTooLarge(
                actualBytes: byteCount + addedBytes,
                maximumBytes: maximumBytes
            )
        }
        output.append(value)
        byteCount += addedBytes
    }
}

private enum FloorpRichTextSchema {
    private static let supportedNodes: Set<String> = [
        "doc", "paragraph", "text", "heading", "blockquote", "codeBlock",
        "hardBreak", "horizontalRule", "bulletList", "orderedList", "listItem", "image",
    ]
    private static let supportedMarks: Set<String> = [
        "bold", "italic", "underline", "strike", "code",
    ]
    private static let leafNodes: Set<String> = ["text", "hardBreak", "horizontalRule", "image"]
    private static let inlineNodes: Set<String> = ["text", "hardBreak"]
    private static let blockNodes: Set<String> = [
        "paragraph", "heading", "blockquote", "codeBlock", "horizontalRule",
        "bulletList", "orderedList", "image",
    ]

    static func analyze(_ root: FloorpRichTextJSONValue) -> FloorpRichTextCompatibility {
        var analyzer = Analyzer()
        analyzer.analyzeNode(
            root,
            path: "",
            depth: 0,
            expectedTypes: ["doc"],
            allowsMarks: false
        )
        return FloorpRichTextCompatibility(issues: analyzer.issues)
    }

    private struct Analyzer {
        var issues = [FloorpRichTextCompatibilityIssue]()
        var nodeCount = 0
        var reachedResourceLimit = false
        var declaredImagePixels: UInt64 = 0
        var imageMetadataBySource = [String: FloorpRichTextImagePolicy.RasterMetadata]()
        var rejectedImageSources = Set<String>()

        mutating func analyzeNode(
            _ value: FloorpRichTextJSONValue,
            path: String,
            depth: Int,
            expectedTypes: Set<String>,
            allowsMarks: Bool
        ) {
            guard !reachedResourceLimit else { return }
            guard depth <= FloorpRichTextCodec.maximumDepth,
                  nodeCount < FloorpRichTextCodec.maximumNodeCount else {
                reachedResourceLimit = true
                append(.resourceLimit, path: path)
                return
            }
            nodeCount += 1

            guard let node = value.objectValue,
                  let type = node["type"]?.stringValue else {
                append(.invalidShape("node must be an object with a string type"), path: path)
                return
            }
            guard FloorpRichTextSchema.supportedNodes.contains(type) else {
                append(.unsupportedNode(type), path: path)
                return
            }
            if !expectedTypes.contains(type) {
                append(.invalidShape("unexpected \(type) node"), path: path)
            }

            validateFields(node, type: type, path: path)
            validateAttributes(node["attrs"], type: type, path: path + "/attrs")
            validateMarks(
                node["marks"],
                type: type,
                allowsMarks: allowsMarks,
                path: path + "/marks"
            )

            let content = node["content"]
            if FloorpRichTextSchema.leafNodes.contains(type) {
                if content != nil {
                    append(.invalidShape("leaf node contains content"), path: path + "/content")
                }
                return
            }

            guard let content else {
                if ["doc", "blockquote", "bulletList", "orderedList", "listItem"].contains(type) {
                    append(.invalidShape("required content is missing"), path: path + "/content")
                }
                return
            }
            guard let children = content.arrayValue else {
                append(.invalidShape("content must be an array"), path: path + "/content")
                return
            }
            if children.isEmpty {
                switch type {
                case "doc":
                    append(.invalidShape("document must contain a block"), path: path + "/content")
                case "blockquote":
                    append(.invalidShape("blockquote must contain a block"), path: path + "/content")
                case "bulletList", "orderedList":
                    append(.invalidShape("list must contain a list item"), path: path + "/content")
                case "listItem":
                    append(.invalidShape("list item must contain a paragraph"), path: path + "/content")
                default:
                    break
                }
            }

            for (index, child) in children.enumerated() {
                let expectedChildTypes: Set<String>
                if type == "listItem" {
                    expectedChildTypes = index == 0 ? ["paragraph"] : FloorpRichTextSchema.blockNodes
                } else {
                    expectedChildTypes = childTypes(for: type)
                }
                analyzeNode(
                    child,
                    path: path + "/content/\(index)",
                    depth: depth + 1,
                    expectedTypes: expectedChildTypes,
                    allowsMarks: type != "codeBlock"
                )
            }
        }

        private mutating func validateFields(
            _ node: [String: FloorpRichTextJSONValue],
            type: String,
            path: String
        ) {
            var allowed: Set<String> = ["type", "attrs", "content"]
            if type == "text" {
                allowed = ["type", "text", "marks"]
                guard node["text"]?.stringValue?.isEmpty == false else {
                    append(.invalidShape("text node requires non-empty text"), path: path + "/text")
                    return
                }
            } else if type == "hardBreak" {
                allowed = ["type", "marks"]
            }
            for key in node.keys where !allowed.contains(key) {
                append(.unsupportedField(key), path: path + "/" + key)
            }
        }

        private mutating func validateAttributes(
            _ value: FloorpRichTextJSONValue?,
            type: String,
            path: String
        ) {
            guard let value, value != .null else {
                if type == "heading" || type == "image" {
                    append(.invalidShape("required attributes are missing"), path: path)
                }
                return
            }
            guard let attributes = value.objectValue else {
                append(.invalidShape("attributes must be an object"), path: path)
                return
            }

            let allowedKeys: Set<String>
            switch type {
            case "paragraph":
                allowedKeys = ["textAlign"]
                validateAlignment(attributes["textAlign"], path: path + "/textAlign")
            case "heading":
                allowedKeys = ["level", "textAlign"]
                guard let level = attributes["level"]?.integerValue, (1...6).contains(level) else {
                    append(.invalidShape("heading level must be 1 through 6"), path: path + "/level")
                    validateUnknownAttributes(attributes, allowedKeys: allowedKeys, path: path)
                    return
                }
                validateAlignment(attributes["textAlign"], path: path + "/textAlign")
            case "orderedList":
                allowedKeys = ["start", "type"]
                if let start = attributes["start"], start != .null {
                    if start.integerValue.map(FloorpRichTextListPolicy.allowedStartRange.contains) != true {
                        append(
                            .invalidShape("ordered-list start must be a signed 32-bit integer"),
                            path: path + "/start"
                        )
                    }
                }
                if let markerType = attributes["type"], markerType != .null,
                   markerType.stringValue.map({ $0.utf8.count <= 16 }) != true {
                    append(.invalidShape("ordered-list type must be a short string"), path: path + "/type")
                }
            case "codeBlock":
                allowedKeys = ["language"]
                if let language = attributes["language"], language != .null,
                   language.stringValue == nil {
                    append(.invalidShape("code-block language must be a string"), path: path + "/language")
                }
            case "image":
                allowedKeys = ["src", "alt", "title", "width"]
                validateImageAttributes(attributes, path: path)
            default:
                allowedKeys = []
            }
            validateUnknownAttributes(attributes, allowedKeys: allowedKeys, path: path)
        }

        private mutating func validateUnknownAttributes(
            _ attributes: [String: FloorpRichTextJSONValue],
            allowedKeys: Set<String>,
            path: String
        ) {
            for key in attributes.keys where !allowedKeys.contains(key) {
                append(.unsupportedField(key), path: path + "/" + key)
            }
        }

        private mutating func validateAlignment(_ value: FloorpRichTextJSONValue?, path: String) {
            guard let value, value != .null else { return }
            guard let alignment = value.stringValue,
                  ["left", "center", "right", "justify"].contains(alignment) else {
                append(.invalidShape("unsupported text alignment"), path: path)
                return
            }
        }

        private mutating func validateImageAttributes(
            _ attributes: [String: FloorpRichTextJSONValue],
            path: String
        ) {
            guard let source = attributes["src"]?.stringValue,
                  let metadata = rasterMetadata(for: source) else {
                append(.unsafeImageSource, path: path + "/src")
                return
            }
            let (nextDeclaredImagePixels, didOverflow) = declaredImagePixels.addingReportingOverflow(
                metadata.cumulativePixels
            )
            guard !didOverflow,
                  nextDeclaredImagePixels <= FloorpRichTextImagePolicy.maximumCumulativePixels else {
                append(.resourceLimit, path: path + "/src")
                return
            }
            declaredImagePixels = nextDeclaredImagePixels
            for key in ["alt", "title"] {
                if let value = attributes[key], value != .null,
                   value.stringValue.map({
                       $0.utf8.count <= FloorpRichTextImagePolicy.maximumMetadataBytes
                   }) != true {
                    append(
                        .invalidShape("image \(key) must be a short string"),
                        path: path + "/" + key
                    )
                }
            }
            if let width = attributes["width"], width != .null,
               width.integerValue.map(FloorpRichTextImagePolicy.allowedDisplayWidth.contains) != true {
                append(.invalidShape("image width is outside the supported range"), path: path + "/width")
            }
        }

        private mutating func rasterMetadata(
            for source: String
        ) -> FloorpRichTextImagePolicy.RasterMetadata? {
            if let metadata = imageMetadataBySource[source] { return metadata }
            guard !rejectedImageSources.contains(source),
                  let metadata = FloorpRichTextImagePolicy.safePersistedMetadata(source) else {
                rejectedImageSources.insert(source)
                return nil
            }
            imageMetadataBySource[source] = metadata
            return metadata
        }

        private mutating func validateMarks(
            _ value: FloorpRichTextJSONValue?,
            type: String,
            allowsMarks: Bool,
            path: String
        ) {
            guard let value else { return }
            guard type == "text" || type == "hardBreak",
                  let marks = value.arrayValue else {
                append(.invalidShape("marks are only valid on inline nodes"), path: path)
                return
            }
            if !allowsMarks && !marks.isEmpty {
                append(.invalidShape("marks are not allowed in this parent node"), path: path)
            }
            var seen = Set<String>()
            for (index, markValue) in marks.enumerated() {
                let markPath = path + "/\(index)"
                guard let mark = markValue.objectValue,
                      let markType = mark["type"]?.stringValue else {
                    append(.invalidShape("mark must be an object with a string type"), path: markPath)
                    continue
                }
                guard FloorpRichTextSchema.supportedMarks.contains(markType) else {
                    append(.unsupportedMark(markType), path: markPath)
                    continue
                }
                if !seen.insert(markType).inserted {
                    append(.invalidShape("duplicate mark"), path: markPath)
                }
                for key in mark.keys where key != "type" && key != "attrs" {
                    append(.unsupportedField(key), path: markPath + "/" + key)
                }
                if let attributes = mark["attrs"], attributes != .null,
                   attributes.objectValue?.isEmpty != true {
                    append(.unsupportedField("attrs"), path: markPath + "/attrs")
                }
            }
        }

        private func childTypes(for type: String) -> Set<String> {
            switch type {
            case "doc":
                return FloorpRichTextSchema.blockNodes
            case "paragraph", "heading":
                return FloorpRichTextSchema.inlineNodes
            case "blockquote":
                return FloorpRichTextSchema.blockNodes
            case "codeBlock":
                return ["text"]
            case "bulletList", "orderedList":
                return ["listItem"]
            case "listItem":
                return ["paragraph", "blockquote", "codeBlock", "bulletList", "orderedList"]
            default:
                return []
            }
        }

        private mutating func append(_ kind: FloorpRichTextCompatibilityIssue.Kind, path: String) {
            issues.append(FloorpRichTextCompatibilityIssue(kind: kind, path: path.isEmpty ? "/" : path))
        }
    }
}

enum FloorpRichTextAlignment: String, Codable, Equatable, Sendable {
    case left
    case center
    case right
}

enum FloorpRichTextMark: String, Codable, Equatable, Hashable, Sendable {
    case bold
    case italic
    case underline
    case strike
}

enum FloorpRichTextListKind: String, Codable, Equatable, Sendable {
    case bullet
    case ordered
}

struct FloorpRichTextImage: Codable, Equatable, Sendable {
    let source: String
    let alt: String?
    let title: String?
    let width: Int?

    init(source: String, alt: String? = nil, title: String? = nil, width: Int? = nil) {
        self.source = source
        self.alt = alt
        self.title = title
        self.width = width
    }
}

enum FloorpRichTextCommand: Codable, Equatable, Sendable {
    case undo
    case redo
    case setParagraph
    case toggleHeading(level: Int)
    case toggleMark(FloorpRichTextMark)
    case toggleList(FloorpRichTextListKind)
    case setAlignment(FloorpRichTextAlignment)
    case insertImage(FloorpRichTextImage)

    private enum Kind: String, Codable {
        case undo
        case redo
        case setParagraph
        case toggleHeading
        case toggleMark
        case toggleList
        case setAlignment
        case insertImage
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case level
        case mark
        case listKind
        case alignment
        case image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .undo:
            self = .undo
        case .redo:
            self = .redo
        case .setParagraph:
            self = .setParagraph
        case .toggleHeading:
            self = .toggleHeading(level: try container.decode(Int.self, forKey: .level))
        case .toggleMark:
            self = .toggleMark(try container.decode(FloorpRichTextMark.self, forKey: .mark))
        case .toggleList:
            self = .toggleList(try container.decode(FloorpRichTextListKind.self, forKey: .listKind))
        case .setAlignment:
            self = .setAlignment(try container.decode(FloorpRichTextAlignment.self, forKey: .alignment))
        case .insertImage:
            self = .insertImage(try container.decode(FloorpRichTextImage.self, forKey: .image))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .undo:
            try container.encode(Kind.undo, forKey: .kind)
        case .redo:
            try container.encode(Kind.redo, forKey: .kind)
        case .setParagraph:
            try container.encode(Kind.setParagraph, forKey: .kind)
        case .toggleHeading(let level):
            try container.encode(Kind.toggleHeading, forKey: .kind)
            try container.encode(level, forKey: .level)
        case .toggleMark(let mark):
            try container.encode(Kind.toggleMark, forKey: .kind)
            try container.encode(mark, forKey: .mark)
        case .toggleList(let listKind):
            try container.encode(Kind.toggleList, forKey: .kind)
            try container.encode(listKind, forKey: .listKind)
        case .setAlignment(let alignment):
            try container.encode(Kind.setAlignment, forKey: .kind)
            try container.encode(alignment, forKey: .alignment)
        case .insertImage(let image):
            try container.encode(Kind.insertImage, forKey: .kind)
            try container.encode(image, forKey: .image)
        }
    }
}

enum FloorpRichTextBridgeProtocol {
    static let currentSchemaVersion = 1
    static let maximumSafeSequenceNumber = 9_007_199_254_740_991
    static let maximumNoteIDBytes = 1_024
    static let maximumDocumentIDBytes = 128
}

enum FloorpRichTextListPolicy {
    static let allowedStartRange = Int(Int32.min)...Int(Int32.max)
}

enum FloorpRichTextEditorSessionError: Error, Equatable, Sendable {
    case invalidNoteID
    case invalidDocumentID
    case invalidGeneration(Int)
    case invalidRevision(Int)
}

struct FloorpRichTextEditorSessionCursor: Codable, Equatable, Hashable, Sendable {
    let noteID: FloorpNoteID
    let documentID: String
    let generation: Int
    let revision: Int

    init(noteID: FloorpNoteID, documentID: String, generation: Int, revision: Int) throws {
        guard !noteID.rawValue.isEmpty,
              noteID.rawValue.utf8.count <= FloorpRichTextBridgeProtocol.maximumNoteIDBytes else {
            throw FloorpRichTextEditorSessionError.invalidNoteID
        }
        guard !documentID.isEmpty,
              documentID.utf8.count <= FloorpRichTextBridgeProtocol.maximumDocumentIDBytes else {
            throw FloorpRichTextEditorSessionError.invalidDocumentID
        }
        guard (0...FloorpRichTextBridgeProtocol.maximumSafeSequenceNumber).contains(generation) else {
            throw FloorpRichTextEditorSessionError.invalidGeneration(generation)
        }
        guard (0...FloorpRichTextBridgeProtocol.maximumSafeSequenceNumber).contains(revision) else {
            throw FloorpRichTextEditorSessionError.invalidRevision(revision)
        }
        self.noteID = noteID
        self.documentID = documentID
        self.generation = generation
        self.revision = revision
    }

    func advancing(to revision: Int) throws -> Self {
        try Self(
            noteID: noteID,
            documentID: documentID,
            generation: generation,
            revision: revision
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                noteID: container.decode(FloorpNoteID.self, forKey: .noteID),
                documentID: container.decode(String.self, forKey: .documentID),
                generation: container.decode(Int.self, forKey: .generation),
                revision: container.decode(Int.self, forKey: .revision)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid rich-text editor session cursor",
                    underlyingError: error
                )
            )
        }
    }
}

struct FloorpRichTextEditorEnvelope<Payload>: Codable, Equatable, Sendable
where Payload: Codable & Equatable & Sendable {
    let schemaVersion: Int
    let requestID: String?
    let session: FloorpRichTextEditorSessionCursor
    let payload: Payload

    init(
        schemaVersion: Int = FloorpRichTextBridgeProtocol.currentSchemaVersion,
        requestID: String? = nil,
        session: FloorpRichTextEditorSessionCursor,
        payload: Payload
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.session = session
        self.payload = payload
    }
}

struct FloorpRichTextPlannedCommand: Codable, Equatable, Sendable {
    let command: FloorpRichTextCommand
    let exclusiveMarkToUnset: FloorpRichTextMark?
}

struct FloorpRichTextEditorState: Codable, Equatable, Sendable {
    let isReady: Bool
    let canUndo: Bool
    let canRedo: Bool
    let activeHeadingLevel: Int?
    let activeMarks: [FloorpRichTextMark]?
    let activeListKind: FloorpRichTextListKind?
    let alignment: FloorpRichTextAlignment?

    init(
        isReady: Bool,
        canUndo: Bool,
        canRedo: Bool,
        activeHeadingLevel: Int? = nil,
        activeMarks: [FloorpRichTextMark]? = nil,
        activeListKind: FloorpRichTextListKind? = nil,
        alignment: FloorpRichTextAlignment? = nil
    ) {
        self.isReady = isReady
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.activeHeadingLevel = activeHeadingLevel
        self.activeMarks = activeMarks
        self.activeListKind = activeListKind
        self.alignment = alignment
    }
}

struct FloorpRichTextEditorUpdate: Codable, Equatable, Sendable {
    let source: String
    let isDirty: Bool

    init(source: String, isDirty: Bool = true) {
        self.source = source
        self.isDirty = isDirty
    }
}

typealias FloorpRichTextCommandEnvelope = FloorpRichTextEditorEnvelope<FloorpRichTextPlannedCommand>
typealias FloorpRichTextStateEnvelope = FloorpRichTextEditorEnvelope<FloorpRichTextEditorState>
typealias FloorpRichTextUpdateEnvelope = FloorpRichTextEditorEnvelope<FloorpRichTextEditorUpdate>

enum FloorpRichTextEnvelopeValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case noteIdentityMismatch(expected: FloorpNoteID, actual: FloorpNoteID)
    case documentIdentityMismatch(expected: String, actual: String)
    case generationMismatch(expected: Int, actual: Int)
    case revisionMismatch(expected: Int, actual: Int)
    case staleRevision(current: Int, incoming: Int)
}

private enum FloorpRichTextEnvelopeRevisionRule {
    case exact
    case newer
}

private enum FloorpRichTextEnvelopePolicy {
    static func validate<Payload>(
        _ envelope: FloorpRichTextEditorEnvelope<Payload>,
        for expected: FloorpRichTextEditorSessionCursor,
        revisionRule: FloorpRichTextEnvelopeRevisionRule
    ) throws where Payload: Codable & Equatable & Sendable {
        guard envelope.schemaVersion == FloorpRichTextBridgeProtocol.currentSchemaVersion else {
            throw FloorpRichTextEnvelopeValidationError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.session.noteID == expected.noteID else {
            throw FloorpRichTextEnvelopeValidationError.noteIdentityMismatch(
                expected: expected.noteID,
                actual: envelope.session.noteID
            )
        }
        guard envelope.session.documentID == expected.documentID else {
            throw FloorpRichTextEnvelopeValidationError.documentIdentityMismatch(
                expected: expected.documentID,
                actual: envelope.session.documentID
            )
        }
        guard envelope.session.generation == expected.generation else {
            throw FloorpRichTextEnvelopeValidationError.generationMismatch(
                expected: expected.generation,
                actual: envelope.session.generation
            )
        }
        switch revisionRule {
        case .exact:
            guard envelope.session.revision == expected.revision else {
                throw FloorpRichTextEnvelopeValidationError.revisionMismatch(
                    expected: expected.revision,
                    actual: envelope.session.revision
                )
            }
        case .newer:
            guard envelope.session.revision > expected.revision else {
                throw FloorpRichTextEnvelopeValidationError.staleRevision(
                    current: expected.revision,
                    incoming: envelope.session.revision
                )
            }
        }
    }
}

enum FloorpRichTextEditorStatePolicy {
    static func accept(
        _ envelope: FloorpRichTextStateEnvelope,
        for session: FloorpRichTextEditorSessionCursor
    ) throws -> FloorpRichTextEditorState {
        try FloorpRichTextEnvelopePolicy.validate(envelope, for: session, revisionRule: .exact)
        return envelope.payload
    }
}

enum FloorpRichTextCommandError: Error, Equatable, Sendable {
    case documentRequiresExplicitConversion([FloorpRichTextCompatibilityIssue])
    case invalidHeadingLevel(Int)
    case unsafeImageSource
    case imageResourceLimitExceeded
    case invalidImageWidth(Int)
    case imageMetadataTooLong
}

enum FloorpRichTextCommandPlanner {
    static func plan(
        _ command: FloorpRichTextCommand,
        for document: FloorpRichTextDocument,
        session: FloorpRichTextEditorSessionCursor
    ) throws -> FloorpRichTextCommandEnvelope {
        guard document.compatibility.isEditable else {
            throw FloorpRichTextCommandError.documentRequiresExplicitConversion(
                document.compatibility.issues
            )
        }

        var plannedCommand = command
        var exclusiveMarkToUnset: FloorpRichTextMark?
        switch command {
        case .undo, .redo, .setParagraph, .toggleList, .setAlignment:
            break
        case .toggleHeading(let level):
            guard (1...3).contains(level) else {
                throw FloorpRichTextCommandError.invalidHeadingLevel(level)
            }
        case .toggleMark(let mark):
            switch mark {
            case .bold, .italic:
                break
            case .underline:
                exclusiveMarkToUnset = .strike
            case .strike:
                exclusiveMarkToUnset = .underline
            }
        case .insertImage(let image):
            guard let normalizedSource = FloorpRichTextImagePolicy.normalizedSourceForDesktop(
                image.source
            ) else {
                throw FloorpRichTextCommandError.unsafeImageSource
            }
            if let width = image.width,
               !FloorpRichTextImagePolicy.allowedDisplayWidth.contains(width) {
                throw FloorpRichTextCommandError.invalidImageWidth(width)
            }
            guard [image.alt, image.title].compactMap({ $0 }).allSatisfy({
                $0.utf8.count <= FloorpRichTextImagePolicy.maximumMetadataBytes
            }) else {
                throw FloorpRichTextCommandError.imageMetadataTooLong
            }
            let normalizedImage = FloorpRichTextImage(
                source: normalizedSource,
                alt: image.alt,
                title: image.title,
                width: image.width
            )
            guard projectedDocumentAccepts(image: normalizedImage, document: document) else {
                throw FloorpRichTextCommandError.imageResourceLimitExceeded
            }
            plannedCommand = .insertImage(normalizedImage)
        }
        return FloorpRichTextCommandEnvelope(
            session: session,
            payload: FloorpRichTextPlannedCommand(
                command: plannedCommand,
                exclusiveMarkToUnset: exclusiveMarkToUnset
            )
        )
    }

    private static func projectedDocumentAccepts(
        image: FloorpRichTextImage,
        document: FloorpRichTextDocument
    ) -> Bool {
        guard var root = document.root.objectValue else { return false }
        var attributes: [String: FloorpRichTextJSONValue] = [
            "src": .string(image.source),
        ]
        if let alt = image.alt { attributes["alt"] = .string(alt) }
        if let title = image.title { attributes["title"] = .string(title) }
        if let width = image.width { attributes["width"] = .number(String(width)) }
        var content = root["content"]?.arrayValue ?? []
        content.append(.object([
            "type": .string("image"),
            "attrs": .object(attributes),
        ]))
        root["content"] = .array(content)
        return FloorpRichTextSchema.analyze(.object(root)).isEditable
    }
}

enum FloorpRichTextEditorUpdateError: Error, Equatable, Sendable {
    case originalRequiresExplicitConversion([FloorpRichTextCompatibilityIssue])
    case updatedDocumentIsUnsupported([FloorpRichTextCompatibilityIssue])
}

enum FloorpRichTextEditorUpdatePolicy {
    struct AcceptedUpdate: Equatable, Sendable {
        let document: FloorpRichTextDocument
        let session: FloorpRichTextEditorSessionCursor
    }

    static func accept(
        _ envelope: FloorpRichTextUpdateEnvelope,
        for session: FloorpRichTextEditorSessionCursor,
        replacing original: FloorpRichTextDocument
    ) throws -> AcceptedUpdate {
        try FloorpRichTextEnvelopePolicy.validate(envelope, for: session, revisionRule: .newer)
        guard original.compatibility.isEditable else {
            throw FloorpRichTextEditorUpdateError.originalRequiresExplicitConversion(
                original.compatibility.issues
            )
        }
        let updated = try FloorpRichTextCodec.decode(envelope.payload.source)
        guard updated.compatibility.isEditable else {
            throw FloorpRichTextEditorUpdateError.updatedDocumentIsUnsupported(
                updated.compatibility.issues
            )
        }
        return AcceptedUpdate(
            document: updated,
            session: try session.advancing(to: envelope.session.revision)
        )
    }
}

enum FloorpRichTextImagePolicy {
    struct RasterMetadata: Equatable, Sendable {
        let frameCount: Int
        let cumulativePixels: UInt64
    }

    private struct NormalizedRasterSource {
        let source: String
        let metadata: RasterMetadata
    }

    static let maximumPersistedSourceBytes = 200 * 1_024
    static let maximumMetadataBytes = 1_024
    static let allowedDisplayWidth = 40...8_192
    static let maximumPixelDimension: UInt64 = 4_096
    static let maximumPixelsPerFrame: UInt64 = 4_194_304
    static let maximumFrameCount = 120
    static let maximumCumulativePixels: UInt64 = 16_777_216

    private static let rasterMIMETypes = ["jpeg", "png", "gif", "webp"]

    static func isSafePersistedSource(_ source: String) -> Bool {
        safePersistedMetadata(source) != nil
    }

    static func safePersistedMetadata(_ source: String) -> RasterMetadata? {
        guard let normalized = normalizedRasterDataURL(source),
              normalized.source == source else {
            return nil
        }
        return normalized.metadata
    }

    static func normalizedSourceForDesktop(_ source: String) -> String? {
        if source.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return normalizedRasterDataURL(source)?.source
        }
        return nil
    }

    private static func normalizedRasterDataURL(_ source: String) -> NormalizedRasterSource? {
        guard source.utf8.count <= maximumPersistedSourceBytes,
              let commaIndex = source.firstIndex(of: ",") else {
            return nil
        }
        let metadata = source[..<commaIndex]
        let payload = source[source.index(after: commaIndex)...]
        let prefix = "data:image/"
        let suffix = ";base64"
        guard !payload.isEmpty,
              !payload.contains(where: { $0.isWhitespace }),
              metadata.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil,
              metadata.lowercased().hasSuffix(suffix),
              metadata.count > prefix.count + suffix.count else {
            return nil
        }
        let mimeStart = metadata.index(metadata.startIndex, offsetBy: prefix.count)
        let mimeEnd = metadata.index(metadata.endIndex, offsetBy: -suffix.count)
        let mime = String(metadata[mimeStart..<mimeEnd]).lowercased()
        guard rasterMIMETypes.contains(mime),
              let decoded = Data(base64Encoded: String(payload)),
              hasExpectedSignature(decoded, mime: mime),
              let rasterMetadata = safeRasterMetadata(decoded, mime: mime) else {
            return nil
        }
        return NormalizedRasterSource(
            source: "data:image/\(mime);base64,\(payload)",
            metadata: rasterMetadata
        )
    }

    private static func safeRasterMetadata(_ data: Data, mime: String) -> RasterMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let typeIdentifier = CGImageSourceGetType(source),
              let actualType = UTType(typeIdentifier as String),
              let expectedType = UTType(mimeType: "image/\(mime)"),
              actualType.conforms(to: expectedType) else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        guard (1...maximumFrameCount).contains(frameCount),
              let sourceProperties = CGImageSourceCopyProperties(
                source,
                options
              ) as? [CFString: Any],
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let firstFrameProperties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options
              ) as? [CFString: Any],
              let canvas = declaredCanvasDimensions(
                sourceProperties,
                firstFrameProperties: firstFrameProperties,
                mime: mime,
                frameCount: frameCount
              ),
              canvas.width > 0,
              canvas.height > 0,
              canvas.width <= maximumPixelDimension,
              canvas.height <= maximumPixelDimension else {
            return nil
        }
        let (canvasPixels, canvasDidOverflow) = canvas.width.multipliedReportingOverflow(
            by: canvas.height
        )
        guard !canvasDidOverflow,
              canvasPixels <= maximumCumulativePixels else {
            return nil
        }

        guard let firstFrameWidth = (
            firstFrameProperties[kCGImagePropertyPixelWidth] as? NSNumber
        )?.uint64Value,
              let firstFrameHeight = (
                firstFrameProperties[kCGImagePropertyPixelHeight] as? NSNumber
              )?.uint64Value else {
            return nil
        }

        var cumulativePixels: UInt64 = 0
        for index in 0..<frameCount {
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    source,
                    index,
                    options
                  ) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
                  width > 0,
                  height > 0,
                  width <= maximumPixelDimension,
                  height <= maximumPixelDimension,
                  width <= canvas.width,
                  height <= canvas.height else {
                return nil
            }
            let (framePixels, didOverflow) = width.multipliedReportingOverflow(by: height)
            guard !didOverflow, framePixels <= maximumPixelsPerFrame else { return nil }
            let (nextCumulativePixels, cumulativeDidOverflow) = cumulativePixels.addingReportingOverflow(
                framePixels
            )
            guard !cumulativeDidOverflow,
                  nextCumulativePixels <= maximumCumulativePixels else {
                return nil
            }
            cumulativePixels = nextCumulativePixels
        }
        if frameCount == 1,
           firstFrameWidth == canvas.width,
           firstFrameHeight == canvas.height {
            return RasterMetadata(frameCount: frameCount, cumulativePixels: cumulativePixels)
        }
        let (totalPixels, totalDidOverflow) = cumulativePixels.addingReportingOverflow(canvasPixels)
        guard !totalDidOverflow,
              totalPixels <= maximumCumulativePixels else {
            return nil
        }
        return RasterMetadata(frameCount: frameCount, cumulativePixels: totalPixels)
    }

    private static func declaredCanvasDimensions(
        _ properties: [CFString: Any],
        firstFrameProperties: [CFString: Any],
        mime: String,
        frameCount: Int
    ) -> (width: UInt64, height: UInt64)? {
        let formatKeys: (
            dictionary: CFString,
            dimensions: (width: CFString, height: CFString)
        )?
        switch mime {
        case "gif":
            formatKeys = (
                kCGImagePropertyGIFDictionary,
                (kCGImagePropertyGIFCanvasPixelWidth, kCGImagePropertyGIFCanvasPixelHeight)
            )
        case "png" where frameCount > 1:
            formatKeys = (
                kCGImagePropertyPNGDictionary,
                (kCGImagePropertyAPNGCanvasPixelWidth, kCGImagePropertyAPNGCanvasPixelHeight)
            )
        case "webp":
            formatKeys = (
                kCGImagePropertyWebPDictionary,
                (kCGImagePropertyWebPCanvasPixelWidth, kCGImagePropertyWebPCanvasPixelHeight)
            )
        default:
            formatKeys = nil
        }
        if let formatKeys {
            guard let dictionary = properties[formatKeys.dictionary] as? [CFString: Any],
                  let width = (
                    dictionary[formatKeys.dimensions.width] as? NSNumber
                  )?.uint64Value,
                  let height = (
                    dictionary[formatKeys.dimensions.height] as? NSNumber
                  )?.uint64Value else {
                return nil
            }
            return (width, height)
        }
        guard let width = (firstFrameProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (firstFrameProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value else {
            return nil
        }
        return (width, height)
    }

    private static func hasExpectedSignature(_ data: Data, mime: String) -> Bool {
        switch mime {
        case "jpeg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
        case "png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "gif":
            return data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
        case "webp":
            return data.count >= 12
                && data.prefix(4) == Data("RIFF".utf8)
                && data[8..<12] == Data("WEBP".utf8)
        default:
            return false
        }
    }
}
