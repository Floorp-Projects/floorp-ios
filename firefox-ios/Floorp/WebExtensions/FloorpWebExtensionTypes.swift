// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct FloorpWebExtensionID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count >= 3,
              value.count <= 128,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }
        self.rawValue = value
    }

    var description: String { rawValue }
}

enum FloorpWebExtensionError: Error, Equatable, LocalizedError, Sendable {
    case invalidExtensionID
    case invalidMatchPattern(String)
    case invalidScriptID(String)
    case invalidCSSHandle(String)
    case unsupported(String)
    case permissionDenied(String)
    case quotaExceeded(String)
    case duplicateIdentifier(String)
    case ruleNotFound(Int)

    var errorDescription: String? {
        switch self {
        case .invalidExtensionID:
            return "The extension identifier is invalid."
        case .invalidMatchPattern(let pattern):
            return "The match pattern is invalid: \(pattern)"
        case .invalidScriptID(let identifier):
            return "The registered script identifier is invalid: \(identifier)"
        case .invalidCSSHandle(let identifier):
            return "The CSS insertion handle is invalid: \(identifier)"
        case .unsupported(let capability):
            return "This WebExtensions capability is not supported: \(capability)"
        case .permissionDenied(let permission):
            return "The extension does not have permission for \(permission)."
        case .quotaExceeded(let resource):
            return "The extension exceeded its \(resource) quota."
        case .duplicateIdentifier(let identifier):
            return "The identifier is already registered: \(identifier)"
        case .ruleNotFound(let identifier):
            return "The declarative rule does not exist: \(identifier)"
        }
    }
}

