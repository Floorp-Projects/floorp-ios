// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
                noteID: FloorpNoteID(""),
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
                .noteIdentityMismatch(
                    expected: currentSession.noteID,
                    actual: FloorpNoteID("note-b")
                )
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

    func testUpdateRejectsCanonicallyEquivalentButByteDistinctNoteIdentity() throws {
        let composedID = "note-\u{00E9}"
        let decomposedID = "note-e\u{0301}"
        let currentSession = try session(noteID: composedID)
        let incomingSession = try session(
            noteID: decomposedID,
            revision: currentSession.revision + 1
        )
        let original = try FloorpRichTextCodec.decode(minimalDocument())
        let envelope = updateEnvelope(minimalDocument(), session: incomingSession)

        XCTAssertEqual(composedID, decomposedID)
        XCTAssertNotEqual(Data(composedID.utf8), Data(decomposedID.utf8))
        XCTAssertThrowsError(
            try FloorpRichTextEditorUpdatePolicy.accept(
                envelope,
                for: currentSession,
                replacing: original
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpRichTextEnvelopeValidationError,
                .noteIdentityMismatch(
                    expected: FloorpNoteID(composedID),
                    actual: FloorpNoteID(decomposedID)
                )
            )
        }

        let encoded = try JSONEncoder().encode(incomingSession)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedNoteID = try XCTUnwrap(object["noteID"] as? String)
        XCTAssertEqual(Data(encodedNoteID.utf8), Data(decomposedID.utf8))
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

    func testImageCommandAcceptsSafeRasterData() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let dataPayload = safePNGDataURL.split(separator: ",", maxSplits: 1)[1]
        let safeJPEGDataURL = rasterDataURL(
            mime: "jpeg",
            data: try jpegData(width: 1, height: 1)
        )
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
                FloorpRichTextImage(source: safeJPEGDataURL, alt: "jpeg pixel"),
                safeJPEGDataURL
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

    func testImagePolicyRejectsDeclaredHugeRasterMetadataWithoutRewritingSource() throws {
        let oversizedDimension = UInt32(FloorpRichTextImagePolicy.maximumPixelDimension + 1)
        let fixtures = [
            (
                "png",
                try pngData(width: oversizedDimension, height: 1)
            ),
            (
                "jpeg",
                try jpegData(width: UInt16(oversizedDimension), height: 1)
            ),
            (
                "gif",
                try gifData(width: Int(oversizedDimension), height: 1, frameCount: 1)
            ),
            (
                "webp",
                try webPData(width: UInt16(oversizedDimension), height: 1)
            ),
        ]

        for (mime, data) in fixtures {
            let dataURL = rasterDataURL(mime: mime, data: data)
            XCTAssertLessThan(dataURL.utf8.count, FloorpRichTextImagePolicy.maximumPersistedSourceBytes)
            XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(dataURL), mime)
            let source = #"{"type":"doc","content":[{"type":"image","attrs":{"src":"\#(dataURL)"}}]}"#
            let document = try FloorpRichTextCodec.decode(source)

            XCTAssertFalse(document.compatibility.isEditable, mime)
            XCTAssertTrue(
                document.compatibility.issues.contains { $0.kind == .unsafeImageSource },
                mime
            )
            XCTAssertEqual(try FloorpRichTextCodec.encode(document), source, mime)
        }
    }

    func testImagePolicyRejectsAnimatedFrameAndCumulativePixelBudgets() throws {
        let tooManyFrames = rasterDataURL(
            mime: "gif",
            data: try gifData(width: 1, height: 1, frameCount: 121)
        )
        let tooManyCumulativePixels = rasterDataURL(
            mime: "gif",
            data: try gifData(width: 1_000, height: 1_000, frameCount: 16)
        )

        XCTAssertLessThan(
            tooManyFrames.utf8.count,
            FloorpRichTextImagePolicy.maximumPersistedSourceBytes
        )
        XCTAssertLessThan(
            tooManyCumulativePixels.utf8.count,
            FloorpRichTextImagePolicy.maximumPersistedSourceBytes
        )
        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(tooManyFrames))
        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(tooManyCumulativePixels))
    }

    func testImagePolicyAccountsForAnimatedCanvasWithoutRewritingSource() throws {
        let canvasFrameMismatch = rasterDataURL(
            mime: "gif",
            data: animatedGIF(width: 4_096, height: 4_096, frameCount: 1)
        )
        XCTAssertLessThan(
            canvasFrameMismatch.utf8.count,
            FloorpRichTextImagePolicy.maximumPersistedSourceBytes
        )
        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(canvasFrameMismatch))

        let source = #"{"type":"doc","content":[{"type":"image","attrs":{"src":"\#(canvasFrameMismatch)"}}]}"#
        let document = try FloorpRichTextCodec.decode(source)

        XCTAssertFalse(document.compatibility.isEditable)
        XCTAssertTrue(document.compatibility.issues.contains { $0.kind == .unsafeImageSource })
        XCTAssertEqual(try FloorpRichTextCodec.encode(document), source)
    }

    func testImagePolicyRejectsZeroAndPerFramePixelBudgets() throws {
        let zeroDimension = rasterDataURL(
            mime: "gif",
            data: animatedGIF(width: 0, height: 1, frameCount: 1)
        )
        let tooManyPixels = rasterDataURL(
            mime: "png",
            data: try pngData(width: 3_000, height: 2_000)
        )

        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(zeroDimension))
        XCTAssertFalse(FloorpRichTextImagePolicy.isSafePersistedSource(tooManyPixels))
        XCTAssertTrue(FloorpRichTextImagePolicy.isSafePersistedSource(safePNGDataURL))
    }

    func testImagePolicyEnforcesDocumentAggregatePixelBudgetWithoutRewritingSource() throws {
        let imageSource = rasterDataURL(
            mime: "png",
            data: try encodedRasterData(width: 2_048, height: 2_048, type: .png)
        )
        let imageNode = #"{"type":"image","attrs":{"src":"\#(imageSource)"}}"#
        let boundarySource = "{\"type\":\"doc\",\"content\":["
            + Array(repeating: imageNode, count: 4).joined(separator: ",")
            + "]}"
        let excessiveSource = "{\"type\":\"doc\",\"content\":["
            + Array(repeating: imageNode, count: 5).joined(separator: ",")
            + "]}"

        let metadata = try XCTUnwrap(FloorpRichTextImagePolicy.safePersistedMetadata(imageSource))
        XCTAssertEqual(metadata.cumulativePixels, FloorpRichTextImagePolicy.maximumPixelsPerFrame)
        let boundaryDocument = try FloorpRichTextCodec.decode(boundarySource)
        XCTAssertTrue(boundaryDocument.compatibility.isEditable)
        XCTAssertEqual(try FloorpRichTextCodec.encode(boundaryDocument), boundarySource)

        let excessiveDocument = try FloorpRichTextCodec.decode(excessiveSource)
        XCTAssertFalse(excessiveDocument.compatibility.isEditable)
        XCTAssertTrue(excessiveDocument.compatibility.issues.contains { $0.kind == .resourceLimit })
        XCTAssertEqual(try FloorpRichTextCodec.encode(excessiveDocument), excessiveSource)
    }

    func testImageCommandRejectsProjectedDocumentAggregateLimit() throws {
        let imageSource = rasterDataURL(
            mime: "png",
            data: try encodedRasterData(width: 2_048, height: 2_048, type: .png)
        )
        let imageNode = #"{"type":"image","attrs":{"src":"\#(imageSource)"}}"#
        let boundarySource = "{\"type\":\"doc\",\"content\":["
            + Array(repeating: imageNode, count: 4).joined(separator: ",")
            + "]}"
        let document = try FloorpRichTextCodec.decode(boundarySource)
        XCTAssertTrue(document.compatibility.isEditable)

        XCTAssertThrowsError(
            try FloorpRichTextCommandPlanner.plan(
                .insertImage(FloorpRichTextImage(source: safePNGDataURL)),
                for: document,
                session: try session()
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpRichTextCommandError,
                .imageResourceLimitExceeded
            )
        }
        XCTAssertEqual(try FloorpRichTextCodec.encode(document), boundarySource)
    }

    func testImageCommandRejectsObjectURLsVectorsAndMismatchedData() throws {
        let document = try FloorpRichTextCodec.decode(minimalDocument())
        let currentSession = try session()
        let unsafeSources = [
            "blob:https://example.test/temporary-object",
            "http://example.test/image.png",
            "https://images.example.test/image.png",
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
            "https://images.example.test/photo.webp",
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
            "direction": "ltr",
            "version": 1,
            "children": [
              {
                "type": "heading",
                "tag": "h2",
                "direction": "ltr",
                "format": "center",
                "version": 1,
                "children": [
                  {"type":"text","text":"Title","format":3,"detail":0,"mode":"normal","style":"","version":1}
                ]
              },
              {
                "type": "paragraph",
                "direction": "ltr",
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
                "direction": "ltr",
                "version": 1,
                "children": [
                  {"type":"listitem","value":1,"direction":"ltr","version":1,"children":[
                    {"type":"text","text":"One","format":0,"version":1}
                  ]}
                ]
              },
              {
                "type": "quote",
                "direction": "ltr",
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

    func testLexicalOrderedListPreservesStartAndAcceptsOnlyDefaultMetadata() throws {
        let source = """
        {
          "root": {
            "type":"root", "version":1, "direction":"ltr", "format":"",
            "indent":0, "textFormat":0, "textStyle":"",
            "children":[{
              "type":"list", "listType":"number", "start":3, "tag":"ol",
              "version":1, "direction":null, "format":"", "indent":0,
              "textFormat":0, "textStyle":"", "children":[
                {"type":"listitem", "value":3, "version":1, "children":[
                  {"type":"text", "text":"Three", "format":0, "detail":0,
                   "mode":"normal", "style":"", "version":1}
                ]},
                {"type":"listitem", "value":4, "version":1, "children":[
                  {"type":"text", "text":"Four", "format":0, "detail":0,
                   "mode":"normal", "style":"", "version":1}
                ]}
              ]
            }]
          }
        }
        """

        let migration = try FloorpLexicalMigrator.migrate(source)

        XCTAssertTrue(migration.isEditable, "\(migration.compatibility.issues)")
        let encoded = try FloorpRichTextCodec.encode(try XCTUnwrap(migration.document))
        let root = try XCTUnwrap(try semanticJSON(encoded) as? [String: Any])
        let list = try XCTUnwrap((root["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(list["type"] as? String, "orderedList")
        XCTAssertEqual((list["attrs"] as? [String: Any])?["start"] as? Int, 3)
        XCTAssertEqual((list["content"] as? [[String: Any]])?.count, 2)
    }

    func testOrderedListStartOutsideSigned32BitRemainsReadOnlyAndByteExact() throws {
        let unsupportedStarts = [Int(Int32.min) - 1, Int(Int32.max) + 1]

        for start in unsupportedStarts {
            let tipTapSource = """
            { "type":"doc", "content":[{
              "type":"orderedList", "attrs":{"start":\(start)}, "content":[{
                "type":"listItem", "content":[{"type":"paragraph"}]
              }]
            }] }
            """
            let document = try FloorpRichTextCodec.decode(tipTapSource)
            XCTAssertFalse(document.compatibility.isEditable, tipTapSource)
            XCTAssertEqual(try FloorpRichTextCodec.encode(document), tipTapSource)

            let lexicalSource = lexicalListFixture(
                listType: "number",
                start: start,
                tag: "ol",
                value: start
            )
            let migration = try FloorpLexicalMigrator.migrate(lexicalSource)
            XCTAssertFalse(migration.isEditable, lexicalSource)
            XCTAssertNil(migration.document, lexicalSource)
            XCTAssertEqual(migration.originalSource, lexicalSource)
        }
    }

    func testLexicalNonDefaultMetadataAndListSemanticsRemainReadOnly() throws {
        let fixtures = [
            #"{"root":{"type":"root","indent":1,"children":[]}}"#,
            #"{"root":{"children":[{"type":"paragraph","direction":"rtl","children":[]}]}}"#,
            #"{"root":{"children":[{"type":"paragraph","textFormat":1,"children":[]}]}}"#,
            #"{"root":{"children":[{"type":"paragraph","textStyle":"color:red","children":[]}]}}"#,
            """
            {"root":{"children":[{"type":"paragraph","children":[
              {"type":"text","text":"x","format":0,"detail":1}
            ]}]}}
            """,
            """
            {"root":{"children":[{"type":"paragraph","children":[
              {"type":"text","text":"x","format":0,"style":"color:red"}
            ]}]}}
            """,
            """
            {"root":{"children":[{"type":"paragraph","children":[
              {"type":"text","text":"x","format":0,"mode":"token"}
            ]}]}}
            """,
            lexicalListFixture(listType: "number", start: 3, tag: "ul", value: 3),
            lexicalListFixture(listType: "bullet", start: 2, tag: "ul", value: 1),
            lexicalListFixture(listType: "number", start: 1, tag: "ol", value: 7),
            lexicalListFixture(
                listType: "number",
                start: 9_007_199_254_740_992,
                tag: "ol",
                value: 9_007_199_254_740_992
            ),
        ]

        for source in fixtures {
            let migration = try FloorpLexicalMigrator.migrate(source)
            XCTAssertFalse(migration.isEditable, source)
            XCTAssertNil(migration.document, source)
            XCTAssertEqual(migration.originalSource, source)
            XCTAssertFalse(migration.compatibility.issues.isEmpty, source)
        }
    }

    func testLexicalMetadataRequiresSupportedVersionAndStrictTypes() throws {
        let fixtures = [
            #"{"root":{"type":"root","children":[]}}"#,
            #"{"root":{"version":1,"children":[]}}"#,
            #"{"root":{"type":"root","version":2,"children":[]}}"#,
            #"{"root":{"type":"root","version":"1","children":[]}}"#,
            #"{"root":{"type":7,"version":1,"children":[]}}"#,
            """
            {"root":{"children":[
              {"type":"paragraph","version":2,"children":[]}
            ]}}
            """,
            """
            {"root":{"children":[
              {"type":"paragraph","children":[{"type":"linebreak","version":false}]}
            ]}}
            """,
            """
            {"root":{"children":[
              {"type":"heading","tag":3,"children":[]}
            ]}}
            """,
            """
            {"root":{"type":"root","version":1,"children":[
              {"type":"heading","version":1,"children":[]}
            ]}}
            """,
            """
            {"root":{"children":[
              {"type":"list","listType":1,"children":[]}
            ]}}
            """,
            """
            {"root":{"type":"root","version":1,"children":[
              {"type":"list","version":1,"children":[]}
            ]}}
            """,
            """
            {"root":{"children":[{
              "type":"list","listType":"bullet","tag":1,"children":[
                {"type":"listitem","children":[{"type":"text","text":"x","format":0}]}
              ]
            }]}}
            """,
            """
            {"root":{"children":[
              {"type":"paragraph","format":true,"children":[]}
            ]}}
            """,
            """
            {"root":{"children":[{"type":"paragraph","children":[
              {"type":"text","text":"x","format":"1","version":1}
            ]}]}}
            """,
            """
            {"root":{"type":"root","version":1,"children":[
              {"type":"paragraph","version":1,"children":[
                {"type":"text","text":"x","version":1}
              ]}
            ]}}
            """,
            """
            {"root":{"children":[{"type":"paragraph","children":[
              {"type":"text","text":"x","format":0,"detail":null,"version":1}
            ]}]}}
            """,
        ]

        for source in fixtures {
            let migration = try FloorpLexicalMigrator.migrate(source)
            XCTAssertFalse(migration.isEditable, source)
            XCTAssertNil(migration.document, source)
            XCTAssertFalse(migration.compatibility.issues.isEmpty, source)
        }
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

            let note = makeFloorpTestNote(
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

    private func lexicalListFixture(
        listType: String,
        start: Int,
        tag: String,
        value: Int
    ) -> String {
        """
        {"root":{"children":[{
          "type":"list","listType":"\(listType)","start":\(start),"tag":"\(tag)","children":[
            {"type":"listitem","value":\(value),"children":[
              {"type":"text","text":"x","format":0}
            ]}
          ]
        }]}}
        """
    }

    private func session(
        noteID: String = "note-a",
        documentID: String = "document-a",
        generation: Int = 3,
        revision: Int = 7
    ) throws -> FloorpRichTextEditorSessionCursor {
        try FloorpRichTextEditorSessionCursor(
            noteID: FloorpNoteID(noteID),
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

    private func rasterDataURL(mime: String, data: Data) -> String {
        "data:image/\(mime);base64," + data.base64EncodedString()
    }

    private func pngData(width: UInt32, height: UInt32) throws -> Data {
        let payload = try XCTUnwrap(safePNGDataURL.split(separator: ",", maxSplits: 1).last)
        var data = try XCTUnwrap(Data(base64Encoded: String(payload)))
        writeBigEndian(width, to: &data, at: 16)
        writeBigEndian(height, to: &data, at: 20)
        let checksum = crc32(Data(data[12..<29]))
        writeBigEndian(checksum, to: &data, at: 29)
        return data
    }

    private func jpegData(width: UInt16, height: UInt16) throws -> Data {
        let base64 = [
            "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAaADAAQA",
            "AAABAAAAAQAAAAD/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIE",
            "AwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpT",
            "VFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ",
            "2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3",
            "AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpj",
            "ZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn",
            "6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8P",
            "Dw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ",
            "EBAQ/90ABAAB/9oADAMBAAIRAxEAPwD4vooor+Uz/fw//9k=",
        ].joined()
        var data = try XCTUnwrap(Data(base64Encoded: base64))
        let startOfFrameMarkers: Set<UInt8> = [
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
            0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
        ]
        let markerOffset = try XCTUnwrap((0..<(data.count - 8)).first { offset in
            data[offset] == 0xFF && startOfFrameMarkers.contains(data[offset + 1])
        })
        writeBigEndian(height, to: &data, at: markerOffset + 5)
        writeBigEndian(width, to: &data, at: markerOffset + 7)
        return data
    }

    private func animatedGIF(width: UInt16, height: UInt16, frameCount: Int) -> Data {
        var data = Data("GIF89a".utf8)
        appendLittleEndian(width, to: &data)
        appendLittleEndian(height, to: &data)
        data.append(contentsOf: [0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF])
        let frame: [UInt8] = [
            0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0,
            2, 1, 0x4C, 0,
        ]
        for _ in 0..<frameCount {
            data.append(contentsOf: frame)
        }
        data.append(0x3B)
        return data
    }

    private func gifData(width: Int, height: Int, frameCount: Int) throws -> Data {
        try encodedRasterData(
            width: width,
            height: height,
            type: .gif,
            frameCount: frameCount
        )
    }

    private func encodedRasterData(
        width: Int,
        height: Int,
        type: UTType,
        frameCount: Int = 1
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            frameCount,
            nil
        ))
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func webPData(width: UInt16, height: UInt16) throws -> Data {
        let base64 = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEALmk0mk0iIiIiIgBoSygABc6zbAAA"
        var data = try XCTUnwrap(Data(base64Encoded: base64))
        let signature = Data([0x9D, 0x01, 0x2A])
        let signatureRange = try XCTUnwrap(data.range(of: signature))
        writeLittleEndian(width, to: &data, at: signatureRange.upperBound)
        writeLittleEndian(height, to: &data, at: signatureRange.upperBound + 2)
        return data
    }

    private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private func writeLittleEndian(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }

    private func writeBigEndian(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeBigEndian(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum & 1) == 1
                    ? (checksum >> 1) ^ 0xEDB8_8320
                    : checksum >> 1
            }
        }
        return ~checksum
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
