// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common
import Shared

enum FloorpPanelRegistryItem: Hashable {
    case panel(String)
    case autoUnload
    case restoreBuiltIns
}

@MainActor
final class FloorpPanelRegistryAutoUnloadSwitch: UISwitch {
    var expectedRevision: FloorpOverlayDrawerConfigRevision

    init(config: FloorpOverlayDrawerConfig) {
        expectedRevision = FloorpOverlayDrawerConfigRevision(config: config)
        super.init(frame: .zero)
        isOn = config.autoUnload
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct FloorpPanelRegistryMove: Equatable {
    let panelID: String
    let destinationIndex: Int
}

enum FloorpPanelRegistryReorder {
    /// Diffable marks the interactively dragged item as a paired removal and
    /// insertion. Shifted neighbours are unassociated changes, so this yields
    /// the one mutation the manager needs to persist and notify.
    static func move(
        in difference: CollectionDifference<FloorpPanelRegistryItem>,
        finalPanelIDs: [String]
    ) -> FloorpPanelRegistryMove? {
        let movedPanelIDs = difference.compactMap { change -> String? in
            guard case .remove(_, .panel(let id), let associatedOffset) = change,
                  associatedOffset != nil else { return nil }
            return id
        }
        guard movedPanelIDs.count == 1,
              let panelID = movedPanelIDs.first,
              let destinationIndex = finalPanelIDs.firstIndex(of: panelID) else { return nil }
        return FloorpPanelRegistryMove(panelID: panelID, destinationIndex: destinationIndex)
    }
}

struct FloorpWebPanelAddressSummary: Equatable {
    enum Status: Equatable {
        case secure
        case insecureHTTP
        case needsAttention
    }

    let host: String?
    let status: Status

    static func make(urlText: String?) -> FloorpWebPanelAddressSummary {
        guard let urlText,
              let validated = try? FloorpWebPanelValidator.validate(
                FloorpWebPanelDraft(title: "Panel", urlText: urlText, iconName: "globe")
              ) else {
            return FloorpWebPanelAddressSummary(host: nil, status: .needsAttention)
        }
        return FloorpWebPanelAddressSummary(
            host: validated.url.host,
            status: validated.url.scheme?.lowercased() == "http" ? .insecureHTTP : .secure
        )
    }

    static func make(validatedURL: URL) -> FloorpWebPanelAddressSummary {
        FloorpWebPanelAddressSummary(
            host: validatedURL.host,
            status: validatedURL.scheme?.lowercased() == "http" ? .insecureHTTP : .secure
        )
    }
}

struct FloorpPanelRegistryErrorPresentation: Equatable {
    let title: String
    let message: String
}

enum FloorpPanelRegistryErrorMapper {
    static func presentation(for error: Error?) -> FloorpPanelRegistryErrorPresentation {
        if let error = error as? FloorpPanelError {
            switch error {
            case .panelLimitReached:
                return FloorpPanelRegistryErrorPresentation(
                    title: FloorpStrings.PanelRegistry.panelLimitTitle,
                    message: FloorpStrings.PanelRegistry.panelLimitMessage
                )
            case .cannotRemoveLastPanel:
                return FloorpPanelRegistryErrorPresentation(
                    title: FloorpStrings.PanelRegistry.lastPanelTitle,
                    message: FloorpStrings.PanelRegistry.lastPanelMessage
                )
            case .registryReadOnly:
                return FloorpPanelRegistryErrorPresentation(
                    title: FloorpStrings.PanelRegistry.registryReadOnlyTitle,
                    message: FloorpStrings.PanelRegistry.registryReadOnlyMessage
                )
            case .editConflict:
                return FloorpPanelRegistryErrorPresentation(
                    title: FloorpStrings.PanelRegistry.editConflictTitle,
                    message: FloorpStrings.PanelRegistry.editConflictMessage
                )
            default:
                break
            }
        }

        if let error = error as? FloorpWebPanelValidationError {
            let message: String
            switch error {
            case .emptyTitle, .titleTooLong, .titleContainsControlCharacters:
                message = FloorpStrings.PanelRegistry.invalidTitleMessage
            case .unsupportedScheme:
                message = FloorpStrings.PanelRegistry.unsupportedSchemeMessage
            case .credentialsNotAllowed:
                message = FloorpStrings.PanelRegistry.credentialsNotAllowedMessage
            case .unsupportedIcon:
                message = FloorpStrings.PanelRegistry.unsupportedIconMessage
            case .emptyURL, .urlTooLong, .urlContainsControlCharacters, .invalidURL, .missingHost:
                message = FloorpStrings.PanelRegistry.invalidURLMessage
            }
            return FloorpPanelRegistryErrorPresentation(
                title: FloorpStrings.PanelRegistry.validationFailedTitle,
                message: message
            )
        }

        return FloorpPanelRegistryErrorPresentation(
            title: FloorpStrings.PanelRegistry.operationFailedTitle,
            message: FloorpStrings.PanelRegistry.operationFailedMessage
        )
    }
}

/// Manages the profile-wide set of panels shown in Floorp's sidebar.
///
/// The registry is deliberately separate from the drawer's window-scoped
/// presentation state. Adding, removing, editing, or moving a panel here is
/// reflected in every window, while the selected panel remains window-local.
@MainActor
final class FloorpPanelRegistryViewController: UIViewController,
                                               Themeable,
                                               UICollectionViewDelegate {
    private enum Section: Int, CaseIterable {
        case panels
        case settings
        case recovery
    }

    private typealias Item = FloorpPanelRegistryItem
    typealias AutoUnloadMutation = @MainActor (
        Bool,
        FloorpOverlayDrawerConfigRevision
    ) throws -> FloorpOverlayDrawerConfig

    private enum EditorRequest {
        case add(FloorpWebPanelDraft?)
        case edit(String)
    }

    // MARK: - Themeable

    var themeManager: ThemeManager
    var themeListenerCancellable: Any?
    var notificationCenter: NotificationProtocol
    let windowUUID: WindowUUID
    var currentWindowUUID: UUID? { windowUUID }

    // MARK: - Public integration

    /// Called by the sheet host when the user finishes managing panels.
    var onDone: (() -> Void)?

    private let panelManager: FloorpPanelManager
    private let autoUnloadMutation: AutoUnloadMutation
    private var webPanelSuggestion: FloorpWebPanelDraft?
    private var pendingEditorRequest: EditorRequest?
    private var isViewVisible = false

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.delegate = self
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "Floorp.PanelRegistry.collection"
        return view
    }()

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

    private lazy var addButton = UIBarButtonItem(
        barButtonSystemItem: .add,
        target: self,
        action: #selector(addTapped)
    )

    private lazy var editButton = UIBarButtonItem(
        barButtonSystemItem: .edit,
        target: self,
        action: #selector(editTapped)
    )

    private lazy var closeButton = UIBarButtonItem(
        barButtonSystemItem: .done,
        target: self,
        action: #selector(doneTapped)
    )

    init(
        panelManager: FloorpPanelManager,
        windowUUID: WindowUUID,
        webPanelSuggestion: FloorpWebPanelDraft? = nil,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        autoUnloadMutation: AutoUnloadMutation? = nil
    ) {
        self.panelManager = panelManager
        self.autoUnloadMutation = autoUnloadMutation ?? { value, expectedRevision in
            try panelManager.setAutoUnload(value, expectedRevision: expectedRevision)
        }
        self.windowUUID = windowUUID
        self.webPanelSuggestion = webPanelSuggestion
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FloorpStrings.PanelRegistry.title
        navigationItem.leftBarButtonItem = closeButton
        navigationItem.rightBarButtonItems = [addButton, editButton]
        addButton.accessibilityLabel = FloorpStrings.PanelRegistry.addWebPanel
        editButton.accessibilityLabel = FloorpStrings.PanelRegistry.edit
        closeButton.accessibilityLabel = FloorpStrings.PanelRegistry.done

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        applySnapshot(animatingDifferences: false)
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        notificationCenter.addObserver(
            self,
            selector: #selector(panelRegistryDidChange),
            name: .FloorpPanelRegistryDidChange,
            object: panelManager
        )
        applyTheme()
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isViewLoaded else { return }
        applySnapshot(animatingDifferences: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        presentPendingEditorIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isViewVisible = false
    }

    // MARK: - Drawer entry points

    /// Opens the add editor. If the registry has not appeared yet, the request
    /// is retained until `viewDidAppear` so modal presentation remains valid.
    func presentEditor(for panelID: String?) {
        let request: EditorRequest
        if let panelID {
            request = .edit(panelID)
        } else {
            request = .add(takeWebPanelSuggestion())
        }
        enqueueOrPresentEditor(request)
    }

    /// Convenience entry point for a rail add button. When a presenter is
    /// supplied, only the editor is shown; otherwise it follows the registry's
    /// pending-presentation path.
    func presentAddEditor(from presentingViewController: UIViewController? = nil) {
        guard let presentingViewController,
              presentingViewController !== self,
              presentingViewController !== navigationController else {
            presentEditor(for: nil)
            return
        }

        let request = EditorRequest.add(takeWebPanelSuggestion())
        presentEditor(request, from: presentingViewController)
    }

    // MARK: - Collection view

    private func makeLayout(backgroundColor: UIColor? = nil) -> UICollectionViewCompositionalLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = backgroundColor ?? .systemGroupedBackground
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<
            UICollectionViewListCell,
            Item
        > { [weak self] cell, _, item in
            self?.configure(cell: cell, for: item)
        }

        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: item
            )
        }
        self.dataSource = dataSource

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            self?.configure(header: header, for: indexPath.section)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }

        dataSource.reorderingHandlers.canReorderItem = { [weak self] item in
            guard self?.isEditing == true else { return false }
            if case .panel = item { return true }
            return false
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let panelIDs = transaction.finalSnapshot.itemIdentifiers(inSection: .panels).compactMap { item in
                if case .panel(let id) = item { return id }
                return nil
            }
            let move = FloorpPanelRegistryReorder.move(
                in: transaction.difference,
                finalPanelIDs: panelIDs
            )
            DispatchQueue.main.async { [weak self] in
                self?.persist(move: move)
            }
        }
    }

    func configure(cell: UICollectionViewListCell, for item: FloorpPanelRegistryItem) {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = theme.colors.layer2
        cell.backgroundConfiguration = background
        cell.accessories = []
        cell.accessibilityCustomActions = nil
        cell.accessibilityValue = nil
        cell.accessibilityElements = nil
        cell.isAccessibilityElement = true
        cell.isUserInteractionEnabled = true
        cell.accessibilityTraits = []

        switch item {
        case .panel(let id):
            guard let panel = panelManager.panel(for: id) else { return }
            configurePanelCell(cell, panel: panel)
        case .autoUnload:
            configureAutoUnloadCell(cell)
        case .restoreBuiltIns:
            configureRestoreCell(cell)
        }
    }

    private func configurePanelCell(_ cell: UICollectionViewListCell, panel: FloorpPanel) {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let isWebPanel = panel.type == .web
        let needsAttention = isWebPanel && (try? FloorpWebPanelValidator.validate(panel)) == nil
        let title = isWebPanel
            ? panel.safeDisplayTitle ?? FloorpStrings.PanelRegistry.needsAttention
            : panel.type.localizedBuiltInTitle ?? FloorpStrings.PanelRegistry.builtInPanel
        let kind = isWebPanel
            ? FloorpStrings.PanelRegistry.webPanel
            : FloorpStrings.PanelRegistry.builtInPanel
        let addressSummary = isWebPanel
            ? FloorpWebPanelAddressSummary.make(urlText: panel.url)
            : FloorpWebPanelAddressSummary(host: nil, status: .needsAttention)

        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = isWebPanel
            ? webPanelSubtitle(for: addressSummary, needsAttention: needsAttention)
            : kind
        let iconName = isWebPanel && FloorpWebPanelValidator.curatedIconNames.contains(panel.iconName)
            ? panel.iconName
            : panel.type.systemIconName
        content.image = UIImage(systemName: iconName) ?? UIImage(systemName: "globe")
        content.textProperties.color = theme.colors.textPrimary
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = theme.colors.textSecondary
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.numberOfLines = 2
        content.imageProperties.tintColor = theme.colors.iconSecondary
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        cell.contentConfiguration = content

        cell.accessories = [
            .delete(displayed: .whenEditing, actionHandler: { [weak self] in
                self?.requestRemoval(of: panel.id)
            }),
            .reorder(displayed: .whenEditing),
        ]
        cell.accessibilityIdentifier = "Floorp.PanelRegistry.panel.\(panel.sortOrder)"
        cell.accessibilityLabel = FloorpStrings.PanelRegistry.panelAccessibilityLabel(
            title: title,
            kind: kind
        )
        cell.accessibilityHint = accessibilityHint(
            forWebPanel: isWebPanel,
            addressSummary: addressSummary,
            needsAttention: needsAttention
        )
        cell.accessibilityValue = needsAttention ? FloorpStrings.PanelRegistry.needsAttention : nil
        if isWebPanel {
            cell.accessibilityTraits.insert(.button)
        }
        cell.accessibilityCustomActions = accessibilityActions(for: panel)
    }

    private func configureAutoUnloadCell(_ cell: UICollectionViewListCell) {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let config = panelManager.config
        var content = UIListContentConfiguration.subtitleCell()
        content.text = FloorpStrings.PanelRegistry.autoUnload
        content.secondaryText = FloorpStrings.PanelRegistry.autoUnloadDescription
        content.textProperties.color = theme.colors.textPrimary
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = theme.colors.textSecondary
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let toggle = FloorpPanelRegistryAutoUnloadSwitch(config: config)
        toggle.onTintColor = theme.colors.actionPrimary
        toggle.accessibilityIdentifier = "Floorp.PanelRegistry.autoUnload"
        toggle.accessibilityLabel = FloorpStrings.PanelRegistry.autoUnload
        toggle.accessibilityHint = FloorpStrings.PanelRegistry.autoUnloadDescription
        toggle.isAccessibilityElement = true
        toggle.addTarget(
            self,
            action: #selector(autoUnloadSwitchChanged(_:)),
            for: .valueChanged
        )
        cell.accessories = [
            .customView(configuration: .init(
                customView: toggle,
                placement: .trailing(displayed: .always)
            )),
        ]
        cell.accessibilityIdentifier = "Floorp.PanelRegistry.autoUnloadRow"
        cell.accessibilityLabel = nil
        cell.accessibilityHint = nil
        cell.isAccessibilityElement = false
        cell.accessibilityElements = [toggle]
    }

    private func webPanelSubtitle(
        for summary: FloorpWebPanelAddressSummary,
        needsAttention: Bool
    ) -> String {
        if needsAttention {
            return summary.host.map { FloorpStrings.PanelRegistry.attentionHost(host: $0) }
                ?? FloorpStrings.PanelRegistry.needsAttention
        }
        switch summary.status {
        case .secure:
            return summary.host ?? FloorpStrings.PanelRegistry.needsAttention
        case .insecureHTTP:
            return FloorpStrings.PanelRegistry.insecureHost(
                host: summary.host ?? FloorpStrings.PanelRegistry.needsAttention
            )
        case .needsAttention:
            return FloorpStrings.PanelRegistry.needsAttention
        }
    }

    private func accessibilityHint(
        forWebPanel isWebPanel: Bool,
        addressSummary: FloorpWebPanelAddressSummary,
        needsAttention: Bool
    ) -> String {
        guard isWebPanel else { return FloorpStrings.PanelRegistry.reorderAccessibilityHint }
        if needsAttention {
            return FloorpStrings.PanelRegistry.needsAttentionAccessibilityHint
        }
        switch addressSummary.status {
        case .secure:
            return FloorpStrings.PanelRegistry.webPanelAccessibilityHint
        case .insecureHTTP:
            return FloorpStrings.PanelRegistry.insecureHTTPAccessibilityHint
        case .needsAttention:
            return FloorpStrings.PanelRegistry.needsAttentionAccessibilityHint
        }
    }

    private func configureRestoreCell(_ cell: UICollectionViewListCell) {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let hasMissingBuiltIns = missingBuiltInPanelCount > 0
        var content = UIListContentConfiguration.subtitleCell()
        content.text = FloorpStrings.PanelRegistry.restoreBuiltIns
        content.secondaryText = hasMissingBuiltIns
            ? FloorpStrings.PanelRegistry.restoreBuiltInsDescription
            : FloorpStrings.PanelRegistry.allBuiltInsVisible
        content.image = UIImage(systemName: "arrow.counterclockwise")
        content.textProperties.color = hasMissingBuiltIns
            ? theme.colors.actionPrimary
            : theme.colors.textSecondary
        content.secondaryTextProperties.color = theme.colors.textSecondary
        content.secondaryTextProperties.numberOfLines = 0
        content.imageProperties.tintColor = hasMissingBuiltIns
            ? theme.colors.actionPrimary
            : theme.colors.iconSecondary
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "Floorp.PanelRegistry.restoreBuiltIns"
        cell.accessibilityLabel = FloorpStrings.PanelRegistry.restoreBuiltIns
        cell.accessibilityHint = content.secondaryText
        cell.accessibilityTraits = hasMissingBuiltIns ? .button : .notEnabled
        cell.isUserInteractionEnabled = hasMissingBuiltIns
    }

    private func configure(header: UICollectionViewListCell, for sectionIndex: Int) {
        guard let section = Section(rawValue: sectionIndex) else { return }
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        var content = UIListContentConfiguration.groupedHeader()
        switch section {
        case .panels:
            content.text = FloorpStrings.PanelRegistry.panelsSection
        case .settings:
            content.text = FloorpStrings.PanelRegistry.settingsSection
        case .recovery:
            content.text = FloorpStrings.PanelRegistry.recoverySection
        }
        content.textProperties.color = theme.colors.textSecondary
        header.contentConfiguration = content
    }

    private func applySnapshot(animatingDifferences: Bool = true) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(panelManager.panels.map { .panel($0.id) }, toSection: .panels)
        snapshot.appendItems([.autoUnload], toSection: .settings)
        snapshot.appendItems([.restoreBuiltIns], toSection: .recovery)

        let currentItems = Set(dataSource.snapshot().itemIdentifiers)
        let itemsToReload = snapshot.itemIdentifiers.filter(currentItems.contains)
        if !itemsToReload.isEmpty {
            snapshot.reloadItems(itemsToReload)
        }
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    // MARK: - Actions and mutations

    @objc private func addTapped() {
        presentEditor(for: nil)
    }

    @objc private func editTapped() {
        setEditing(true, animated: true)
    }

    @objc private func doneEditingTapped() {
        setEditing(false, animated: true)
    }

    @objc private func doneTapped() {
        if isEditing {
            setEditing(false, animated: false)
        }
        if let onDone {
            onDone()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }

    @objc private func autoUnloadSwitchChanged(_ control: UISwitch) {
        guard let control = control as? FloorpPanelRegistryAutoUnloadSwitch else { return }
        let currentConfig = panelManager.config
        guard control.isOn != currentConfig.autoUnload else {
            update(control: control, with: currentConfig, animated: false)
            return
        }

        do {
            let updatedConfig = try autoUnloadMutation(
                control.isOn,
                control.expectedRevision
            )
            update(control: control, with: updatedConfig, animated: false)
        } catch {
            update(control: control, with: panelManager.config, animated: true)
            applySnapshot(animatingDifferences: false)
            presentOperationError(error)
        }
    }

    private func update(
        control: FloorpPanelRegistryAutoUnloadSwitch,
        with config: FloorpOverlayDrawerConfig,
        animated: Bool
    ) {
        control.expectedRevision = FloorpOverlayDrawerConfigRevision(config: config)
        control.setOn(config.autoUnload, animated: animated)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        editButton = UIBarButtonItem(
            barButtonSystemItem: editing ? .done : .edit,
            target: self,
            action: editing ? #selector(doneEditingTapped) : #selector(editTapped)
        )
        editButton.accessibilityLabel = editing
            ? FloorpStrings.PanelRegistry.doneEditing
            : FloorpStrings.PanelRegistry.edit
        addButton.isEnabled = !editing
        navigationItem.rightBarButtonItems = [addButton, editButton]
        applySnapshot(animatingDifferences: animated)
    }

    @objc private func panelRegistryDidChange() {
        guard isViewLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applySnapshot(animatingDifferences: true)
        }
    }

    private func persist(move: FloorpPanelRegistryMove?) {
        guard let move else {
            applySnapshot(animatingDifferences: false)
            return
        }
        do {
            _ = try panelManager.movePanel(id: move.panelID, to: move.destinationIndex)
            applySnapshot(animatingDifferences: false)
        } catch {
            applySnapshot(animatingDifferences: false)
            presentOperationError(error)
        }
    }

    private func movePanel(id: String, offset: Int) -> Bool {
        guard let currentIndex = panelManager.panels.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let destinationIndex = currentIndex + offset
        guard panelManager.panels.indices.contains(destinationIndex) else { return false }

        do {
            _ = try panelManager.movePanel(id: id, to: destinationIndex)
            applySnapshot()
            let panelTitle = panelManager.panel(for: id).map(displayTitle(for:))
                ?? FloorpStrings.PanelRegistry.needsAttention
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.PanelRegistry.moveAnnouncement(
                    title: panelTitle,
                    position: destinationIndex + 1
                )
            )
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.presentOperationError(error)
            }
            return false
        }
    }

    private func requestRemoval(of id: String) {
        guard let panel = panelManager.panel(for: id) else { return }
        let panelTitle = displayTitle(for: panel)
        let isWebPanel = panel.type == .web
        let alert = UIAlertController(
            title: isWebPanel
                ? FloorpStrings.PanelRegistry.deleteWebPanelTitle
                : FloorpStrings.PanelRegistry.removeBuiltInTitle,
            message: isWebPanel
                ? FloorpStrings.PanelRegistry.deleteWebPanelMessage(title: panelTitle)
                : FloorpStrings.PanelRegistry.removeBuiltInMessage(title: panelTitle),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FloorpStrings.PanelRegistry.cancel,
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: isWebPanel
                ? FloorpStrings.PanelRegistry.delete
                : FloorpStrings.PanelRegistry.removeFromSidebar,
            style: isWebPanel ? .destructive : .default,
            handler: { [weak self] _ in
                self?.removePanel(id: id, announcementTitle: panelTitle)
            }
        ))
        present(alert, animated: true)
    }

    private func removePanel(id: String, announcementTitle: String) {
        do {
            _ = try panelManager.removePanel(id: id)
            applySnapshot()
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.PanelRegistry.removedAnnouncement(title: announcementTitle)
            )
        } catch {
            // The confirmation alert is still dismissing while its action
            // handler runs. Defer so the operation-specific error is not lost.
            DispatchQueue.main.async { [weak self] in
                self?.presentOperationError(error)
            }
        }
    }

    private func restoreBuiltInPanels() {
        guard missingBuiltInPanelCount > 0 else { return }
        do {
            _ = try panelManager.restoreMissingBuiltIns()
            applySnapshot()
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.PanelRegistry.restoredAnnouncement
            )
        } catch {
            presentOperationError(error)
        }
    }

    // MARK: - Editor presentation

    private func takeWebPanelSuggestion() -> FloorpWebPanelDraft? {
        defer { webPanelSuggestion = nil }
        return webPanelSuggestion
    }

    private func enqueueOrPresentEditor(_ request: EditorRequest) {
        guard isViewLoaded, isViewVisible, view.window != nil, presentedViewController == nil else {
            pendingEditorRequest = request
            return
        }
        presentEditor(request, from: self)
    }

    private func presentPendingEditorIfNeeded() {
        guard let request = pendingEditorRequest, presentedViewController == nil else { return }
        pendingEditorRequest = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, isViewVisible, presentedViewController == nil else { return }
            presentEditor(request, from: self)
        }
    }

    private func presentEditor(_ request: EditorRequest, from presenter: UIViewController) {
        let panel: FloorpPanel?
        let suggestion: FloorpWebPanelDraft?
        switch request {
        case .add(let draft):
            guard panelManager.panels.count < FloorpPanelManager.maximumPanelCount else {
                presentPanelLimitAlert(from: presenter)
                return
            }
            panel = nil
            suggestion = draft
        case .edit(let id):
            guard let existingPanel = panelManager.panel(for: id), existingPanel.type == .web else {
                presentOperationError(nil, from: presenter)
                return
            }
            panel = existingPanel
            suggestion = nil
        }

        let manager = panelManager
        let expectedRevision = panel.map { FloorpWebPanelRevision(panel: $0) }
        let editor = FloorpWebPanelEditorViewController(
            panel: panel,
            initialDraft: suggestion,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter,
            saveHandler: { [weak self] draft in
                if let panel, let expectedRevision {
                    _ = try manager.updateWebPanel(
                        id: panel.id,
                        draft: draft,
                        expectedRevision: expectedRevision
                    )
                } else {
                    _ = try manager.addWebPanel(draft: draft)
                }
                self?.applySnapshot()
            }
        )
        let navigationController = UINavigationController(rootViewController: editor)
        navigationController.modalPresentationStyle = .formSheet
        navigationController.presentationController?.delegate = editor
        presenter.present(navigationController, animated: true) {
            navigationController.presentationController?.delegate = editor
        }
    }

    private func presentPanelLimitAlert(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: FloorpStrings.PanelRegistry.panelLimitTitle,
            message: FloorpStrings.PanelRegistry.panelLimitMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.done, style: .default))
        presenter.present(alert, animated: true)
    }

    private func presentOperationError(_ error: Error?, from presenter: UIViewController? = nil) {
        let errorPresentation = FloorpPanelRegistryErrorMapper.presentation(for: error)
        let alert = UIAlertController(
            title: errorPresentation.title,
            message: errorPresentation.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.done, style: .default))
        (presenter ?? self).present(alert, animated: true)
    }

    // MARK: - Menus, swipe, and accessibility

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource?.itemIdentifier(for: indexPath),
              case .panel(let id) = item,
              let panel = panelManager.panel(for: id) else { return nil }

        let remove = UIContextualAction(
            style: panel.type == .web ? .destructive : .normal,
            title: panel.type == .web
                ? FloorpStrings.PanelRegistry.delete
                : FloorpStrings.PanelRegistry.removeFromSidebar,
            handler: { [weak self] _, _, completion in
                self?.requestRemoval(of: id)
                completion(false)
            }
        )
        if panel.type != .web {
            remove.backgroundColor = .systemOrange
        }

        var actions = [remove]
        if panel.type == .web {
            let edit = UIContextualAction(
                style: .normal,
                title: FloorpStrings.PanelRegistry.edit,
                handler: { [weak self] _, _, completion in
                    self?.presentEditor(for: id)
                    completion(false)
                }
            )
            edit.backgroundColor = .systemBlue
            actions.append(edit)
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func accessibilityActions(for panel: FloorpPanel) -> [UIAccessibilityCustomAction] {
        guard let index = panelManager.panels.firstIndex(where: { $0.id == panel.id }) else { return [] }
        var actions = [UIAccessibilityCustomAction]()
        if panel.type == .web {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.PanelRegistry.edit,
                actionHandler: { [weak self] _ in
                    self?.presentEditor(for: panel.id)
                    return true
                }
            ))
        }
        if index > panelManager.panels.startIndex {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.PanelRegistry.moveUp,
                actionHandler: { [weak self] _ in
                    self?.movePanel(id: panel.id, offset: -1) ?? false
                }
            ))
        }
        if index < panelManager.panels.index(before: panelManager.panels.endIndex) {
            actions.append(UIAccessibilityCustomAction(
                name: FloorpStrings.PanelRegistry.moveDown,
                actionHandler: { [weak self] _ in
                    self?.movePanel(id: panel.id, offset: 1) ?? false
                }
            ))
        }
        actions.append(UIAccessibilityCustomAction(
            name: panel.type == .web
                ? FloorpStrings.PanelRegistry.delete
                : FloorpStrings.PanelRegistry.removeFromSidebar,
            actionHandler: { [weak self] _ in
                self?.requestRemoval(of: panel.id)
                return true
            }
        ))
        return actions
    }

    private var missingBuiltInPanelCount: Int {
        let existingIDs = Set(panelManager.panels.map(\.id))
        return FloorpPanel.defaultPanels().filter { !existingIDs.contains($0.id) }.count
    }

    private func displayTitle(for panel: FloorpPanel) -> String {
        if panel.type == .web {
            return panel.safeDisplayTitle ?? FloorpStrings.PanelRegistry.needsAttention
        }
        return panel.type.localizedBuiltInTitle ?? FloorpStrings.PanelRegistry.builtInPanel
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section == Section.panels.rawValue else {
            let lastPanelIndex = max(0, panelManager.panels.count - 1)
            return IndexPath(item: lastPanelIndex, section: Section.panels.rawValue)
        }
        return proposedIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .panel(let id):
            return panelManager.panel(for: id)?.type == .web
        case .autoUnload:
            return false
        case .restoreBuiltIns:
            return missingBuiltInPanelCount > 0
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .panel(let id):
            presentEditor(for: id)
        case .autoUnload:
            break
        case .restoreBuiltIns:
            restoreBuiltInPanels()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource?.itemIdentifier(for: indexPath),
              case .panel(let id) = item,
              let panel = panelManager.panel(for: id) else { return nil }

        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            var actions = [UIMenuElement]()
            if panel.type == .web {
                actions.append(UIAction(
                    title: FloorpStrings.PanelRegistry.edit,
                    image: UIImage(systemName: "pencil"),
                    handler: { _ in self?.presentEditor(for: id) }
                ))
            }
            actions.append(UIAction(
                title: panel.type == .web
                    ? FloorpStrings.PanelRegistry.delete
                    : FloorpStrings.PanelRegistry.removeFromSidebar,
                image: UIImage(systemName: panel.type == .web ? "trash" : "sidebar.left"),
                attributes: panel.type == .web ? .destructive : [],
                handler: { _ in self?.requestRemoval(of: id) }
            ))
            return UIMenu(children: actions)
        }
    }

    // MARK: - Themeable

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        view.backgroundColor = theme.colors.layer1
        collectionView.setCollectionViewLayout(
            makeLayout(backgroundColor: theme.colors.layer1),
            animated: false
        )
        collectionView.backgroundColor = theme.colors.layer1
        navigationController?.navigationBar.tintColor = theme.colors.actionPrimary
        applySnapshot(animatingDifferences: false)
    }
}

