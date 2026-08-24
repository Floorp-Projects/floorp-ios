// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import UIKit
import WebKit

enum FloorpWebExtensionPageHostError: Error, Equatable, LocalizedError, Sendable {
    case packageDisabled
    case invalidGeneration
    case resourceNotInGeneration(String)
    case invalidResourceURL
    case unsupportedResourceType(String)
    case resourceTooLarge

    var errorDescription: String? {
        switch self {
        case .packageDisabled:
            return "The extension package is disabled."
        case .invalidGeneration:
            return "The extension package generation is invalid."
        case .resourceNotInGeneration(let path):
            return "The extension page resource is not part of the active generation: \(path)"
        case .invalidResourceURL:
            return "The extension page resource URL is invalid."
        case .unsupportedResourceType(let path):
            return "The extension page resource type is not supported: \(path)"
        case .resourceTooLarge:
            return "The extension page resource exceeds the allowed size."
        }
    }
}

enum FloorpWebExtensionPageSurface: Hashable, Sendable {
    case actionPopup
    case options
}

/// Immutable, profile-owned authority for one extension-owned document.
/// `originHost` is intentionally a per-controller UUID rather than an
/// extension identifier, so no other extension page can reuse this bridge.
struct FloorpWebExtensionPageBridgeIdentity: Hashable, Sendable {
    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    let extensionID: FloorpWebExtensionID
    let packageGeneration: String
    let originHost: String
    let surface: FloorpWebExtensionPageSurface

    init(
        profileKey: FloorpWebExtensionCoordinatorProfileKey,
        package: FloorpWebExtensionPagePackageGeneration,
        originHost: String,
        surface: FloorpWebExtensionPageSurface
    ) throws {
        let prefix = "page-"
        guard originHost.hasPrefix(prefix),
              UUID(uuidString: String(originHost.dropFirst(prefix.count))) != nil else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        self.profileKey = profileKey
        extensionID = package.extensionID
        packageGeneration = package.generation
        self.originHost = originHost.lowercased()
        self.surface = surface
    }

    /// Only a main-frame document served by this exact private origin may use
    /// the bridge.  The scheme handler separately enforces the package's
    /// resource inventory for every request.
    func authorizesDocument(_ url: URL, isMainFrame: Bool) -> Bool {
        guard isMainFrame,
              url.scheme?.lowercased() == FloorpWebExtensionPageNavigationPolicy.resourceScheme,
              url.host?.lowercased() == originHost,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil else {
            return false
        }
        return true
    }
}

/// Identifies one immutable package generation. Page requests always carry
/// this identity so an integration cannot accidentally resolve a resource
/// from a newly-installed generation into an already-open page.
struct FloorpWebExtensionPagePackageGeneration: Hashable, Sendable {
    let extensionID: FloorpWebExtensionID
    let generation: String
    let resourcePaths: Set<String>

    init(installedPackage: FloorpWebExtensionInstalledPackage) throws {
        guard installedPackage.isEnabled else {
            throw FloorpWebExtensionPageHostError.packageDisabled
        }
        try self.init(
            extensionID: installedPackage.extensionID,
            generation: installedPackage.generation,
            resourcePaths: installedPackage.resourcePaths
        )
    }

    init(
        extensionID: FloorpWebExtensionID,
        generation: String,
        resourcePaths: Set<String>
    ) throws {
        guard !generation.isEmpty,
              generation.utf8.count <= 128,
              generation.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw FloorpWebExtensionPageHostError.invalidGeneration
        }
        self.extensionID = extensionID
        self.generation = generation
        self.resourcePaths = resourcePaths
    }
}

enum FloorpWebExtensionBackgroundRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case missingProfileAuthority
    case profileAuthorityMismatch
    case missingBackgroundDeclaration
    case conflictingBackgroundDeclarations
    case persistentBackgroundUnsupported
    case unsupportedBackgroundType(String)
    case bridgeInstallationFailed
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .missingProfileAuthority:
            return "The background runtime has no profile authority."
        case .profileAuthorityMismatch:
            return "The background package does not belong to this runtime profile."
        case .missingBackgroundDeclaration:
            return "The extension has no executable background declaration."
        case .conflictingBackgroundDeclarations:
            return "The extension declares conflicting background entry points."
        case .persistentBackgroundUnsupported:
            return "Persistent background execution is not supported."
        case .unsupportedBackgroundType(let type):
            return "The background script type is not supported: \(type)"
        case .bridgeInstallationFailed:
            return "The authenticated background bridge could not be installed."
        case .loadFailed:
            return "The package background document failed to load."
        }
    }
}

