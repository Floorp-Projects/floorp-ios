// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Overlay Drawer - View Controller
// A slide-in side panel with vertical icon sidebar, matching Floorp desktop's Panel Sidebar.
//
// Desktop layout reference:
//   [Icon Column 42px] │ [Content Area]
//   ┌──────────┐       │ ┌────────────────┐
//   │ 🔖 BM    │       │ │ Header: ←→↻⌂  ✕│
//   │ 🕐 Hist  │       │ ├────────────────┤
//   │ 📥 DL    │       │ │  Search         │
//   │          │       │ ├────────────────┤
//   │ + Add    │       │ │  Content List   │
//   └──────────┘       │ └────────────────┘
//
// iOS adaptation: 50px icon sidebar, search bar, and content area.
//
// This file is part of the Floorp customization layer.

import UIKit
import Common
import Storage
import MozillaAppServices
import Shared

@MainActor
protocol FloorpPanelPrivacyModePresenting: AnyObject {
    func rebindActiveContent(forSelectedTabIsPrivate isPrivate: Bool)
    func privateWebPanelSessionsDidClose(selectedTabIsPrivate: Bool?)
}

@MainActor
final class FloorpPanelPresentationState: NSObject {
    let windowUUID: WindowUUID
    private(set) var selectedPanelId: String?
    private weak var activePresentation: (any FloorpPanelPrivacyModePresenting)?
    private(set) var webPanelSessionStore: FloorpWebPanelSessionStore?
    private var panelManager: FloorpPanelManager?
    private var observesPanelRegistry = false
    private weak var observedTabManager: (any TabManager)?
    private(set) var hasPendingNotesOperationError = false
    var libraryPanelHost: (any FloorpLibraryPanelHosting)?

    var activeDrawer: FloorpOverlayDrawerViewController? {
        activePresentation as? FloorpOverlayDrawerViewController
    }

    var hasActivePresentation: Bool {
        activePresentation != nil
    }

    init(
        windowUUID: WindowUUID,
        selectedPanelId: String? = nil,
        webPanelSessionStore: FloorpWebPanelSessionStore? = nil
    ) {
        self.windowUUID = windowUUID
        self.selectedPanelId = selectedPanelId
        self.webPanelSessionStore = webPanelSessionStore
        super.init()
    }

    func selectedPanel(in panels: [FloorpPanel]) -> FloorpPanel? {
        if let selectedPanelId,
           let selectedPanel = panels.first(where: { $0.id == selectedPanelId }) {
            return selectedPanel
        }
        selectedPanelId = panels.first?.id
        return panels.first
    }

    func select(_ panel: FloorpPanel) {
        selectedPanelId = panel.id
    }

    func attach(_ presentation: any FloorpPanelPrivacyModePresenting) -> Bool {
        guard activePresentation == nil || activePresentation === presentation else {
            return false
        }
        activePresentation = presentation
        return true
    }

    func detach(_ presentation: any FloorpPanelPrivacyModePresenting) {
        guard activePresentation === presentation else { return }
        activePresentation = nil
    }

    func recordPendingNotesOperationError() {
        hasPendingNotesOperationError = true
    }

    @discardableResult
    func consumePendingNotesOperationError() -> Bool {
        guard hasPendingNotesOperationError else { return false }
        hasPendingNotesOperationError = false
        return true
    }

    func configureWebPanelRuntime(
        profile: Profile,
        panelManager: FloorpPanelManager = .shared,
        openInMainBrowser: @escaping FloorpWebPanelNavigationExecutor.OpenInMainBrowser
    ) {
        guard webPanelSessionStore == nil else { return }
        webPanelSessionStore = FloorpWebPanelSessionStore(
            windowUUID: windowUUID,
            factory: DefaultFloorpWebPanelSessionFactory(
                profile: profile,
                openInMainBrowser: openInMainBrowser
            )
        )
        self.panelManager = panelManager
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelRegistryDidChange),
            name: .FloorpPanelRegistryDidChange,
            object: nil
        )
        observesPanelRegistry = true
    }

    func observePrivateTabLifecycle(in tabManager: any TabManager) {
        guard tabManager.windowUUID == windowUUID else { return }
        guard observedTabManager !== tabManager else { return }
        observedTabManager?.removeDelegate(self, completion: nil)
        observedTabManager = tabManager
        tabManager.addDelegate(self)
        closePrivateWebPanelSessionsIfNeeded(
            in: tabManager,
            selectedTabIsPrivate: tabManager.selectedTab?.isPrivate
        )
    }

    func invalidateWebPanelRuntime() {
        observedTabManager?.removeDelegate(self, completion: nil)
        observedTabManager = nil
        if observesPanelRegistry {
            NotificationCenter.default.removeObserver(
                self,
                name: .FloorpPanelRegistryDidChange,
                object: nil
            )
        }
        observesPanelRegistry = false
        panelManager = nil
        activeDrawer?.webPanelRuntimeWillInvalidate()
        webPanelSessionStore?.invalidateAll()
        webPanelSessionStore = nil
    }

    private func closePrivateWebPanelSessionsIfNeeded(
        in tabManager: any TabManager,
        selectedTabIsPrivate: Bool?
    ) {
        guard observedTabManager === tabManager,
              tabManager.windowUUID == windowUUID,
              selectedTabIsPrivate != true,
              tabManager.privateTabs.isEmpty,
              webPanelSessionStore?.closePrivateSessions() == true else {
            return
        }
        activePresentation?.privateWebPanelSessionsDidClose(
            selectedTabIsPrivate: selectedTabIsPrivate
        )
    }

    @objc private func panelRegistryDidChange() {
        guard let panelManager else { return }
        webPanelSessionStore?.reconcile(with: panelManager.panels)
    }
}

extension FloorpPanelPresentationState: TabManagerDelegate {
    func tabManager(
        _ tabManager: any TabManager,
        didSelectedTabChange selectedTab: Tab,
        previousTab: Tab?,
        isRestoring: Bool
    ) {
        guard observedTabManager === tabManager,
              tabManager.windowUUID == windowUUID,
              selectedTab.windowUUID == windowUUID else {
            return
        }
        activePresentation?.rebindActiveContent(
            forSelectedTabIsPrivate: selectedTab.isPrivate
        )
        closePrivateWebPanelSessionsIfNeeded(
            in: tabManager,
            selectedTabIsPrivate: selectedTab.isPrivate
        )
    }

    func tabManager(
        _ tabManager: any TabManager,
        didRemoveTab tab: Tab,
        isRestoring: Bool
    ) {
        guard tab.isPrivate else { return }
        closePrivateWebPanelSessionsIfNeeded(
            in: tabManager,
            selectedTabIsPrivate: tabManager.selectedTab?.isPrivate
        )
    }
}

struct FloorpDrawerLayoutMetrics {
    static let outsideDismissWidth: CGFloat = 44
    static let compactMaximumWidth: CGFloat = 420
    static let regularMinimumWidth: CGFloat = 360
    static let regularMaximumWidth: CGFloat = 480