/// Add/edit form for a custom web panel.
@MainActor
final class FloorpWebPanelEditorViewController: UITableViewController,
                                                 Themeable,
                                                 UITextFieldDelegate,
                                                 UIPickerViewDataSource,
                                                 UIPickerViewDelegate,
                                                 UIAdaptivePresentationControllerDelegate {
    typealias SaveHandler = @MainActor (FloorpWebPanelDraft) throws -> Void

    private enum Row: Int, CaseIterable {
        case title
        case url
        case icon
    }

    var themeManager: ThemeManager
    var themeListenerCancellable: Any?
    var notificationCenter: NotificationProtocol
    let windowUUID: WindowUUID
    var currentWindowUUID: UUID? { windowUUID }

    private let isEditingExistingPanel: Bool
    private let initialTitle: String
    private let initialURLText: String
    private let initialIconName: String
    private let saveHandler: SaveHandler
    private let iconNames = FloorpWebPanelValidator.curatedIconNames
    private var selectedIconName: String
    private var isClosingAfterSave = false

    private lazy var iconPicker = UIPickerView()
    private lazy var iconPickerToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: FloorpStrings.PanelRegistry.done,
                style: .done,
                target: self,
                action: #selector(finishIconSelection)
            ),
        ]
        return toolbar
    }()

    private lazy var saveButton = UIBarButtonItem(
        barButtonSystemItem: .save,
        target: self,
        action: #selector(saveTapped)
    )
    private lazy var cancelButton = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: self,
        action: #selector(cancelTapped)
    )

    private lazy var titleCell = makeFieldCell(
        label: FloorpStrings.PanelRegistry.titleField,
        placeholder: FloorpStrings.PanelRegistry.titlePlaceholder,
        identifier: "Floorp.WebPanelEditor.title"
    )
    private lazy var urlCell = makeFieldCell(
        label: FloorpStrings.PanelRegistry.urlField,
        placeholder: FloorpStrings.PanelRegistry.urlPlaceholder,
        identifier: "Floorp.WebPanelEditor.url"
    )
    private lazy var iconCell = makeFieldCell(
        label: FloorpStrings.PanelRegistry.iconField,
        placeholder: FloorpStrings.PanelRegistry.iconPlaceholder,
        identifier: "Floorp.WebPanelEditor.icon",
        showsIconPreview: true
    )

    init(
        panel: FloorpPanel?,
        initialDraft: FloorpWebPanelDraft? = nil,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        saveHandler: @escaping SaveHandler
    ) {
        isEditingExistingPanel = panel != nil
        initialTitle = initialDraft?.title ?? panel?.title ?? ""
        initialURLText = initialDraft?.urlText ?? panel?.url ?? ""
        let requestedIconName = initialDraft?.iconName ?? panel?.iconName ?? FloorpPanelType.web.systemIconName
        let normalizedIconName = FloorpWebPanelValidator.curatedIconNames.contains(requestedIconName)
            ? requestedIconName
            : FloorpPanelType.web.systemIconName
        initialIconName = normalizedIconName
        selectedIconName = normalizedIconName
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.saveHandler = saveHandler
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isEditingExistingPanel
            ? FloorpStrings.PanelRegistry.editWebPanel
            : FloorpStrings.PanelRegistry.addWebPanel
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = saveButton
        cancelButton.accessibilityLabel = FloorpStrings.PanelRegistry.cancel
        saveButton.accessibilityLabel = FloorpStrings.PanelRegistry.saveAccessibilityLabel

        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.accessibilityIdentifier = "Floorp.WebPanelEditor.form"

        titleCell.textField.text = initialTitle
        titleCell.textField.returnKeyType = .next

        urlCell.textField.text = initialURLText
        urlCell.textField.textContentType = .URL
        urlCell.textField.keyboardType = .URL
        urlCell.textField.autocapitalizationType = .none
        urlCell.textField.autocorrectionType = .no
        urlCell.textField.smartDashesType = .no
        urlCell.textField.smartQuotesType = .no
        urlCell.textField.returnKeyType = .next

        iconCell.textField.text = FloorpStrings.PanelRegistry.iconDisplayName(for: selectedIconName)
        iconCell.textField.autocapitalizationType = .none
        iconCell.textField.autocorrectionType = .no
        iconCell.textField.returnKeyType = .done
        iconCell.textField.inputView = iconPicker
        iconCell.textField.inputAccessoryView = iconPickerToolbar
        iconPicker.dataSource = self
        iconPicker.delegate = self
        if let selectedIconIndex = iconNames.firstIndex(of: initialIconName) {
            iconPicker.selectRow(selectedIconIndex, inComponent: 0, animated: false)
        } else if let defaultIconIndex = iconNames.firstIndex(of: FloorpPanelType.web.systemIconName) {
            selectedIconName = FloorpPanelType.web.systemIconName
            iconCell.textField.text = FloorpStrings.PanelRegistry.iconDisplayName(for: selectedIconName)
            iconPicker.selectRow(defaultIconIndex, inComponent: 0, animated: false)
        }

        [titleCell, urlCell, iconCell].forEach { cell in
            cell.textField.delegate = self
            cell.textField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        }
        updateFormState()
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
    }

    // MARK: - Form

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = Row(rawValue: indexPath.row) else { return UITableViewCell() }
        switch row {
        case .title: return titleCell
        case .url: return urlCell
        case .icon: return iconCell
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        FloorpStrings.PanelRegistry.detailsSection
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        FloorpStrings.PanelRegistry.iconHelp
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let row = Row(rawValue: indexPath.row) else { return }
        switch row {
        case .title: titleCell.textField.becomeFirstResponder()
        case .url: urlCell.textField.becomeFirstResponder()
        case .icon: iconCell.textField.becomeFirstResponder()
        }
    }

    private func makeFieldCell(
        label: String,
        placeholder: String,
        identifier: String,
        showsIconPreview: Bool = false
    ) -> FloorpWebPanelFieldCell {
        let cell = FloorpWebPanelFieldCell(showsIconPreview: showsIconPreview)
        cell.configure(label: label, placeholder: placeholder, accessibilityIdentifier: identifier)
        return cell
    }

    @objc private func fieldChanged() {
        updateFormState()
    }

    private func updateFormState() {
        let title = titleCell.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = urlCell.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        saveButton.isEnabled = !title.isEmpty && !url.isEmpty

        let addressSummary = FloorpWebPanelAddressSummary.make(urlText: url)
        let messageVisibilityChanged: Bool
        if addressSummary.status == .insecureHTTP {
            messageVisibilityChanged = urlCell.setMessage(
                FloorpStrings.PanelRegistry.insecureHTTPWarning,
                color: .systemOrange
            )
        } else {
            messageVisibilityChanged = urlCell.setMessage(nil, color: .systemOrange)
        }
        if messageVisibilityChanged, tableView.window != nil {
            tableView.beginUpdates()
            tableView.endUpdates()
        }

        iconCell.updateIconPreview(named: selectedIconName)
    }

    @objc private func saveTapped() {
        let title = titleCell.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlText = urlCell.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !urlText.isEmpty else { return }

        let draft = FloorpWebPanelDraft(title: title, urlText: urlText, iconName: selectedIconName)
        do {
            _ = try FloorpWebPanelValidator.validate(draft)
            try saveHandler(draft)
            isClosingAfterSave = true
            dismiss(animated: true)
        } catch let validationError as FloorpWebPanelValidationError {
            presentValidationError(validationError)
        } catch {
            presentOperationError(error)
        }
    }

    @objc private func cancelTapped() {
        attemptToClose()
    }

    @objc private func finishIconSelection() {
        iconCell.textField.resignFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case titleCell.textField:
            urlCell.textField.becomeFirstResponder()
        case urlCell.textField:
            iconCell.textField.becomeFirstResponder()
        default:
            if saveButton.isEnabled {
                saveTapped()
            } else {
                textField.resignFirstResponder()
            }
        }
        return true
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        textField !== iconCell.textField
    }

    // MARK: - Icon picker

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        iconNames.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard iconNames.indices.contains(row) else { return nil }
        return FloorpStrings.PanelRegistry.iconDisplayName(for: iconNames[row])
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard iconNames.indices.contains(row) else { return }
        selectedIconName = iconNames[row]
        iconCell.textField.text = FloorpStrings.PanelRegistry.iconDisplayName(for: selectedIconName)
        iconCell.textField.sendActions(for: .editingChanged)
    }

    // MARK: - Dismissal protection

    private var hasUnsavedChanges: Bool {
        guard !isClosingAfterSave else { return false }
        return titleCell.textField.text != initialTitle
            || urlCell.textField.text != initialURLText
            || selectedIconName != initialIconName
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !hasUnsavedChanges
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        attemptToClose()
    }

    private func attemptToClose() {
        guard hasUnsavedChanges else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(
            title: FloorpStrings.PanelRegistry.discardChangesTitle,
            message: FloorpStrings.PanelRegistry.discardChangesMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FloorpStrings.PanelRegistry.keepEditing,
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: FloorpStrings.PanelRegistry.discardChanges,
            style: .destructive,
            handler: { [weak self] _ in
                self?.isClosingAfterSave = true
                self?.dismiss(animated: true)
            }
        ))
        present(alert, animated: true)
    }

    // MARK: - Error handling

    private func presentValidationError(_ error: FloorpWebPanelValidationError) {
        let errorPresentation = FloorpPanelRegistryErrorMapper.presentation(for: error)
        let alert = UIAlertController(
            title: errorPresentation.title,
            message: errorPresentation.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FloorpStrings.PanelRegistry.done,
            style: .default,
            handler: { [weak self] _ in
                self?.focusFirstInvalidField(for: error)
            }
        ))
        present(alert, animated: true)
    }

    private func focusFirstInvalidField(for error: FloorpWebPanelValidationError) {
        let textField: UITextField
        switch error {
        case .emptyTitle, .titleTooLong, .titleContainsControlCharacters:
            textField = titleCell.textField
        case .unsupportedIcon:
            textField = iconCell.textField
        case .emptyURL, .urlTooLong, .urlContainsControlCharacters, .invalidURL,
             .unsupportedScheme, .missingHost, .credentialsNotAllowed:
            textField = urlCell.textField
        }
        textField.becomeFirstResponder()
        UIAccessibility.post(notification: .layoutChanged, argument: textField)
    }

    private func presentOperationError(_ error: Error) {
        let errorPresentation = FloorpPanelRegistryErrorMapper.presentation(for: error)
        let alert = UIAlertController(
            title: errorPresentation.title,
            message: errorPresentation.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.PanelRegistry.done, style: .default))
        present(alert, animated: true)
    }

    // MARK: - Themeable

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        view.backgroundColor = theme.colors.layer1
        tableView.backgroundColor = theme.colors.layer1
        tableView.separatorColor = theme.colors.borderPrimary
        navigationController?.navigationBar.tintColor = theme.colors.actionPrimary
        [titleCell, urlCell, iconCell].forEach {
            $0.applyTheme(
                backgroundColor: theme.colors.layer2,
                textColor: theme.colors.textPrimary,
                secondaryTextColor: theme.colors.textSecondary,
                tintColor: theme.colors.actionPrimary
            )
        }
    }
}