/// Executable entry points for one immutable bundled package generation.
/// MV3 service workers are hosted as either classic or module scripts. The
/// Safari-compatible script-array form is admitted only when it explicitly
/// opts out of persistence.
struct FloorpWebExtensionBackgroundPackageGeneration: Sendable {
    let package: FloorpWebExtensionPagePackageGeneration
    let scripts: [FloorpWebExtensionScriptSource]
    let loadsAsModule: Bool

    init(installedPackage: FloorpWebExtensionInstalledPackage) throws {
        let package = try FloorpWebExtensionPagePackageGeneration(installedPackage: installedPackage)
        guard let background = installedPackage.preflight.manifest.background else {
            throw FloorpWebExtensionBackgroundRuntimeError.missingBackgroundDeclaration
        }
        try self.init(package: package, background: background)
    }

    init(
        package: FloorpWebExtensionPagePackageGeneration,
        background: FloorpWebExtensionManifestBackground
    ) throws {
        guard background.persistent != true else {
            throw FloorpWebExtensionBackgroundRuntimeError.persistentBackgroundUnsupported
        }
        if let serviceWorker = background.serviceWorker {
            guard background.scripts.isEmpty else {
                throw FloorpWebExtensionBackgroundRuntimeError.conflictingBackgroundDeclarations
            }
            if let type = background.type, type.lowercased() != "module" {
                throw FloorpWebExtensionBackgroundRuntimeError.unsupportedBackgroundType(type)
            }
            scripts = [serviceWorker]
            loadsAsModule = background.type?.lowercased() == "module"
        } else {
            guard !background.scripts.isEmpty else {
                throw FloorpWebExtensionBackgroundRuntimeError.missingBackgroundDeclaration
            }
            guard background.persistent == false else {
                throw FloorpWebExtensionBackgroundRuntimeError.persistentBackgroundUnsupported
            }
            guard background.type == nil else {
                throw FloorpWebExtensionBackgroundRuntimeError.conflictingBackgroundDeclarations
            }
            scripts = background.scripts
            loadsAsModule = false
        }
        guard scripts.allSatisfy({ package.resourcePaths.contains($0.path) }) else {
            let missingPath = scripts.first(where: { !package.resourcePaths.contains($0.path) })?.path ?? ""
            throw FloorpWebExtensionPageHostError.resourceNotInGeneration(missingPath)
        }
        self.package = package
    }
}

/// Exact authority for the synthetic hidden background document. Its random
/// host is unique per activation and its internal entry path is unique per
/// WebView, while all imported scripts still resolve from the immutable
/// package inventory.
struct FloorpWebExtensionBackgroundBridgeIdentity: Hashable, Sendable {
    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    let extensionID: FloorpWebExtensionID
    let packageGeneration: String
    let originHost: String
    let entryPath: String

    init(
        profileKey: FloorpWebExtensionCoordinatorProfileKey,
        package: FloorpWebExtensionPagePackageGeneration,
        originHost: String,
        entryPath: String
    ) throws {
        let originPrefix = "background-"
        guard originHost.hasPrefix(originPrefix),
              UUID(uuidString: String(originHost.dropFirst(originPrefix.count))) != nil,
              entryPath.hasPrefix("__floorp_background_"),
              entryPath.hasSuffix(".html"),
              (try? FloorpWebExtensionScriptSource(entryPath)) != nil else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        self.profileKey = profileKey
        extensionID = package.extensionID
        packageGeneration = package.generation
        self.originHost = originHost.lowercased()
        self.entryPath = entryPath
    }

    @MainActor
    func authorizesDocument(_ url: URL, isMainFrame: Bool) -> Bool {
        guard isMainFrame,
              url.scheme?.lowercased() == FloorpWebExtensionPageNavigationPolicy.resourceScheme,
              url.host?.lowercased() == originHost,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              FloorpWebExtensionPageSchemeHandler.packagePath(from: url) == entryPath else {
            return false
        }
        return true
    }

