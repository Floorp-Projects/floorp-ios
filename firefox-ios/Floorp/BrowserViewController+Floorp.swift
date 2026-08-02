// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common

@MainActor
enum FloorpPanelPresentationStateAssociation {
    nonisolated(unsafe) private static var key: UInt8 = 0

    static func state(
        for owner: AnyObject,
        windowUUID: WindowUUID
    ) -> FloorpPanelPresentationState {
        if let state = objc_getAssociatedObject(owner, &key) as? FloorpPanelPresentationState {
            return state
        }
        let state = FloorpPanelPresentationState(windowUUID: windowUUID)
        objc_setAssociatedObject(owner, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}

// MARK: - Floorp Overlay Drawer Integration
extension BrowserViewController {
    // MARK: - Properties

    var floorpOverlayDrawer: FloorpOverlayDrawerViewController? {
        floorpPanelPresentationState.activeDrawer
    }

    private var floorpPanelPresentationState: FloorpPanelPresentationState {
        FloorpPanelPresentationStateAssociation.state(
            for: self,
            windowUUID: windowUUID
        )
    }

    // MARK: - Setup (called from patched setupEssentialUI)

    func setupFloorp() {
        guard FloorpFlags.isOverlayDrawerEnabled else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(floorpToggleDrawerNotification(_:)),
            name: .FloorpToggleDrawer,
            object: nil
        )
    }

    // MARK: - Notification Handler

    @objc private func floorpToggleDrawerNotification(_ notification: Notification) {
        guard FloorpFlags.isOverlayDrawerEnabled,
              let notificationWindowUUID = notification.userInfo?["windowUUID"] as? WindowUUID,
              notificationWindowUUID == windowUUID else { return }
        toggleFloorpOverlayDrawer()
    }

    // MARK: - Overlay Drawer

    func showFloorpOverlayDrawer() {
        let presentationState = floorpPanelPresentationState
        guard FloorpPanelManager.shared.config.isEnabled,
              !presentationState.hasActivePresentation else { return }

        let drawer = FloorpOverlayDrawerViewController(presentationState: presentationState)
        drawer.onItemSelected = { [weak self] url in
            self?.floorpOpenURLInNewTabOrCurrent(url)
        }
        drawer.webPanelSuggestionProvider = { [weak self] in
            self?.floorpCurrentPageWebPanelSuggestion()
        }
        if !drawer.show(from: self) {
            // Keep the window state for its selected-panel identity. The
            // drawer detaches itself when presentation cannot start.
            return
        }
    }

    private func toggleFloorpOverlayDrawer() {
        if floorpOverlayDrawer != nil {
            floorpOverlayDrawer?.dismissDrawer()
        } else {
            showFloorpOverlayDrawer()
        }
    }

    private func floorpOpenURLInNewTabOrCurrent(_ url: URL) {
        guard let tab = tabManager.selectedTab else {
            tabManager.addTab(URLRequest(url: url))
            return
        }
        tab.loadRequest(URLRequest(url: url))
    }

    /// Returns a persistence-safe suggestion for the panel editor. Private and
    /// internal pages are deliberately excluded so opening the editor cannot
    /// leak them into profile-wide panel configuration.
    private func floorpCurrentPageWebPanelSuggestion() -> FloorpWebPanelDraft? {
        guard let tab = tabManager.selectedTab,
              !tab.isPrivate,
              let url = tab.currentURL(),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }

        let titleCandidates = [tab.title, url.host, FloorpStrings.PanelRegistry.webPanel]
            .compactMap { $0 }
        for titleCandidate in titleCandidates {
            let draft = FloorpWebPanelDraft(
                title: String(titleCandidate.prefix(FloorpWebPanelValidator.maximumTitleLength)),
                urlText: url.absoluteString,
                iconName: FloorpPanelType.web.systemIconName
            )
            if let validated = try? FloorpWebPanelValidator.validate(draft) {
                return FloorpWebPanelDraft(
                    title: validated.title,
                    urlText: validated.url.absoluteString,
                    iconName: validated.iconName
                )
            }
        }
        return nil
    }

    // MARK: - Keyboard Shortcut

    @objc func toggleFloorpOverlayDrawerKeyCommand() {
        guard FloorpFlags.isOverlayDrawerEnabled else { return }
        toggleFloorpOverlayDrawer()
    }
}