    static func drawerWidth(
        availableWidth: CGFloat,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> CGFloat {
        let availableDrawerWidth = max(0, availableWidth - outsideDismissWidth)
        let preferredWidth: CGFloat
        switch horizontalSizeClass {
        case .regular:
            preferredWidth = min(
                max(availableWidth * 0.42, regularMinimumWidth),
                regularMaximumWidth
            )
        case .compact, .unspecified:
            preferredWidth = min(availableDrawerWidth, compactMaximumWidth)
        @unknown default:
            preferredWidth = min(availableDrawerWidth, compactMaximumWidth)
        }
        return min(preferredWidth, availableDrawerWidth)
    }

    static func dismissalTranslation(
        drawerWidth: CGFloat,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        layoutDirection == .rightToLeft ? -drawerWidth : drawerWidth
    }

    static func dismissalSwipeDirection(
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> UISwipeGestureRecognizer.Direction {
        layoutDirection == .rightToLeft ? .left : .right
    }

    static func exposedCornerMask(
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CACornerMask {
        if layoutDirection == .rightToLeft {
            return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
        return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

    static func sidebarWidth(configuredWidth: Int) -> CGFloat {
        CGFloat(min(max(configuredWidth, 44), 72))
    }
}

// MARK: - Drawer View Controller

/// A side drawer that slides in from the right, with a vertical icon sidebar
/// for panel switching (matching Floorp desktop's Panel Sidebar layout).
///
/// Layout:
/// ```
/// ┌─────────┬──────────────────┐
/// │ Sidebar │ Header: [✕]      │
/// │ (50px)  ├──────────────────┤
/// │         │ [🔍 Search...]   │
/// │  🔖     ├──────────────────┤
/// │  🕐     │                  │
/// │  📥     │ Content List     │
/// │         │ (BM/Hist/DL)     │
/// └─────────┴──────────────────┘
/// ```
struct FloorpNotesReorderSession: Equatable {
    let originalVisibleIDs: [String]
    let expectedRevision: UInt64
    private(set) var orderedVisibleIDs: [String]

    init(visibleIDs: [String], expectedRevision: UInt64) {
        self.originalVisibleIDs = visibleIDs
        self.expectedRevision = expectedRevision
        self.orderedVisibleIDs = visibleIDs
    }

    var hasChanges: Bool {
        originalVisibleIDs != orderedVisibleIDs
    }

    mutating func move(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        guard orderedVisibleIDs.indices.contains(sourceIndex),
              orderedVisibleIDs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return false }
        let id = orderedVisibleIDs.remove(at: sourceIndex)
        orderedVisibleIDs.insert(id, at: destinationIndex)
        return true
    }

    mutating func move(id: String, offset: Int) -> Int? {
        guard let sourceIndex = orderedVisibleIDs.firstIndex(of: id) else { return nil }
        let destinationIndex = sourceIndex + offset
        guard orderedVisibleIDs.indices.contains(destinationIndex) else { return nil }
        return move(from: sourceIndex, to: destinationIndex) ? destinationIndex : nil
    }
}

private struct FloorpNoteMoveAnnouncement {
    let id: String
    let position: Int
    let total: Int
}

typealias FloorpNotesSnapshotLoader = @MainActor () async throws -> FloorpNotesSnapshot
typealias FloorpNotesReorderWriter = @MainActor (
    _ originalVisibleIDs: [String],
    _ orderedVisibleIDs: [String],
    _ expectedRevision: UInt64
) async throws -> Bool
typealias FloorpNoteAccessibilityFocusPoster = @MainActor (_ argument: Any?) -> Void

@MainActor
final class FloorpOverlayDrawerViewController:
    UIViewController,
    Themeable,
    FloorpPanelPrivacyModePresenting {
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?
    let windowUUID: WindowUUID
    var currentWindowUUID: UUID? { windowUUID }
    private let notificationCenter: NotificationProtocol

    // MARK: - Constants
    private enum UX {
        static let animationDuration: TimeInterval = 0.3
        static let cornerRadius: CGFloat = 16
        static let headerHeight: CGFloat = 52
        static let webPanelToolbarHeight: CGFloat = 44
        static let searchBarHeight: CGFloat = 44
        static let rowHeight: CGFloat = 56
        static let iconSize: CGFloat = 28
        static let sidebarIconSize: CGFloat = 22
        static let horizontalPadding: CGFloat = 16
        static let separatorHeight: CGFloat = 0.5
    }

    // MARK: - Properties
    private let panelManager: FloorpPanelManager
    private let presentationState: FloorpPanelPresentationState
    private let notesStore: FloorpNotesStore
    private let logger: Logger
    private let isPrivateProvider: @MainActor () -> Bool
    private let libraryPanelHost: (any FloorpLibraryPanelHosting)?
    private let registryFallbackRetryDelayNanoseconds: UInt64
    private let notesSnapshotLoader: FloorpNotesSnapshotLoader
    private let notesReorderWriter: FloorpNotesReorderWriter
    private let noteAccessibilityFocusPoster: FloorpNoteAccessibilityFocusPoster

    /// Callback when user taps a bookmark/history item.
    var onItemSelected: ((URL) -> Void)?

    /// Callback when drawer is dismissed.
    var onDismissed: (() -> Void)?

    /// Supplies a safe, non-private current page suggestion for a new web panel.
    var webPanelSuggestionProvider: (() -> FloorpWebPanelDraft?)?

    private var currentPanelType: FloorpPanelType = .bookmarks
    private var items = [DrawerItem]()
    private var filteredItems = [DrawerItem]()
    private var isSearching = false
    private var isCreatingNote = false
    private var notesRevision: UInt64?
    private var notesReorderSession: FloorpNotesReorderSession?
    private var isCommittingNotesReorder = false
    private var pendingNoteAccessibilityFocusID: String?
    private var pendingNoteAccessibilityFocusRequiresReload = false
    private var shouldFocusAddNoteButton = false
    private var panelLoadTask: Task<Void, Never>?
    private var notesLoadGeneration = UUID()
    private var isTransitioningDrawer = false
    private var didFinishDismissal = false
    private var dismissWhenPresentationFinishes = false
    private var displayedPanelIDs = [String]()
    private var activeWebPanelSession: (any FloorpWebPanelSessionProtocol)?
    private var webPanelFindController: FloorpWebPanelFindController?
    private var webPanelStateObserverID: UUID?
    private var explicitlyUnloadedWebPanelKey: FloorpWebPanelSessionKey?
    private var pendingRegistryFallbackIndex: Int?
    private var pendingRegistryFallbackRetryTask: Task<Void, Never>?
    private var pendingRegistryFallbackRetryID: UUID?

    // MARK: - UI Components

    // Background dimming overlay
    private lazy var dimmingView: UIControl = {
        let view = UIControl()
        view.alpha = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addTarget(self, action: #selector(dimmingViewTapped), for: .touchUpInside)
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "Floorp.Drawer.Dimming"
        return view
    }()

    // Main container
    private lazy var containerView: UIView = {
        let view = UIView()
        view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMinXMinYCorner]
        view.layer.cornerRadius = UX.cornerRadius
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = "Floorp.Drawer.Container"
        return view
    }()

    private lazy var dismissSwipeGesture: UISwipeGestureRecognizer = {
        let gesture = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        return gesture
    }()

    private var containerWidthConstraint: NSLayoutConstraint?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarStackWidthConstraint: NSLayoutConstraint?
    private var webPanelToolbarHeightConstraint: NSLayoutConstraint?

    // Sidebar (icon column)
    private lazy var sidebarView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var sidebarScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "Floorp.Drawer.PanelRail"
        return scrollView
    }()

    private lazy var sidebarStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .center
        sv.spacing = 4
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var addWebPanelButton: UIButton = {
        let button = makeRailActionButton(
            systemImageName: "plus",
            accessibilityLabel: FloorpStrings.PanelRegistry.addWebPanel,
            accessibilityIdentifier: "Floorp.Drawer.AddWebPanel"
        )
        button.addTarget(self, action: #selector(addWebPanelTapped), for: .touchUpInside)
        return button
    }()

    private lazy var managePanelsButton: UIButton = {
        let button = makeRailActionButton(
            systemImageName: "slider.horizontal.3",
            accessibilityLabel: FloorpStrings.PanelRegistry.title,
            accessibilityIdentifier: "Floorp.Drawer.ManagePanels"
        )
        button.addTarget(self, action: #selector(managePanelsTapped), for: .touchUpInside)
        return button
    }()

    // Header
    private lazy var headerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = FXFontStyles.Bold.headline.scaledFont()
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = FloorpStrings.Drawer.closeAccessibilityLabel
        button.accessibilityIdentifier = "Floorp.Drawer.Close"
        return button
    }()

    private lazy var addNoteButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "plus"), for: .normal)
        button.addTarget(self, action: #selector(addNoteTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = FloorpStrings.Notes.newNote
        button.accessibilityIdentifier = "Floorp.Notes.Add"
        button.isHidden = true
        return button
    }()

    private lazy var notesReorderButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
        button.addTarget(self, action: #selector(notesReorderTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = FloorpStrings.Notes.reorder
        button.accessibilityIdentifier = "Floorp.Notes.Reorder"
        button.isHidden = true
        return button
    }()

    private lazy var cancelNotesReorderButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        button.addTarget(self, action: #selector(cancelNotesReorderTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = FloorpStrings.Notes.cancel
        button.accessibilityIdentifier = "Floorp.Notes.Reorder.Cancel"
        button.isHidden = true
        return button
    }()

    private lazy var headerActionsStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [
            notesReorderButton,
            addNoteButton,
            cancelNotesReorderButton,
            closeButton,
        ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    private lazy var webPanelToolbarView: UIView = {
        let view = UIView()
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = "Floorp.WebPanel.Toolbar"
        return view
    }()

    private lazy var webPanelToolbarScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private lazy var webPanelBackButton = makeWebPanelToolbarButton(
        systemImageName: "chevron.backward",
        accessibilityLabel: FloorpStrings.Drawer.webPanelBack,
        accessibilityIdentifier: "Floorp.WebPanel.Back",
        action: #selector(webPanelBackTapped)
    )

    private lazy var webPanelForwardButton = makeWebPanelToolbarButton(
        systemImageName: "chevron.forward",
        accessibilityLabel: FloorpStrings.Drawer.webPanelForward,
        accessibilityIdentifier: "Floorp.WebPanel.Forward",
        action: #selector(webPanelForwardTapped)
    )

    private lazy var webPanelReloadButton = makeWebPanelToolbarButton(
        systemImageName: "arrow.clockwise",
        accessibilityLabel: FloorpStrings.Drawer.webPanelReload,
        accessibilityIdentifier: "Floorp.WebPanel.ReloadOrStop",
        action: #selector(webPanelReloadOrStopTapped)
    )

    private lazy var webPanelHomeButton = makeWebPanelToolbarButton(
        systemImageName: "house",
        accessibilityLabel: FloorpStrings.Drawer.webPanelHome,
        accessibilityIdentifier: "Floorp.WebPanel.Home",
        action: #selector(webPanelHomeTapped)
    )

    private lazy var webPanelFindButton = makeWebPanelToolbarButton(
        systemImageName: "magnifyingglass",
        accessibilityLabel: FloorpStrings.Drawer.webPanelFind,
        accessibilityIdentifier: "Floorp.WebPanel.Find",
        action: #selector(webPanelFindTapped)
    )

    private lazy var webPanelOpenInMainButton = makeWebPanelToolbarButton(
        systemImageName: "arrow.up.right.square",
        accessibilityLabel: FloorpStrings.Drawer.webPanelOpenInMainBrowser,
        accessibilityIdentifier: "Floorp.WebPanel.OpenInMainBrowser",
        action: #selector(webPanelOpenInMainBrowserTapped)
    )

    private lazy var webPanelToolbarStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [
            webPanelBackButton,
            webPanelForwardButton,
            webPanelReloadButton,
            webPanelHomeButton,
            webPanelFindButton,
            webPanelOpenInMainButton,
        ])
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    // Search bar
    private lazy var searchTextField: UITextField = {
        let tf = UITextField()
        tf.placeholder = FloorpStrings.Drawer.searchPlaceholder
        tf.font = FXFontStyles.Regular.subheadline.scaledFont()
        tf.adjustsFontForContentSizeCategory = true
        tf.clearButtonMode = .whileEditing
        tf.returnKeyType = .search
        tf.layer.cornerRadius = 10
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        tf.leftViewMode = .always
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.accessibilityLabel = FloorpStrings.Drawer.searchFieldAccessibility
        tf.accessibilityIdentifier = "Floorp.Notes.Search"
        tf.delegate = self
        tf.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        return tf
    }()

    // Content table
    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.register(DrawerItemCell.self, forCellReuseIdentifier: DrawerItemCell.reuseIdentifier)
        tv.dataSource = self
        tv.delegate = self
        tv.separatorInset = UIEdgeInsets(top: 0, left: UX.horizontalPadding, bottom: 0, right: 0)
        tv.cellLayoutMarginsFollowReadableWidth = false
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = UX.rowHeight
        tv.keyboardDismissMode = .interactive
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.accessibilityIdentifier = "Floorp.Drawer.Content"
        return tv
    }()

    private lazy var webPanelContainerView: UIView = {
        let view = UIView()
        view.isHidden = true
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = "Floorp.Drawer.WebPanelContent"
        return view
    }()

    private lazy var nativeContentContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = "Floorp.Drawer.NativeLibraryContent"
        view.isHidden = true
        return view
    }()

    // Empty state
    private lazy var emptyStateLabel: UILabel = {
        let label = UILabel()
        label.font = FXFontStyles.Regular.subheadline.scaledFont()
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.isHidden = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(FloorpStrings.Drawer.retryButton, for: .normal)
        button.titleLabel?.font = FXFontStyles.Bold.subheadline.scaledFont()
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private var currentRetryAction: (() -> Void)?

    // Sidebar buttons (one per panel)
    private var sidebarButtons: [UIButton] = []

    // MARK: - Initialization

    init(panelManager: FloorpPanelManager = .shared,
         notesStore: FloorpNotesStore = .shared,
         logger: Logger = DefaultLogger.shared,
         presentationState: FloorpPanelPresentationState? = nil,
         libraryPanelHost: (any FloorpLibraryPanelHosting)? = nil,
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         notificationCenter: NotificationProtocol = NotificationCenter.default,
         isPrivateProvider: @escaping @MainActor () -> Bool = { false },
         registryFallbackRetryDelayNanoseconds: UInt64 = 250_000_000,
         notesSnapshotLoader: FloorpNotesSnapshotLoader? = nil,
         notesReorderWriter: FloorpNotesReorderWriter? = nil,
         noteAccessibilityFocusPoster: @escaping FloorpNoteAccessibilityFocusPoster = {
             UIAccessibility.post(notification: .layoutChanged, argument: $0)
         }) {
        let presentationState = presentationState ?? FloorpPanelPresentationState(
            windowUUID: WindowUUID.XCTestDefaultUUID
        )
        self.panelManager = panelManager
        self.presentationState = presentationState
        self.notesStore = notesStore
        self.logger = logger
        self.libraryPanelHost = libraryPanelHost
        self.windowUUID = presentationState.windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.isPrivateProvider = isPrivateProvider
        self.registryFallbackRetryDelayNanoseconds = registryFallbackRetryDelayNanoseconds
        self.notesSnapshotLoader = notesSnapshotLoader ?? {
            try await notesStore.loadSnapshot()
        }
        self.notesReorderWriter = notesReorderWriter ?? {
            try await notesStore.reorderVisibleNotes(
                originalVisibleIDs: $0,
                orderedVisibleIDs: $1,
                expectedRevision: $2
            )
        }
        self.noteAccessibilityFocusPoster = noteAccessibilityFocusPoster
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        panelLoadTask?.cancel()
        pendingRegistryFallbackRetryTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        setupConstraints()
        presentationState.webPanelSessionStore?.reconcile(with: panelManager.panels)
        buildSidebarButtons()
        if let selectedPanel = presentationState.selectedPanel(in: panelManager.panels) {
            selectPanel(selectedPanel.id)
        }
        loadCurrentPanel()
        notificationCenter.addObserver(
            self,
            selector: #selector(notesDidChange(_:)),
            name: .FloorpNotesDidChange,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(panelRegistryDidChange),
            name: .FloorpPanelRegistryDidChange,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(libraryPanelStateDidChange(_:)),
            name: .LibraryPanelStateDidChange,
            object: nil
        )
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
        logger.log("Floorp: OverlayDrawer loaded", level: .info, category: .setup)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // BrowserViewController has upstream paths that dismiss whichever
        // modal is presented. Release its associated drawer in those paths as
        // well as in dismissDrawer(), without treating a child editor as a
        // drawer dismissal.
        if isBeingDismissed || presentingViewController == nil {
            finishDismissal()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentPendingNotesOperationErrorIfPossible() else { return }
        applyPendingNoteAccessibilityFocus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDrawerGeometry(availableWidth: view.bounds.width)
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            guard let self else { return }
            self.updateDrawerGeometry(availableWidth: size.width)
            self.view.layoutIfNeeded()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(
                title: FloorpStrings.Drawer.closeAccessibilityLabel,
                action: #selector(closeTapped),
                input: "d",
                modifierFlags: [.command, .shift]
            ),
            UIKeyCommand(
                title: FloorpStrings.Drawer.closeAccessibilityLabel,
                action: #selector(handleEscapeKeyCommand),
                input: UIKeyCommand.inputEscape,
                modifierFlags: []
            ),
        ]
        guard currentPanelType == .web,
              activeWebPanelSession != nil,
              webPanelFindController != nil else {
            return commands
        }
        commands.append(contentsOf: [
            UIKeyCommand(
                title: FloorpStrings.Drawer.webPanelFind,
                action: #selector(webPanelFindTapped),
                input: "f",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: FloorpStrings.Drawer.webPanelFindNext,
                action: #selector(webPanelFindNextKeyCommand),
                input: "g",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: FloorpStrings.Drawer.webPanelFindPrevious,
                action: #selector(webPanelFindPreviousKeyCommand),
                input: "g",
                modifierFlags: [.command, .shift]
            ),
        ])
        return commands
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !isCommittingNotesReorder else { return false }
        if webPanelFindController?.dismissIfActive() == true {
            return true
        }
        dismissDrawer()
        return true
    }

    // MARK: - Setup

    private func setupView() {
        view.backgroundColor = .clear

        // Dimming overlay behind the drawer
        view.addSubview(dimmingView)
        view.addSubview(containerView)

        // Container layout: sidebar | content
        containerView.addSubview(sidebarView)
        containerView.addSubview(headerView)
        containerView.addSubview(webPanelToolbarView)
        containerView.addSubview(searchTextField)
        containerView.addSubview(tableView)
        containerView.addSubview(webPanelContainerView)
        containerView.addSubview(nativeContentContainerView)
        containerView.addSubview(emptyStateLabel)
        containerView.addSubview(retryButton)

        headerView.addSubview(titleLabel)
        headerView.addSubview(headerActionsStackView)
        webPanelToolbarView.addSubview(webPanelToolbarScrollView)
        webPanelToolbarScrollView.addSubview(webPanelToolbarStackView)

        sidebarView.addSubview(sidebarScrollView)
        sidebarScrollView.addSubview(sidebarStackView)
        sidebarView.addSubview(managePanelsButton)

        containerView.addGestureRecognizer(dismissSwipeGesture)
    }

    private func setupConstraints() {
        let initialWidth = FloorpDrawerLayoutMetrics.drawerWidth(
            availableWidth: view.bounds.width,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
        let containerWidthConstraint = containerView.widthAnchor.constraint(equalToConstant: initialWidth)
        let sidebarWidth = FloorpDrawerLayoutMetrics.sidebarWidth(
            configuredWidth: panelManager.config.sidebarWidth
        )
        let sidebarWidthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let sidebarStackWidthConstraint = sidebarStackView.widthAnchor.constraint(
            equalToConstant: max(0, sidebarWidth - 8)
        )
        let tableSafeAreaBottomConstraint = tableView.bottomAnchor.constraint(
            equalTo: containerView.safeAreaLayoutGuide.bottomAnchor
        )
        let webPanelToolbarHeightConstraint = webPanelToolbarView.heightAnchor.constraint(
            equalToConstant: 0
        )
        tableSafeAreaBottomConstraint.priority = .defaultHigh
        self.containerWidthConstraint = containerWidthConstraint
        self.sidebarWidthConstraint = sidebarWidthConstraint
        self.sidebarStackWidthConstraint = sidebarStackWidthConstraint
        self.webPanelToolbarHeightConstraint = webPanelToolbarHeightConstraint

        let constraints = [
            // Dimming view fills entire screen
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Container: right-aligned, full height
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: FloorpDrawerLayoutMetrics.outsideDismissWidth
            ),
            containerWidthConstraint,

            // Sidebar
            sidebarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            sidebarWidthConstraint,

            // Header
            headerView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            headerView.trailingAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.trailingAnchor
            ),
            headerView.heightAnchor.constraint(equalToConstant: UX.headerHeight),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: UX.horizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: headerActionsStackView.leadingAnchor,
                constant: -8
            ),

            headerActionsStackView.trailingAnchor.constraint(
                equalTo: headerView.trailingAnchor,
                constant: -UX.horizontalPadding
            ),
            headerActionsStackView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        NSLayoutConstraint.activate(headerActionConstraints)
        NSLayoutConstraint.activate(contentConstraints(
            tableSafeAreaBottomConstraint: tableSafeAreaBottomConstraint
        ))
        NSLayoutConstraint.activate(nativeContentConstraints)
        NSLayoutConstraint.activate(webPanelToolbarConstraints(
            heightConstraint: webPanelToolbarHeightConstraint
        ))
        NSLayoutConstraint.activate(panelRailConstraints(
            sidebarStackWidthConstraint: sidebarStackWidthConstraint
        ))
    }

