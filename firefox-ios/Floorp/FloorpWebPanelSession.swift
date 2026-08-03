// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import UIKit

struct FloorpWebPanelSessionKey: Hashable {
    let windowUUID: WindowUUID
    let panelID: String
    let isPrivate: Bool
}

struct FloorpWebPanelSessionConfiguration: Equatable {
    let panelTitle: String
    let homeURL: URL
    let iconName: String
    let zoomLevel: FloorpWebPanelZoomLevel
    let contentMode: FloorpWebPanelContentMode

    init(
        panelTitle: String,
        homeURL: URL,
        iconName: String,
        zoomLevel: FloorpWebPanelZoomLevel = .defaultLevel,
        contentMode: FloorpWebPanelContentMode = .mobile
    ) {
        self.panelTitle = panelTitle
        self.homeURL = homeURL
        self.iconName = iconName
        self.zoomLevel = zoomLevel
        self.contentMode = contentMode
    }
}

struct FloorpWebPanelSessionState: Equatable {
    var configuration: FloorpWebPanelSessionConfiguration
    var currentURL: URL?
    var pageTitle: String?
    var canGoBack: Bool
    var canGoForward: Bool
    var isLoading: Bool
    var estimatedProgress: Double
    var isUserMediaPaused: Bool
    /// Session-local revision for the user-controlled media pause state.
    /// Every optimistic change and rollback advances it so stale UI actions
    /// cannot become valid again after an A-B-A state sequence.
    var userMediaStateRevision: UInt64

    init(
        configuration: FloorpWebPanelSessionConfiguration,
        currentURL: URL? = nil,
        pageTitle: String? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        isUserMediaPaused: Bool = false,
        userMediaStateRevision: UInt64 = 0
    ) {
        self.configuration = configuration
        self.currentURL = currentURL
        self.pageTitle = pageTitle
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.isUserMediaPaused = isUserMediaPaused
        self.userMediaStateRevision = userMediaStateRevision
    }
}

typealias FloorpWebPanelMediaPauseCompletion = @MainActor (Result<Void, Error>) -> Void

enum FloorpWebPanelRestorationPolicy {
    static func safeWebURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              FloorpWebPanelNavigationPolicy.decision(
                for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
              ) == .allow else {
            return nil
        }
        return url
    }
}

@MainActor
protocol FloorpWebPanelSessionProtocol: AnyObject {
    var key: FloorpWebPanelSessionKey { get }
    /// Stable identity for the lifetime of this session. Unlike an object
    /// address, this token cannot become valid again after deallocation.
    var sessionIdentifier: UUID { get }
    var state: FloorpWebPanelSessionState { get }
    var isVisible: Bool { get }
    var contentView: UIView? { get }
    var findTarget: (any FloorpWebPanelFindTarget)? { get }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration)
    @discardableResult
    func addStateObserver(
        _ observer: @escaping @MainActor (FloorpWebPanelSessionState) -> Void
    ) -> UUID?
    func removeStateObserver(_ identifier: UUID)
    func loadHome()
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    func openCurrentPageInMainBrowser()
    func setVisible(_ isVisible: Bool)
    var isContentModeReloadPending: Bool { get }
    @discardableResult
    func applyPendingContentModeReload() -> Bool
    /// iOS intentionally exposes pause/resume instead of desktop-style audio
    /// mute. Public WebKit API suspends all audio and video playback together;
    /// this session-scoped state is therefore labeled as media playback pause.
    @discardableResult
    func setUserMediaPaused(
        _ isUserMediaPaused: Bool,
        completion: @escaping FloorpWebPanelMediaPauseCompletion
    ) -> Bool
    /// Returns a synchronous, safe URL candidate immediately before unload.
    /// Implementations backed by an asynchronous runtime should prefer its
    /// latest value over observer-derived state.
    func restorationURLForUnload() -> URL?
    func unload()
    func invalidate()
}

extension FloorpWebPanelSessionProtocol {
    var contentView: UIView? { nil }
    var findTarget: (any FloorpWebPanelFindTarget)? { nil }

    @discardableResult
    func addStateObserver(
        _ observer: @escaping @MainActor (FloorpWebPanelSessionState) -> Void
    ) -> UUID? {
        observer(state)
        return nil
    }

    func removeStateObserver(_ identifier: UUID) {}
    func loadHome() {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func openCurrentPageInMainBrowser() {}
    var isContentModeReloadPending: Bool { false }
    @discardableResult
    func applyPendingContentModeReload() -> Bool { false }
    @discardableResult
    func setUserMediaPaused(
        _ isUserMediaPaused: Bool,
        completion: @escaping FloorpWebPanelMediaPauseCompletion
    ) -> Bool { false }
    func restorationURLForUnload() -> URL? {
        FloorpWebPanelRestorationPolicy.safeWebURL(state.currentURL)
    }
    func unload() {
        invalidate()
    }
}

@MainActor
protocol FloorpWebPanelSessionFactory {
    func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
    ) throws -> any FloorpWebPanelSessionProtocol
}

extension FloorpWebPanelSessionFactory {
    func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration
    ) throws -> any FloorpWebPanelSessionProtocol {
        try makeSession(for: key, configuration: configuration, restorationURL: nil)
    }
}
