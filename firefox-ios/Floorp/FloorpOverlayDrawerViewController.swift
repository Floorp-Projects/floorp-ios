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
        static let drawerWidthRatio: CGFloat = 1.0
        static let animationDuration: TimeInterval = 0.3
        static let cornerRadius: CGFloat = 0
        static let headerHeight: CGFloat = 52
        static let searchBarHeight: CGFloat = 44
        static let rowHeight: CGFloat = 56
        static let iconSize: CGFloat = 28
        static let sidebarWidth: CGFloat = 50
        static let sidebarIconSize: CGFloat = 22
        static let horizontalPadding: CGFloat = 16
        static let separatorHeight: CGFloat = 0.5
    }

    // MARK: - Properties
    private let panelManager: FloorpPanelManager
    private let notesStore: FloorpNotesStore
    private let logger: Logger

    /// Callback when user taps a bookmark/history item.
    var onItemSelected: ((URL) -> Void)?

    /// Callback when drawer is dismissed.
    var onDismissed: (() -> Void)?

    private var currentPanelType: FloorpPanelType = .bookmarks
    private var items = [DrawerItem]()
    private var filteredItems = [DrawerItem]()
    private var isSearching = false
    private var isCreatingNote = false
    private var panelLoadTask: Task<Void, Never>?

    // MARK: - UI Components

    // Background dimming overlay
    private lazy var dimmingView: UIView = {
        let view = UIView()
        view.alpha = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(dimmingViewTapped))
        view.addGestureRecognizer(tap)
        return view
    }()

    // Main container
    private lazy var containerView: UIView = {
        let view = UIView()
        view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMinXMinYCorner]
        view.layer.cornerRadius = UX.cornerRadius
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // Sidebar (icon column)
    private lazy var sidebarView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var sidebarStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .center
        sv.spacing = 4
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
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
        tv.translatesAutoresizingMaskIntoConstraints = false
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
         windowUUID: WindowUUID = WindowUUID.XCTestDefaultUUID,
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         notificationCenter: NotificationProtocol = NotificationCenter.default) {
        self.panelManager = panelManager
        self.notesStore = notesStore
        self.logger = logger
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        setupConstraints()
        buildSidebarButtons()
        selectPanel(panelManager.selectedPanel?.id ?? panelManager.panels.first?.id ?? "floorp//bookmarks")
        loadCurrentPanel()
        notificationCenter.addObserver(
            self,
            selector: #selector(notesDidChange),
            name: .FloorpNotesDidChange,
            object: nil
        )
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
        logger.log("Floorp: OverlayDrawer loaded", level: .info, category: .setup)
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

        sidebarView.addSubview(sidebarStackView)

        // Swipe gesture to dismiss
        let swipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeGesture.direction = .right
        containerView.addGestureRecognizer(swipeGesture)
    }

    private func setupConstraints() {
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
            containerView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: UX.drawerWidthRatio),

            // Sidebar
            sidebarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: UX.sidebarWidth),

            // Sidebar stack view
            sidebarStackView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 12),
            sidebarStackView.centerXAnchor.constraint(equalTo: sidebarView.centerXAnchor),
            sidebarStackView.widthAnchor.constraint(equalToConstant: UX.sidebarWidth - 8),

            // Header
            headerView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
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
                equalTo: containerView.trailingAnchor,
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
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

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
        ])
    }

    // MARK: - Themeable

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let colors = theme.colors

        // Main view background (behind dimming)
        view.backgroundColor = colors.layerScrim.withAlphaComponent(0.4)

        // Dimming overlay
        dimmingView.backgroundColor = colors.layerScrim.withAlphaComponent(0.4)

        // Main container
        containerView.backgroundColor = colors.layer1
        containerView.layer.borderColor = colors.borderPrimary.cgColor
        containerView.layer.borderWidth = 0.5

        // Sidebar
        sidebarView.backgroundColor = colors.layer3

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
        sidebarButtons.forEach { $0.removeFromSuperview() }
        sidebarButtons.removeAll()

        for panel in panelManager.panels {
            let button = createSidebarButton(for: panel)
            sidebarStackView.addArrangedSubview(button)
            sidebarButtons.append(button)
        }
    }

    private func createSidebarButton(for panel: FloorpPanel) -> UIButton {
        let button = UIButton(type: .system)
        let icon = UIImage(systemName: panel.iconName) ?? UIImage(systemName: "square.dashed")
        button.setImage(icon, for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = panel.type.localizedBuiltInTitle ?? panel.title
        button.accessibilityHint = FloorpStrings.Drawer.panelSidebarAccessibility

        button.addTarget(self, action: #selector(sidebarButtonTapped(_:)), for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Store panel ID in accessibility identifier for retrieval
        button.accessibilityIdentifier = panel.id

        return button
    }

    private func updateSidebarSelection() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let colors = theme.colors
        for button in sidebarButtons {
            let panelId = button.accessibilityIdentifier ?? ""
            let isSelected = panelId == (panelManager.config.selectedPanelId ?? "")
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

    private func selectPanel(_ panelId: String) {
        guard let panel = panelManager.panel(for: panelId) else { return }
        currentPanelType = panel.type
        panelManager.selectPanel(id: panelId)
        let panelTitle = panel.type.localizedBuiltInTitle ?? panel.title
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
            let preview = FloorpNoteContent.plainText(from: note.content)
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
            updatedAt: timestamp
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
            notificationCenter: notificationCenter
        ) { updatedNote in
            try await persistenceSession.save(updatedNote)
        }
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

    /// Presents the drawer by adding it as a child of the given parent VC.
    func show(from parentVC: UIViewController) {
        parentVC.addChild(self)
        view.frame = CGRect(
            x: parentVC.view.bounds.width,
            y: 0,
            width: parentVC.view.bounds.width,
            height: parentVC.view.bounds.height
        )
        parentVC.view.addSubview(view)
        didMove(toParent: parentVC)
        view.accessibilityViewIsModal = true

        // Animate slide in + dim
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : UX.animationDuration
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
            self.dimmingView.alpha = 1
            self.view.frame = parentVC.view.bounds
        } completion: { _ in
            UIAccessibility.post(notification: .screenChanged, argument: self.titleLabel)
        }
    }

    /// Dismisses the drawer with animation.
    func dismissDrawer() {
        // An editor or confirmation alert owns its own save/destructive gate.
        // Do not let an external toolbar toggle tear down that presentation.
        guard presentedViewController == nil, let parentVC = parent else { return }

        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : UX.animationDuration
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseIn,
            animations: {
                self.dimmingView.alpha = 0
                self.view.frame.origin.x = parentVC.view.bounds.width
            },
            completion: { _ in
                self.willMove(toParent: nil)
                self.view.removeFromSuperview()
                self.removeFromParent()
                self.onDismissed?()
            }
        )
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