    private func contentConstraints(
        tableSafeAreaBottomConstraint: NSLayoutConstraint
    ) -> [NSLayoutConstraint] {
        [
            // Search bar
            searchTextField.topAnchor.constraint(
                equalTo: webPanelToolbarView.bottomAnchor, constant: 4
            ),
            searchTextField.leadingAnchor.constraint(
                equalTo: sidebarView.trailingAnchor,
                constant: UX.horizontalPadding
            ),
            searchTextField.trailingAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.trailingAnchor,
                constant: -UX.horizontalPadding
            ),
            searchTextField.heightAnchor.constraint(
                equalToConstant: UX.searchBarHeight
            ),

            // Table view
            tableView.topAnchor.constraint(
                equalTo: searchTextField.bottomAnchor, constant: 8
            ),
            tableView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            tableView.trailingAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.trailingAnchor
            ),
            tableView.bottomAnchor.constraint(
                lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor
            ),
            tableSafeAreaBottomConstraint,

            // Web panel content stays inside the drawer and below its header,
            // independently from the browser's address toolbar hierarchy.
            webPanelContainerView.topAnchor.constraint(equalTo: webPanelToolbarView.bottomAnchor),
            webPanelContainerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            webPanelContainerView.trailingAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.trailingAnchor
            ),
            webPanelContainerView.bottomAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.bottomAnchor
            ),

            // Empty state
            emptyStateLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor, constant: -20),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: tableView.leadingAnchor,
                constant: UX.horizontalPadding
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: tableView.trailingAnchor,
                constant: -UX.horizontalPadding
            ),

            // Retry button
            retryButton.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: emptyStateLabel.bottomAnchor, constant: 12),
        ]
    }

    private func webPanelToolbarConstraints(
        heightConstraint: NSLayoutConstraint
    ) -> [NSLayoutConstraint] {
        [
            webPanelToolbarView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webPanelToolbarView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            webPanelToolbarView.trailingAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.trailingAnchor
            ),
            heightConstraint,
            webPanelToolbarScrollView.topAnchor.constraint(equalTo: webPanelToolbarView.topAnchor),
            webPanelToolbarScrollView.leadingAnchor.constraint(
                equalTo: webPanelToolbarView.leadingAnchor
            ),
            webPanelToolbarScrollView.trailingAnchor.constraint(
                equalTo: webPanelToolbarView.trailingAnchor
            ),
            webPanelToolbarScrollView.bottomAnchor.constraint(
                equalTo: webPanelToolbarView.bottomAnchor
            ),
            webPanelToolbarStackView.topAnchor.constraint(
                equalTo: webPanelToolbarScrollView.contentLayoutGuide.topAnchor
            ),
            webPanelToolbarStackView.leadingAnchor.constraint(
                equalTo: webPanelToolbarScrollView.contentLayoutGuide.leadingAnchor,
                constant: 8
            ),
            webPanelToolbarStackView.trailingAnchor.constraint(
                equalTo: webPanelToolbarScrollView.contentLayoutGuide.trailingAnchor,
                constant: -8
            ),
            webPanelToolbarStackView.bottomAnchor.constraint(
                equalTo: webPanelToolbarScrollView.contentLayoutGuide.bottomAnchor
            ),
            webPanelToolbarStackView.heightAnchor.constraint(
                equalTo: webPanelToolbarScrollView.frameLayoutGuide.heightAnchor
            ),
        ]
    }

    private var headerActionConstraints: [NSLayoutConstraint] {
        [
            notesReorderButton.widthAnchor.constraint(equalToConstant: 44),
            notesReorderButton.heightAnchor.constraint(equalToConstant: 44),
            addNoteButton.widthAnchor.constraint(equalToConstant: 44),
            addNoteButton.heightAnchor.constraint(equalToConstant: 44),
            cancelNotesReorderButton.widthAnchor.constraint(equalToConstant: 44),
            cancelNotesReorderButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ]
    }

    private var nativeContentConstraints: [NSLayoutConstraint] {
        [
            nativeContentContainerView.topAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.topAnchor
            ),
            nativeContentContainerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            nativeContentContainerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            nativeContentContainerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ]
    }

    /// Keeps the scrollable rail independent from the content constraints so
    /// adding panel-management controls does not make layout setup monolithic.
    private func panelRailConstraints(
        sidebarStackWidthConstraint: NSLayoutConstraint
    ) -> [NSLayoutConstraint] {
        [
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 8),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: managePanelsButton.topAnchor, constant: -4),
            sidebarStackView.topAnchor.constraint(
                equalTo: sidebarScrollView.contentLayoutGuide.topAnchor,
                constant: 4
            ),
            sidebarStackView.centerXAnchor.constraint(
                equalTo: sidebarScrollView.frameLayoutGuide.centerXAnchor
            ),
            sidebarStackView.bottomAnchor.constraint(
                equalTo: sidebarScrollView.contentLayoutGuide.bottomAnchor,
                constant: -4
            ),
            sidebarStackWidthConstraint,
            managePanelsButton.centerXAnchor.constraint(equalTo: sidebarView.centerXAnchor),
            managePanelsButton.bottomAnchor.constraint(
                equalTo: containerView.safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            managePanelsButton.widthAnchor.constraint(equalToConstant: 44),
            managePanelsButton.heightAnchor.constraint(equalToConstant: 44),
        ]
    }

    private func updateDrawerGeometry(availableWidth: CGFloat) {
        let layoutDirection = view.effectiveUserInterfaceLayoutDirection
        containerWidthConstraint?.constant = FloorpDrawerLayoutMetrics.drawerWidth(
            availableWidth: availableWidth,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
        let sidebarWidth = FloorpDrawerLayoutMetrics.sidebarWidth(
            configuredWidth: panelManager.config.sidebarWidth
        )
        sidebarWidthConstraint?.constant = sidebarWidth
        sidebarStackWidthConstraint?.constant = max(0, sidebarWidth - 8)
        dismissSwipeGesture.direction = FloorpDrawerLayoutMetrics.dismissalSwipeDirection(
            layoutDirection: layoutDirection
        )
        containerView.layer.maskedCorners = FloorpDrawerLayoutMetrics.exposedCornerMask(
            layoutDirection: layoutDirection
        )
    }

    // MARK: - Themeable

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let colors = theme.colors

        view.backgroundColor = .clear

        // Dimming overlay
        dimmingView.backgroundColor = colors.layerScrim.withAlphaComponent(0.4)

        // Main container
        containerView.backgroundColor = colors.layer1
        containerView.layer.borderColor = colors.borderPrimary.cgColor
        containerView.layer.borderWidth = 0.5

        // Sidebar
        sidebarView.backgroundColor = colors.layer3
        addWebPanelButton.tintColor = colors.iconSecondary
        managePanelsButton.tintColor = colors.iconSecondary

        // Header
        headerView.backgroundColor = colors.layer1
        titleLabel.textColor = colors.textPrimary
        closeButton.tintColor = colors.iconSecondary
        addNoteButton.tintColor = colors.actionPrimary
        webPanelToolbarView.backgroundColor = colors.layer1
        [
            webPanelBackButton,
            webPanelForwardButton,
            webPanelReloadButton,
            webPanelHomeButton,
            webPanelFindButton,
            webPanelOpenInMainButton,
        ].forEach { $0.tintColor = colors.iconPrimary }
        webPanelFindController?.applyTheme(
            backgroundColor: colors.layer1,
            textColor: colors.textPrimary,
            secondaryTextColor: colors.textSecondary,
            tintColor: colors.iconPrimary
        )

        // Search bar
        searchTextField.backgroundColor = colors.layer3
        searchTextField.textColor = colors.textPrimary
        searchTextField.attributedPlaceholder = NSAttributedString(
            string: searchTextField.placeholder ?? FloorpStrings.Drawer.searchPlaceholder,
            attributes: [.foregroundColor: colors.textSecondary]
        )

        // Table view — use layer5 for cell-like background
        tableView.backgroundColor = colors.layer5
        tableView.separatorColor = colors.borderPrimary
        webPanelContainerView.backgroundColor = colors.layer1

        // Empty state
        emptyStateLabel.textColor = colors.textSecondary
        retryButton.setTitleColor(colors.actionPrimary, for: .normal)

        // Sidebar buttons
        updateSidebarSelection()

        // Force reload all visible cells with proper theme
        tableView.reloadData()
    }

    // MARK: - Sidebar Buttons

    private func buildSidebarButtons() {
        sidebarStackView.arrangedSubviews.forEach {
            sidebarStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        sidebarButtons.removeAll()

        for panel in panelManager.panels {
            let button = createSidebarButton(for: panel)
            sidebarStackView.addArrangedSubview(button)
            sidebarButtons.append(button)
        }
        sidebarStackView.addArrangedSubview(addWebPanelButton)
        displayedPanelIDs = panelManager.panels.map(\.id)
    }

    private func makeRailActionButton(
        systemImageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemImageName), for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityHint = FloorpStrings.Drawer.panelSidebarAccessibility
        button.accessibilityIdentifier = accessibilityIdentifier
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    private func makeWebPanelToolbarButton(
        systemImageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemImageName), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
        button.isEnabled = false
        button.isPointerInteractionEnabled = true
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func createSidebarButton(for panel: FloorpPanel) -> UIButton {
        let button = UIButton(type: .system)
        let icon = UIImage(systemName: displayIconName(for: panel))
            ?? UIImage(systemName: "square.dashed")
        button.setImage(icon, for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = displayTitle(for: panel)
        button.accessibilityHint = FloorpStrings.Drawer.panelSidebarAccessibility
        if panel.type == .web, (try? FloorpWebPanelValidator.validate(panel)) == nil {
            button.accessibilityValue = FloorpStrings.PanelRegistry.needsAttention
        }

        button.addTarget(self, action: #selector(sidebarButtonTapped(_:)), for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Store panel ID in accessibility identifier for retrieval
        button.accessibilityIdentifier = panel.id
        button.menu = makeSidebarMenu(for: panel)

        return button
    }

    private func makeSidebarMenu(for panel: FloorpPanel) -> UIMenu {
        guard let index = panelManager.panels.firstIndex(where: { $0.id == panel.id }) else {
            return UIMenu(children: [])
        }
        var actions = [UIMenuElement]()
        if panel.type == .web {
            actions.append(UIAction(
                title: FloorpStrings.PanelRegistry.edit,
                image: UIImage(systemName: "pencil"),
                handler: { [weak self] _ in self?.presentPanelRegistry(editingPanelID: panel.id) }
            ))
        }
        actions.append(UIAction(
            title: FloorpStrings.PanelRegistry.moveUp,
            image: UIImage(systemName: "arrow.up"),
            attributes: index == panelManager.panels.startIndex ? .disabled : [],
            handler: { [weak self] _ in self?.movePanel(id: panel.id, offset: -1) }
        ))
        actions.append(UIAction(
            title: FloorpStrings.PanelRegistry.moveDown,
            image: UIImage(systemName: "arrow.down"),
            attributes: index == panelManager.panels.index(before: panelManager.panels.endIndex)
                ? .disabled
                : [],
            handler: { [weak self] _ in self?.movePanel(id: panel.id, offset: 1) }
        ))
        actions.append(UIAction(
            title: panel.type == .web
                ? FloorpStrings.PanelRegistry.delete
                : FloorpStrings.PanelRegistry.removeFromSidebar,
            image: UIImage(systemName: panel.type == .web ? "trash" : "sidebar.left"),
            attributes: panel.type == .web ? .destructive : [],
            handler: { [weak self] _ in self?.requestPanelRemoval(id: panel.id) }
        ))
        return UIMenu(children: actions)
    }

    private func displayTitle(for panel: FloorpPanel) -> String {
        if panel.type == .web {
            return panel.safeDisplayTitle ?? FloorpStrings.PanelRegistry.needsAttention
        }
        return panel.type.localizedBuiltInTitle ?? FloorpStrings.PanelRegistry.builtInPanel
    }

    private func displayIconName(for panel: FloorpPanel) -> String {
        if panel.type == .web {
            return FloorpWebPanelValidator.curatedIconNames.contains(panel.iconName)
                ? panel.iconName
                : FloorpPanelType.web.systemIconName
        }
        return panel.iconName
    }

    private func updateSidebarSelection() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let colors = theme.colors
        for button in sidebarButtons {
            let panelId = button.accessibilityIdentifier ?? ""
            let isSelected = panelId == presentationState.selectedPanelId
            button.tintColor = isSelected ? colors.iconAccent : colors.iconSecondary
            button.backgroundColor = isSelected ? colors.actionPrimary.withAlphaComponent(0.12) : .clear
            if isSelected {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }
    }

    @objc private func sidebarButtonTapped(_ sender: UIButton) {
        guard let panelId = sender.accessibilityIdentifier,
              let panel = panelManager.panel(for: panelId),
              canSelectPanel(panel) else { return }
        if explicitlyUnloadedWebPanelKey?.panelID == panelId {
            explicitlyUnloadedWebPanelKey = nil
        }
        selectPanel(panelId)
        loadCurrentPanel()
    }

    @objc private func addWebPanelTapped() {
        guard canLeaveCurrentPanel else { return }
        presentPanelRegistry(presentsAddEditor: true)
    }

    @objc private func managePanelsTapped() {
        guard canLeaveCurrentPanel else { return }
        presentPanelRegistry()
    }

    func presentPanelRegistry(
        editingPanelID: String? = nil,
        presentsAddEditor: Bool = false
    ) {
        guard canLeaveCurrentPanel,
              presentedViewController == nil else { return }
        let registry = FloorpPanelRegistryViewController(
            panelManager: panelManager,
            windowUUID: windowUUID,
            webPanelSuggestion: webPanelSuggestionProvider?(),
            themeManager: themeManager,
            notificationCenter: notificationCenter
        )
        let navigationController = UINavigationController(rootViewController: registry)
        navigationController.modalPresentationStyle = traitCollection.horizontalSizeClass == .regular
            ? .formSheet
            : .pageSheet
        registry.onDone = { [weak navigationController] in
            navigationController?.dismiss(animated: true)
        }
        present(navigationController, animated: true) {
            if presentsAddEditor {
                registry.presentEditor(for: nil)
            } else if let editingPanelID {
                registry.presentEditor(for: editingPanelID)
            }
        }
    }

    func movePanel(id: String, offset: Int) {
        guard canLeaveCurrentPanel,
              let currentIndex = panelManager.panels.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = currentIndex + offset
        guard panelManager.panels.indices.contains(destinationIndex) else { return }
        do {
            try panelManager.movePanel(id: id, to: destinationIndex)
            let panelTitle = panelManager.panel(for: id).map(displayTitle(for:)) ?? ""
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.PanelRegistry.moveAnnouncement(
                    title: panelTitle,
                    position: destinationIndex + 1
                )
            )
        } catch {
            presentPanelOperationError(error)
        }
    }

    func requestPanelRemoval(id: String) {
        guard canLeaveCurrentPanel,
              presentedViewController == nil,
              let panel = panelManager.panel(for: id) else { return }
        guard panelManager.panels.count > 1 else {
            let alert = UIAlertController(
                title: FloorpStrings.PanelRegistry.lastPanelTitle,
                message: FloorpStrings.PanelRegistry.lastPanelMessage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.done, style: .default))
            present(alert, animated: true)
            return
        }

        let title = displayTitle(for: panel)
        let isWebPanel = panel.type == .web
        let alert = UIAlertController(
            title: isWebPanel
                ? FloorpStrings.PanelRegistry.deleteWebPanelTitle
                : FloorpStrings.PanelRegistry.removeBuiltInTitle,
            message: isWebPanel
                ? FloorpStrings.PanelRegistry.deleteWebPanelMessage(title: title)
                : FloorpStrings.PanelRegistry.removeBuiltInMessage(title: title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.cancel, style: .cancel))
        alert.addAction(UIAlertAction(
            title: isWebPanel
                ? FloorpStrings.PanelRegistry.delete
                : FloorpStrings.PanelRegistry.removeFromSidebar,
            style: isWebPanel ? .destructive : .default,
            handler: { [weak self] _ in
                do {
                    try self?.panelManager.removePanel(id: id)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: FloorpStrings.PanelRegistry.removedAnnouncement(title: title)
                    )
                } catch {
                    DispatchQueue.main.async {
                        self?.presentPanelOperationError(error)
                    }
                }
            }
        ))
        present(alert, animated: true)
    }

    private func presentPanelOperationError(_ error: Error) {
        logger.log(
            "Floorp: Panel registry operation failed: \(error.localizedDescription)",
            level: .warning,
            category: .setup
        )
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: FloorpStrings.PanelRegistry.operationFailedTitle,
            message: FloorpStrings.PanelRegistry.operationFailedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.done, style: .default))
        present(alert, animated: true)
    }

    @objc private func panelRegistryDidChange() {
        guard isViewLoaded else { return }
        presentationState.webPanelSessionStore?.reconcile(with: panelManager.panels)
        let previousPanelIDs = displayedPanelIDs
        let previousSelection = presentationState.selectedPanelId
        buildSidebarButtons()

        if let previousSelection,
           let selectedPanel = panelManager.panel(for: previousSelection) {
            clearPendingRegistryFallback()
            selectPanel(selectedPanel.id)
            if selectedPanel.type == .web {
                loadCurrentPanel()
            }
            return
        }

        guard !panelManager.panels.isEmpty else {
            pendingRegistryFallbackIndex = pendingRegistryFallbackIndex
                ?? previousSelection.flatMap { previousPanelIDs.firstIndex(of: $0) }
                ?? 0
            cancelPendingRegistryFallbackRetry()
            panelLoadTask?.cancel()
            items = []
            filteredItems = []
            tableView.reloadData()
            return
        }

        let previousIndex = pendingRegistryFallbackIndex
            ?? previousSelection.flatMap { previousPanelIDs.firstIndex(of: $0) }
            ?? 0
        guard canLeaveCurrentPanel else {
            pendingRegistryFallbackIndex = previousIndex
            schedulePendingRegistryFallbackRetry()
            return
        }
        applyRegistryFallback(at: previousIndex)
    }

    @objc private func libraryPanelStateDidChange(_ notification: Notification) {
        guard notification.windowUUID == windowUUID,
              let pendingRegistryFallbackIndex,
              canLeaveCurrentPanel else { return }
        applyRegistryFallback(at: pendingRegistryFallbackIndex)
    }

    private func applyRegistryFallback(at previousIndex: Int) {
        guard !panelManager.panels.isEmpty else { return }
        clearPendingRegistryFallback()
        let fallbackIndex = min(previousIndex, panelManager.panels.count - 1)
        let fallbackPanel = panelManager.panels[fallbackIndex]
        selectPanel(fallbackPanel.id)
        loadCurrentPanel()
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    private func selectPanel(_ panelId: String) {
        guard let panel = panelManager.panel(for: panelId) else { return }
        clearPendingRegistryFallback()
        if currentPanelType == .notes, panel.type != .notes {
            endNotesReordering(reload: false)
        }
        currentPanelType = panel.type
        presentationState.select(panel)
        let panelTitle = displayTitle(for: panel)
        titleLabel.text = panel.type == .notes
            ? "\(panelTitle) · \(FloorpStrings.Notes.localOnly)"
            : panelTitle
        titleLabel.accessibilityValue = panel.type == .notes ? FloorpStrings.Notes.localOnly : nil
        addNoteButton.isHidden = panel.type != .notes
        notesReorderButton.isHidden = panel.type != .notes
        cancelNotesReorderButton.isHidden = true
        searchTextField.placeholder = panel.type == .notes
            ? FloorpStrings.Notes.searchPlaceholder
            : FloorpStrings.Drawer.searchPlaceholder
        searchTextField.accessibilityIdentifier = panel.type == .notes
            ? "Floorp.Notes.Search"
            : "Floorp.Drawer.Search"
        updateNotesReorderControls()
        updateSidebarSelection()
    }

    private func schedulePendingRegistryFallbackRetry() {
        guard pendingRegistryFallbackRetryTask == nil else { return }
        let retryID = UUID()
        let retryDelayNanoseconds = registryFallbackRetryDelayNanoseconds
        pendingRegistryFallbackRetryID = retryID
        pendingRegistryFallbackRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    break
                }

                guard let self,
                      let pendingRegistryFallbackIndex = self.pendingRegistryFallbackIndex else {
                    break
                }
                guard self.canLeaveCurrentPanel else { continue }
                self.applyRegistryFallback(at: pendingRegistryFallbackIndex)
                break
            }

            guard self?.pendingRegistryFallbackRetryID == retryID else { return }
            self?.pendingRegistryFallbackRetryTask = nil
            self?.pendingRegistryFallbackRetryID = nil
        }
    }

    private func clearPendingRegistryFallback() {
        pendingRegistryFallbackIndex = nil
        cancelPendingRegistryFallbackRetry()
    }

    private func cancelPendingRegistryFallbackRetry() {
        pendingRegistryFallbackRetryID = nil
        pendingRegistryFallbackRetryTask?.cancel()
        pendingRegistryFallbackRetryTask = nil
    }

    // MARK: - Data Loading

    private func loadCurrentPanel(webPanelPrivacyMode: Bool? = nil) {
        panelLoadTask?.cancel()
        notesLoadGeneration = UUID()
        let requestedWebPanelPrivacyMode = webPanelPrivacyMode
            ?? (currentPanelType == .web ? isPrivateProvider() : false)
        let keepsActiveWebPanelVisible = currentPanelType == .web
            && activeWebPanelSession?.key.panelID == presentationState.selectedPanelId
            && activeWebPanelSession?.key.isPrivate == requestedWebPanelPrivacyMode
        detachWebPanelContent(applyHiddenLifecycle: !keepsActiveWebPanelVisible)
        endNotesReordering(reload: false)
        setWebPanelToolbarVisible(currentPanelType == .web)
        items = []
        filteredItems = []
        notesRevision = nil
        searchTextField.text = nil
        searchTextField.isEnabled = true
        addNoteButton.isEnabled = currentPanelType == .notes && !isCreatingNote
        isSearching = false
        emptyStateLabel.isHidden = true
        retryButton.isHidden = true
        currentRetryAction = nil
        searchTextField.isHidden = false
        tableView.isHidden = false
        webPanelContainerView.isHidden = true
        tableView.reloadData()

        if currentPanelType.usesNativeLibrary,
           showNativeLibraryPanel(currentPanelType) {
            return
        }

        hideNativeLibraryPanel()
        setLegacyContentHidden(false)

        switch currentPanelType {
        case .bookmarks:
            loadBookmarks()
        case .history:
            loadHistory()
        case .downloads:
            loadDownloads()
        case .notes:
            loadNotes()
        case .web:
            loadWebPanel(isPrivate: requestedWebPanelPrivacyMode)
        }
    }

    private func loadWebPanel(isPrivate: Bool) {
        searchTextField.isHidden = true
        tableView.isHidden = true
        emptyStateLabel.isHidden = true
        retryButton.isHidden = true

        guard let panelID = presentationState.selectedPanelId,
              let panel = panelManager.panel(for: panelID),
              panel.type == .web,
              let sessionStore = presentationState.webPanelSessionStore else {
            showWebPanelUnavailable()
            return
        }

        let requestedKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: panel.id,
            isPrivate: isPrivate
        )
        guard explicitlyUnloadedWebPanelKey != requestedKey else {
            showWebPanelUnloaded()
            return
        }
        do {
            let session = try sessionStore.session(for: panel, isPrivate: isPrivate)
            guard session.key.windowUUID == windowUUID,
                  session.key.panelID == panel.id,
                  session.key.isPrivate == isPrivate,
                  let contentView = session.contentView else {
                showWebPanelUnavailable()
                return
            }

            activeWebPanelSession = session
            session.setVisible(true)
            contentView.removeFromSuperview()
            contentView.translatesAutoresizingMaskIntoConstraints = false
            webPanelContainerView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: webPanelContainerView.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: webPanelContainerView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: webPanelContainerView.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: webPanelContainerView.bottomAnchor),
            ])
            installWebPanelFindController(for: session)
            webPanelContainerView.isHidden = false
            let sessionKey = session.key
            renderWebPanelState(session.state, expectedKey: sessionKey)
            webPanelStateObserverID = session.addStateObserver { [weak self] state in
                self?.renderWebPanelState(state, expectedKey: sessionKey)
            }
        } catch {
            showWebPanelUnavailable()
        }
    }

    private func renderWebPanelState(
        _ state: FloorpWebPanelSessionState,
        expectedKey: FloorpWebPanelSessionKey
    ) {
        guard activeWebPanelSession?.key == expectedKey else { return }
        // The persisted, validated panel title is safe for initial rendering;
        // arbitrary document titles are deliberately not promoted into chrome.
        titleLabel.text = state.configuration.panelTitle
        titleLabel.accessibilityValue = nil
        webPanelContainerView.accessibilityValue = state.isLoading
            ? String(Int(state.estimatedProgress * 100)) + "%"
            : nil
        renderWebPanelToolbarState(state)
    }

    private func detachWebPanelContent(applyHiddenLifecycle: Bool = true) {
        let session = activeWebPanelSession
        removeWebPanelFindController()
        if let webPanelStateObserverID {
            session?.removeStateObserver(webPanelStateObserverID)
        }
        webPanelStateObserverID = nil
        session?.contentView?.removeFromSuperview()
        if applyHiddenLifecycle, let session {
            let wasHandled = presentationState.webPanelSessionStore?.hideSession(
                session,
                autoUnload: panelManager.config.autoUnload
            ) == true
            if !wasHandled {
                session.setVisible(false)
            }
        }
        activeWebPanelSession = nil
        webPanelContainerView.isHidden = true
        webPanelContainerView.accessibilityValue = nil
        renderWebPanelToolbarState(nil)
    }

    private func installWebPanelFindController(
        for session: any FloorpWebPanelSessionProtocol
    ) {
        removeWebPanelFindController()
        guard let target = session.findTarget else { return }
        let controller = FloorpWebPanelFindController(target: target)
        let findToolbar = controller.toolbarView
        webPanelContainerView.addSubview(findToolbar)
        let keyboardConstraint = findToolbar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )
        keyboardConstraint.priority = .defaultHigh
        let safeAreaConstraint = findToolbar.bottomAnchor.constraint(
            equalTo: webPanelContainerView.safeAreaLayoutGuide.bottomAnchor
        )
        safeAreaConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            findToolbar.leadingAnchor.constraint(equalTo: webPanelContainerView.leadingAnchor),
            findToolbar.trailingAnchor.constraint(equalTo: webPanelContainerView.trailingAnchor),
            findToolbar.bottomAnchor.constraint(
                lessThanOrEqualTo: webPanelContainerView.safeAreaLayoutGuide.bottomAnchor
            ),
            keyboardConstraint,
            safeAreaConstraint,
            findToolbar.heightAnchor.constraint(
                equalToConstant: FloorpWebPanelFindController.fallbackToolbarHeight
            ),
        ])
        let colors = themeManager.getCurrentTheme(for: windowUUID).colors
        controller.applyTheme(
            backgroundColor: colors.layer1,
            textColor: colors.textPrimary,
            secondaryTextColor: colors.textSecondary,
            tintColor: colors.iconPrimary
        )
        webPanelFindController = controller
    }

    private func removeWebPanelFindController() {
        webPanelFindController?.invalidate()
        webPanelFindController?.toolbarView.removeFromSuperview()
        webPanelFindController = nil
    }

    /// Unloads the attached runtime without leaving stale observer, content,
    /// or toolbar state behind. A future user-facing action can call this
    /// boundary without reaching into the window-scoped session store.
    @discardableResult
    func unloadActiveWebPanel() -> Bool {
        guard currentPanelType == .web,
              let session = activeWebPanelSession,
              let sessionStore = presentationState.webPanelSessionStore else {
            return false
        }

        let key = session.key
        detachWebPanelContent(applyHiddenLifecycle: false)
        guard sessionStore.unloadSession(for: key) else {
            showWebPanelUnavailable()
            return false
        }

        explicitlyUnloadedWebPanelKey = key
        showWebPanelUnloaded()
        return true
    }

    func rebindActiveContent(forSelectedTabIsPrivate isPrivate: Bool) {
        guard isViewLoaded,
              currentPanelType == .web else {
            return
        }
        if activeWebPanelSession?.key.isPrivate == isPrivate {
            return
        }
        if activeWebPanelSession == nil,
           explicitlyUnloadedWebPanelKey?.panelID == presentationState.selectedPanelId,
           explicitlyUnloadedWebPanelKey?.isPrivate == isPrivate {
            return
        }
        loadCurrentPanel(webPanelPrivacyMode: isPrivate)
    }

    func privateWebPanelSessionsDidClose(selectedTabIsPrivate: Bool?) {
        guard activeWebPanelSession?.key.isPrivate == true else { return }
        detachWebPanelContent(applyHiddenLifecycle: false)

        guard selectedTabIsPrivate == false else {
            dismissDrawer()
            return
        }
        loadCurrentPanel(webPanelPrivacyMode: false)
    }

    fileprivate func webPanelRuntimeWillInvalidate() {
        guard activeWebPanelSession != nil else { return }
        detachWebPanelContent(applyHiddenLifecycle: false)
        if currentPanelType == .web {
            showWebPanelUnavailable()
        }
    }

    private func setWebPanelToolbarVisible(_ isVisible: Bool) {
        webPanelToolbarView.isHidden = !isVisible
        webPanelToolbarHeightConstraint?.constant = isVisible ? UX.webPanelToolbarHeight : 0
    }

    private func renderWebPanelToolbarState(_ state: FloorpWebPanelSessionState?) {
        webPanelBackButton.isEnabled = state?.canGoBack == true
        webPanelForwardButton.isEnabled = state?.canGoForward == true
        webPanelReloadButton.isEnabled = state.map {
            $0.isLoading || $0.currentURL != nil
        } ?? false
        webPanelHomeButton.isEnabled = state != nil
        webPanelFindButton.isEnabled = state != nil && webPanelFindController != nil
        webPanelOpenInMainButton.isEnabled = state?.currentURL.map(isSafeMainBrowserURL) == true

        let isLoading = state?.isLoading == true
        webPanelReloadButton.setImage(
            UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise"),
            for: .normal
        )
        webPanelReloadButton.accessibilityLabel = isLoading
            ? FloorpStrings.Drawer.webPanelStopLoading
            : FloorpStrings.Drawer.webPanelReload
    }

    private func isSafeMainBrowserURL(_ url: URL) -> Bool {
        if case .openInMainBrowser = FloorpWebPanelNavigationPolicy.decision(
            for: FloorpWebPanelNavigationRequest(url: url, target: .newWindow)
        ) {
            return true
        }
        return false
    }

    private func showWebPanelUnavailable() {
        detachWebPanelContent()
        searchTextField.isHidden = true
        tableView.isHidden = false
        showEmptyState(message: FloorpStrings.Drawer.webPanelUnavailable)
    }

    private func showWebPanelUnloaded() {
        searchTextField.isHidden = true
        tableView.isHidden = false
        webPanelContainerView.isHidden = true
        showEmptyState(message: FloorpStrings.Drawer.webPanelUnloaded)
    }

    private var canLeaveCurrentPanel: Bool {
        guard !notesInteractionsLocked else { return false }
        guard currentPanelType.usesNativeLibrary,
              let libraryPanelHost else { return true }
        return libraryPanelHost.allowsPanelSwitching
    }

    private func canSelectPanel(_ panel: FloorpPanel) -> Bool {
        guard panel.id != presentationState.selectedPanelId else { return true }
        return canLeaveCurrentPanel
    }

    private func showNativeLibraryPanel(_ panelType: FloorpPanelType) -> Bool {
        guard let libraryPanelHost,
              libraryPanelHost.select(panelType: panelType) else { return false }

        setLegacyContentHidden(true)
        nativeContentContainerView.isHidden = false
        let libraryViewController = libraryPanelHost.viewController
        guard libraryViewController.parent !== self else { return true }

        addChild(libraryViewController)
        let forwardsAppearance = view.window != nil
        if forwardsAppearance {
            libraryViewController.beginAppearanceTransition(true, animated: false)
        }
        nativeContentContainerView.addSubview(libraryViewController.view)
        libraryViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            libraryViewController.view.topAnchor.constraint(equalTo: nativeContentContainerView.topAnchor),
            libraryViewController.view.leadingAnchor.constraint(equalTo: nativeContentContainerView.leadingAnchor),
            libraryViewController.view.trailingAnchor.constraint(equalTo: nativeContentContainerView.trailingAnchor),
            libraryViewController.view.bottomAnchor.constraint(equalTo: nativeContentContainerView.bottomAnchor),
        ])
        libraryViewController.didMove(toParent: self)
        if forwardsAppearance {
            libraryViewController.endAppearanceTransition()
        }
        libraryPanelHost.onRequestDrawerDismiss = { [weak self] in
            self?.performDrawerDismissal()
        }
        return true
    }

    private func hideNativeLibraryPanel() {
        nativeContentContainerView.isHidden = true
        guard let libraryViewController = libraryPanelHost?.viewController,
              libraryViewController.parent === self else { return }
        libraryViewController.willMove(toParent: nil)
        let forwardsAppearance = view.window != nil
        if forwardsAppearance {
            libraryViewController.beginAppearanceTransition(false, animated: false)
        }
        libraryViewController.view.removeFromSuperview()
        if forwardsAppearance {
            libraryViewController.endAppearanceTransition()
        }
        libraryViewController.removeFromParent()
    }

    private func setLegacyContentHidden(_ isHidden: Bool) {
        headerView.isHidden = isHidden
        searchTextField.isHidden = isHidden
        tableView.isHidden = isHidden
        if isHidden {
            emptyStateLabel.isHidden = true
            retryButton.isHidden = true
        }
    }

    private func loadBookmarks() {
        panelLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bookmarks = try await panelManager.dataProvider.getRecentBookmarks(limit: 50)
                guard !Task.isCancelled, currentPanelType == .bookmarks else { return }
                items = bookmarks.map { bookmark in
                    DrawerItem(
                        id: "bookmark:\(bookmark.guid)",
                        title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                        url: bookmark.url,
                        icon: UIImage(systemName: "bookmark.fill"),
                        subtitle: bookmark.url,
                        source: .bookmark(guid: bookmark.guid)
                    )
                }
                applySearchFilter()
                updateUI()
            } catch {
                guard !Task.isCancelled, currentPanelType == .bookmarks else { return }
                logger.log(
                    "Floorp: Failed to load bookmarks: \(error.localizedDescription)",
                    level: .warning,
                    category: .setup
                )
                showEmptyState(
                    message: FloorpStrings.Drawer.bookmarksLoadError,
                    retryAction: { [weak self] in self?.loadBookmarks() }
                )
            }
        }
    }

    private func loadHistory() {
        panelLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let history = try await panelManager.dataProvider.getRecentHistory(limit: 50)
                guard !Task.isCancelled, currentPanelType == .history else { return }
                items = history.infos.map { info in
                    DrawerItem(
                        id: "history:\(info.url)",
                        title: info.title ?? info.url,
                        url: info.url,
                        icon: UIImage(systemName: "clock.arrow.circlepath"),
                        subtitle: info.url,
                        source: .history(url: info.url)
                    )
                }
                applySearchFilter()
                updateUI()
            } catch {
                guard !Task.isCancelled, currentPanelType == .history else { return }
                logger.log(
                    "Floorp: Failed to load history: \(error.localizedDescription)",
                    level: .warning,
                    category: .setup
                )
                showEmptyState(
                    message: FloorpStrings.Drawer.historyLoadError,
                    retryAction: { [weak self] in self?.loadHistory() }
                )
            }
        }
    }

    private func loadDownloads() {
        panelLoadTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, currentPanelType == .downloads else { return }
            let downloads = panelManager.dataProvider.getRecentDownloads(limit: 50)
            items = downloads.map { file in
                let fileIcon = UIImage(
                    systemName: "doc.fill"
                ) ?? UIImage(systemName: "arrow.down.circle.fill")
                return DrawerItem(
                    id: "download:\(file.path.path)",
                    title: file.filename,
                    url: nil,
                    icon: fileIcon,
                    subtitle: file.formattedSize,
                    source: .download(fileURL: file.path)
                )
            }
            if items.isEmpty {
                showEmptyState(message: FloorpStrings.Drawer.noDownloads)
            } else {
                applySearchFilter()
                updateUI()
            }
        }
    }

    private func loadNotes() {
        panelLoadTask?.cancel()
        let generation = UUID()
        notesLoadGeneration = generation
        panelLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await notesSnapshotLoader()
                guard !Task.isCancelled,
                      notesLoadGeneration == generation,
                      currentPanelType == .notes else { return }
                guard let didDiscardReorder = applyNotesSnapshot(snapshot) else { return }
                pendingNoteAccessibilityFocusRequiresReload = false
                updateUI()
                applyPendingNoteAccessibilityFocus()
                if didDiscardReorder {
                    announceNotesReorderCancelledForChanges()
                }
            } catch let error as FloorpNotesStoreError {
                guard !Task.isCancelled,
                      notesLoadGeneration == generation,
                      currentPanelType == .notes else { return }
                handleNotesLoadError(error)
            } catch {
                guard !Task.isCancelled,
                      notesLoadGeneration == generation,
                      currentPanelType == .notes else { return }
                showGenericNotesLoadError()
            }
        }
    }

    private func makeNoteItems(_ notes: [FloorpNote]) -> [DrawerItem] {
        notes.map { note in
            let preview = FloorpNoteContent.plainText(
                from: note.content,
                contentFormat: note.contentFormat
            )
            let subtitle = preview.isEmpty ? nil : String(preview.prefix(160))
            return DrawerItem(
                id: note.id,
                title: note.title.isEmpty ? FloorpStrings.Notes.untitled : note.title,
                icon: UIImage(systemName: "note.text"),
                subtitle: subtitle,
                searchText: preview,
                source: .note(id: note.id)
            )
        }
    }

    /// Returns nil when an already-applied revision is newer than this result.
    private func applyNotesSnapshot(_ snapshot: FloorpNotesSnapshot) -> Bool? {
        if let notesRevision, snapshot.revision < notesRevision {
            return nil
        }
        let didDiscardReorder = notesReorderSession.map {
            $0.expectedRevision != snapshot.revision
        } ?? false
        if didDiscardReorder {
            discardNotesReordering()
        }
        notesRevision = snapshot.revision
        items = makeNoteItems(snapshot.notes)
        applySearchFilter()
        return didDiscardReorder
    }

    private func handleNotesLoadError(_ error: FloorpNotesStoreError) {
        logNotesLoadError()
        switch error {
        case .corruptArchive, .writesBlockedByCorruption:
            showEmptyState(
                message: FloorpStrings.Notes.damagedDataMessage,
                retryTitle: FloorpStrings.Notes.reset,
                retryAction: { [weak self] in self?.confirmResetNotes() }
            )
        case .corruptArchiveCouldNotBePreserved:
            showEmptyState(message: FloorpStrings.Notes.damagedDataCouldNotBePreservedMessage)
        case .unsupportedSchema:
            showEmptyState(message: FloorpStrings.Notes.newerDataReadOnlyMessage)
        case .archiveTooLarge:
            showEmptyState(message: FloorpStrings.Notes.archiveTooLargeMessage)
        default:
            showEmptyState(
                message: FloorpStrings.Notes.loadFailed,
                retryAction: { [weak self] in self?.loadNotes() }
            )
        }
    }

    private func showGenericNotesLoadError() {
        logNotesLoadError()
        showEmptyState(
            message: FloorpStrings.Notes.loadFailed,
            retryAction: { [weak self] in self?.loadNotes() }
        )
    }

    private func logNotesLoadError() {
        logger.log(
            "Floorp: Failed to load notes storage",
            level: .warning,
            category: .setup
        )
    }

    private func updateUI() {
        let isReordering = notesReorderSession != nil
        searchTextField.isEnabled = !isReordering && !isCommittingNotesReorder
        addNoteButton.isEnabled = currentPanelType == .notes
            && !isCreatingNote
            && !isReordering
            && !isCommittingNotesReorder
        tableView.reloadData()
        let displayItems = isSearching ? filteredItems : items
        let isEmpty = displayItems.isEmpty
        emptyStateLabel.isHidden = !isEmpty

        if isEmpty {
            if isSearching {
                emptyStateLabel.text = currentPanelType == .notes
                    ? FloorpStrings.Notes.noSearchResults
                    : FloorpStrings.Drawer.noItemsFound
            } else {
                emptyStateLabel.text = currentPanelType == .notes
                    ? FloorpStrings.Notes.noNotes
                    : FloorpStrings.Drawer.noItemsFound
            }
        }
        retryButton.isHidden = true
        retryButton.setTitle(FloorpStrings.Drawer.retryButton, for: .normal)
        currentRetryAction = nil
        updateNotesReorderControls()
    }

    private func deleteItem(_ item: DrawerItem) async throws {
        switch item.source {
        case .bookmark(let guid):
            try await panelManager.dataProvider.deleteBookmark(guid: guid)
        case .history(let url):
            try await panelManager.dataProvider.deleteHistory(url: url)
        case .note(let id):
            try await notesStore.deleteNote(id: id)
        case .download, .none:
            return
        }
    }

    private func showEmptyState(
        message: String,
        retryTitle: String = FloorpStrings.Drawer.retryButton,
        retryAction: (() -> Void)? = nil
    ) {
        items = []
        filteredItems = []
        notesRevision = nil
        endNotesReordering(reload: false)
        searchTextField.isEnabled = false
        addNoteButton.isEnabled = false
        emptyStateLabel.text = message
        emptyStateLabel.isHidden = false

        if let retryAction = retryAction {
            currentRetryAction = retryAction
            retryButton.isHidden = false
            retryButton.setTitle(retryTitle, for: .normal)
            retryButton.removeTarget(nil, action: nil, for: .allEvents)
            retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        } else {
            currentRetryAction = nil
            retryButton.isHidden = true
        }

        tableView.reloadData()
    }

    // MARK: - Search

    @objc private func searchTextChanged() {
        guard notesReorderSession == nil, !isCommittingNotesReorder else { return }
        applySearchFilter()
        updateUI()
    }

    private func applySearchFilter() {
        guard let query = searchTextField.text, !query.isEmpty else {
            isSearching = false
            filteredItems = items
            return
        }
        isSearching = true
        filteredItems = items.filter { $0.matchesSearchQuery(query) }
    }

    @objc private func retryTapped() {
        currentRetryAction?()
    }

    private var displayedItems: [DrawerItem] {
        isSearching ? filteredItems : items
    }

    private var displayedNoteIDs: [String] {
        displayedItems.compactMap { item in
            if case .note(let id) = item.source { return id }
            return nil
        }
    }

    private var notesInteractionsLocked: Bool {
        notesReorderSession != nil || isCommittingNotesReorder
    }

    private func updateNotesReorderControls() {
        let isNotesPanel = currentPanelType == .notes
        let isReordering = notesReorderSession != nil
        notesReorderButton.isHidden = !isNotesPanel
        addNoteButton.isHidden = !isNotesPanel || isReordering
        cancelNotesReorderButton.isHidden = !isNotesPanel || !isReordering
        notesReorderButton.setImage(
            UIImage(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down"),
            for: .normal
        )
        notesReorderButton.accessibilityLabel = isReordering
            ? FloorpStrings.Notes.reorderDone
            : FloorpStrings.Notes.reorder
        notesReorderButton.isEnabled = !isCommittingNotesReorder
            && (isReordering || displayedNoteIDs.count > 1)
        cancelNotesReorderButton.isEnabled = !isCommittingNotesReorder
        closeButton.isEnabled = !isCommittingNotesReorder
        isModalInPresentation = isCommittingNotesReorder
        sidebarButtons.forEach { $0.isEnabled = !notesInteractionsLocked }
        addWebPanelButton.isEnabled = !notesInteractionsLocked
        managePanelsButton.isEnabled = !notesInteractionsLocked
        if tableView.isEditing != isReordering {
            tableView.setEditing(isReordering, animated: false)
        }
    }

    @objc private func notesReorderTapped() {
        if notesReorderSession == nil {
            beginNotesReordering()
        } else {
            commitNotesReordering()
        }
    }

    @objc private func cancelNotesReorderTapped() {
        guard notesReorderSession != nil, !isCommittingNotesReorder else { return }
        endNotesReordering(reload: true)
        UIAccessibility.post(notification: .layoutChanged, argument: notesReorderButton)
    }

    private func beginNotesReordering() {
        guard currentPanelType == .notes,
              presentedViewController == nil,
              !isCommittingNotesReorder,
              let notesRevision,
              displayedNoteIDs.count > 1 else { return }
        searchTextField.resignFirstResponder()
        notesReorderSession = FloorpNotesReorderSession(
            visibleIDs: displayedNoteIDs,
            expectedRevision: notesRevision
        )
        updateUI()
        UIAccessibility.post(notification: .layoutChanged, argument: tableView)
    }

    private func commitNotesReordering() {
        guard let session = notesReorderSession, !isCommittingNotesReorder else { return }
        guard session.hasChanges else {
            endNotesReordering(reload: false)
            return
        }
        persistNotesOrder(session, focusNoteID: nil, completesStagedReorder: true)
    }

    private func endNotesReordering(reload: Bool) {
        if let session = notesReorderSession {
            restoreDisplayedNoteOrder(session.originalVisibleIDs)
        }
        notesReorderSession = nil
        if tableView.isEditing {
            tableView.setEditing(false, animated: false)
        }
        updateUI()
        if reload, currentPanelType == .notes {
            loadNotes()
        }
    }

    @discardableResult
    private func discardNotesReordering() -> Bool {
        guard notesReorderSession != nil else { return false }
        notesReorderSession = nil
        if tableView.isEditing {
            tableView.setEditing(false, animated: false)
        }
        updateNotesReorderControls()
        return true
    }

    private func announceNotesReorderCancelledForChanges() {
        UIAccessibility.post(
            notification: .announcement,
            argument: FloorpStrings.Notes.reorderCancelledForChanges
        )
    }

    private func restoreDisplayedNoteOrder(_ orderedIDs: [String]) {
        let itemsByID = Dictionary(uniqueKeysWithValues: displayedItems.map { ($0.id, $0) })
        let restoredItems = orderedIDs.compactMap { itemsByID[$0] }
        guard restoredItems.count == orderedIDs.count else { return }
        if isSearching {
            filteredItems = restoredItems
        } else {
            items = restoredItems
            filteredItems = restoredItems
        }
    }

    @discardableResult
    func performNoteAccessibilityMove(id: String, offset: Int) -> Bool {
        guard currentPanelType == .notes, !isCommittingNotesReorder else { return false }

        if var session = notesReorderSession {
            guard let sourceIndex = session.orderedVisibleIDs.firstIndex(of: id),
                  let destinationIndex = session.move(id: id, offset: offset) else { return false }
            notesReorderSession = session
            moveDisplayedItem(from: sourceIndex, to: destinationIndex)
            tableView.reloadData()
            announceNoteMove(id: id, position: destinationIndex, total: session.orderedVisibleIDs.count)
            return true
        }

        guard let notesRevision else { return false }
        var session = FloorpNotesReorderSession(
            visibleIDs: displayedNoteIDs,
            expectedRevision: notesRevision
        )
        guard let destinationIndex = session.move(id: id, offset: offset) else { return false }
        persistNotesOrder(
            session,
            focusNoteID: id,
            completesStagedReorder: false,
            announcement: FloorpNoteMoveAnnouncement(
                id: id,
                position: destinationIndex,
                total: session.orderedVisibleIDs.count
            )
        )
        return true
    }

    @discardableResult
    func performNoteAccessibilityDelete(id: String) -> Bool {
        guard notesReorderSession == nil,
              !isCommittingNotesReorder,
              let item = displayedItems.first(where: { $0.id == id }),
              itemIsNote(item) else { return false }
        confirmNoteDeletion(item)
        return true
    }

    private func persistNotesOrder(
        _ session: FloorpNotesReorderSession,
        focusNoteID: String?,
        completesStagedReorder: Bool,
        announcement: FloorpNoteMoveAnnouncement? = nil
    ) {
        guard !isCommittingNotesReorder else { return }
        isCommittingNotesReorder = true
        updateUI()
        // Once Done is accepted, keep the transaction owner alive even if an
        // upstream parent dismisses the modal hierarchy programmatically.
        Task { @MainActor [self] in
            do {
                _ = try await notesReorderWriter(
                    session.originalVisibleIDs,
                    session.orderedVisibleIDs,
                    session.expectedRevision
                )
                if completesStagedReorder {
                    notesReorderSession = nil
                    tableView.setEditing(false, animated: false)
                }
                setPendingNoteAccessibilityFocus(
                    focusNoteID,
                    requiresReload: focusNoteID != nil
                )
                isCommittingNotesReorder = false
                updateUI()
                if let announcement {
                    announceNoteMove(
                        id: announcement.id,
                        position: announcement.position,
                        total: announcement.total
                    )
                }
                loadNotes()
            } catch FloorpNotesStoreError.reorderConflict {
                handleStaleNotesReorder()
            } catch is FloorpNotesListOrderError {
                handleStaleNotesReorder()
            } catch {
                isCommittingNotesReorder = false
                endNotesReordering(reload: true)
                presentOperationError()
            }
        }
    }

    private func handleStaleNotesReorder() {
        isCommittingNotesReorder = false
        endNotesReordering(reload: true)
        announceNotesReorderCancelledForChanges()
    }

    private func moveDisplayedItem(from sourceIndex: Int, to destinationIndex: Int) {
        if isSearching {
            guard filteredItems.indices.contains(sourceIndex),
                  filteredItems.indices.contains(destinationIndex) else { return }
            let item = filteredItems.remove(at: sourceIndex)
            filteredItems.insert(item, at: destinationIndex)
        } else {
            guard items.indices.contains(sourceIndex),
                  items.indices.contains(destinationIndex) else { return }
            let item = items.remove(at: sourceIndex)
            items.insert(item, at: destinationIndex)
            filteredItems = items
        }
    }

    private func announceNoteMove(id: String, position: Int, total: Int) {
        guard let item = displayedItems.first(where: { $0.id == id }) else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: FloorpStrings.Notes.moveAnnouncement(
                title: item.title,
                position: position + 1,
                total: total
            )
        )
    }

    private func applyPendingNoteAccessibilityFocus() {
        guard presentedViewController == nil else { return }
        guard !pendingNoteAccessibilityFocusRequiresReload else { return }
        view.layoutIfNeeded()

        if let id = pendingNoteAccessibilityFocusID {
            guard let row = displayedItems.firstIndex(where: { $0.id == id }) else {
                handleMissingPendingNoteAccessibilityFocus()
                return
            }
            let indexPath = IndexPath(row: row, section: 0)
            tableView.scrollToRow(at: indexPath, at: .none, animated: false)
            tableView.layoutIfNeeded()
            clearPendingNoteAccessibilityFocus()
            noteAccessibilityFocusPoster(tableView.cellForRow(at: indexPath))
            return
        }

        guard shouldFocusAddNoteButton else { return }
        clearPendingNoteAccessibilityFocus()
        noteAccessibilityFocusPoster(addNoteButton)
    }

    private func setPendingNoteAccessibilityFocus(
        _ id: String?,
        requiresReload: Bool = false
    ) {
        pendingNoteAccessibilityFocusID = id
        pendingNoteAccessibilityFocusRequiresReload = id != nil && requiresReload
        shouldFocusAddNoteButton = false
    }

    private func clearPendingNoteAccessibilityFocus() {
        pendingNoteAccessibilityFocusID = nil
        pendingNoteAccessibilityFocusRequiresReload = false
        shouldFocusAddNoteButton = false
    }

    private func handleMissingPendingNoteAccessibilityFocus() {
        clearPendingNoteAccessibilityFocus()
        if isSearching {
            noteAccessibilityFocusPoster(searchTextField)
        } else if let firstCell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) {
            noteAccessibilityFocusPoster(firstCell)
        } else {
            noteAccessibilityFocusPoster(addNoteButton)
        }
    }

    // MARK: - Actions

    @objc private func addNoteTapped() {
        guard !isCreatingNote,
              notesReorderSession == nil,
              !isCommittingNotesReorder else { return }
        isCreatingNote = true
        addNoteButton.isEnabled = false
        defer {
            isCreatingNote = false
            addNoteButton.isEnabled = currentPanelType == .notes && !isCreatingNote
        }

        let timestamp = FloorpNotesStore.currentTimeInMilliseconds()
        let draft = FloorpNote(
            id: UUID().uuidString,
            title: FloorpStrings.Notes.newNote,
            content: "",
            createdAt: timestamp,
            updatedAt: timestamp,
            contentFormat: .plainText
        )
        presentNoteEditor(draft, isPersisted: false)
    }

    @objc private func notesDidChange(_: Notification) {
        guard currentPanelType == .notes else { return }
        guard !isCommittingNotesReorder else { return }
        if discardNotesReordering() {
            loadNotes()
            announceNotesReorderCancelledForChanges()
            return
        }
        loadNotes()
    }

    private func openNote(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let note = try await notesStore.loadNotes().first(where: { $0.id == id }) else {
                    loadNotes()
                    return
                }
                presentNoteEditor(note)
            } catch {
                presentOperationError()
            }
        }
    }

    private func presentNoteEditor(_ note: FloorpNote, isPersisted: Bool = true) {
        guard presentedViewController == nil else { return }
        if isPersisted {
            setPendingNoteAccessibilityFocus(note.id)
        } else {
            clearPendingNoteAccessibilityFocus()
            shouldFocusAddNoteButton = true
        }
        let persistenceSession = FloorpNotePersistenceSession(
            notesStore: notesStore,
            persistedNote: isPersisted ? note : nil,
            onCreatedNote: { [weak self] in
                self?.noteCreatedInOwningDrawer($0)
            }
        )
        let editor = FloorpNoteEditorViewController(
            note: note,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter,
            isPersisted: isPersisted,
            persistence: persistenceSession
        )
        editor.navigationItem.prompt = FloorpStrings.Notes.localOnly
        let navigationController = UINavigationController(rootViewController: editor)
        navigationController.modalPresentationStyle = .pageSheet
        present(navigationController, animated: true)
    }

    func noteCreatedInOwningDrawer(_ note: FloorpNote) {
        guard currentPanelType == .notes else { return }
        searchTextField.text = nil
        isSearching = false
        filteredItems = items
        setPendingNoteAccessibilityFocus(note.id, requiresReload: true)
        loadNotes()
    }

    private func confirmResetNotes() {
        let alert = UIAlertController(
            title: FloorpStrings.Notes.reset,
            message: FloorpStrings.Notes.damagedDataMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: FloorpStrings.Notes.reset, style: .destructive) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await notesStore.resetAfterCorruption()
                        loadNotes()
                    } catch {
                        presentOperationError()
                    }
                }
            }
        )
        present(alert, animated: true)
    }

    private func presentOperationError() {
        presentationState.recordPendingNotesOperationError()
        guard canPresentNotesOperationError else { return }
        presentNotesOperationErrorAlert()
    }

    @discardableResult
    private func presentPendingNotesOperationErrorIfPossible() -> Bool {
        guard presentationState.hasPendingNotesOperationError,
              canPresentNotesOperationError else { return false }
        presentNotesOperationErrorAlert()
        return true
    }

    private var canPresentNotesOperationError: Bool {
        presentedViewController == nil
            && presentingViewController != nil
            && viewIfLoaded?.window != nil
            && !isBeingDismissed
            && !didFinishDismissal
            && !isTransitioningDrawer
    }

    private func presentNotesOperationErrorAlert() {
        let alert = UIAlertController(
            title: FloorpStrings.Notes.operationFailedTitle,
            message: FloorpStrings.Notes.operationFailedMessage,
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(title: FloorpStrings.Notes.close, style: .default) { [weak self] _ in
                self?.presentationState.consumePendingNotesOperationError()
            }
        )
        present(alert, animated: true)
    }

    @objc private func webPanelBackTapped() {
        activeWebPanelSession?.goBack()
    }

    @objc private func webPanelForwardTapped() {
        activeWebPanelSession?.goForward()
    }

    @objc private func webPanelReloadOrStopTapped() {
        guard let activeWebPanelSession else { return }
        if activeWebPanelSession.state.isLoading {
            activeWebPanelSession.stopLoading()
        } else {
            activeWebPanelSession.reload()
        }
    }

    @objc private func webPanelHomeTapped() {
        activeWebPanelSession?.loadHome()
    }

    @objc private func webPanelFindTapped() {
        guard currentPanelType == .web else { return }
        _ = webPanelFindController?.present()
    }

    @objc private func webPanelFindNextKeyCommand() {
        guard currentPanelType == .web else { return }
        webPanelFindController?.findNext()
    }

    @objc private func webPanelFindPreviousKeyCommand() {
        guard currentPanelType == .web else { return }
        webPanelFindController?.findPrevious()
    }

    @objc private func handleEscapeKeyCommand() {
        if webPanelFindController?.dismissIfActive() == true {
            return
        }
        closeTapped()
    }

    @objc private func webPanelOpenInMainBrowserTapped() {
        guard let activeWebPanelSession,
              let currentURL = activeWebPanelSession.state.currentURL,
              isSafeMainBrowserURL(currentURL) else {
            return
        }
        activeWebPanelSession.openCurrentPageInMainBrowser()
        dismissDrawer()
    }

    @objc private func closeTapped() {
        dismissDrawer()
    }

    @objc private func dimmingViewTapped() {
        dismissDrawer()
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        dismissDrawer()
    }

    // MARK: - Present / Dismiss

    /// Presents above the browser chrome so later toolbar z-order updates
    /// cannot move the address bar in front of the drawer.
    @discardableResult
    func show(
        from parentVC: UIViewController,
        onPresented: (() -> Void)? = nil
    ) -> Bool {
        guard presentingViewController == nil,
              !isTransitioningDrawer,
              parentVC.presentedViewController == nil else { return false }

        parentVC.loadViewIfNeeded()
        guard parentVC.view.window != nil,
              presentationState.attach(self) else { return false }

        loadViewIfNeeded()
        updateDrawerGeometry(availableWidth: parentVC.view.bounds.width)
        view.layoutIfNeeded()
        containerView.transform = CGAffineTransform(
            translationX: FloorpDrawerLayoutMetrics.dismissalTranslation(
                drawerWidth: containerWidthConstraint?.constant ?? parentVC.view.bounds.width,
                layoutDirection: view.effectiveUserInterfaceLayoutDirection
            ),
            y: 0
        )
        view.accessibilityViewIsModal = true
        isTransitioningDrawer = true

        parentVC.present(self, animated: false) { [weak self] in
            guard let self else { return }
            let duration = UIAccessibility.isReduceMotionEnabled ? 0 : UX.animationDuration
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                self.dimmingView.alpha = 1
                self.containerView.transform = .identity
            } completion: { _ in
                self.isTransitioningDrawer = false
                onPresented?()
                if self.dismissWhenPresentationFinishes {
                    self.dismissWhenPresentationFinishes = false
                    self.dismissDrawer()
                    return
                }
                if self.presentPendingNotesOperationErrorIfPossible() {
                    return
                }
                UIAccessibility.post(notification: .screenChanged, argument: self.titleLabel)
            }
        }
        let didPresent = presentingViewController === parentVC
        if !didPresent {
            isTransitioningDrawer = false
            detachWebPanelContent()
            presentationState.detach(self)
        }
        return didPresent
    }

    /// Dismisses the drawer with animation.
    func dismissDrawer() {
        if currentPanelType.usesNativeLibrary,
           let libraryPanelHost {
            guard libraryPanelHost.prepareForDrawerDismissal() == .allow else { return }
        }
        performDrawerDismissal()
    }

    private func performDrawerDismissal() {
        // An editor or confirmation alert owns its own save/destructive gate.
        // Do not let an external toolbar toggle tear down that presentation.
        guard !isCommittingNotesReorder,
              presentedViewController == nil,
              presentingViewController != nil,
              !didFinishDismissal else { return }
        if isTransitioningDrawer {
            dismissWhenPresentationFinishes = true
            return
        }

        endNotesReordering(reload: false)

        isTransitioningDrawer = true
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : UX.animationDuration
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseIn,
            animations: {
                self.dimmingView.alpha = 0
                self.containerView.transform = CGAffineTransform(
                    translationX: FloorpDrawerLayoutMetrics.dismissalTranslation(
                        drawerWidth: self.containerView.bounds.width,
                        layoutDirection: self.view.effectiveUserInterfaceLayoutDirection
                    ),
                    y: 0
                )
            },
            completion: { _ in
                self.dismiss(animated: false) { [weak self] in
                    self?.finishDismissal()
                }
            }
        )
    }

    private func finishDismissal() {
        guard !didFinishDismissal else { return }
        didFinishDismissal = true
        isTransitioningDrawer = false
        clearPendingRegistryFallback()
        detachWebPanelContent()
        presentationState.detach(self)
        if libraryPanelHost?.viewController.parent === self {
            hideNativeLibraryPanel()
        }
        libraryPanelHost?.onRequestDrawerDismiss = nil
        onDismissed?()
    }
}