    func authorizesSender(_ sender: any FloorpWebExtensionMessageSender) -> Bool {
        guard sender.extensionID == extensionID,
              sender.isPrivate == profileKey.isPrivateBrowsing else {
            return false
        }
        if let pageSender = sender as? FloorpWebExtensionPageRuntimeMessageSender {
            return pageSender.profileKey == profileKey &&
                pageSender.packageGeneration == packageGeneration
        }
        if let backgroundSender = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender {
            return backgroundSender.profileKey == profileKey &&
                backgroundSender.packageGeneration == packageGeneration
        }
        // Ordinary tab senders are created only by this profile's authenticated
        // tab bridge and carry the matching normal/private partition bit.
        return sender is FloorpWebExtensionRuntimeMessageSender
    }
}

struct FloorpWebExtensionPageResourceRequest: Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let generation: String
    let path: String
}

/// The package-store integration supplies bytes for the exact immutable
/// generation named in the request. The page host never accepts a directory
/// URL and never reads arbitrary filesystem paths.
struct FloorpWebExtensionPageResourceResolver: Sendable {
    typealias Resolve = @Sendable (FloorpWebExtensionPageResourceRequest) throws -> Data

    private let resolveResource: Resolve

    init(resolve: @escaping Resolve) {
        resolveResource = resolve
    }

    func resolve(_ request: FloorpWebExtensionPageResourceRequest) throws -> Data {
        try resolveResource(request)
    }
}

enum FloorpWebExtensionPageNavigationDecision: Equatable, Sendable {
    case allowPackageResource
    case openExternal(URL)
    case cancel
}

/// Pure navigation policy shared by the view controller and unit tests.
struct FloorpWebExtensionPageNavigationPolicy: Sendable {
    static let resourceScheme = "floorp-extension"

    let originHost: String

    func decision(for url: URL?, isTopLevel: Bool) -> FloorpWebExtensionPageNavigationDecision {
        guard let url else { return .cancel }
        if isPackageURL(url) {
            return isTopLevel ? .allowPackageResource : .cancel
        }
        guard isTopLevel,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .cancel
        }
        return .openExternal(url)
    }

    func isPackageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == Self.resourceScheme &&
            url.host?.lowercased() == originHost &&
            url.user == nil && url.password == nil && url.port == nil
    }
}

struct FloorpWebExtensionPageResourceResponse {
    let response: HTTPURLResponse
    let data: Data
}

/// Serves one package generation through a private, per-page origin.
/// `resourcePaths` is the trusted extraction inventory committed by the
/// package store, so even a permissive resolver cannot expose another file.
final class FloorpWebExtensionPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let contentSecurityPolicy = [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "media-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "worker-src 'self'"
    ].joined(separator: "; ")

    private let package: FloorpWebExtensionPagePackageGeneration
    private let navigationPolicy: FloorpWebExtensionPageNavigationPolicy
    private let resolver: FloorpWebExtensionPageResourceResolver

    init(
        package: FloorpWebExtensionPagePackageGeneration,
        navigationPolicy: FloorpWebExtensionPageNavigationPolicy,
        resolver: FloorpWebExtensionPageResourceResolver
    ) {
        self.package = package
        self.navigationPolicy = navigationPolicy
        self.resolver = resolver
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            let result = try response(for: urlSchemeTask.request)
            urlSchemeTask.didReceive(result.response)
            urlSchemeTask.didReceive(result.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func response(for request: URLRequest) throws -> FloorpWebExtensionPageResourceResponse {
        guard request.httpMethod == nil || request.httpMethod == "GET",
              let url = request.url,
              navigationPolicy.isPackageURL(url),
              url.query == nil,
              let path = Self.packagePath(from: url),
              package.resourcePaths.contains(path) else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        let mimeType = try Self.mimeType(for: path)
        let data = try resolver.resolve(.init(
            extensionID: package.extensionID,
            generation: package.generation,
            path: path
        ))
        guard data.count <= FloorpWebExtensionManifest.maximumPackageResourceByteSize else {
            throw FloorpWebExtensionPageHostError.resourceTooLarge
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Security-Policy": Self.contentSecurityPolicy,
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "no-store"
            ]
        ) else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        return .init(response: response, data: data)
    }

    static func packagePath(from url: URL) -> String? {
        guard let encodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath else {
            return nil
        }
        let lowercasePath = encodedPath.lowercased()
        guard encodedPath.hasPrefix("/"),
              !lowercasePath.contains("%2f"),
              !lowercasePath.contains("%5c"),
              let decodedPath = encodedPath.removingPercentEncoding else {
            return nil
        }
        let path = String(decodedPath.dropFirst())
        guard let source = try? FloorpWebExtensionScriptSource(path) else {
            return nil
        }
        return source.path
    }

    static func mimeType(for path: String) throws -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "ico":
            return "image/x-icon"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        case "mp3":
            return "audio/mpeg"
        case "mp4":
            return "video/mp4"
        default:
            throw FloorpWebExtensionPageHostError.unsupportedResourceType(path)
        }
    }
}

