// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

enum FloorpWebExtensionI18nError: Error, Equatable, LocalizedError, Sendable {
    case invalidLocale(String)
    case invalidMessagesCatalog(String)
    case messagesCatalogTooLarge(String)
    case tooManySubstitutions
    case expandedMessageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLocale(let locale):
            return "The WebExtensions locale identifier is invalid: \(locale)"
        case .invalidMessagesCatalog(let locale):
            return "The WebExtensions messages catalog is invalid: \(locale)"
        case .messagesCatalogTooLarge(let locale):
            return "The WebExtensions messages catalog is too large: \(locale)"
        case .tooManySubstitutions:
            return "A localized extension message accepts at most nine substitutions."
        case .expandedMessageTooLarge:
            return "The expanded localized extension message is too large."
        }
    }
}

/// Generic, package-backed implementation of the Stage 2 `i18n` surface.
///
/// The loader is intentionally independent of the package store and the
/// WebKit bridge. Composition supplies the currently-active immutable package
/// generation and returns `nil` only when that generation has no such file.
struct FloorpWebExtensionI18n: Sendable {
    typealias ResourceLoader = @Sendable (
        _ extensionID: FloorpWebExtensionID,
        _ source: FloorpWebExtensionScriptSource
    ) throws -> String?

    private struct Message: Decodable {
        struct Placeholder: Decodable {
            let content: String
            let example: String?
        }

        let message: String
        let description: String?
        let placeholders: [String: Placeholder]?
    }

    static let maximumCatalogByteCount = 1 * 1_024 * 1_024
    static let maximumMessageCount = 5_000
    static let maximumMessageByteCount = 16 * 1_024
    static let maximumSubstitutionByteCount = 64 * 1_024
    static let maximumExpandedMessageByteCount = 256 * 1_024

    let uiLanguage: String
    let acceptLanguages: [String]
    private let resourceLoader: ResourceLoader

    init(
        preferredLocales: [String],
        resourceLoader: @escaping ResourceLoader
    ) throws {
        var normalized = [String]()
        for locale in preferredLocales {
            let value = try Self.normalizedLanguageTag(locale)
            if !normalized.contains(value) {
                normalized.append(value)
            }
        }
        if normalized.isEmpty {
            normalized = ["en"]
        }
        uiLanguage = normalized[0]
        acceptLanguages = normalized
        self.resourceLoader = resourceLoader
    }

    /// Implements `i18n.getMessage`. A missing key or unavailable catalog
    /// returns the WebExtensions-compatible empty string. Malformed package
    /// catalogs fail explicitly instead of being silently treated as empty.
    func message(
        _ name: String,
        substitutions: [String] = [],
        extensionID: FloorpWebExtensionID,
        defaultLocale: String
    ) throws -> String {
        guard substitutions.count <= 9,
              substitutions.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumSubstitutionByteCount else {
            throw FloorpWebExtensionI18nError.tooManySubstitutions
        }
        if let special = specialMessage(name, extensionID: extensionID) {
            return special
        }
        guard Self.isValidMessageName(name) else { return "" }

        let defaultLanguage = try Self.normalizedLanguageTag(defaultLocale)
        for locale in Self.localeCandidates(preferred: [uiLanguage], defaultLocale: defaultLanguage) {
            guard let catalog = try loadCatalog(locale: locale, extensionID: extensionID) else {
                continue
            }
            guard let entry = catalog[name.lowercased()] else { continue }
            return try Self.interpolate(entry, substitutions: substitutions)
        }
        return ""
    }