private extension FloorpPanelType {
    var usesNativeLibrary: Bool {
        switch self {
        case .bookmarks, .history, .downloads: return true
        case .notes, .web: return false
        }
    }
}

// MARK: - UITextFieldDelegate

extension FloorpOverlayDrawerViewController: UITextFieldDelegate {
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        searchTextField.text = nil
        isSearching = false
        filteredItems = items
        updateUI()
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Table View Data Source

extension FloorpOverlayDrawerViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isSearching ? filteredItems.count : items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: DrawerItemCell.reuseIdentifier,
            for: indexPath
        ) as? DrawerItemCell else {
            return UITableViewCell()
        }

        guard displayedItems.indices.contains(indexPath.row) else { return UITableViewCell() }
        let item = displayedItems[indexPath.row]
        let accessibilityIdentifier: String
        switch item.source {
        case .note(let id):
            accessibilityIdentifier = "Floorp.Notes.Row.\(id)"
        default:
            accessibilityIdentifier = "Floorp.Drawer.Row.\(item.id)"
        }
        cell.configure(
            title: item.title,
            subtitle: item.subtitle,
            icon: item.icon,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityHint: notesReorderSession == nil
                ? nil
                : FloorpStrings.Notes.reorderAccessibilityHint,
            accessibilityActions: accessibilityActions(for: item, at: indexPath.row),
            showsReorderControl: notesReorderSession != nil
        )
        cell.applyTheme(themeManager.getCurrentTheme(for: windowUUID))
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard displayedItems.indices.contains(indexPath.row) else { return false }
        let item = displayedItems[indexPath.row]
        if notesReorderSession != nil {
            return itemIsNote(item)
        }
        switch item.source {
        case .bookmark, .history, .note:
            return true
        case .download, .none:
            return false
        }
    }

    func tableView(
        _ tableView: UITableView,
        canMoveRowAt indexPath: IndexPath
    ) -> Bool {
        guard notesReorderSession != nil,
              displayedItems.indices.contains(indexPath.row) else { return false }
        return itemIsNote(displayedItems[indexPath.row])
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard var session = notesReorderSession,
              session.move(from: sourceIndexPath.row, to: destinationIndexPath.row) else { return }
        notesReorderSession = session
        moveDisplayedItem(from: sourceIndexPath.row, to: destinationIndexPath.row)
        tableView.reloadData()
        announceNoteMove(
            id: session.orderedVisibleIDs[destinationIndexPath.row],
            position: destinationIndexPath.row,
            total: session.orderedVisibleIDs.count
        )
    }
}

