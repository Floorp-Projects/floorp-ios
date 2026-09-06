// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import UIKit
import WebKit

/// Stable identity wrapper used by WebKit for the lifetime of a Firefox/Floorp tab.
/// The browser remains the owner of the tab and its WKWebView.
@MainActor
final class FloorpNativeWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    weak var host: FloorpNativeWebExtensionHost?

    init(tab: Tab, host: FloorpNativeWebExtensionHost) {
        self.tab = tab
        self.host = host
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return nil }
        return host.windowAdapter(for: tab.windowUUID, isPrivate: tab.isPrivate)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return NSNotFound }
        return host.tabs(for: tab.windowUUID, isPrivate: tab.isPrivate)
            .firstIndex(where: { $0 === tab }) ?? NSNotFound
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab, let parent = tab.parent, let host,
              host.canOperate(tab: parent, in: context) else { return nil }
        return host.tabAdapter(for: parent)
    }

    func setParentTab(
        _ parentTab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        guard parentTab == nil || parentTab is FloorpNativeWebExtensionTab else {
            completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("setParentTab"))
            return
        }
        tab.parent = (parentTab as? FloorpNativeWebExtensionTab)?.tab
        completionHandler(nil)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return nil }
        return tab.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return nil }
        return tab.displayTitle
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return false }
        return tab.readerModeAvailableOrActive
    }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return false }
        return tab.readerModeState == .active
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return .zero }
        return tab.webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return 1 }
        return Double(tab.pageZoom)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context),
              zoomFactor.isFinite, zoomFactor > 0 else {
            completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("setZoomFactor"))
            return
        }
        tab.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return nil }
        return tab.webView?.url ?? tab.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return nil }
        return tab.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return true }
        return !tab.isLoading
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (UIImage?, (any Error)?) -> Void
    ) {
        guard let tab, let host, host.canOperate(tab: tab, in: context), let webView = tab.webView else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        host.load(url: url, in: tab, requestedBy: context) { didAcceptLoad in
            completionHandler(
                didAcceptLoad
                    ? nil
                    : FloorpNativeWebExtensionError.unsupportedOperation(
                        "tab navigation was cancelled"
                    )
            )
        }
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        tab.reload(bypassCache: fromOrigin)
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        tab.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        tab.goForward()
        completionHandler(nil)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        do {
            try host.requestActivation(of: tab, requestedBy: context)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let host, host.canOperate(tab: tab, in: context) else { return false }
        return host.activeTab(for: tab.windowUUID, isPrivate: tab.isPrivate) === tab
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard selected else {
            completionHandler(nil)
            return
        }
        activate(for: context, completionHandler: completionHandler)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context),
              let manager = host.tabManager(for: tab.windowUUID) else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        do {
            if configuration.shouldBeActive {
                try host.validateDeferredActivation(requestedBy: context)
            }
        } catch {
            completionHandler(nil, error)
            return
        }
        let url = configuration.url ?? tab.webView?.url ?? tab.url
        let duplicate = manager.addTab(
            nil as URLRequest?,
            afterTab: tab,
            zombie: false,
            isPrivate: tab.isPrivate
        )
        host.announceTabIfNeeded(duplicate)
        do {
            if configuration.shouldBeActive {
                try host.requestActivation(
                    of: duplicate,
                    requestedBy: context,
                    cancellation: { [weak host, weak duplicate] in
                        guard let host, let duplicate else { return }
                        host.rollbackCreatedTabsAfterFailedActivation(
                            [duplicate],
                            from: manager,
                            completion: {}
                        )
                    }
                )
            }
            if let url {
                host.load(url: url, in: duplicate, requestedBy: context)
            }
            completionHandler(host.tabAdapter(for: duplicate), nil)
        } catch {
            host.rollbackCreatedTabsAfterFailedActivation(
                [duplicate],
                from: manager
            ) {
                completionHandler(nil, error)
            }
        }
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let host, host.canMutate(tab: tab, in: context),
              let manager = host.tabManager(for: tab.windowUUID) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        manager.removeTab(tab.tabUUID) { didRemove in
            completionHandler(
                didRemove
                    ? nil
                    : FloorpNativeWebExtensionError.unsupportedOperation(
                        "tab close was cancelled"
                    )
            )
        }
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let host else { return false }
        return host.canMutate(tab: tab, in: context)
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }
}

/// WebKit treats private state as a property of a window. Floorp therefore
/// exposes one logical window per (UIScene window, privacy mode) pair.
@MainActor
final class FloorpNativeWebExtensionWindow: NSObject, WKWebExtensionWindow {
    let windowUUID: WindowUUID
    let isPrivateBrowsing: Bool
    weak var host: FloorpNativeWebExtensionHost?

    init(windowUUID: WindowUUID, isPrivateBrowsing: Bool, host: FloorpNativeWebExtensionHost) {
        self.windowUUID = windowUUID
        self.isPrivateBrowsing = isPrivateBrowsing
        self.host = host
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let host,
              host.canOperate(windowUUID: windowUUID, isPrivate: isPrivateBrowsing, in: context) else {
            return []
        }
        return host.tabs(for: windowUUID, isPrivate: isPrivateBrowsing).map { host.tabAdapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let host,
              host.canOperate(windowUUID: windowUUID, isPrivate: isPrivateBrowsing, in: context),
              let tab = host.activeTab(for: windowUUID, isPrivate: isPrivateBrowsing) else { return nil }
        return host.tabAdapter(for: tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isPrivateBrowsing
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        guard let host,
              host.canOperate(windowUUID: windowUUID, isPrivate: isPrivateBrowsing, in: context) else {
            return .zero
        }
        return host.activeTab(for: windowUUID, isPrivate: isPrivateBrowsing)?
            .webView?.window?.frame ?? UIScreen.main.bounds
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let host,
              host.canMutate(windowUUID: windowUUID, isPrivate: isPrivateBrowsing, in: context) else {
            completionHandler(FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        do {
            try host.requestFocus(
                windowUUID: windowUUID,
                isPrivate: isPrivateBrowsing,
                requestedBy: context
            )
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