    private func loadCatalog(
        locale: String,
        extensionID: FloorpWebExtensionID
    ) throws -> [String: Message]? {
        for directoryLocale in Self.packageLocaleIdentifiers(for: locale) {
            let path = "_locales/\(directoryLocale)/messages.json"
            let source = try FloorpWebExtensionScriptSource(path)
            guard let contents = try resourceLoader(extensionID, source) else { continue }
            guard contents.utf8.count <= Self.maximumCatalogByteCount else {
                throw FloorpWebExtensionI18nError.messagesCatalogTooLarge(locale)
            }
            let decoded: [String: Message]
            do {
                decoded = try JSONDecoder().decode(
                    [String: Message].self,
                    from: Data(contents.utf8)
                )
            } catch {
                throw FloorpWebExtensionI18nError.invalidMessagesCatalog(locale)
            }
            guard decoded.count <= Self.maximumMessageCount else {
                throw FloorpWebExtensionI18nError.messagesCatalogTooLarge(locale)
            }

            var normalized = [String: Message]()
            for (name, entry) in decoded {
                let normalizedName = Self.asciiLowercased(name)
                var normalizedPlaceholderNames = Set<String>()
                guard Self.isValidMessageName(name),
                      normalized[normalizedName] == nil,
                      entry.message.utf8.count <= Self.maximumMessageByteCount,
                      (entry.placeholders?.count ?? 0) <= 64,
                      entry.placeholders?.allSatisfy({ placeholderName, placeholder in
                          Self.isValidPlaceholderName(placeholderName) &&
                              normalizedPlaceholderNames.insert(
                                  Self.asciiLowercased(placeholderName)
                              ).inserted &&
                              placeholder.content.utf8.count <= Self.maximumMessageByteCount &&
                              (placeholder.example?.utf8.count ?? 0) <= Self.maximumMessageByteCount
                      }) ?? true else {
                    throw FloorpWebExtensionI18nError.invalidMessagesCatalog(locale)
                }
                normalized[normalizedName] = entry
            }
            return normalized
        }
        return nil
    }

    private func specialMessage(
        _ name: String,
        extensionID: FloorpWebExtensionID
    ) -> String? {
        let isRightToLeft = Self.isRightToLeft(uiLanguage)
        switch name.lowercased() {
        case "@@extension_id":
            return extensionID.rawValue
        case "@@ui_locale":
            return uiLanguage.replacingOccurrences(of: "-", with: "_")
        case "@@bidi_dir":
            return isRightToLeft ? "rtl" : "ltr"
        case "@@bidi_reversed_dir":
            return isRightToLeft ? "ltr" : "rtl"
        case "@@bidi_start_edge":
            return isRightToLeft ? "right" : "left"
        case "@@bidi_end_edge":
            return isRightToLeft ? "left" : "right"
        default:
            return nil
        }
    }

    private static func interpolate(_ entry: Message, substitutions: [String]) throws -> String {
        try scan(entry.message) { token in
            if token.count == 1,
               let digit = token.utf8.first,
               isASCIIDigit(digit) {
                let index = Int(digit - CharacterASCII.zero)
                if index > 0, index <= substitutions.count {
                    return substitutions[index - 1]
                }
            }
            guard let placeholder = entry.placeholders?.first(where: {
                $0.key.caseInsensitiveCompare(token) == .orderedSame
            })?.value else {
                return ""
            }
            return try scan(placeholder.content) { positional in
                guard positional.count == 1,
                      let digit = positional.utf8.first,
                      isASCIIDigit(digit),
                      digit > CharacterASCII.zero else {
                    return ""
                }
                let index = Int(digit - CharacterASCII.zero)
                guard index <= substitutions.count else { return "" }
                return substitutions[index - 1]
            }
        }
    }

    /// Scans `$name$`, `$1` and `$$` without recursively interpreting caller
    /// substitutions, preventing a value containing `$...` from becoming code
    /// or a second expansion pass.
    private static func scan(
        _ input: String,
        replacement: (String) throws -> String
    ) throws -> String {
        var result = ""
        var resultByteCount = 0
        var index = input.startIndex

        func append(_ value: String) throws {
            let byteCount = value.utf8.count
            guard byteCount <= maximumExpandedMessageByteCount - resultByteCount else {
                throw FloorpWebExtensionI18nError.expandedMessageTooLarge
            }
            result.append(contentsOf: value)
            resultByteCount += byteCount
        }

        while index < input.endIndex {
            guard input[index] == "$" else {
                try append(String(input[index]))
                input.formIndex(after: &index)
                continue
            }
            let next = input.index(after: index)
            guard next < input.endIndex else {
                try append("$")
                break
            }
            if input[next] == "$" {
                try append("$")
                index = input.index(after: next)
                continue
            }
            if isASCIIDigit(input[next].asciiValue) {
                var end = next
                while end < input.endIndex, isASCIIDigit(input[end].asciiValue) {
                    input.formIndex(after: &end)
                }
                try append(try replacement(String(input[next..<end])))
                index = end
                continue
            }
            guard let closing = input[next...].firstIndex(of: "$") else {
                try append("$")
                index = next
                continue
            }
            let token = String(input[next..<closing])
            if isValidPlaceholderName(token) {
                try append(try replacement(token))
                index = input.index(after: closing)
            } else {
                try append("$")
                index = next
            }
        }
        return result
    }