/// Adds one generated, non-package HTML entry point in front of the ordinary
/// package scheme handler. It contains only external package script tags and a
/// restrictive CSP; every JavaScript/module request is still checked against
/// the immutable package resource inventory.
final class FloorpWebExtensionBackgroundSchemeHandler: NSObject, WKURLSchemeHandler {
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "worker-src 'none'"
    ].joined(separator: "; ")

    private let identity: FloorpWebExtensionBackgroundBridgeIdentity
    private let entryHTML: Data
    private let readinessPath: String
    private let packageHandler: FloorpWebExtensionPageSchemeHandler

    init(
        identity: FloorpWebExtensionBackgroundBridgeIdentity,
        background: FloorpWebExtensionBackgroundPackageGeneration,
        resolver: FloorpWebExtensionPageResourceResolver
    ) throws {
        self.identity = identity
        packageHandler = .init(
            package: background.package,
            navigationPolicy: .init(originHost: identity.originHost),
            resolver: resolver
        )
        readinessPath = identity.entryPath.replacingOccurrences(
            of: ".html",
            with: ".ready.js"
        )
        let scriptTags = try background.scripts.map { source -> String in
            guard let url = Self.resourceURL(originHost: identity.originHost, path: source.path) else {
                throw FloorpWebExtensionPageHostError.invalidResourceURL
            }
            let type = background.loadsAsModule ? " type=\"module\"" : ""
            return "<script\(type) src=\"\(Self.escapeHTMLAttribute(url.absoluteString))\"></script>"
        }.joined(separator: "\n")
        guard let readinessURL = Self.resourceURL(
            originHost: identity.originHost,
            path: readinessPath
        ) else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        let readinessType = background.loadsAsModule ? " type=\"module\"" : ""
        let readinessTag = "<script\(readinessType) src=\"\(Self.escapeHTMLAttribute(readinessURL.absoluteString))\"></script>"
        entryHTML = Data("<!doctype html><meta charset=\"utf-8\">\n\(scriptTags)\n\(readinessTag)".utf8)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            let result = try response(for: urlSchemeTask.request)
            urlSchemeTask.didReceive(result.response)
            urlSchemeTask.didReceive(result.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func response(for request: URLRequest) throws -> FloorpWebExtensionPageResourceResponse {
        guard request.httpMethod == nil || request.httpMethod == "GET",
              let url = request.url,
              url.query == nil else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        if identity.authorizesDocument(url, isMainFrame: true) {
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                    "X-Content-Type-Options": "nosniff",
                    "Cache-Control": "no-store"
                ]
            ) else {
                throw FloorpWebExtensionPageHostError.invalidResourceURL
            }
            return .init(response: response, data: entryHTML)
        }
        if url.scheme?.lowercased() == FloorpWebExtensionPageNavigationPolicy.resourceScheme,
           url.host?.lowercased() == identity.originHost,
           url.user == nil,
           url.password == nil,
           url.port == nil,
           FloorpWebExtensionPageSchemeHandler.packagePath(from: url) == readinessPath {
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/javascript; charset=utf-8",
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                    "X-Content-Type-Options": "nosniff",
                    "Cache-Control": "no-store"
                ]
            ) else {
                throw FloorpWebExtensionPageHostError.invalidResourceURL
            }
            return .init(
                response: response,
                data: Data("globalThis.__floorpWebExtensionBackgroundScriptsReady = true;".utf8)
            )
        }
        return try packageHandler.response(for: request)
    }

    private static func resourceURL(originHost: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = FloorpWebExtensionPageNavigationPolicy.resourceScheme
        components.host = originHost
        components.path = "/" + path
        return components.url
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Restricted hidden-WebKit implementation of the generic lazy background
/// handler. It is intentionally page-backed rather than a true ServiceWorker:
/// the generated document is never attached to UI, has an ephemeral data
/// store, cannot navigate or open windows, and can load only package resources
/// from its random custom-scheme origin.
@MainActor
final class FloorpWebExtensionWKBackgroundEventHandler: NSObject,
                                                        FloorpWebExtensionBackgroundEventHandling,
                                                        WKNavigationDelegate,
                                                        WKUIDelegate {
    private enum LoadState {
        case idle
        case loading
        case ready
        case failed
    }

    /// WebKit exposes JavaScript values as untyped property-list objects.
    /// The value is produced and consumed exclusively on MainActor; this box
    /// only permits the continuation hand-off required by Swift 6's sending
    /// checks and is never exposed outside the actor.
    private struct JavaScriptResult: @unchecked Sendable {
        let value: Any?
    }

    private let identity: FloorpWebExtensionBackgroundBridgeIdentity
    private weak var messageRuntime: FloorpWebExtensionMessageRuntime?
    private let entryPointURL: URL
    private var loadState = LoadState.idle
    private var scriptsReady = false
    private var loadWaiters = [CheckedContinuation<Void, Error>]()
    private var nextJavaScriptCallID: UInt64 = 0
    private var pendingJavaScriptCalls = [UInt64: CheckedContinuation<JavaScriptResult, Error>]()
    private var isInvalidated = false

    private(set) var webView: WKWebView?

    init(
        profileKey: FloorpWebExtensionCoordinatorProfileKey,
        background: FloorpWebExtensionBackgroundPackageGeneration,
        resolver: FloorpWebExtensionPageResourceResolver,
        messageRuntime: FloorpWebExtensionMessageRuntime
    ) throws {
        let identifier = UUID().uuidString.lowercased()
        let originHost = "background-" + identifier
        let entryPath = "__floorp_background_\(identifier).html"
        identity = try .init(
            profileKey: profileKey,
            package: background.package,
            originHost: originHost,
            entryPath: entryPath
        )
        guard let entryPointURL = Self.resourceURL(originHost: originHost, path: entryPath) else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        self.entryPointURL = entryPointURL
        self.messageRuntime = messageRuntime

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let schemeHandler = try FloorpWebExtensionBackgroundSchemeHandler(
            identity: identity,
            background: background,
            resolver: resolver
        )
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: FloorpWebExtensionPageNavigationPolicy.resourceScheme
        )
        guard messageRuntime.installBackgroundBridge(identity, on: configuration.userContentController) else {
            throw FloorpWebExtensionBackgroundRuntimeError.bridgeInstallationFailed
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard identity.authorizesSender(sender),
              messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }
        try await ensureLoaded()
        guard messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }

        let messageJSON = try Self.jsonString(from: message.jsonData)
        let senderJSON = try Self.senderJSON(sender)
        let rawResult: Any?
        do {
            rawResult = try await callBackgroundJavaScript(
                """
                const deliver = globalThis.__floorpWebExtensionDeliverRuntimeMessage;
                if (typeof deliver !== "function") throw new Error("Background bridge unavailable");
                return await deliver(JSON.parse(messageJSON), JSON.parse(senderJSON));
                """,
                arguments: ["messageJSON": messageJSON, "senderJSON": senderJSON]
            )
        } catch let error as FloorpWebExtensionMessageError {
            throw error
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        guard messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        guard let serialized = rawResult as? String,
              let data = serialized.data(using: .utf8) else {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        return try FloorpWebExtensionMessagePayload(jsonData: data)
    }

    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        guard event.extensionID == identity.extensionID,
              messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }
        try await ensureLoaded()
        guard messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }

        var alarm: [String: Any] = [
            "name": event.alarm.name,
            "scheduledTime": event.alarm.scheduledTime.timeIntervalSince1970 * 1_000
        ]
        if let period = event.alarm.period {
            alarm["periodInMinutes"] = period / 60
        }
        let data = try JSONSerialization.data(withJSONObject: alarm)
        let alarmJSON = try Self.jsonString(from: data)
        do {
            _ = try await callBackgroundJavaScript(
                """
                const deliver = globalThis.__floorpWebExtensionDeliverAlarm;
                if (typeof deliver !== "function") throw new Error("Alarm bridge unavailable");
                await deliver(JSON.parse(alarmJSON));
                """,
                arguments: ["alarmJSON": alarmJSON]
            )
        } catch let error as FloorpWebExtensionMessageError {
            throw error
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        guard messageRuntime?.isBackgroundBridgeActive(identity) == true else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finishLoading(with: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finishLoading(with: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame,
           identity.authorizesDocument(
               navigationAction.request.url ?? URL(fileURLWithPath: "/"),
               isMainFrame: true
           ) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func invalidateBackgroundResources() {
        guard !isInvalidated else { return }
        isInvalidated = true
        loadState = .failed
        scriptsReady = false

        let loadWaiters = self.loadWaiters
        self.loadWaiters.removeAll()
        loadWaiters.forEach {
            $0.resume(throwing: FloorpWebExtensionMessageError.backgroundReplaced)
        }

        let javaScriptCalls = pendingJavaScriptCalls.values
        pendingJavaScriptCalls.removeAll()
        javaScriptCalls.forEach {
            $0.resume(throwing: FloorpWebExtensionMessageError.backgroundReplaced)
        }

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    private func ensureLoaded() async throws {
        guard !isInvalidated else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        switch loadState {
        case .ready:
            break
        case .failed:
            throw FloorpWebExtensionBackgroundRuntimeError.loadFailed
        case .idle, .loading:
            try await withCheckedThrowingContinuation { continuation in
                loadWaiters.append(continuation)
                if loadState == .idle {
                    loadState = .loading
                    guard webView?.load(URLRequest(url: entryPointURL)) != nil else {
                        finishLoading(with: FloorpWebExtensionBackgroundRuntimeError.loadFailed)
                        return
                    }
                }
            }
        }
        guard !scriptsReady else { return }
        for _ in 0..<250 {
            let ready = try await callBackgroundJavaScript(
                "return globalThis.__floorpWebExtensionBackgroundScriptsReady === true"
            ) as? Bool
            if ready == true {
                scriptsReady = true
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FloorpWebExtensionBackgroundRuntimeError.loadFailed
    }

    /// Uses WebKit's callback API so the async task does not keep a strong
    /// reference to the hidden WKWebView while JavaScript is outstanding.
    /// Invalidation resumes the Swift waiter immediately; a late WebKit
    /// callback is ignored by its removed call identifier.
    private func callBackgroundJavaScript(
        _ source: String,
        arguments: [String: Any] = [:]
    ) async throws -> Any? {
        guard !isInvalidated, webView != nil else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        nextJavaScriptCallID &+= 1
        let callID = nextJavaScriptCallID
        let result: JavaScriptResult = try await withCheckedThrowingContinuation { continuation in
            guard !isInvalidated, let webView = self.webView else {
                continuation.resume(throwing: FloorpWebExtensionMessageError.backgroundReplaced)
                return
            }
            pendingJavaScriptCalls[callID] = continuation
            webView.callAsyncJavaScript(
                source,
                arguments: arguments,
                in: nil,
                in: .page
            ) { [weak self] result in
                self?.finishJavaScriptCall(callID, with: result)
            }
        }
        return result.value
    }

    private func finishJavaScriptCall(
        _ callID: UInt64,
        with result: Result<Any, Error>
    ) {
        guard let continuation = pendingJavaScriptCalls.removeValue(forKey: callID) else {
            return
        }
        switch result {
        case .success(let value):
            continuation.resume(returning: JavaScriptResult(value: value))
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func finishLoading(with error: Error?) {
        guard loadState == .loading else { return }
        let waiters = loadWaiters
        loadWaiters.removeAll()
        if let error {
            loadState = .failed
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            loadState = .ready
            waiters.forEach { $0.resume() }
        }
    }

    private static func resourceURL(originHost: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = FloorpWebExtensionPageNavigationPolicy.resourceScheme
        components.host = originHost
        components.path = "/" + path
        return components.url
    }

    private static func jsonString(from data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return value
    }

    private static func senderJSON(_ sender: any FloorpWebExtensionMessageSender) throws -> String {
        var object: [String: Any] = [
            "id": sender.extensionID.rawValue,
            "isPrivate": sender.isPrivate
        ]
        if let tab = sender as? FloorpWebExtensionRuntimeMessageSender {
            object["url"] = tab.url.absoluteString
            object["tab"] = [
                "id": tab.tabID,
                "url": tab.url.absoluteString,
                "isPrivate": tab.isPrivate
            ]
            object["frameId"] = tab.isMainFrame ? 0 : -1
            object["documentGeneration"] = tab.documentGeneration
        } else if let page = sender as? FloorpWebExtensionPageRuntimeMessageSender {
            object["url"] = "floorp-extension://\(page.originHost)/"
            object["page"] = [
                "originHost": page.originHost,
                "surface": page.surface == .actionPopup ? "actionPopup" : "options"
            ]
        } else if let background = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender {
            object["url"] = "floorp-extension://\(background.originHost)/"
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= FloorpWebExtensionMessagePayload.maximumByteCount,
              let serialized = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionMessageError.payloadTooLarge
        }
        return serialized
    }
}

extension FloorpWebExtensionMessageRuntime {
    /// Registers the generic package-backed runtime without creating WebKit
    /// state. The hidden WebView is allocated only when the first event reaches
    /// `backgroundHost.dispatch`.
    func registerPackageBackground(
        package: FloorpWebExtensionInstalledPackage,
        packageProfileKey: FloorpWebExtensionPackageProfileKey,
        resolver: FloorpWebExtensionPageResourceResolver
    ) throws {
        guard let profileKey else {
            unregisterPackageBackground(for: package.extensionID)
            throw FloorpWebExtensionBackgroundRuntimeError.missingProfileAuthority
        }
        guard packageProfileKey.profileIdentifier == profileKey.profileIdentifier,
              packageProfileKey.isPrivateBrowsing == profileKey.isPrivateBrowsing else {
            unregisterPackageBackground(for: package.extensionID)
            throw FloorpWebExtensionBackgroundRuntimeError.profileAuthorityMismatch
        }
        let background: FloorpWebExtensionBackgroundPackageGeneration
        do {
            background = try .init(installedPackage: package)
        } catch {
            unregisterPackageBackground(for: package.extensionID)
            throw error
        }

        invalidateBackgroundBridges(for: package.extensionID)
        backgroundHost.register(extensionID: package.extensionID) { [weak self] in
            guard let self else {
                throw FloorpWebExtensionMessageError.backgroundUnavailable
            }
            return try FloorpWebExtensionWKBackgroundEventHandler(
                profileKey: profileKey,
                background: background,
                resolver: resolver,
                messageRuntime: self
            )
        }
    }

    func unregisterPackageBackground(for extensionID: FloorpWebExtensionID) {
        invalidateBackgroundBridges(for: extensionID)
        backgroundHost.unregister(extensionID: extensionID)
    }
}

/// A restricted WebKit container for an extension action popup or options
/// page. It has an ephemeral website-data store, no shared browser handlers,
/// no window opening, and no network navigation.  Its optional API bridge is
/// installed only by the profile-owned message runtime after this controller's
/// opaque origin and package generation have been bound together.
@MainActor
final class FloorpWebExtensionPageViewController: UIViewController {
    typealias ExternalNavigationHandler = @MainActor (URL) -> Void

    let webView: WKWebView
    let surface: FloorpWebExtensionPageSurface

    private let navigationControllerDelegate: FloorpWebExtensionPageNavigationDelegate
    private let entryPointURL: URL

    init(
        surface: FloorpWebExtensionPageSurface,
        package: FloorpWebExtensionPagePackageGeneration,
        entryPoint: FloorpWebExtensionActionResource,
        resolver: FloorpWebExtensionPageResourceResolver,
        messageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternal: @escaping ExternalNavigationHandler
    ) throws {
        guard package.resourcePaths.contains(entryPoint.path) else {
            throw FloorpWebExtensionPageHostError.resourceNotInGeneration(entryPoint.path)
        }
        let originHost = "page-" + UUID().uuidString.lowercased()
        let navigationPolicy = FloorpWebExtensionPageNavigationPolicy(originHost: originHost)
        let handler = FloorpWebExtensionPageSchemeHandler(
            package: package,
            navigationPolicy: navigationPolicy,
            resolver: resolver
        )
        let configuration = Self.makeConfiguration(
            schemeHandler: handler
        )
        guard let entryPointURL = Self.resourceURL(
            originHost: originHost,
            path: entryPoint.path
        ) else {
            throw FloorpWebExtensionPageHostError.invalidResourceURL
        }
        if let profileKey = messageRuntime?.profileKey {
            let identity = try FloorpWebExtensionPageBridgeIdentity(
                profileKey: profileKey,
                package: package,
                originHost: originHost,
                surface: surface
            )
            _ = messageRuntime?.installPageBridge(
                identity,
                on: configuration.userContentController
            )
        }
        self.surface = surface
        self.entryPointURL = entryPointURL
        navigationControllerDelegate = .init(
            policy: navigationPolicy,
            openExternal: openExternal
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = navigationControllerDelegate
        webView.uiDelegate = navigationControllerDelegate
        preferredContentSize = surface == .actionPopup
            ? CGSize(width: 360, height: 520)
            : CGSize(width: 640, height: 720)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: entryPointURL))
    }

    private static func makeConfiguration(
        schemeHandler: WKURLSchemeHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: FloorpWebExtensionPageNavigationPolicy.resourceScheme
        )
        return configuration
    }

    private static func resourceURL(originHost: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = FloorpWebExtensionPageNavigationPolicy.resourceScheme
        components.host = originHost
        components.path = "/" + path
        return components.url
    }
}

/// Keeps external navigation handling separate from the page controller. All
/// HTTP(S) links are cancelled in this WebView before the embedding browser is
/// asked to open them as a normal tab.
@MainActor
private final class FloorpWebExtensionPageNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let policy: FloorpWebExtensionPageNavigationPolicy
    private let openExternal: FloorpWebExtensionPageViewController.ExternalNavigationHandler

    init(
        policy: FloorpWebExtensionPageNavigationPolicy,
        openExternal: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler
    ) {
        self.policy = policy
        self.openExternal = openExternal
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
        switch policy.decision(for: navigationAction.request.url, isTopLevel: isTopLevel) {
        case .allowPackageResource:
            decisionHandler(.allow)
        case .openExternal(let url):
            openExternal(url)
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if case .openExternal(let url) = policy.decision(
            for: navigationAction.request.url,
            isTopLevel: true
        ) {
            openExternal(url)
        }
        return nil
    }
}

/// Action-menu integration hook. The menu coordinator supplies its current
/// enabled package and action state; this factory returns nil when no popup is
/// configured rather than opening a URL directly.
@MainActor
enum FloorpWebExtensionPageHost {
    static func makeActionPopup(
        package: FloorpWebExtensionInstalledPackage,
        actionState: FloorpWebExtensionActionState,
        resolver: FloorpWebExtensionPageResourceResolver,
        messageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternal: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler
    ) throws -> FloorpWebExtensionPageViewController? {
        guard actionState.isEnabled, let popup = actionState.popup else { return nil }
        return try .init(
            surface: .actionPopup,
            package: .init(installedPackage: package),
            entryPoint: popup,
            resolver: resolver,
            messageRuntime: messageRuntime,
            openExternal: openExternal
        )
    }

    static func makeOptionsPage(
        package: FloorpWebExtensionInstalledPackage,
        entryPoint: FloorpWebExtensionActionResource,
        resolver: FloorpWebExtensionPageResourceResolver,
        messageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternal: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler
    ) throws -> FloorpWebExtensionPageViewController {
        try .init(
            surface: .options,
            package: .init(installedPackage: package),
            entryPoint: entryPoint,
            resolver: resolver,
            messageRuntime: messageRuntime,
            openExternal: openExternal
        )
    }

    /// Settings retains only the reviewed page generation, not the package's
    /// source URL or files. This overload keeps an options page bound to that
    /// immutable generation after the Settings snapshot has been rendered.
    static func makeOptionsPage(
        packageGeneration: FloorpWebExtensionPagePackageGeneration,
        entryPoint: FloorpWebExtensionActionResource,
        resolver: FloorpWebExtensionPageResourceResolver,
        messageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternal: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler
    ) throws -> FloorpWebExtensionPageViewController {
        try .init(
            surface: .options,
            package: packageGeneration,
            entryPoint: entryPoint,
            resolver: resolver,
            messageRuntime: messageRuntime,
            openExternal: openExternal
        )
    }
}
