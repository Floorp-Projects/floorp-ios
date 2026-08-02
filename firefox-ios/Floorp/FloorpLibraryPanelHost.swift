// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Storage
import UIKit

import enum MozillaAppServices.VisitType

enum FloorpLibraryPanelDismissalDisposition: Equatable {
    case allow
    case consumed
    case blocked
}

@MainActor
protocol FloorpLibraryPanelHosting: AnyObject {
    var viewController: UIViewController { get }
    var selectedPanelType: FloorpPanelType? { get }
    var allowsPanelSwitching: Bool { get }
    var onRequestDrawerDismiss: (() -> Void)? { get set }

    @discardableResult
    func select(panelType: FloorpPanelType) -> Bool
    func prepareForDrawerDismissal() -> FloorpLibraryPanelDismissalDisposition
}

@MainActor
final class FloorpLibraryPanelHost: FloorpLibraryPanelHosting, LibraryCoordinatorDelegate {
    private let navigationController: ThemedNavigationController
    private let libraryCoordinator: LibraryCoordinator
    private weak var actionDelegate: (any LibraryPanelDelegate & RecentlyClosedPanelDelegate)?

    let windowUUID: WindowUUID
    var onRequestDrawerDismiss: (() -> Void)?

    var viewController: UIViewController {
        navigationController
    }

    var selectedPanelType: FloorpPanelType? {
        guard let panelType = libraryCoordinator.libraryViewController?.viewModel.selectedPanel else {
            return nil
        }
        return FloorpPanelType(libraryPanelType: panelType)
    }

    var allowsPanelSwitching: Bool {
        guard !containsPresentedViewController(navigationController) else { return false }
        return libraryCoordinator.libraryViewController?.allowsExternalPanelSwitching ?? false
    }

    init(
        profile: Profile,
        tabManager: TabManager,
        actionDelegate: any LibraryPanelDelegate & RecentlyClosedPanelDelegate,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        bookmarksHandler: BookmarksHandler? = nil
    ) {
        windowUUID = tabManager.windowUUID
        self.actionDelegate = actionDelegate
        navigationController = ThemedNavigationController(
            windowUUID: tabManager.windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter
        )
        libraryCoordinator = LibraryCoordinator(
            router: DefaultRouter(navigationController: navigationController),
            profile: profile,
            tabManager: tabManager,
            presentationMode: .externalSwitcher,
            bookmarksHandler: bookmarksHandler
        )
        libraryCoordinator.parentCoordinator = self
        libraryCoordinator.libraryViewController?.onRequestHostDismiss = { [weak self] in
            guard let self,
                  self.prepareForDrawerDismissal() == .allow else { return }
            self.onRequestDrawerDismiss?()
        }
    }

    @discardableResult
    func select(panelType: FloorpPanelType) -> Bool {
        guard let libraryPanelType = panelType.libraryPanelType else { return false }
        if selectedPanelType != panelType && !allowsPanelSwitching {
            return false
        }

        libraryCoordinator.start(with: libraryPanelType.homepanelSection)
        return selectedPanelType == panelType
    }

    func prepareForDrawerDismissal() -> FloorpLibraryPanelDismissalDisposition {
        guard !containsPresentedViewController(navigationController) else { return .blocked }
        guard let libraryViewController = libraryCoordinator.libraryViewController else { return .allow }
        guard libraryViewController.allowsExternalPanelSwitching else { return .blocked }
        return libraryViewController.prepareForExternalDismissal() ? .allow : .consumed
    }

    func libraryPanelDidRequestToOpenInNewTab(_ url: URL, isPrivate: Bool) {
        actionDelegate?.libraryPanelDidRequestToOpenInNewTab(url, isPrivate: isPrivate)
    }

    func libraryPanel(didSelectURL url: URL, visitType: VisitType) {
        actionDelegate?.libraryPanel(didSelectURL: url, visitType: visitType)
    }

    var libraryPanelWindowUUID: WindowUUID {
        windowUUID
    }

    func showToast(message: String) {
        actionDelegate?.showToast(message: message)
    }

    func openRecentlyClosedSiteInNewTab(_ url: URL, isPrivate: Bool) {
        actionDelegate?.openRecentlyClosedSiteInNewTab(url, isPrivate: isPrivate)
    }

    func didFinishLibrary(from coordinator: Coordinator) {
        onRequestDrawerDismiss?()
    }

    private func containsPresentedViewController(_ viewController: UIViewController) -> Bool {
        if viewController.presentedViewController != nil {
            return true
        }
        return viewController.children.contains(where: containsPresentedViewController)
    }
}

private extension FloorpPanelType {
    var libraryPanelType: LibraryPanelType? {
        switch self {
        case .bookmarks: return .bookmarks
        case .history: return .history
        case .downloads: return .downloads
        case .notes, .web: return nil
        }
    }

    init?(libraryPanelType: LibraryPanelType) {
        switch libraryPanelType {
        case .bookmarks: self = .bookmarks
        case .history: self = .history
        case .downloads: self = .downloads
        case .readingList: return nil
        }
    }
}
