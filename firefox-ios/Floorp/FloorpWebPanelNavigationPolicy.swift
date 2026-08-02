// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

enum FloorpWebPanelNavigationTarget: CaseIterable {
    case mainFrame
    case subframe
    case newWindow
}

struct FloorpWebPanelNavigationRequest {
    let url: URL?
    let target: FloorpWebPanelNavigationTarget
}

enum FloorpWebPanelNavigationDecision: Equatable {
    case allow
    case openInMainBrowser(URL)
    case cancel
}

enum FloorpWebPanelNavigationPolicy {
    static func decision(
        for request: FloorpWebPanelNavigationRequest
    ) -> FloorpWebPanelNavigationDecision {
        guard let url = request.url else { return .cancel }

        if isExactAboutBlank(url) {
            return request.target == .newWindow ? .cancel : .allow
        }

        guard isSafeWebURL(url) else { return .cancel }
        return request.target == .newWindow ? .openInMainBrowser(url) : .allow
    }

    private static func isExactAboutBlank(_ url: URL) -> Bool {
        url.absoluteString.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              !host.contains("@"),
              !host.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }

        if components.rangeOfPort != nil || hasExplicitPortDelimiter(url.absoluteString) {
            guard let port = components.port, (1...65_535).contains(port) else { return false }
        }
        return true
    }

    private static func hasExplicitPortDelimiter(_ value: String) -> Bool {
        guard let authoritySeparator = value.range(of: "://") else { return false }
        let authorityStart = authoritySeparator.upperBound
        let authorityEnd = value[authorityStart...].firstIndex(where: { "/?#".contains($0) })
            ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""

        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else { return false }
            let afterBracket = hostAndPort.index(after: closingBracket)
            return afterBracket < hostAndPort.endIndex && hostAndPort[afterBracket] == ":"
        }
        return hostAndPort.contains(":")
    }
}