    private static func localeCandidates(
        preferred: [String],
        defaultLocale: String
    ) -> [String] {
        var result = [String]()
        for locale in preferred + [defaultLocale] {
            if !result.contains(locale) {
                result.append(locale)
            }
            if let language = locale.split(separator: "-").first.map(String.init),
               !result.contains(language) {
                result.append(language)
            }
        }
        return result
    }

    private static func packageLocaleIdentifiers(for languageTag: String) -> [String] {
        let underscore = languageTag.replacingOccurrences(of: "-", with: "_")
        return underscore == languageTag ? [languageTag] : [underscore, languageTag]
    }

    private static func normalizedLanguageTag(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              !trimmed.hasPrefix("-"),
              !trimmed.hasSuffix("-"),
              trimmed.utf8.allSatisfy({
                  Self.isASCIIAlpha($0) || Self.isASCIIDigit($0) ||
                      $0 == CharacterASCII.hyphen || $0 == CharacterASCII.underscore
              }) else {
            throw FloorpWebExtensionI18nError.invalidLocale(rawValue)
        }
        let components = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
        guard let language = components.first,
              (2...8).contains(language.utf8.count),
              language.utf8.allSatisfy(Self.isASCIIAlpha),
              components.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 }) else {
            throw FloorpWebExtensionI18nError.invalidLocale(rawValue)
        }
        return components.enumerated().map { index, component in
            if index == 0 { return component.lowercased() }
            if component.count == 2 || component.count == 3 {
                return component.uppercased()
            }
            return component.lowercased()
        }.joined(separator: "-")
    }

    private static func isValidMessageName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.utf8.allSatisfy {
            isASCIIAlpha($0) || isASCIIDigit($0) ||
                $0 == CharacterASCII.underscore || $0 == CharacterASCII.at
        }
    }

    private static func isValidPlaceholderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy {
            isASCIIAlpha($0) || isASCIIDigit($0) ||
                $0 == CharacterASCII.underscore || $0 == CharacterASCII.at
        }
    }

    private static func asciiLowercased(_ value: String) -> String {
        String(decoding: value.utf8.map { byte in
            (CharacterASCII.uppercaseA...CharacterASCII.uppercaseZ).contains(byte)
                ? byte + CharacterASCII.caseOffset
                : byte
        }, as: UTF8.self)
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (CharacterASCII.uppercaseA...CharacterASCII.uppercaseZ).contains(byte) ||
            (CharacterASCII.lowercaseA...CharacterASCII.lowercaseZ).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return (CharacterASCII.zero...CharacterASCII.nine).contains(byte)
    }

    private enum CharacterASCII {
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let uppercaseA = UInt8(ascii: "A")
        static let uppercaseZ = UInt8(ascii: "Z")
        static let lowercaseA = UInt8(ascii: "a")
        static let lowercaseZ = UInt8(ascii: "z")
        static let hyphen = UInt8(ascii: "-")
        static let underscore = UInt8(ascii: "_")
        static let at = UInt8(ascii: "@")
        static let caseOffset = lowercaseA - uppercaseA
    }

    private static func isRightToLeft(_ languageTag: String) -> Bool {
        let language = languageTag.split(separator: "-").first?.lowercased() ?? ""
        return ["ar", "ckb", "dv", "fa", "he", "ku", "ps", "sd", "ug", "ur", "yi"].contains(language)
    }
}
