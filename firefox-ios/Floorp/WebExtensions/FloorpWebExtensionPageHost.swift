// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

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