@MainActor
private final class FloorpWebPanelFieldCell: UITableViewCell {
    let textField = UITextField()

    private let fieldLabel = UILabel()
    private let iconPreview = UIImageView()
    private let messageLabel = UILabel()
    private let showsIconPreview: Bool
    private var fieldPlaceholder = ""

    init(showsIconPreview: Bool) {
        self.showsIconPreview = showsIconPreview
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none

        fieldLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldLabel.font = .preferredFont(forTextStyle: .caption1)
        fieldLabel.adjustsFontForContentSizeCategory = true

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .whileEditing

        iconPreview.translatesAutoresizingMaskIntoConstraints = false
        iconPreview.contentMode = .scaleAspectFit
        iconPreview.isAccessibilityElement = false
        iconPreview.isHidden = !showsIconPreview

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true

        contentView.addSubview(fieldLabel)
        contentView.addSubview(textField)
        contentView.addSubview(iconPreview)
        contentView.addSubview(messageLabel)

        let trailingConstraint = showsIconPreview
            ? textField.trailingAnchor.constraint(equalTo: iconPreview.leadingAnchor, constant: -12)
            : textField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
        NSLayoutConstraint.activate([
            fieldLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            fieldLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            fieldLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            textField.topAnchor.constraint(equalTo: fieldLabel.bottomAnchor, constant: 2),
            textField.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            trailingConstraint,
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            messageLabel.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 2),
            messageLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            messageLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),

            iconPreview.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            iconPreview.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            iconPreview.widthAnchor.constraint(equalToConstant: 28),
            iconPreview.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(label: String, placeholder: String, accessibilityIdentifier: String) {
        fieldLabel.text = label
        fieldPlaceholder = placeholder
        textField.placeholder = placeholder
        textField.accessibilityLabel = label
        textField.accessibilityIdentifier = accessibilityIdentifier
        if showsIconPreview {
            textField.accessibilityHint = FloorpStrings.PanelRegistry.iconHelp
        }
    }

    func updateIconPreview(named iconName: String) {
        guard showsIconPreview else { return }
        iconPreview.image = UIImage(systemName: iconName) ?? UIImage(systemName: "globe")
    }

    @discardableResult
    func setMessage(_ message: String?, color: UIColor) -> Bool {
        let wasHidden = messageLabel.isHidden
        messageLabel.text = message
        messageLabel.textColor = color
        messageLabel.isHidden = message == nil
        messageLabel.accessibilityIdentifier = message == nil ? nil : "Floorp.WebPanelEditor.fieldMessage"
        return wasHidden != messageLabel.isHidden
    }

    func applyTheme(
        backgroundColor: UIColor,
        textColor: UIColor,
        secondaryTextColor: UIColor,
        tintColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        contentView.backgroundColor = backgroundColor
        fieldLabel.textColor = secondaryTextColor
        textField.textColor = textColor
        textField.tintColor = tintColor
        textField.attributedPlaceholder = NSAttributedString(
            string: fieldPlaceholder,
            attributes: [.foregroundColor: secondaryTextColor]
        )
        iconPreview.tintColor = tintColor
    }
}
