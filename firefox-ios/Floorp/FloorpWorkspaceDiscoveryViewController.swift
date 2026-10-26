// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

@MainActor
final class FloorpWorkspaceDiscoveryViewController: UITableViewController {
    private let coordinator: FloorpWorkspaceDiscoveryCoordinator
    private let destination: FloorpWorkspaceCopyDestination
    private let onCopied: () -> Void
    private var observer: NSObjectProtocol?
    private var pendingCopy: FloorpWorkspacePendingCopy?
    private var isCopying = false
    private var copyProgress: FloorpWorkspaceCopyProgress?
    private var workspaceSection: Int { pendingCopy == nil ? 1 : 2 }

    init(coordinator: FloorpWorkspaceDiscoveryCoordinator,
         destination: FloorpWorkspaceCopyDestination,
         onCopied: @escaping () -> Void) {
        self.coordinator = coordinator
        self.destination = destination
        self.onCopied = onCopied
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FloorpStrings.Workspaces.title
        tableView.accessibilityIdentifier = "Floorp.Workspaces.List"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh,
                                                           target: self,
                                                           action: #selector(refresh))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        observer = NotificationCenter.default.addObserver(
            forName: .floorpWorkspaceDiscoveryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        coordinator.refresh()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        reload()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func refresh() {
        if !coordinator.isEnabled { coordinator.setEnabled(true) }
        coordinator.refresh()
    }

    private func reload() {
        if coordinator.state != .loading { refreshControl?.endRefreshing() }
        let previousOperation = pendingCopy?.operationID
        if let token = coordinator.ownershipToken {
            pendingCopy = try? FloorpWorkspaceCopyService.shared.pendingOperation(
                generation: token, destination: destination
            )
        } else {
            pendingCopy = nil
        }
        if previousOperation != pendingCopy?.operationID { copyProgress = nil }
        navigationItem.rightBarButtonItem?.isEnabled = !isCopying
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { workspaceSection + 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == workspaceSection ? max(coordinator.workspaces.count, 1) : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        if indexPath.section == 0 {
            content.text = FloorpStrings.Workspaces.receiveUpdates
            let toggle = UISwitch()
            toggle.isOn = coordinator.isEnabled
            toggle.isEnabled = coordinator.state != .runtimeUnavailable
            toggle.accessibilityLabel = FloorpStrings.Workspaces.receiveUpdates
            toggle.addTarget(self, action: #selector(toggleUpdates(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if indexPath.section != workspaceSection, let pendingCopy {
            content.text = FloorpStrings.Workspaces.retryCopy
            let progress = copyProgress ?? pendingCopy.progress
            content.secondaryText = String(format: FloorpStrings.Workspaces.copyProgress,
                                           progress.completed,
                                           progress.total)
            content.image = UIImage(systemName: "arrow.clockwise")
            cell.accessoryType = .disclosureIndicator
        } else if coordinator.workspaces.isEmpty {
            content.text = statusText
            cell.selectionStyle = .none
        } else {
            let workspace = coordinator.workspaces[indexPath.row]
            content.text = workspace.name.isEmpty ? FloorpStrings.Workspaces.untitled : workspace.name
            content.secondaryText = String(format: FloorpStrings.Workspaces.tabCount, workspace.tabs.count)
            content.image = UIImage(systemName: Self.icon(for: workspace.icon))
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "Floorp.Workspaces.Workspace.\(workspace.id)"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return FloorpStrings.Workspaces.independentCopies }
        if section != workspaceSection { return nil }
        var lines = [statusText]
        if let received = coordinator.lastReceivedAt {
            let date = DateFormatter.localizedString(from: received, dateStyle: .medium, timeStyle: .short)
            lines.append(String(format: FloorpStrings.Workspaces.lastReceived, date))
        }
        lines.append(FloorpStrings.Workspaces.standardSyncNotice)
        return lines.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isCopying, indexPath.section != 0 else { return }
        if indexPath.section != workspaceSection, let pendingCopy {
            offerPendingCopy(pendingCopy)
            return
        }
        guard indexPath.section == workspaceSection,
              coordinator.workspaces.indices.contains(indexPath.row),
              let snapshot = coordinator.snapshot else { return }
        let workspace = coordinator.workspaces[indexPath.row]
        let preview = FloorpWorkspacePreviewViewController(coordinator: coordinator,
                                                           snapshot: snapshot,
                                                           workspaceID: workspace.id,
                                                           destination: destination,
                                                           onCopied: onCopied)
        navigationController?.pushViewController(preview, animated: true)
    }

    @objc private func toggleUpdates(_ toggle: UISwitch) {
        coordinator.setEnabled(toggle.isOn)
        if toggle.isOn { coordinator.refresh() }
        reload()
    }

    private func offerPendingCopy(_ pending: FloorpWorkspacePendingCopy) {
        let progress = String(format: FloorpStrings.Workspaces.copyProgress,
                              pending.progress.completed,
                              pending.progress.total)
        let alert = UIAlertController(title: FloorpStrings.Workspaces.pendingCopy,
                                      message: progress,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FloorpStrings.Workspaces.retryCopy, style: .default) { [weak self] _ in
            self?.resume(pending)
        })
        alert.addAction(UIAlertAction(title: FloorpStrings.Workspaces.cancelCopy, style: .cancel) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try FloorpWorkspaceCopyService.shared.cancelPendingOperations(windowID: self.destination.windowID)
                    try await self.destination.discardUncertainCopyInventory()
                    self.reload()
                } catch {
                    self.showCopyError()
                }
            }
        })
        present(alert, animated: true)
    }

    private func resume(_ pending: FloorpWorkspacePendingCopy) {
        guard !isCopying, let token = coordinator.ownershipToken,
              coordinator.isCopyAllowed(ownershipToken: token) else { return }
        isCopying = true
        navigationController?.isModalInPresentation = true
        reload()
        Task { [self] in
            do {
                _ = try await FloorpWorkspaceCopyService.shared.resume(
                    operationID: pending.operationID,
                    generation: token,
                    destination: destination,
                    isGenerationValid: { [coordinator] in coordinator.isCopyAllowed(ownershipToken: token) },
                    progress: { [weak self] progress in
                        self?.copyProgress = progress
                        self?.tableView.reloadData()
                    }
                )
                isCopying = false
                navigationController?.isModalInPresentation = false
                onCopied()
            } catch {
                isCopying = false
                navigationController?.isModalInPresentation = false
                reload()
                showCopyError()
            }
        }
    }

    private func showCopyError() {
        let alert = UIAlertController(title: FloorpStrings.Workspaces.copyFailed,
                                      message: FloorpStrings.Workspaces.copyFailedMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FloorpStrings.Workspaces.ok, style: .default))
        FloorpWorkspaceCopyRecovery.addDiscardAction(to: alert, presenter: self, destination: destination) { [weak self] in
            self?.copyProgress = nil
            self?.reload()
        }
        present(alert, animated: true)
    }

    private var statusText: String {
        switch coordinator.state {
        case .signedOut: return FloorpStrings.Workspaces.signIn
        case .loading: return FloorpStrings.Workspaces.loading
        case .ready:
            return coordinator.workspaces.isEmpty ? FloorpStrings.Workspaces.empty : FloorpStrings.Workspaces.upToDate
        case .offline: return FloorpStrings.Workspaces.offline
        case .failed: return FloorpStrings.Workspaces.failed
        case .unsupportedVersion: return FloorpStrings.Workspaces.unsupported
        case .notPublished: return FloorpStrings.Workspaces.notPublished
        case .disabled: return FloorpStrings.Workspaces.disabled
        case .runtimeUnavailable: return FloorpStrings.Workspaces.runtimeUnavailable
        }
    }

    private static func icon(for value: String?) -> String {
        let icons = ["book": "book", "briefcase": "briefcase", "code": "chevron.left.forwardslash.chevron.right",
                     "globe": "globe", "home": "house", "shopping-cart": "cart", "star": "star"]
        return value.flatMap { icons[$0] } ?? "square.stack.3d.up"
    }
}

