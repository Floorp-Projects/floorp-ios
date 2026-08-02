// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class FloorpRichTextDocumentTests: XCTestCase {
    private let safePNGDataURL = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    func testDesktopNodeAndMarkFixtureRoundTripsSemantically() throws {
        let source = desktopFeatureFixture
        let document = try FloorpRichTextCodec.decode(source)

        XCTAssertEqual(document.modelVersion, FloorpRichTextDocument.currentModelVersion)
        XCTAssertTrue(document.compatibility.isEditable, "\(document.compatibility.issues)")
        XCTAssertEqual(try FloorpRichTextCodec.encode(document), source)

        let canonicalDocument = FloorpRichTextDocument(
            root: document.root,
            compatibility: document.compatibility
        )
        let canonical = try FloorpRichTextCodec.encode(canonicalDocument)
        XCTAssertEqual(try semanticJSON(canonical), try semanticJSON(source))
        XCTAssertEqual(try FloorpRichTextCodec.decode(canonical), document)
    }

    func testUnknownNodesMarksAndFieldsRemainByteForByteUntouched() throws {
        let fixtures = [
            """
              { "type" : "doc", "content" : [
                {"type":"futureWidget","attrs":{"opaque":[3,2,1]},"content":[]}
              ] }
            """,
            """
            {"type":"doc","content":[{"type":"paragraph","content":[
              {"type":"text","text":"keep","marks":[{"type":"futureMark","attrs":{"token":"A B"}}]}
            ]}]}
            """,
            """
            {"type":"doc","futureRoot":{"spacing":"  untouched  "},"content":[{"type":"paragraph"}]}
            """,
        ]

        for source in fixtures {
            let document = try FloorpRichTextCodec.decode(source)
            XCTAssertFalse(document.compatibility.isEditable)
            XCTAssertEqual(try FloorpRichTextCodec.encode(document), source)
        }
    }

    func testUnknownDocumentRequiresExplicitConversionBeforeCommandsOrUpdates() throws {
        let source = """
        { "type":"doc", "content":[{"type":"futureWidget","payload":"preserve"}] }
        """
        let document = try FloorpRichTextCodec.decode(source)
        let currentSession = try session()
        let nextSession = try session(revision: currentSession.revision + 1)

        XCTAssertThrowsError(
            try FloorpRichTextCommandPlanner.plan(
                .toggleMark(.bold),
                for: document,
                session: currentSession
            )
        ) { error in
            guard case FloorpRichTextCommandError.documentRequiresExplicitConversion(let issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains { $0.kind == .unsupportedNode("futureWidget") })
        }
        XCTAssertThrowsError(
            try FloorpRichTextEditorUpdatePolicy.accept(
                updateEnvelope(minimalDocument(), session: nextSession),
                for: currentSession,
                replacing: document
            )
        ) { error in
            guard case FloorpRichTextEditorUpdateError.originalRequiresExplicitConversion = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FloorpRichTextCodec.encode(document), source)

        let explicitlyConverted = try FloorpRichTextCodec.document(fromPlainText: "preserve")
        XCTAssertNoThrow(
            try FloorpRichTextCommandPlanner.plan(
                .toggleMark(.bold),
                for: explicitlyConverted,
                session: currentSession
            )
        )
    }

    func testEditorUpdateRejectsNewUnknownContent() throws {
        let original = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let nextSession = try session(revision: currentSession.revision + 1)
        let unsupportedUpdates = [
            """
            {"type":"doc","content":[{"type":"paragraph","content":[
              {"type":"text","text":"A","marks":[{"type":"futureMark"}]}
            ]}]}
            """,
            #"{"type":"doc","content":[{"type":"listItem","content":[{"type":"heading","attrs":{"level":1}}]}]}"#,
            """
            {"type":"doc","content":[{"type":"codeBlock","content":[
              {"type":"text","text":"code","marks":[{"type":"bold"}]}
            ]}]}
            """,
            #"{"type":"doc","content":[{"type":"blockquote","content":[]}]}"#,
            #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":""}]}]}"#,
        ]

        for unsupportedUpdate in unsupportedUpdates {
            XCTAssertThrowsError(
                try FloorpRichTextEditorUpdatePolicy.accept(
                    updateEnvelope(unsupportedUpdate, session: nextSession),
                    for: currentSession,
                    replacing: original
                )
            ) { error in
                guard case FloorpRichTextEditorUpdateError.updatedDocumentIsUnsupported = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testVersionedEnvelopesCarryMandatoryIdentityAndRoundTrip() throws {
        let currentSession = try session()
        let nextSession = try session(revision: currentSession.revision + 1)
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let command = try FloorpRichTextCommandPlanner.plan(
            .toggleHeading(level: 2),
            for: document,
            session: currentSession
        )
        let state = FloorpRichTextStateEnvelope(
            session: currentSession,
            payload: FloorpRichTextEditorState(isReady: true, canUndo: true, canRedo: false)
        )
        let update = updateEnvelope(minimalDocument(), session: nextSession)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(FloorpRichTextCommandEnvelope.self, from: encoder.encode(command)),
            command
        )
        XCTAssertEqual(
            try decoder.decode(FloorpRichTextStateEnvelope.self, from: encoder.encode(state)),
            state
        )
        XCTAssertEqual(
            try decoder.decode(FloorpRichTextUpdateEnvelope.self, from: encoder.encode(update)),
            update
        )
        XCTAssertEqual(
            try FloorpRichTextEditorStatePolicy.accept(state, for: currentSession),
            state.payload
        )

        let missingDocumentIdentity = Data(
            """
            {
              "schemaVersion": 1,
              "session": {"noteID": "note-a", "generation": 3, "revision": 7},
              "payload": {"isReady": true, "canUndo": false, "canRedo": false}
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try decoder.decode(FloorpRichTextStateEnvelope.self, from: missingDocumentIdentity)
        )
        XCTAssertThrowsError(
            try FloorpRichTextEditorSessionCursor(
                noteID: "",
                documentID: "document-a",
                generation: 3,
                revision: 7
            )
        ) { error in
            XCTAssertEqual(error as? FloorpRichTextEditorSessionError, .invalidNoteID)
        }

        let futureState = FloorpRichTextStateEnvelope(
            session: nextSession,
            payload: state.payload
        )
        XCTAssertThrowsError(
            try FloorpRichTextEditorStatePolicy.accept(futureState, for: currentSession)
        ) { error in
            XCTAssertEqual(
                error as? FloorpRichTextEnvelopeValidationError,
                .revisionMismatch(expected: currentSession.revision, actual: nextSession.revision)
            )
        }
    }

    func testUpdateRejectsWrongIdentityGenerationAndStaleRevisionBeforeDocumentDecode() throws {
        let currentSession = try session()
        let nextSession = try session(revision: currentSession.revision + 1)
        let original = try FloorpRichTextCodec.decode(minimalDocument())
        let invalidSource = "{"
        let rejected: [(FloorpRichTextUpdateEnvelope, FloorpRichTextEnvelopeValidationError)] = [
            (
                FloorpRichTextUpdateEnvelope(
                    schemaVersion: FloorpRichTextBridgeProtocol.currentSchemaVersion + 1,
                    session: nextSession,
                    payload: FloorpRichTextEditorUpdate(source: invalidSource)
                ),
                .unsupportedSchemaVersion(FloorpRichTextBridgeProtocol.currentSchemaVersion + 1)
            ),
            (
                updateEnvelope(
                    invalidSource,
                    session: try session(noteID: "note-b", revision: nextSession.revision)
                ),
                .noteIdentityMismatch(expected: currentSession.noteID, actual: "note-b")
            ),
            (
                updateEnvelope(
                    invalidSource,
                    session: try session(documentID: "document-b", revision: nextSession.revision)
                ),
                .documentIdentityMismatch(expected: currentSession.documentID, actual: "document-b")
            ),
            (
                updateEnvelope(
                    invalidSource,
                    session: try session(generation: currentSession.generation - 1, revision: nextSession.revision)
                ),
                .generationMismatch(
                    expected: currentSession.generation,
                    actual: currentSession.generation - 1
                )
            ),
            (
                updateEnvelope(invalidSource, session: currentSession),
                .staleRevision(current: currentSession.revision, incoming: currentSession.revision)
            ),
        ]

        for (envelope, expectedError) in rejected {
            XCTAssertThrowsError(
                try FloorpRichTextEditorUpdatePolicy.accept(
                    envelope,
                    for: currentSession,
                    replacing: original
                )
            ) { error in
                XCTAssertEqual(error as? FloorpRichTextEnvelopeValidationError, expectedError)
            }
        }

        XCTAssertThrowsError(
            try FloorpRichTextEditorUpdatePolicy.accept(
                updateEnvelope(invalidSource, session: nextSession),
                for: currentSession,
                replacing: original
            )
        ) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .invalidJSON)
        }

        let accepted = try FloorpRichTextEditorUpdatePolicy.accept(
            updateEnvelope(minimalDocument(), session: nextSession),
            for: currentSession,
            replacing: original
        )
        XCTAssertTrue(accepted.document.compatibility.isEditable)
        XCTAssertEqual(accepted.session, nextSession)
    }

    func testPlainTextConversionPreservesLinesAndEscaping() throws {
        let document = try FloorpRichTextCodec.document(fromPlainText: "first\n\n\"third\"\\end")
        let source = try FloorpRichTextCodec.encode(document)
        let decoded = try FloorpRichTextCodec.decode(source)

        XCTAssertTrue(decoded.compatibility.isEditable, "\(decoded.compatibility.issues)")
        guard case .object(let root) = decoded.root,
              case .array(let content)? = root["content"] else {
            return XCTFail("Expected a document content array")
        }
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(try semanticJSON(source), try semanticJSON(try FloorpRichTextCodec.encode(decoded)))
    }

    func testPlainTextConversionUsesOneTokenizerForPlatformAndUnicodeNewlines() throws {
        let document = try FloorpRichTextCodec.document(
            fromPlainText: "a\r\nb\rc\u{0085}d\u{2028}e\u{2029}f"
        )
        let source = try FloorpRichTextCodec.encode(document)
        let decoded = try FloorpRichTextCodec.decode(source)

        guard case .object(let root) = decoded.root,
              case .array(let content)? = root["content"] else {
            return XCTFail("Expected a document content array")
        }
        XCTAssertEqual(content.count, 6)
        XCTAssertTrue(decoded.compatibility.isEditable, "\(decoded.compatibility.issues)")
    }

    func testPlainTextPreflightRejectsNewlineNodeBombBeforeBuildingNodes() {
        let newlineForms = ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"]

        for newline in newlineForms {
            let newlineBomb = String(repeating: newline, count: FloorpRichTextCodec.maximumNodeCount)
            XCTAssertThrowsError(try FloorpRichTextCodec.document(fromPlainText: newlineBomb)) { error in
                XCTAssertEqual(error as? FloorpRichTextCodecError, .resourceLimitExceeded)
            }
        }
    }

    func testPlainTextSingleLineHonorsExactEncodedArchiveBoundary() throws {
        let oneCharacter = try FloorpRichTextCodec.document(fromPlainText: "a")
        let fixedOutputBytes = try FloorpRichTextCodec.encode(oneCharacter).utf8.count - 1
        let fittingText = String(
            repeating: "a",
            count: FloorpRichTextCodec.maximumInputBytes - fixedOutputBytes
        )
        let fittingDocument = try FloorpRichTextCodec.document(fromPlainText: fittingText)

        XCTAssertTrue(fittingDocument.compatibility.isEditable)
        XCTAssertEqual(
            try FloorpRichTextCodec.encode(fittingDocument).utf8.count,
            FloorpRichTextCodec.maximumInputBytes
        )

        XCTAssertThrowsError(
            try FloorpRichTextCodec.document(fromPlainText: fittingText + "a")
        ) { error in
            XCTAssertEqual(
                error as? FloorpRichTextCodecError,
                .inputTooLarge(
                    actualBytes: FloorpRichTextCodec.maximumInputBytes + 1,
                    maximumBytes: FloorpRichTextCodec.maximumInputBytes
                )
            )
        }
    }

    func testEveryEditablePlainTextConversionCanBeEncoded() throws {
        let corpus = [
            "",
            "plain",
            "first\n\nlast",
            "CRLF\r\nbare CR\rUnicode\u{0085}newlines\u{2028}are\u{2029}split",
            "quotes: \" and slash: \\",
            "controls: \u{0000}\u{0008}\u{0009}\u{000C}\u{000D}",
            "日本語と🦊",
        ]

        for plainText in corpus {
            let document = try FloorpRichTextCodec.document(fromPlainText: plainText)
            XCTAssertTrue(document.compatibility.isEditable, "\(document.compatibility.issues)")
            let encoded = try FloorpRichTextCodec.encode(document)
            XCTAssertLessThanOrEqual(encoded.utf8.count, FloorpRichTextCodec.maximumInputBytes)
            XCTAssertTrue(try FloorpRichTextCodec.decode(encoded).compatibility.isEditable)
        }
    }

    func testEncoderStopsWhenGeneratedOutputExceedsArchiveBoundary() {
        let oversizedDocument = FloorpRichTextDocument(
            root: .object([
                "type": .string("doc"),
                "content": .array([
                    .object([
                        "type": .string("paragraph"),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(
                                    String(repeating: "a", count: FloorpRichTextCodec.maximumInputBytes)
                                ),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            compatibility: FloorpRichTextCompatibility(issues: [])
        )

        XCTAssertThrowsError(try FloorpRichTextCodec.encode(oversizedDocument)) { error in
            guard case FloorpRichTextCodecError.inputTooLarge(let actual, let maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, FloorpRichTextCodec.maximumInputBytes)
        }
    }

    func testCommandPlannerCoversDesktopToolbarCommands() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let commands: [FloorpRichTextCommand] = [
            .undo,
            .redo,
            .setParagraph,
            .toggleHeading(level: 1),
            .toggleHeading(level: 2),
            .toggleHeading(level: 3),
            .toggleMark(.bold),
            .toggleMark(.italic),
            .toggleMark(.underline),
            .toggleMark(.strike),
            .toggleList(.bullet),
            .toggleList(.ordered),
            .setAlignment(.left),
            .setAlignment(.center),
            .setAlignment(.right),
        ]

        for command in commands {
            let envelope = try FloorpRichTextCommandPlanner.plan(
                command,
                for: document,
                session: currentSession
            )
            XCTAssertEqual(envelope.schemaVersion, FloorpRichTextBridgeProtocol.currentSchemaVersion)
            XCTAssertEqual(envelope.session, currentSession)
            XCTAssertEqual(envelope.payload.command, command)
        }

        let underline = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.underline),
            for: document,
            session: currentSession
        )
        XCTAssertEqual(underline.payload.exclusiveMarkToUnset, .strike)
        let strike = try FloorpRichTextCommandPlanner.plan(
            .toggleMark(.strike),
            for: document,
            session: currentSession
        )
        XCTAssertEqual(strike.payload.exclusiveMarkToUnset, .underline)
    }

    func testCommandPlannerRejectsUnsupportedHeadingLevels() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()

        for level in [0, 4, Int.max] {
            XCTAssertThrowsError(
                try FloorpRichTextCommandPlanner.plan(
                    .toggleHeading(level: level),
                    for: document,
                    session: currentSession
                )
            ) { error in
                XCTAssertEqual(error as? FloorpRichTextCommandError, .invalidHeadingLevel(level))
            }
        }
    }

    func testImageCommandAcceptsSafeRasterDataAndHTTPS() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let dataPayload = safePNGDataURL.split(separator: ",", maxSplits: 1)[1]
        let images: [(input: FloorpRichTextImage, normalizedSource: String)] = [
            (
                FloorpRichTextImage(source: safePNGDataURL, alt: "pixel", width: 40),
                safePNGDataURL
            ),
            (
                FloorpRichTextImage(
                    source: "DATA:IMAGE/PNG;BASE64," + dataPayload,
                    alt: "uppercase metadata"
                ),
                "data:image/png;base64," + dataPayload
            ),
            (
                FloorpRichTextImage(
                    source: "HTTPS://images.example.test/photo.webp",
                    alt: "remote",
                    title: "Photo",
                    width: 800
                ),
                "https://images.example.test/photo.webp"
            ),
        ]

        for (input, normalizedSource) in images {
            let envelope = try FloorpRichTextCommandPlanner.plan(
                .insertImage(input),
                for: document,
                session: currentSession
            )
            guard case .insertImage(let normalizedImage) = envelope.payload.command else {
                return XCTFail("Expected an image command")
            }
            XCTAssertEqual(normalizedImage.source, normalizedSource)
            XCTAssertEqual(normalizedImage.alt, input.alt)
            XCTAssertEqual(normalizedImage.title, input.title)
            XCTAssertEqual(normalizedImage.width, input.width)
            XCTAssertTrue(FloorpRichTextImagePolicy.isSafePersistedSource(normalizedSource))
        }
    }

    func testImageCommandRejectsObjectURLsVectorsAndMismatchedData() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let unsafeSources = [
            "blob:https://example.test/temporary-object",
            "http://example.test/image.png",
            "https://user:secret@example.test/image.png",
            "javascript:alert(1)",
            "file:///tmp/image.png",
            "data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9YWxlcnQoMSk+PC9zdmc+",
            "data:image/png;base64,PGh0bWw+c2NyaXB0PC9odG1sPg==",
        ]

        for source in unsafeSources {
            XCTAssertThrowsError(
                try FloorpRichTextCommandPlanner.plan(
                    .insertImage(FloorpRichTextImage(source: source)),
                    for: document,
                    session: currentSession
                )
            ) { error in
                XCTAssertEqual(error as? FloorpRichTextCommandError, .unsafeImageSource)
            }
        }
    }

    func testImageCommandEnforcesWidthMetadataAndPersistedSizeLimits() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()

        for width in [39, 8_193] {
            XCTAssertThrowsError(
                try FloorpRichTextCommandPlanner.plan(
                    .insertImage(FloorpRichTextImage(source: safePNGDataURL, width: width)),
                    for: document,
                    session: currentSession
                )
            ) { error in
                XCTAssertEqual(error as? FloorpRichTextCommandError, .invalidImageWidth(width))
            }
        }
        XCTAssertThrowsError(
            try FloorpRichTextCommandPlanner.plan(
                .insertImage(
                    FloorpRichTextImage(
                        source: safePNGDataURL,
                        alt: String(repeating: "a", count: 1_025)
                    )
                ),
                for: document,
                session: currentSession
            )
        ) { error in
            XCTAssertEqual(error as? FloorpRichTextCommandError, .imageMetadataTooLong)
        }
        XCTAssertThrowsError(
            try FloorpRichTextCommandPlanner.plan(
                .insertImage(
                    FloorpRichTextImage(
                        source: safePNGDataURL,
                        title: String(repeating: "🦊", count: 300)
                    )
                ),
                for: document,
                session: currentSession
            )
        ) { error in
            XCTAssertEqual(error as? FloorpRichTextCommandError, .imageMetadataTooLong)
        }

        let oversizedDataURL = "data:image/png;base64,"
            + String(repeating: "A", count: FloorpRichTextImagePolicy.maximumPersistedSourceBytes)
        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(oversizedDataURL))
    }

    func testUnsafeOrNonCanonicalPersistedImageBlocksEditingWithoutRewritingSource() throws {
        let sources = [
            "blob:https://example.test/temporary",
            "HTTPS://images.example.test/photo.webp",
            "DATA:IMAGE/PNG;BASE64," + safePNGDataURL.split(separator: ",", maxSplits: 1)[1],
        ]

        for imageSource in sources {
            let source = """
              {"type":"doc","content":[{"type":"image","attrs":{
                "src":"\(imageSource)","alt":null,"title":null,"width":200
              }}]}
            """
            let document = try FloorpRichTextCodec.decode(source)

            XCTAssertFalse(document.compatibility.isEditable)
            XCTAssertTrue(document.compatibility.issues.contains { $0.kind == .unsafeImageSource })
            XCTAssertEqual(try FloorpRichTextCodec.encode(document), source)
        }
    }

    func testCodecDistinguishesInvalidJSONNonTipTapAndVersionErrors() {
        XCTAssertThrowsError(try FloorpRichTextCodec.decode("{")) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .invalidJSON)
        }
        XCTAssertThrowsError(try FloorpRichTextCodec.decode(#"{"root":{"children":[]}}"#)) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .rootIsNotTipTapDocument)
        }
        XCTAssertThrowsError(
            try FloorpRichTextCodec.decode(minimalDocument(), modelVersion: 2)
        ) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .unsupportedModelVersion(2))
        }

        let invalidNumber = FloorpRichTextDocument(
            root: .object([
                "type": .string("doc"),
                "content": .array([
                    .object([
                        "type": .string("orderedList"),
                        "attrs": .object(["start": .number("1}")]),
                        "content": .array([]),
                    ]),
                ]),
            ]),
            compatibility: FloorpRichTextCompatibility(issues: [])
        )
        XCTAssertThrowsError(try FloorpRichTextCodec.encode(invalidNumber)) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .encodingFailed)
        }
    }

    func testCodecRejectsInputBeyondArchiveBoundary() {
        let oversized = "{\"type\":\"doc\",\"padding\":\""
            + String(repeating: "x", count: FloorpRichTextCodec.maximumInputBytes)
            + "\"}"

        XCTAssertThrowsError(try FloorpRichTextCodec.decode(oversized)) { error in
            guard case FloorpRichTextCodecError.inputTooLarge(let actual, let maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, FloorpRichTextCodec.maximumInputBytes)
        }
    }

    func testCodecRejectsExcessiveJSONStructure() {
        let excessiveValues = "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}],\"future\":["
            + Array(
                repeating: "null",
                count: FloorpRichTextCodec.maximumJSONValueCount
            ).joined(separator: ",")
            + "]}"

        XCTAssertLessThan(excessiveValues.utf8.count, FloorpRichTextCodec.maximumInputBytes)
        XCTAssertThrowsError(try FloorpRichTextCodec.decode(excessiveValues)) { error in
            XCTAssertEqual(error as? FloorpRichTextCodecError, .resourceLimitExceeded)
        }
    }

    func testKnownLexicalFixtureMigratesWithDesktopMarksBlocksListsAndAlignment() throws {
        let source = """
        {
          "root": {
            "type": "root",
            "version": 1,
            "children": [
              {
                "type": "heading",
                "tag": "h2",
                "format": "center",
                "version": 1,
                "children": [
                  {"type":"text","text":"Title","format":3,"detail":0,"mode":"normal","style":"","version":1}
                ]
              },
              {
                "type": "paragraph",
                "format": "right",
                "version": 1,
                "children": [
                  {"type":"text","text":"A","format":12,"version":1},
                  {"type":"linebreak","version":1},
                  {"type":"text","text":"B","format":0,"version":1}
                ]
              },
              {
                "type": "list",
                "listType": "number",
                "version": 1,
                "children": [
                  {"type":"listitem","value":1,"version":1,"children":[
                    {"type":"text","text":"One","format":0,"version":1}
                  ]}
                ]
              },
              {
                "type": "quote",
                "version": 1,
                "children": [
                  {"type":"text","text":"Quote","format":0,"version":1}
                ]
              }
            ]
          }
        }
        """

        let migration = try FloorpLexicalMigrator.migrate(source)

        XCTAssertTrue(migration.isEditable, "\(migration.compatibility.issues)")
        let document = try XCTUnwrap(migration.document)
        let encoded = try FloorpRichTextCodec.encode(document)
        let root = try XCTUnwrap(try semanticJSON(encoded) as? [String: Any])
        let content = try XCTUnwrap(root["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, [
            "heading", "paragraph", "orderedList", "blockquote",
        ])
        XCTAssertEqual((content[0]["attrs"] as? [String: Any])?["level"] as? Int, 2)
        XCTAssertEqual((content[0]["attrs"] as? [String: Any])?["textAlign"] as? String, "center")
        let headingText = try XCTUnwrap((content[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            (headingText["marks"] as? [[String: Any]])?.compactMap { $0["type"] as? String },
            ["bold", "italic"]
        )
        let paragraphText = try XCTUnwrap((content[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            (paragraphText["marks"] as? [[String: Any]])?.compactMap { $0["type"] as? String },
            ["strike", "underline"]
        )
    }

    func testLexicalUnknownNodeOrFieldKeepsOriginalSourceReadOnly() throws {
        let fixtures = [
            """
            { "root" : { "children" : [
              {"type":"futureWidget","payload":{"opaque":true}}
            ] } }
            """,
            """
            { "root" : { "children" : [
              {"type":"paragraph","futureSpacing":7,"children":[
                {"type":"text","text":"keep","format":0}
              ]}
            ] } }
            """,
            """
            { "root" : { "children" : [
              {"type":"paragraph","children":[
                {"type":"text","text":"keep","format":16}
              ]}
            ] } }
            """,
        ]

        for source in fixtures {
            let migration = try FloorpLexicalMigrator.migrate(source)
            XCTAssertFalse(migration.isEditable)
            XCTAssertNil(migration.document)
            XCTAssertEqual(migration.originalSource, source)

            let note = FloorpNote(
                id: "lexical",
                title: "Preserve",
                content: source,
                createdAt: 1,
                updatedAt: 1,
                contentFormat: .automatic
            )
            guard case .readOnly = FloorpRichTextEditorPreparation.prepare(note) else {
                return XCTFail("Unknown Lexical content must remain read-only")
            }
        }
    }

    func testRichEditorStateCarriesAccessibleSelectionState() throws {
        let state = FloorpRichTextEditorState(
            isReady: true,
            canUndo: true,
            canRedo: false,
            activeHeadingLevel: 2,
            activeMarks: [.bold, .underline],
            activeListKind: .ordered,
            alignment: .center
        )
        let envelope = FloorpRichTextStateEnvelope(session: try session(), payload: state)
        let data = try JSONEncoder().encode(envelope)

        XCTAssertEqual(
            try JSONDecoder().decode(FloorpRichTextStateEnvelope.self, from: data),
            envelope
        )
    }

    private func session(
        noteID: String = "note-a",
        documentID: String = "document-a",
        generation: Int = 3,
        revision: Int = 7
    ) throws -> FloorpRichTextEditorSessionCursor {
        try FloorpRichTextEditorSessionCursor(
            noteID: noteID,
            documentID: documentID,
            generation: generation,
            revision: revision
        )
    }

    private func updateEnvelope(
        _ source: String,
        session: FloorpRichTextEditorSessionCursor
    ) -> FloorpRichTextUpdateEnvelope {
        FloorpRichTextUpdateEnvelope(
            session: session,
            payload: FloorpRichTextEditorUpdate(source: source)
        )
    }

    private func minimalDocument() -> String {
        #"{"type":"doc","content":[{"type":"paragraph"}]}"#
    }

    /// Captured from `Editor.getJSON()` with TipTap 2.27.2 and reloaded through
    /// `setContent` in the same pinned schema before being checked in.
    private var desktopFeatureFixture: String {
        """
        {
          "type": "doc",
          "content": [
            {
              "type": "heading",
              "attrs": {
                "textAlign": "center",
                "level": 1
              },
              "content": [
                {
                  "type": "text",
                  "marks": [
                    {
                      "type": "bold"
                    }
                  ],
                  "text": "H1"
                }
              ]
            },
            {
              "type": "heading",
              "attrs": {
                "textAlign": "left",
                "level": 2
              },
              "content": [
                {
                  "type": "text",
                  "marks": [
                    {
                      "type": "italic"
                    }
                  ],
                  "text": "H2"
                }
              ]
            },
            {
              "type": "heading",
              "attrs": {
                "textAlign": "right",
                "level": 3
              },
              "content": [
                {
                  "type": "text",
                  "marks": [
                    {
                      "type": "underline"
                    }
                  ],
                  "text": "H3"
                }
              ]
            },
            {
              "type": "heading",
              "attrs": {
                "textAlign": "justify",
                "level": 6
              },
              "content": [
                {
                  "type": "text",
                  "text": "H6"
                }
              ]
            },
            {
              "type": "paragraph",
              "attrs": {
                "textAlign": "right"
              },
              "content": [
                {
                  "type": "text",
                  "marks": [
                    {
                      "type": "strike"
                    }
                  ],
                  "text": "strike"
                },
                {
                  "type": "hardBreak",
                  "marks": [
                    {
                      "type": "strike"
                    }
                  ]
                },
                {
                  "type": "text",
                  "marks": [
                    {
                      "type": "code"
                    }
                  ],
                  "text": "code"
                }
              ]
            },
            {
              "type": "blockquote",
              "content": [
                {
                  "type": "paragraph",
                  "attrs": {
                    "textAlign": null
                  },
                  "content": [
                    {
                      "type": "text",
                      "text": "quote"
                    }
                  ]
                }
              ]
            },
            {
              "type": "bulletList",
              "content": [
                {
                  "type": "listItem",
                  "content": [
                    {
                      "type": "paragraph",
                      "attrs": {
                        "textAlign": null
                      },
                      "content": [
                        {
                          "type": "text",
                          "text": "bullet"
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "type": "orderedList",
              "attrs": {
                "start": 0,
                "type": "A"
              },
              "content": [
                {
                  "type": "listItem",
                  "content": [
                    {
                      "type": "paragraph",
                      "attrs": {
                        "textAlign": null
                      },
                      "content": [
                        {
                          "type": "text",
                          "text": "ordered"
                        }
                      ]
                    },
                    {
                      "type": "bulletList",
                      "content": [
                        {
                          "type": "listItem",
                          "content": [
                            {
                              "type": "paragraph",
                              "attrs": {
                                "textAlign": null
                              },
                              "content": [
                                {
                                  "type": "text",
                                  "text": "nested"
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    },
                    {
                      "type": "horizontalRule"
                    },
                    {
                      "type": "image",
                      "attrs": {
                        "src": "\(safePNGDataURL)",
                        "alt": null,
                        "title": null,
                        "width": 80
                      }
                    }
                  ]
                }
              ]
            },
            {
              "type": "codeBlock",
              "attrs": {
                "language": "swift"
              },
              "content": [
                {
                  "type": "text",
                  "text": "let floorp = true"
                }
              ]
            },
            {
              "type": "horizontalRule"
            },
            {
              "type": "image",
              "attrs": {
                "src": "\(safePNGDataURL)",
                "alt": "pixel",
                "title": null,
                "width": 120
              }
            }
          ]
        }
        """
    }

    private func semanticJSON(_ source: String) throws -> NSObject {
        let data = try XCTUnwrap(source.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject
        )
    }
}
