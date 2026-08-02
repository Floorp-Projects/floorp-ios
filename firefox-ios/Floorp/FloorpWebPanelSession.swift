// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation

struct FloorpWebPanelSessionKey: Hashable {
    let windowUUID: WindowUUID
    let panelID: String
    let isPrivate: Bool
}

struct FloorpWebPanelSessionConfiguration: Equatable {
    let panelTitle: String
    let homeURL: URL
    let iconName: String
}

struct FloorpWebPanelSessionState: Equatable {
    var configuration: FloorpWebPanelSessionConfiguration
    var currentURL: URL?
    var pageTitle: String?
    var canGoBack: Bool
    var canGoForward: Bool
    var isLoading: Bool
    var estimatedProgress: Double

    init(
        configuration: FloorpWebPanelSessionConfiguration,
        currentURL: URL? = nil,
        pageTitle: String? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        estimatedProgress: Double = 0
    ) {
        self.configuration = configuration
        self.currentURL = currentURL
        self.pageTitle = pageTitle
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
    }
}

@MainActor
protocol FloorpWebPanelSessionProtocol: AnyObject {
    var key: FloorpWebPanelSessionKey { get }
    var state: FloorpWebPanelSessionState { get }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration)
    func invalidate()
}

@MainActor
protocol FloorpWebPanelSessionFactory {
    func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration
    ) throws -> any FloorpWebPanelSessionProtocol
}