@MainActor
private final class FloorpWorkspacePreviewViewController: UITableViewController {
    private let coordinator: FloorpWorkspaceDiscoveryCoordinator
    private var snapshot: FloorpWorkspaceSnapshot?
    private let workspaceID: String
    private let destination: FloorpWorkspaceCopyDestination
    private let onCopied: () -> Void
    private var selectedIDs = Set<String>()
    private var operationID: UUID?
    private var generation: String?
    private var isCopying = false
    private var copyProgress: FloorpWorkspaceCopyProgress?
    private var observer: NSObjectProtocol?
    private lazy var openButton = UIBarButtonItem(title: FloorpStrings.Workspaces.openCopies,
                                                  style: .plain,
                                                  target: self,
                                                  action: #selector(openCopies))
    private lazy var selectAllButton = UIBarButtonItem(title: FloorpStrings.Workspaces.selectAll,
                                                       style: .plain,
                                                       target: self,
                                                       action: #selector(toggleSelectAllTabs))

    private var workspace: FloorpSharedWorkspace? { snapshot?.workspaces.first { $0.id == workspaceID } }
    private var tabs: [FloorpSharedWorkspaceTab] { workspace?.tabs ?? [] }

    init(coordinator: FloorpWorkspaceDiscoveryCoordinator,
         snapshot: FloorpWorkspaceSnapshot,
         workspaceID: String,
         destination: FloorpWorkspaceCopyDestination,
         onCopied: @escaping () -> Void) {
        self.coordinator = coordinator
        self.snapshot = snapshot
        self.workspaceID = workspaceID
        self.destination = destination
        self.onCopied = onCopied
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "Floorp.Workspaces.Preview"
        navigationItem.rightBarButtonItem = selectAllButton
        let space = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        setToolbarItems([space, openButton, space], animated: false)
        openButton.accessibilityIdentifier = "Floorp.Workspaces.OpenCopies"
        observer = NotificationCenter.default.addObserver(
            forName: .floorpWorkspaceDiscoveryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
        updateControls()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    private func refreshSnapshot() {
        if coordinator.ownershipToken == nil ||
            (generation.map { !coordinator.isCopyAllowed(ownershipToken: $0) } ?? false) {
            snapshot = nil
            selectedIDs.removeAll()
            operationID = nil
            generation = nil
            copyProgress = nil
            tableView.reloadData()
        } else if !isCopying, operationID == nil, let current = coordinator.snapshot {
            snapshot = current
            selectedIDs.formIntersection(Set(tabs.map(\.id)))
            tableView.reloadData()
        }
        updateControls()
    }

    private func updateControls() {
        title = workspace?.name.isEmpty == false ? workspace?.name : FloorpStrings.Workspaces.untitled
        let allowed = snapshot.flatMap { coordinator.copyAuthorization(for: $0) } != nil && destination.isAvailable
        openButton.isEnabled = !isCopying && allowed && (operationID != nil || !selectedIDs.isEmpty)
        selectAllButton.isEnabled = !isCopying && operationID == nil && !tabs.isEmpty
        if !isCopying {
            openButton.title = operationID == nil
                ? String(format: FloorpStrings.Workspaces.openCount, selectedIDs.count)
                : FloorpStrings.Workspaces.retryCopy
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tabs.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        var lines = [FloorpStrings.Workspaces.independentCopies, FloorpStrings.Workspaces.standardSyncNotice]
        if coordinator.state == .offline { lines.append(FloorpStrings.Workspaces.offline) }
        if coordinator.state == .failed { lines.append(FloorpStrings.Workspaces.failed) }
        if let received = snapshot?.lastReceivedAt {
            let date = DateFormatter.localizedString(from: received, dateStyle: .medium, timeStyle: .short)
            lines.append(String(format: FloorpStrings.Workspaces.lastReceived, date))
        }
        if let copyProgress {
            lines.append(String(format: FloorpStrings.Workspaces.copyProgress, copyProgress.completed, copyProgress.total))
        }
        return lines.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let tab = tabs[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = tab.title.isEmpty ? tab.url : tab.title
        content.secondaryText = tab.url
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 3
        if tab.pinned { content.image = UIImage(systemName: "pin.fill") }
        cell.contentConfiguration = content
        cell.accessoryType = selectedIDs.contains(tab.id) ? .checkmark : .none
        cell.accessibilityTraits = selectedIDs.contains(tab.id) ? [.button, .selected] : [.button]
        cell.accessibilityLabel = [content.text, tab.url, tab.pinned ? FloorpStrings.Workspaces.pinned : nil]
            .compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityIdentifier = "Floorp.Workspaces.Tab.\(tab.id)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isCopying, operationID == nil else { return }
        let id = tabs[indexPath.row].id
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateControls()
    }

    @objc private func toggleSelectAllTabs() {
        selectedIDs = selectedIDs.count == tabs.count ? [] : Set(tabs.map(\.id))
        tableView.reloadData()
        updateControls()
    }

    @objc private func openCopies() {
        guard !isCopying, let snapshot,
              let authorization = coordinator.copyAuthorization(for: snapshot) else { return }
        do {
            if operationID == nil {
                let items = tabs.filter { selectedIDs.contains($0.id) }.map {
                    FloorpWorkspaceCopyItem(url: $0.url, title: $0.title)
                }
                generation = authorization
                operationID = try FloorpWorkspaceCopyService.shared.start(items: items,
                                                                          generation: authorization,
                                                                          destination: destination)
            }
        } catch {
            showError()
            return
        }
        guard let operationID, let generation else { return }
        isCopying = true
        navigationController?.isModalInPresentation = true
        navigationItem.hidesBackButton = true
        updateControls()
        Task { [self] in
            do {
                _ = try await FloorpWorkspaceCopyService.shared.resume(
                    operationID: operationID,
                    generation: generation,
                    destination: destination,
                    isGenerationValid: { [coordinator] in coordinator.isCopyAllowed(ownershipToken: generation) },
                    progress: { [weak self] progress in
                        self?.copyProgress = progress
                        self?.openButton.title = String(format: FloorpStrings.Workspaces.copyProgress,
                                                        progress.completed,
                                                        progress.total)
                    }
                )
                isCopying = false
                navigationController?.isModalInPresentation = false
                navigationItem.hidesBackButton = false
                self.operationID = nil
                onCopied()
            } catch {
                isCopying = false
                navigationController?.isModalInPresentation = false
                navigationItem.hidesBackButton = false
                updateControls()
                if coordinator.isCopyAllowed(ownershipToken: generation) { showError() }
            }
        }
    }

    private func showError() {
        let details = copyProgress.map {
            String(format: FloorpStrings.Workspaces.copyProgress, $0.completed, $0.total) + "\n\n"
        } ?? ""
        let alert = UIAlertController(title: FloorpStrings.Workspaces.copyFailed,
                                      message: details + FloorpStrings.Workspaces.copyFailedMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FloorpStrings.Workspaces.ok, style: .default))
        FloorpWorkspaceCopyRecovery.addDiscardAction(to: alert, presenter: self, destination: destination) { [weak self] in
            self?.operationID = nil
            self?.generation = nil
            self?.copyProgress = nil
            self?.updateControls()
        }
        present(alert, animated: true)
    }
}

@MainActor
private enum FloorpWorkspaceCopyRecovery {
    static func addDiscardAction(
        to alert: UIAlertController,
        presenter: UIViewController,
        destination: FloorpWorkspaceCopyDestination,
        completion: @escaping () -> Void
    ) {
        let discard = UIAlertAction(title: FloorpStrings.Workspaces.discardAllPending,
                                    style: .destructive) { [weak presenter] _ in
            Task {
                do {
                    try FloorpWorkspaceCopyService.shared.cancelPendingOperations()
                    completion()
                    try await destination.discardUncertainCopyInventory()
                } catch {
                    let failure = UIAlertController(title: FloorpStrings.Workspaces.copyFailed,
                                                    message: FloorpStrings.Workspaces.copyFailedMessage,
                                                    preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: FloorpStrings.Workspaces.ok, style: .default))
                    presenter?.present(failure, animated: true)
                }
            }
        }
        alert.addAction(discard)
    }
}