struct FloorpWebExtensionMatchPattern: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case original
        case scheme
        case host
        case path
    }

    enum Scheme: String, Codable, Sendable {
        case any
        case http
        case https

        fileprivate func matches(_ urlScheme: String?) -> Bool {
            switch self {
            case .any:
                return urlScheme == "http" || urlScheme == "https"
            case .http, .https:
                return rawValue == urlScheme
            }
        }
    }

    private enum Host: Hashable, Codable, Sendable {
        case any
        case exact(String)
        case subdomains(String)

        func matches(_ host: String) -> Bool {
            switch self {
            case .any:
                return true
            case .exact(let expected):
                return host == expected
            case .subdomains(let base):
                return host == base || host.hasSuffix("." + base)
            }
        }

        func covers(_ other: Host) -> Bool {
            switch (self, other) {
            case (.any, _):
                return true
            case (.exact(let allowed), .exact(let requested)):
                return allowed == requested
            case (.subdomains(let allowed), .exact(let requested)):
                return requested == allowed || requested.hasSuffix("." + allowed)
            case (.subdomains(let allowed), .subdomains(let requested)):
                return requested == allowed || requested.hasSuffix("." + allowed)
            case (.exact, .any), (.exact, .subdomains), (.subdomains, .any):
                return false
            }
        }
    }

    let original: String
    private let scheme: Scheme
    private let host: Host
    private let path: String

    init(_ pattern: String) throws {
        if pattern == "<all_urls>" {
            original = pattern
            scheme = .any
            host = .any
            path = "/*"
            return
        }

        let parts = pattern.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let parsedScheme: Scheme?
        switch parts.first {
        case "*":
            parsedScheme = .any
        case "http":
            parsedScheme = .http
        case "https":
            parsedScheme = .https
        default:
            parsedScheme = nil
        }
        guard parts.count == 2,
              let parsedScheme,
              parts[1].hasPrefix("//") else {
            throw FloorpWebExtensionError.invalidMatchPattern(pattern)
        }

        let authorityAndPath = parts[1].dropFirst(2)
        guard let slashIndex = authorityAndPath.firstIndex(of: "/") else {
            throw FloorpWebExtensionError.invalidMatchPattern(pattern)
        }
        let hostPart = String(authorityAndPath[..<slashIndex]).lowercased()
        let pathPart = String(authorityAndPath[slashIndex...])
        guard !pathPart.isEmpty, pathPart.first == "/", !hostPart.contains(":"), !hostPart.isEmpty else {
            throw FloorpWebExtensionError.invalidMatchPattern(pattern)
        }

        let parsedHost: Host
        if hostPart == "*" {
            parsedHost = .any
        } else if hostPart.hasPrefix("*.") {
            let base = String(hostPart.dropFirst(2))
            guard Self.isValidHost(base) else {
                throw FloorpWebExtensionError.invalidMatchPattern(pattern)
            }
            parsedHost = .subdomains(base)
        } else {
            guard Self.isValidHost(hostPart) else {
                throw FloorpWebExtensionError.invalidMatchPattern(pattern)
            }
            parsedHost = .exact(hostPart)
        }

        original = pattern
        scheme = parsedScheme
        host = parsedHost
        path = pathPart
    }

    /// Durable registries are not an authority. Preserve the synthesized
    /// representation for compatibility, but rebuild the executable fields
    /// from `original` and reject any stored representation that disagrees
    /// with that canonical parse.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let original = try container.decode(String.self, forKey: .original)
        let decodedScheme = try container.decode(Scheme.self, forKey: .scheme)
        let decodedHost = try container.decode(Host.self, forKey: .host)
        let decodedPath = try container.decode(String.self, forKey: .path)

        let canonical: Self
        do {
            canonical = try Self(original)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .original,
                in: container,
                debugDescription: "Invalid persisted WebExtension match pattern."
            )
        }
        guard canonical.scheme == decodedScheme,
              canonical.host == decodedHost,
              canonical.path == decodedPath else {
            throw DecodingError.dataCorruptedError(
                forKey: .original,
                in: container,
                debugDescription: "Persisted WebExtension match pattern is not canonical."
            )
        }
        self = canonical
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(original, forKey: .original)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        try container.encode(path, forKey: .path)
    }

    func matches(_ url: URL) -> Bool {
        guard scheme.matches(url.scheme?.lowercased()),
              let urlHost = url.host?.lowercased(),
              host.matches(urlHost) else {
            return false
        }
        return Self.wildcardMatches(path, value: url.path.isEmpty ? "/" : url.path)
    }

    /// Returns whether every URL represented by `other` is also represented
    /// by this pattern. Permission APIs need semantic containment here: a
    /// declaration such as `<all_urls>` or `https://*.example.com/*` may grant
    /// a narrower per-site origin without storing an identical pattern.
    ///
    /// Arbitrary wildcard-path containment is deliberately conservative. The
    /// universal `/*` path covers any narrower path; otherwise the two path
    /// expressions must be identical.
    func covers(_ other: FloorpWebExtensionMatchPattern) -> Bool {
        let schemeCovers: Bool
        switch (scheme, other.scheme) {
        case (.any, _):
            schemeCovers = true
        case (.http, .http), (.https, .https):
            schemeCovers = true
        default:
            schemeCovers = false
        }
        guard schemeCovers, host.covers(other.host) else { return false }
        return path == "/*" || path == other.path
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard host.count <= 253, !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        return host.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    static func wildcardMatches(_ pattern: String, value: String) -> Bool {
        var patternIndex = pattern.startIndex
        var valueIndex = value.startIndex
        var starIndex: String.Index?
        var retryIndex: String.Index?

        while valueIndex < value.endIndex {
            if patternIndex < pattern.endIndex,
               pattern[patternIndex] == value[valueIndex] || pattern[patternIndex] == "?" {
                pattern.formIndex(after: &patternIndex)
                value.formIndex(after: &valueIndex)
            } else if patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                pattern.formIndex(after: &patternIndex)
                retryIndex = valueIndex
            } else if let starIndex, let savedRetryIndex = retryIndex {
                patternIndex = pattern.index(after: starIndex)
                let nextRetryIndex = value.index(after: savedRetryIndex)
                retryIndex = nextRetryIndex
                valueIndex = nextRetryIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            pattern.formIndex(after: &patternIndex)
        }
        return patternIndex == pattern.endIndex
    }
}


enum FloorpWebExtensionExecutionWorld: String, Codable, Sendable {
    case isolated
    case main
}

enum FloorpWebExtensionRunAt: String, Codable, Sendable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"
}

struct FloorpWebExtensionTabContext: Hashable, Codable, Sendable {
    let tabID: Int
    let documentGeneration: UInt64
    let url: URL
    let isPrivate: Bool

    init(tabID: Int, documentGeneration: UInt64, url: URL, isPrivate: Bool = false) {
        self.tabID = tabID
        self.documentGeneration = documentGeneration
        self.url = url
        self.isPrivate = isPrivate
    }
}
