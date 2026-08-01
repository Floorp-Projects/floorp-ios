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
final class FloorpPanelPresentationState {
    let windowUUID: WindowUUID
    private(set) var selectedPanelId: String?
    private(set) weak var activeDrawer: FloorpOverlayDrawerViewController?

    var hasActivePresentation: Bool {
        activeDrawer != nil
    }

    init(windowUUID: WindowUUID, selectedPanelId: String? = nil) {
        self.windowUUID = windowUUID
        self.selectedPanelId = selectedPanelId
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

    func attach(_ drawer: FloorpOverlayDrawerViewController) -> Bool {
        guard activeDrawer == nil || activeDrawer === drawer else { return false }
        activeDrawer = drawer
        return true
    }

    func detach(_ drawer: FloorpOverlayDrawerViewController) {
        guard activeDrawer === drawer else { return }
        activeDrawer = nil
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
@MainActor
final class FloorpOverlayDrawerViewController: UIViewController, Themeable {
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
    private var panelLoadTask: Task<Void, Never>?
    private var isTransitioningDrawer = false
    private var didFinishDismissal = false
    private var dismissWhenPresentationFinishes = false
    private var displayedPanelIDs = [String]()

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
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         notificationCenter: NotificationProtocol = NotificationCenter.default) {
        let presentationState = presentationState ?? FloorpPanelPresentationState(
            windowUUID: WindowUUID.XCTestDefaultUUID
        )
        self.panelManager = panelManager
        self.presentationState = presentationState
        self.notesStore = notesStore
        self.logger = logger
        self.windowUUID = presentationState.windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        panelLoadTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        setupConstraints()
        buildSidebarButtons()
        if let selectedPanel = presentationState.selectedPanel(in: panelManager.panels) {
            selectPanel(selectedPanel.id)
        }
        loadCurrentPanel()
        notificationCenter.addObserver(
            self,
            selector: #selector(notesDidChange),
            name: .FloorpNotesDidChange,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(panelRegistryDidChange),
            name: .FloorpPanelRegistryDidChange,
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
        [
            UIKeyCommand(
                title: FloorpStrings.Drawer.closeAccessibilityLabel,
                action: #selector(closeTapped),
                input: "d",
                modifierFlags: [.command, .shift]
            ),
            UIKeyCommand(
                title: FloorpStrings.Drawer.closeAccessibilityLabel,
                action: #selector(closeTapped),
                input: UIKeyCommand.inputEscape,
                modifierFlags: []
            ),
        ]
    }

    override func accessibilityPerformEscape() -> Bool {
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
        containerView.addSubview(searchTextField)
        containerView.addSubview(tableView)
        containerView.addSubview(emptyStateLabel)
        containerView.addSubview(retryButton)

        headerView.addSubview(titleLabel)
        headerView.addSubview(addNoteButton)
        headerView.addSubview(closeButton)

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
        tableSafeAreaBottomConstraint.priority = .defaultHigh
        self.containerWidthConstraint = containerWidthConstraint
        self.sidebarWidthConstraint = sidebarWidthConstraint
        self.sidebarStackWidthConstraint = sidebarStackWidthConstraint

        NSLayoutConstraint.activate([
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: addNoteButton.leadingAnchor, constant: -8),

            // Notes action
            addNoteButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            addNoteButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            addNoteButton.widthAnchor.constraint(equalToConstant: 44),
            addNoteButton.heightAnchor.constraint(equalToConstant: 44),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -UX.horizontalPadding),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Search bar
            searchTextField.topAnchor.constraint(
                equalTo: headerView.bottomAnchor, constant: 4
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
        ] + panelRailConstraints(sidebarStackWidthConstraint: sidebarStackWidthConstraint))
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
        guard let panelId = sender.accessibilityIdentifier else { return }
        selectPanel(panelId)
        loadCurrentPanel()
    }

    @objc private func addWebPanelTapped() {
        presentPanelRegistry(presentsAddEditor: true)
    }

    @objc private func managePanelsTapped() {
        presentPanelRegistry()
    }

    private func presentPanelRegistry(
        editingPanelID: String? = nil,
        presentsAddEditor: Bool = false
    ) {
        guard presentedViewController == nil else { return }
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

    private func movePanel(id: String, offset: Int) {
        guard let currentIndex = panelManager.panels.firstIndex(where: { $0.id == id }) else { return }
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

    private func requestPanelRemoval(id: String) {
        guard presentedViewController == nil,
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
        let previousPanelIDs = displayedPanelIDs
        let previousSelection = presentationState.selectedPanelId
        buildSidebarButtons()

        if let previousSelection,
           let selectedPanel = panelManager.panel(for: previousSelection) {
            selectPanel(selectedPanel.id)
            if selectedPanel.type == .web {
                loadCurrentPanel()
            }
            return
        }

        guard !panelManager.panels.isEmpty else {
            panelLoadTask?.cancel()
            items = []
            filteredItems = []
            tableView.reloadData()
            return
        }

        let previousIndex = previousSelection.flatMap { previousPanelIDs.firstIndex(of: $0) } ?? 0
        let fallbackIndex = min(previousIndex, panelManager.panels.count - 1)
        let fallbackPanel = panelManager.panels[fallbackIndex]
        selectPanel(fallbackPanel.id)
        loadCurrentPanel()
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    private func selectPanel(_ panelId: String) {
        guard let panel = panelManager.panel(for: panelId) else { return }
        currentPanelType = panel.type
        presentationState.select(panel)
        let panelTitle = displayTitle(for: panel)
        titleLabel.text = panel.type == .notes
            ? "\(panelTitle) · \(FloorpStrings.Notes.localOnly)"
            : panelTitle
        titleLabel.accessibilityValue = panel.type == .notes ? FloorpStrings.Notes.localOnly : nil
        addNoteButton.isHidden = panel.type != .notes
        searchTextField.placeholder = panel.type == .notes
            ? FloorpStrings.Notes.searchPlaceholder
            : FloorpStrings.Drawer.searchPlaceholder
        updateSidebarSelection()
    }

    // MARK: - Data Loading

    private func loadCurrentPanel() {
        panelLoadTask?.cancel()
        items = []
        filteredItems = []
        searchTextField.text = nil
        searchTextField.isEnabled = true
        addNoteButton.isEnabled = currentPanelType == .notes && !isCreatingNote
        isSearching = false
        emptyStateLabel.isHidden = true
        retryButton.isHidden = true
        currentRetryAction = nil
        tableView.reloadData()

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
            showEmptyState(message: FloorpStrings.Drawer.webPanelUnavailable)
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
        panelLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let notes = try await notesStore.loadNotes()
                guard !Task.isCancelled, currentPanelType == .notes else { return }
                items = makeNoteItems(notes)
                applySearchFilter()
                updateUI()
            } catch let error as FloorpNotesStoreError {
                guard !Task.isCancelled, currentPanelType == .notes else { return }
                handleNotesLoadError(error)
            } catch {
                guard !Task.isCancelled, currentPanelType == .notes else { return }
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
        searchTextField.isEnabled = true
        addNoteButton.isEnabled = currentPanelType == .notes && !isCreatingNote
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

    // MARK: - Actions

    @objc private func addNoteTapped() {
        guard !isCreatingNote else { return }
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

    @objc private func notesDidChange() {
        guard currentPanelType == .notes else { return }
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
        let persistenceSession = FloorpNotePersistenceSession(
            notesStore: notesStore,
            persistedNote: isPersisted ? note : nil
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
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: FloorpStrings.Notes.operationFailedTitle,
            message: FloorpStrings.Notes.operationFailedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.close, style: .default))
        present(alert, animated: true)
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
                UIAccessibility.post(notification: .screenChanged, argument: self.titleLabel)
            }
        }
        let didPresent = presentingViewController === parentVC
        if !didPresent {
            isTransitioningDrawer = false
            presentationState.detach(self)
        }
        return didPresent
    }

    /// Dismisses the drawer with animation.
    func dismissDrawer() {
        // An editor or confirmation alert owns its own save/destructive gate.
        // Do not let an external toolbar toggle tear down that presentation.
        guard presentedViewController == nil,
              presentingViewController != nil,
              !didFinishDismissal else { return }
        if isTransitioningDrawer {
            dismissWhenPresentationFinishes = true
            return
        }

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
        presentationState.detach(self)
        onDismissed?()
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

        let displayedItems = isSearching ? filteredItems : items
        guard displayedItems.indices.contains(indexPath.row) else { return UITableViewCell() }
        let item = displayedItems[indexPath.row]
        cell.configure(title: item.title, subtitle: item.subtitle, icon: item.icon)
        cell.applyTheme(themeManager.getCurrentTheme(for: windowUUID))
        return cell
    }
}

// MARK: - Table View Delegate

extension FloorpOverlayDrawerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let displayedItems = isSearching ? filteredItems : items
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
        let displayedItems = isSearching ? filteredItems : items
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
        items.removeAll { $0.id == id }
        filteredItems.removeAll { $0.id == id }
        updateUI()
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

    func configure(title: String, subtitle: String? = nil, icon: UIImage?) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        iconImageView.image = icon
        accessibilityLabel = title
        accessibilityValue = subtitle
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
        iconImageView.image = nil
        accessibilityLabel = nil
        accessibilityValue = nil
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