// MARK: - Table View Delegate

extension FloorpOverlayDrawerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard notesReorderSession == nil, !isCommittingNotesReorder else { return }
        guard displayedItems.indices.contains(indexPath.row) else { return }
        let item = displayedItems[indexPath.row]

        switch item.source {
        case .download(let fileURL):
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController,
               let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
            present(activityVC, animated: true)
            return
        case .note(let id):
            openNote(id: id)
        case .history(let urlString):
            guard let url = URL(string: urlString) else { return }
            onItemSelected?(url)
            dismissDrawer()
        case .bookmark, .none:
            guard let urlString = item.url, let url = URL(string: urlString) else { return }
            onItemSelected?(url)
            dismissDrawer()
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let drawerCell = cell as? DrawerItemCell else { return }
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        drawerCell.applyTheme(theme)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard notesReorderSession == nil, !isCommittingNotesReorder else { return nil }
        guard displayedItems.indices.contains(indexPath.row) else { return nil }
        let item = displayedItems[indexPath.row]

        switch item.source {
        case .bookmark, .history, .note:
            break
        case .download, .none:
            return nil
        }

        let deleteAction = UIContextualAction(
            style: .destructive,
            title: itemIsNote(item) ? FloorpStrings.Notes.delete : FloorpStrings.Drawer.deleteItem
        ) { [weak self] _, _, completionHandler in
            guard let self else {
                completionHandler(false)
                return
            }
            if self.itemIsNote(item) {
                completionHandler(false)
                self.confirmNoteDeletion(item)
                return
            }

            Task { @MainActor in
                do {
                    try await self.deleteItem(item)
                    self.removeItemFromUI(id: item.id)
                    completionHandler(true)
                } catch {
                    completionHandler(false)
                    self.presentOperationError()
                }
            }
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }

    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        let lastRow = max(displayedItems.count - 1, 0)
        return IndexPath(
            row: min(max(proposedDestinationIndexPath.row, 0), lastRow),
            section: sourceIndexPath.section
        )
    }

    private func accessibilityActions(
        for item: DrawerItem,
        at index: Int
    ) -> [UIAccessibilityCustomAction] {
        guard case .note(let id) = item.source else { return [] }
        var actions = [UIAccessibilityCustomAction]()
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.Notes.moveUp,
                actionHandler: { [weak self] _ in
                    self?.performNoteAccessibilityMove(id: id, offset: -1) ?? false
                }
            ))
        }
        if index < displayedNoteIDs.count - 1 {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.Notes.moveDown,
                actionHandler: { [weak self] _ in
                    self?.performNoteAccessibilityMove(id: id, offset: 1) ?? false
                }
            ))
        }
        if notesReorderSession == nil, !isCommittingNotesReorder {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.Notes.delete,
                actionHandler: { [weak self] _ in
                    self?.performNoteAccessibilityDelete(id: id) ?? false
                }
            ))
        }
        return actions
    }

    private func itemIsNote(_ item: DrawerItem) -> Bool {
        if case .note = item.source { return true }
        return false
    }

    private func confirmNoteDeletion(_ item: DrawerItem) {
        let alert = UIAlertController(
            title: FloorpStrings.Notes.deleteTitle,
            message: FloorpStrings.Notes.deleteMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: FloorpStrings.Notes.delete, style: .destructive) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.deleteItem(item)
                        self.removeItemFromUI(id: item.id)
                    } catch {
                        self.presentOperationError()
                    }
                }
            }
        )
        present(alert, animated: true)
    }

    private func removeItemFromUI(id: String) {
        if currentPanelType == .notes,
           let removedIndex = displayedItems.firstIndex(where: { $0.id == id }) {
            let remainingItems = displayedItems.filter { $0.id != id }
            if remainingItems.isEmpty {
                setPendingNoteAccessibilityFocus(nil)
                shouldFocusAddNoteButton = true
            } else {
                let focusIndex = min(removedIndex, remainingItems.count - 1)
                setPendingNoteAccessibilityFocus(remainingItems[focusIndex].id)
            }
        }
        items.removeAll { $0.id == id }
        filteredItems.removeAll { $0.id == id }
        updateUI()
        applyPendingNoteAccessibilityFocus()
    }
}

