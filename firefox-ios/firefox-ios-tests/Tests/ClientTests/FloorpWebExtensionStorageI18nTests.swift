// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class FloorpWebExtensionStorageI18nTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.storage")!
    private let otherExtensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.other")!

    func testLocalStoragePersistsAcrossRestartAndPackageGenerationChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try FloorpWebExtensionStorageService(
            profileIdentifier: "normal-profile",
            isPrivateBrowsing: false,
            directory: directory
        )

        try await first.set(
            [
                "generationIndependent": .object([
                    "enabled": .bool(true),
                    "count": .number(3),
                    "nullable": .null
                ])
            ],
            for: extensionID,
            in: .local
        )

        let restarted = try FloorpWebExtensionStorageService(
            profileIdentifier: "normal-profile",
            isPrivateBrowsing: false,
            directory: directory
        )
        let values = try await restarted.values(for: extensionID, in: .local)

        XCTAssertEqual(
            values["generationIndependent"],
            .object(["enabled": .bool(true), "count": .number(3), "nullable": .null])
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("storage-local.json").path
        ))
    }

    func testSessionAndPrivateLocalStorageAreEphemeralAndProfileIsolated() async throws {
        let normalDirectory = temporaryDirectory()
        let privateSentinel = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: normalDirectory)
            try? FileManager.default.removeItem(at: privateSentinel)
        }
        let normal = try FloorpWebExtensionStorageService(
            profileIdentifier: "same-logical-profile",
            isPrivateBrowsing: false,
            directory: normalDirectory
        )
        try await normal.set(["normal": .string("visible")], for: extensionID, in: .local)
        try await normal.set(["session": .string("temporary")], for: extensionID, in: .session)

        let restartedNormal = try FloorpWebExtensionStorageService(
            profileIdentifier: "same-logical-profile",
            isPrivateBrowsing: false,
            directory: normalDirectory
        )
        let restoredLocal = try await restartedNormal.values(for: extensionID, in: .local)
        let restoredSession = try await restartedNormal.values(for: extensionID, in: .session)
        XCTAssertEqual(restoredLocal, ["normal": .string("visible")])
        XCTAssertTrue(restoredSession.isEmpty)

        let privateStore = try FloorpWebExtensionStorageService(
            profileIdentifier: "same-logical-profile",
            isPrivateBrowsing: true,
            directory: privateSentinel
        )
        let privateInitial = try await privateStore.values(for: extensionID, in: .local)
        XCTAssertTrue(privateInitial.isEmpty)
        try await privateStore.set(["private": .bool(true)], for: extensionID, in: .local)
        let privateValue = try await privateStore.values(for: extensionID, in: .local)
        XCTAssertEqual(privateValue, ["private": .bool(true)])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: privateSentinel.appendingPathComponent("storage-local.json").path
        ))

        let restartedPrivate = try FloorpWebExtensionStorageService(
            profileIdentifier: "same-logical-profile",
            isPrivateBrowsing: true,
            directory: privateSentinel
        )
        let restartedPrivateValues = try await restartedPrivate.values(for: extensionID, in: .local)
        XCTAssertTrue(restartedPrivateValues.isEmpty)
        let normalAfterPrivate = try await restartedNormal.values(for: extensionID, in: .local)
        XCTAssertEqual(normalAfterPrivate, ["normal": .string("visible")])

        XCTAssertThrowsError(
            try FloorpWebExtensionStorageService(
                profileIdentifier: "different-profile",
                isPrivateBrowsing: false,
                directory: normalDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionStorageError,
                .corruptedPersistentStorage
            )
        }
    }

    func testConcurrentServicesMergeLocalWritesWithoutLosingKeys() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try FloorpWebExtensionStorageService(
            profileIdentifier: "shared-profile",
            isPrivateBrowsing: false,
            directory: directory
        )
        let second = try FloorpWebExtensionStorageService(
            profileIdentifier: "shared-profile",
            isPrivateBrowsing: false,
            directory: directory
        )

        let targetExtensionID = extensionID
        async let firstWrite: Void = first.set(
            ["first": .number(1)],
            for: targetExtensionID,
            in: .local
        )
        async let secondWrite: Void = second.set(
            ["second": .number(2)],
            for: targetExtensionID,
            in: .local
        )
        _ = try await (firstWrite, secondWrite)

        let merged = try await first.values(for: targetExtensionID, in: .local)
        XCTAssertEqual(merged, ["first": .number(1), "second": .number(2)])
        let secondBytesInUse = try await second.bytesInUse(for: targetExtensionID, in: .local)
        XCTAssertEqual(secondBytesInUse, "first".utf8.count + 1 + "second".utf8.count + 1)
    }

    func testQuotaFailureIsAtomicAndUnlimitedStorageRemainsBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let quotas = FloorpWebExtensionStorageQuotas(
            localByteLimit: 32,
            unlimitedLocalByteLimit: 96,
            sessionByteLimit: 32,
            maximumKeyCount: 4,
            maximumKeyByteCount: 32
        )
        let storage = try FloorpWebExtensionStorageService(
            profileIdentifier: "quota-profile",
            isPrivateBrowsing: false,
            directory: directory,
            quotas: quotas
        )
        try await storage.set(["safe": .string("ok")], for: extensionID, in: .local)

        do {
            try await storage.set(
                ["large": .string(String(repeating: "x", count: 64))],
                for: extensionID,
                in: .local
            )
            XCTFail("Expected regular local quota failure")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionStorageError, .quotaExceeded(.local))
        }
        let valuesAfterFailure = try await storage.values(for: extensionID, in: .local)
        XCTAssertEqual(valuesAfterFailure, ["safe": .string("ok")])

        try await storage.set(
            ["large": .string(String(repeating: "x", count: 40))],
            for: extensionID,
            in: .local,
            quotaTier: .unlimitedStorage
        )
        do {
            try await storage.set(
                ["stillBounded": .string(String(repeating: "y", count: 128))],
                for: extensionID,
                in: .local,
                quotaTier: .unlimitedStorage
            )
            XCTFail("Expected unlimited local quota failure")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionStorageError, .quotaExceeded(.local))
        }
    }

    func testChangeEventsContainOnlyActualChangesAndDoNotCrossExtensions() async throws {
        let storage = try FloorpWebExtensionStorageService(
            profileIdentifier: "event-profile",
            isPrivateBrowsing: true,
            directory: nil
        )
        let stream = await storage.changeEvents(for: extensionID)
        var iterator = stream.makeAsyncIterator()

        try await storage.set(["theme": .string("dark")], for: otherExtensionID, in: .session)
        try await storage.set(["theme": .string("dark")], for: extensionID, in: .session)
        let inserted = await iterator.next()
        XCTAssertEqual(inserted?.area, .session)
        XCTAssertEqual(
            inserted?.changes["theme"],
            .init(oldValue: nil, newValue: .string("dark"))
        )

        try await storage.set(["theme": .string("dark")], for: extensionID, in: .session)
        try await storage.remove(["theme"], for: extensionID, in: .session)
        let removed = await iterator.next()
        XCTAssertEqual(removed?.revision, (inserted?.revision ?? 0) + 1)
        XCTAssertEqual(
            removed?.changes["theme"],
            .init(oldValue: .string("dark"), newValue: nil)
        )
    }

    func testManagedStorageIsEmptyAndReadOnly() async throws {
        let storage = try FloorpWebExtensionStorageService(
            profileIdentifier: "managed-profile",
            isPrivateBrowsing: true,
            directory: nil
        )
        let managed = try await storage.values(for: extensionID, in: .managed)
        XCTAssertTrue(managed.isEmpty)
        do {
            try await storage.set(["policy": .bool(true)], for: extensionID, in: .managed)
            XCTFail("Expected managed storage write to fail")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionStorageError, .managedStorageIsReadOnly)
        }
    }

    func testI18nLoadsPreferredThenDefaultCatalogAndInterpolatesSafely() throws {
        let resources = [
            "_locales/ja/messages.json": """
            {
              "greeting": {
                "message": "$NAME$ は $2 を $$利用中",
                "placeholders": { "name": { "content": "$1", "example": "Floorp" } }
              }
            }
            """,
            "_locales/en/messages.json": """
            { "fallback_only": { "message": "Default message" } }
            """
        ]
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["ja-JP", "en-US"]) { _, source in
            resources[source.path]
        }

        XCTAssertEqual(i18n.uiLanguage, "ja-JP")
        XCTAssertEqual(i18n.acceptLanguages, ["ja-JP", "en-US"])
        XCTAssertEqual(
            try i18n.message(
                "GREETING",
                substitutions: ["Floorp", "安全に"],
                extensionID: extensionID,
                defaultLocale: "en"
            ),
            "Floorp は 安全に を $利用中"
        )
        XCTAssertEqual(
            try i18n.message("fallback_only", extensionID: extensionID, defaultLocale: "en"),
            "Default message"
        )
        XCTAssertEqual(
            try i18n.message("missing", extensionID: extensionID, defaultLocale: "en"),
            ""
        )
    }

    func testI18nProvidesSpecialMessagesAndRejectsMalformedCatalogs() throws {
        let malformed = "{ \"bad\": { \"message\": 42 } }"
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["ar"]) { _, source in
            source.path == "_locales/ar/messages.json" ? malformed : nil
        }

        XCTAssertEqual(
            try i18n.message("@@bidi_dir", extensionID: extensionID, defaultLocale: "ar"),
            "rtl"
        )
        XCTAssertEqual(
            try i18n.message("@@extension_id", extensionID: extensionID, defaultLocale: "ar"),
            extensionID.rawValue
        )
        XCTAssertThrowsError(
            try i18n.message("bad", extensionID: extensionID, defaultLocale: "ar")
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionI18nError, .invalidMessagesCatalog("ar"))
        }
    }

    func testI18nUsesStrictASCIIIdentifierGrammarIncludingAtSign() throws {
        for invalidLocale in ["ｅｎ", "e", "1n", "en--US", "en_US!"] {
            XCTAssertThrowsError(
                try FloorpWebExtensionI18n(preferredLocales: [invalidLocale]) { _, _ in nil }
            ) { error in
                XCTAssertEqual(
                    error as? FloorpWebExtensionI18nError,
                    .invalidLocale(invalidLocale)
                )
            }
        }

        let validCatalog = """
        {
          "mail@home": {
            "message": "Hello $USER@HOST$",
            "placeholders": { "user@host": { "content": "$1" } }
          }
        }
        """
        let valid = try FloorpWebExtensionI18n(preferredLocales: ["en-US"]) { _, source in
            source.path == "_locales/en_US/messages.json" ? validCatalog : nil
        }
        XCTAssertEqual(
            try valid.message(
                "MAIL@HOME",
                substitutions: ["Floorp"],
                extensionID: extensionID,
                defaultLocale: "en"
            ),
            "Hello Floorp"
        )

        for invalidCatalog in [
            #"{ "méssage": { "message": "bad" }, "valid": { "message": "ok" } }"#,
            #"{ "valid": { "message": "$user$", "placeholders": { "usér": { "content": "$1" } } } }"#
        ] {
            let invalid = try FloorpWebExtensionI18n(preferredLocales: ["en"]) { _, source in
                source.path == "_locales/en/messages.json" ? invalidCatalog : nil
            }
            XCTAssertThrowsError(
                try invalid.message("valid", extensionID: extensionID, defaultLocale: "en")
            ) { error in
                XCTAssertEqual(
                    error as? FloorpWebExtensionI18nError,
                    .invalidMessagesCatalog("en")
                )
            }
        }
    }

    func testI18nRejectsCaseInsensitiveDuplicatePlaceholderNames() throws {
        let catalog = """
        {
          "duplicate": {
            "message": "$user$",
            "placeholders": {
              "User": { "content": "$1" },
              "user": { "content": "$2" }
            }
          }
        }
        """
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["en"]) { _, source in
            source.path == "_locales/en/messages.json" ? catalog : nil
        }

        XCTAssertThrowsError(
            try i18n.message(
                "duplicate",
                substitutions: ["first", "second"],
                extensionID: extensionID,
                defaultLocale: "en"
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionI18nError,
                .invalidMessagesCatalog("en")
            )
        }
    }

    func testI18nTreatsMultiDigitSubstitutionsAsOneUnavailableReference() throws {
        let catalog = """
        {
          "positions": { "message": "[$1][$9][$10][$123][$0]" },
          "placeholder_position": {
            "message": "[$value$]",
            "placeholders": { "value": { "content": "$10" } }
          }
        }
        """
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["en"]) { _, source in
            source.path == "_locales/en/messages.json" ? catalog : nil
        }
        let substitutions = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

        XCTAssertEqual(
            try i18n.message(
                "positions",
                substitutions: substitutions,
                extensionID: extensionID,
                defaultLocale: "en"
            ),
            "[one][nine][][][]"
        )
        XCTAssertEqual(
            try i18n.message(
                "placeholder_position",
                substitutions: substitutions,
                extensionID: extensionID,
                defaultLocale: "en"
            ),
            "[]"
        )
    }

    func testI18nDollarEscapingMatchesChromeMessageSemantics() throws {
        let catalog = #"{ "dollars": { "message": "$$ $$1 $$$1 $$$$" } }"#
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["en"]) { _, source in
            source.path == "_locales/en/messages.json" ? catalog : nil
        }

        XCTAssertEqual(
            try i18n.message(
                "dollars",
                substitutions: ["value"],
                extensionID: extensionID,
                defaultLocale: "en"
            ),
            "$ $1 $value $$"
        )
    }

    func testI18nCapsExpandedOutputWithoutRejectingTheExactBoundary() throws {
        let substitution = String(
            repeating: "x",
            count: FloorpWebExtensionI18n.maximumExpandedMessageByteCount / 4
        )
        XCTAssertEqual(substitution.utf8.count, FloorpWebExtensionI18n.maximumSubstitutionByteCount)
        let atLimit = String(repeating: "$value$", count: 4)
        let overLimit = String(repeating: "$value$", count: 5)
        let catalog = """
        {
          "at_limit": {
            "message": "\(atLimit)",
            "placeholders": { "value": { "content": "$1" } }
          },
          "over_limit": {
            "message": "\(overLimit)",
            "placeholders": { "value": { "content": "$1" } }
          }
        }
        """
        let i18n = try FloorpWebExtensionI18n(preferredLocales: ["en"]) { _, source in
            source.path == "_locales/en/messages.json" ? catalog : nil
        }

        XCTAssertEqual(
            try i18n.message(
                "at_limit",
                substitutions: [substitution],
                extensionID: extensionID,
                defaultLocale: "en"
            ).utf8.count,
            FloorpWebExtensionI18n.maximumExpandedMessageByteCount
        )
        XCTAssertThrowsError(
            try i18n.message(
                "over_limit",
                substitutions: [substitution],
                extensionID: extensionID,
                defaultLocale: "en"
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionI18nError,
                .expandedMessageTooLarge
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-storage-i18n-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
