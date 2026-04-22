// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

// MARK: - Floorp Overlay Drawer Integration
extension BrowserViewController {
    // MARK: - Properties

    private struct FloorpAssociatedKeys {
        nonisolated(unsafe) static var overlayDrawer = "floorpOverlayDrawer"
    }

    var floorpOverlayDrawer: FloorpOverlayDrawerViewController? {
        get {
            objc_getAssociatedObject(
                self,
                &FloorpAssociatedKeys.overlayDrawer
            ) as? FloorpOverlayDrawerViewController
        }
        set {
            objc_setAssociatedObject(
                self,
                &FloorpAssociatedKeys.overlayDrawer,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
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
        guard FloorpFlags.isOverlayDrawerEnabled else { return }
        toggleFloorpOverlayDrawer()
    }

    // MARK: - Overlay Drawer

    func showFloorpOverlayDrawer() {
        guard floorpOverlayDrawer == nil else { return }

        let drawer = FloorpOverlayDrawerViewController(windowUUID: windowUUID)
        drawer.onItemSelected = { [weak self] url in
            self?.floorpOpenURLInNewTabOrCurrent(url)
        }
        drawer.onDismissed = { [weak self] in
            self?.floorpOverlayDrawer = nil
        }
        self.floorpOverlayDrawer = drawer
        drawer.show(from: self)
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

    // MARK: - Keyboard Shortcut

    @objc func toggleFloorpOverlayDrawerKeyCommand() {
        guard FloorpFlags.isOverlayDrawerEnabled else { return }
        toggleFloorpOverlayDrawer()
    }
}