// MARK: - Drawer Item Cell

private final class DrawerItemCell: UITableViewCell {
    static let reuseIdentifier = "FloorpDrawerItemCell"

    private let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FXFontStyles.Regular.body.scaledFont()
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = FXFontStyles.Regular.caption1.scaledFont()
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let iconSize: CGFloat = 28

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.addSubview(iconImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    func configure(
        title: String,
        subtitle: String? = nil,
        icon: UIImage?,
        accessibilityIdentifier: String,
        accessibilityHint: String?,
        accessibilityActions: [UIAccessibilityCustomAction],
        showsReorderControl: Bool
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        iconImageView.image = icon
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityLabel = title
        accessibilityValue = subtitle
        self.accessibilityHint = accessibilityHint
        accessibilityCustomActions = accessibilityActions.isEmpty ? nil : accessibilityActions
        self.showsReorderControl = showsReorderControl
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
        iconImageView.image = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityCustomActions = nil
        showsReorderControl = false
    }

    func applyTheme(_ theme: Theme) {
        let colors = theme.colors

        // Set background on all possible layers
        backgroundColor = colors.layer5
        contentView.backgroundColor = colors.layer5

        iconImageView.tintColor = colors.iconSecondary
        titleLabel.textColor = colors.textPrimary
        subtitleLabel.textColor = colors.textSecondary

        // Selected state
        let selectedBgView = UIView()
        selectedBgView.backgroundColor = colors.actionPrimary.withAlphaComponent(0.15)
        selectedBackgroundView = selectedBgView
    }
}
