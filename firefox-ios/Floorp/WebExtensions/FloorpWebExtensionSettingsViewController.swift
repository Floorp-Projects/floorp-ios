// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

/// The immutable state consumed by the Settings screen.  It deliberately has
/// no package URL or resource data: only the installer receives package bytes.
struct FloorpWebExtensionSettingsOptionsPage: Hashable, Sendable {
    let packageGeneration: FloorpWebExtensionPagePackageGeneration
    let entryPoint: FloorpWebExtensionActionResource
}

struct FloorpWebExtensionSettingsInstalledPackage: Hashable, Sendable {
    let id: FloorpWebExtensionID
    let name: String
    let version: String
    let isEnabled: Bool
    let permissions: [FloorpWebExtensionPermissionCategory]
    let siteAccessDescription: String
    let privateAccessDescription: String
    let errorDescription: String?
    /// Present only for an enabled, manifest-declared options page. The
    /// immutable generation prevents an already-open page from seeing files
    /// belonging to a later package update.
    let optionsPage: FloorpWebExtensionSettingsOptionsPage?
}

/// A narrow UI boundary around the profile-owned package store.
///
/// The protocol prevents Settings from reading package files or touching the
/// WebKit runtime directly.  Each mutation is performed by the installer and
/// reflected in a later snapshot, making enable/disable and uninstall safe to
/// retry after an interrupted app lifecycle transition.
@MainActor
protocol FloorpWebExtensionSettingsManaging: AnyObject, Sendable {
    func settingsPackages() async -> [FloorpWebExtensionSettingsInstalledPackage]
    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws
    func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) async throws
    func uninstall(_ extensionID: FloorpWebExtensionID) async throws
}

/// `Settings > Extensions` for the pinned, bundled MV3 catalog.
///
/// This screen intentionally does not expose remote catalog or file-import
/// controls.  Those sources remain behind their own product and App Review
/// gates even when the generic runtime is enabled.
@MainActor
final class FloorpWebExtensionSettingsViewController: ThemedTableViewController {
    private enum Section: Int, CaseIterable {
        case installed
        case available

        var title: String {
            switch self {
            case .installed: return "Installed"
            case .available: return "Available"
            }
        }
    }

    private enum Row {
        case installed(FloorpWebExtensionSettingsInstalledPackage)
        case available(FloorpWebExtensionBundledCatalogItem)
        case emptyInstalled
        case unavailable
    }

    private let packageManager: (any FloorpWebExtensionSettingsManaging)?
    private let pageResourceResolver: FloorpWebExtensionPageResourceResolver?
    private let pageMessageRuntime: FloorpWebExtensionMessageRuntime?
    private let openExternalURL: FloorpWebExtensionPageViewController.ExternalNavigationHandler
    private var installedPackages = [FloorpWebExtensionSettingsInstalledPackage]()
    private var isLoading = false

    init(
        windowUUID: WindowUUID,
        packageManager: (any FloorpWebExtensionSettingsManaging)?,
        pageResourceResolver: FloorpWebExtensionPageResourceResolver? = nil,
        pageMessageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternalURL: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler = { _ in }
    ) {
        self.packageManager = packageManager
        self.pageResourceResolver = pageResourceResolver
        self.pageMessageRuntime = pageMessageRuntime
        self.openExternalURL = openExternalURL
        super.init(style: .insetGrouped, windowUUID: windowUUID)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Extensions"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refresh)
        )
        tableView.accessibilityIdentifier = "Floorp.WebExtensions.Settings"
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc
    private func refresh() {
        guard let packageManager, !isLoading else {
            tableView.reloadData()
            return
        }
        isLoading = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self, packageManager] in
            let packages = await packageManager.settingsPackages()
            guard let self, !Task.isCancelled else { return }
            self.installedPackages = packages.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.isLoading = false
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        packageManager == nil ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard packageManager != nil else { return "Extensions" }
        return Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        cell.backgroundColor = theme.colors.layer2
        cell.textLabel?.textColor = theme.colors.textPrimary
        cell.detailTextLabel?.textColor = theme.colors.textSecondary
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .none

        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let package):
            cell.textLabel?.text = package.name
            cell.detailTextLabel?.text = installedDetail(package)
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Installed.\(package.id.rawValue)"
        case .available(let item):
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = item.summary
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Available.\(item.id.rawValue)"
        case .emptyInstalled:
            cell.textLabel?.text = "No extensions installed"
            cell.detailTextLabel?.text = "Install a bundled extension to enable it for this profile."
            cell.selectionStyle = .none
            cell.isUserInteractionEnabled = false
        case .unavailable:
            cell.textLabel?.text = "Extensions are unavailable"
            cell.detailTextLabel?.text = "The extension package store is not configured for this profile."
            cell.selectionStyle = .none
            cell.isUserInteractionEnabled = false
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let package):
            showInstalledPackage(package)
        case .available(let item):
            confirmInstall(item)
        case .emptyInstalled, .unavailable:
            break
        }
    }

    private func rows(in section: Int) -> [Row] {
        guard packageManager != nil else { return [.unavailable] }
        guard let section = Section(rawValue: section) else { return [] }
        switch section {
        case .installed:
            return installedPackages.isEmpty ? [.emptyInstalled] : installedPackages.map(Row.installed)
        case .available:
            let installedIDs = Set(installedPackages.map(\.id))
            return FloorpWebExtensionBundledCatalog.items
                .filter { !installedIDs.contains($0.id) }
                .map(Row.available)
        }
    }

    private func installedDetail(_ package: FloorpWebExtensionSettingsInstalledPackage) -> String {
        var details = ["Version \(package.version)", package.isEnabled ? "Enabled" : "Disabled"]
        details.append(package.siteAccessDescription)
        if let errorDescription = package.errorDescription {
            details.append(errorDescription)
        }
        return details.joined(separator: " · ")
    }

    private func confirmInstall(_ item: FloorpWebExtensionBundledCatalogItem) {
        let permissions = item.requestedPermissions.map(\.title).joined(separator: "\n• ")
        let message = "From: \(item.source)\nLicense: \(item.license)\n\nThis extension can:\n• \(permissions)"
        let alert = UIAlertController(title: "Install \(item.name)?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak self] _ in
            self?.performInstall(item)
        })
        present(alert, animated: true)
    }

    private func showInstalledPackage(_ package: FloorpWebExtensionSettingsInstalledPackage) {
        let permissionList = package.permissions.map(\.title).joined(separator: "\n• ")
        let message = [
            "Version: \(package.version)",
            "Site access: \(package.siteAccessDescription)",
            "Private access: \(package.privateAccessDescription)",
            permissionList.isEmpty ? nil : "Permissions:\n• \(permissionList)",
            package.errorDescription
        ].compactMap { $0 }.joined(separator: "\n\n")
        let alert = UIAlertController(title: package.name, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(
            title: package.isEnabled ? "Disable" : "Enable",
            style: .default
        ) { [weak self] _ in
            self?.setEnabled(!package.isEnabled, for: package.id)
        })
        if package.optionsPage != nil,
           pageResourceResolver != nil,
           pageMessageRuntime != nil {
            alert.addAction(UIAlertAction(title: "Options", style: .default) { [weak self] _ in
                self?.openOptionsPage(for: package)
            })
        }
        alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
            self?.confirmUninstall(package)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        present(alert, animated: true)
    }

    private func openOptionsPage(for package: FloorpWebExtensionSettingsInstalledPackage) {
        guard let optionsPage = package.optionsPage,
              let pageResourceResolver,
              let pageMessageRuntime else {
            return
        }
        do {
            let controller = try FloorpWebExtensionPageHost.makeOptionsPage(
                packageGeneration: optionsPage.packageGeneration,
                entryPoint: optionsPage.entryPoint,
                resolver: pageResourceResolver,
                messageRuntime: pageMessageRuntime,
                openExternal: { [weak self] url in
                    self?.openExternalURL(url)
                }
            )
            controller.title = package.name
            navigationController?.pushViewController(controller, animated: true)
        } catch {
            presentError(error)
        }
    }

    private func confirmUninstall(_ package: FloorpWebExtensionSettingsInstalledPackage) {
        let alert = UIAlertController(
            title: "Uninstall \(package.name)?",
            message: "Its stored settings and enabled browser behavior will be removed from this profile.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
            self?.performUninstall(package.id)
        })
        present(alert, animated: true)
    }

    private func performInstall(_ item: FloorpWebExtensionBundledCatalogItem) {
        mutate { manager in
            try await manager.installBundledPackage(item)
        }
    }

    private func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) {
        mutate { manager in
            try await manager.setEnabled(isEnabled, for: extensionID)
        }
    }

    private func performUninstall(_ extensionID: FloorpWebExtensionID) {
        mutate { manager in
            try await manager.uninstall(extensionID)
        }
    }

    private func mutate(
        _ operation: @escaping @Sendable (any FloorpWebExtensionSettingsManaging) async throws -> Void
    ) {
        guard let packageManager else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self, packageManager] in
            do {
                try await operation(packageManager)
                guard let self, !Task.isCancelled else { return }
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.refresh()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.presentError(error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: "Extension could not be changed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Settings-facing live package boundary. Persistent package mutations remain
/// actor-isolated in the store, while this MainActor wrapper reconciles the
/// corresponding Coordinator policy before reporting success to the UI.
///
/// A MainActor class is still re-entrant while it awaits package I/O or WebKit
/// compilation.  The per-extension gate below therefore serializes an entire
/// lifecycle transition, rather than merely making each individual store
/// write serial.  In particular, a reload that captured an enabled package
/// cannot reactivate it after a concurrent disable or uninstall has won.
private actor FloorpWebExtensionLifecycleMutationGate {
    private var isLocked = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class FloorpWebExtensionLivePackageManager: FloorpWebExtensionSettingsManaging {
    /// Selects whether a reconciliation only revokes live execution or also
    /// purges durable extension-owned data. Only explicit uninstall requests
    /// may use `.uninstall`; reload, disable, and grant changes preserve the
    /// package's durable state for a later reactivation.
    enum ReconciliationOperation: Sendable, Equatable {
        case suspend
        case uninstall
    }

    /// Ephemeral authority to replace grants for one enabled immutable
    /// package generation. The revision also invalidates consent across a
    /// disable/re-enable or reload that retains the same package bytes.
    struct PermissionMutationAuthorization: Sendable, Equatable {
        let extensionID: FloorpWebExtensionID
        let packageGeneration: String
        fileprivate let lifecycleRevision: UInt64
    }

    typealias Reconciler = @MainActor (
        FloorpWebExtensionID,
        FloorpWebExtensionInstalledPackage?,
        ReconciliationOperation
    ) async throws -> Void
    typealias PreparedReconciler = @MainActor (
        FloorpWebExtensionID,
        FloorpWebExtensionInstalledPackage,
        ReconciliationOperation,
        FloorpWebExtensionPackageStore.PreparedPackageResources
    ) async throws -> Void
    typealias BundledPackageURLResolver = @MainActor (FloorpWebExtensionBundledCatalogItem) -> URL?
    typealias CurrentCompositionCheck = @MainActor () -> Bool

    let store: FloorpWebExtensionPackageStore
    private let isCurrentComposition: CurrentCompositionCheck
    private let reconcile: Reconciler
    private let reconcilePrepared: PreparedReconciler?
    private let bundledPackageURL: BundledPackageURLResolver
    private var lifecycleMutationGates = [FloorpWebExtensionID: FloorpWebExtensionLifecycleMutationGate]()
    private var lifecycleRevisions = [FloorpWebExtensionID: UInt64]()

    init(
        store: FloorpWebExtensionPackageStore,
        isCurrentComposition: @escaping CurrentCompositionCheck = { true },
        reconcile: @escaping Reconciler,
        bundledPackageURL: @escaping BundledPackageURLResolver = { $0.packageURL() },
        reconcilePrepared: PreparedReconciler? = nil
    ) {
        self.store = store
        self.isCurrentComposition = isCurrentComposition
        self.reconcile = reconcile
        self.reconcilePrepared = reconcilePrepared
        self.bundledPackageURL = bundledPackageURL
    }

    func settingsPackages() async -> [FloorpWebExtensionSettingsInstalledPackage] {
        await store.installedPackages().map { package in
            FloorpWebExtensionSettingsInstalledPackage(
                id: package.extensionID,
                name: package.name,
                version: package.version,
                isEnabled: package.isEnabled,
                permissions: Self.settingsPermissionCategories(for: package.grants),
                siteAccessDescription: Self.siteAccessDescription(
                    package.grants.normalHostAccess,
                    requestedHosts: package.grants.requestedHosts
                ),
                privateAccessDescription: package.grants.privateBrowsingEnabled
                    ? Self.siteAccessDescription(
                        package.grants.privateHostAccess,
                        requestedHosts: package.grants.requestedHosts
                    )
                    : "Not allowed",
                errorDescription: package.activationError ?? (package.preflight.isActivationAllowed
                    ? nil
                    : "This extension is incompatible with the current Floorp build."),
                optionsPage: Self.optionsPage(for: package)
            )
        }
    }

    // swiftlint:disable:next function_body_length
    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws {
        let gate = lifecycleMutationGate(for: item.id)
        await gate.acquire()
        defer { Task { await gate.release() } }
        invalidatePermissionAuthorizations(for: item.id)

        // A prior interrupted uninstall leaves a non-loadable tombstone. An
        // explicit reinstall is also a safe opportunity to finish that purge;
        // never overwrite the tombstone and strand profile-owned data.
        if await store.hasPendingDataPurge(for: item.id) {
            try await reconcile(item.id, nil, .suspend)
            try await reconcile(item.id, nil, .uninstall)
            try await store.completeUninstallCleanup(item.id)
        }

        guard let packageURL = bundledPackageURL(item) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(item.packageDirectoryName)
        }
        let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try FloorpWebExtensionManifest.decode(manifestData)
        let initialGrants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: manifest.apiPermissions,
            requestedHosts: Set(manifest.hostPermissions),
            normalHostAccess: .allRequestedSites,
            privateHostAccess: .denied,
            privateBrowsingEnabled: false
        )
        let transaction = try await store.installBundledPackageTransaction(
            at: packageURL,
            expectedExtensionID: item.id,
            initialGrants: initialGrants
        )
        let installed = transaction.installedPackage
        let previousPackage = transaction.previousPackage

        guard let previousPackage else {
            do {
                try await reconcile(installed.extensionID, installed, .suspend)
            } catch {
                try? await store.recordActivationFailure(
                    for: installed.extensionID,
                    expectedGeneration: installed.generation
                )
                throw error
            }
            return
        }

        // The journal is durable but the active registry still points at the
        // previous generation. Revoke that live generation (including its DNR
        // mutation gate) before making replacement resources observable.
        do {
            if previousPackage.isEnabled {
                try await reconcile(previousPackage.extensionID, nil, .suspend)
            }
        } catch {
            try? await store.abortPreparedBundledPackageUpdate(
                extensionID: item.id,
                replacementGeneration: installed.generation
            )
            if previousPackage.isEnabled {
                try? await reconcile(
                    previousPackage.extensionID,
                    previousPackage,
                    .suspend
                )
            }
            throw error
        }

        if installed.isEnabled {
            do {
                let resources = try await store.preparedPackageResources(
                    extensionID: item.id,
                    replacementGeneration: installed.generation
                )
                if let reconcilePrepared {
                    try await reconcilePrepared(
                        installed.extensionID,
                        installed,
                        .suspend,
                        resources
                    )
                } else {
                    // Unit reconcilers which do not load package bytes may use
                    // the legacy boundary. Production always supplies the
                    // transaction-scoped resource-aware reconciler.
                    try await reconcile(installed.extensionID, installed, .suspend)
                }
            } catch {
                try? await reconcile(installed.extensionID, nil, .suspend)
                try? await store.abortPreparedBundledPackageUpdate(
                    extensionID: item.id,
                    replacementGeneration: installed.generation
                )
                if previousPackage.isEnabled {
                    try? await reconcile(
                        previousPackage.extensionID,
                        previousPackage,
                        .suspend
                    )
                }
                throw error
            }
        }

        do {
            try await store.commitPreparedBundledPackageUpdate(
                extensionID: item.id,
                replacementGeneration: installed.generation
            )
        } catch {
            if installed.isEnabled {
                try? await reconcile(installed.extensionID, nil, .suspend)
            }
            try? await store.abortPreparedBundledPackageUpdate(
                extensionID: item.id,
                replacementGeneration: installed.generation
            )
            if previousPackage.isEnabled {
                try? await reconcile(
                    previousPackage.extensionID,
                    previousPackage,
                    .suspend
                )
            }
            throw error
        }
    }

    func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) async throws {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        invalidatePermissionAuthorizations(for: extensionID)

        if !isEnabled {
            // Revoke live privileges before persisting the disable. If the
            // registry write fails, the extension remains safely inactive.
            try await reconcile(extensionID, nil, .suspend)
        }
        try await store.setEnabled(isEnabled, for: extensionID)
        if isEnabled {
            guard let package = await store.installedPackage(for: extensionID) else {
                throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
            }
            do {
                try await reconcile(extensionID, package, .suspend)
            } catch {
                try? await store.recordActivationFailure(
                    for: extensionID,
                    expectedGeneration: package.generation
                )
                throw error
            }
        }
    }

    /// Captures the currently enabled generation and lifecycle revision before
    /// a trusted consent UI is presented. The returned value is meaningful
    /// only to this manager instance and is consumed by `updateGrants`.
    func authorizePermissionMutation(
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String
    ) async throws -> PermissionMutationAuthorization {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        guard isCurrentComposition(),
              let package = await store.installedPackage(for: extensionID),
              package.isEnabled,
              package.generation == expectedGeneration,
              isCurrentComposition() else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        return .init(
            extensionID: extensionID,
            packageGeneration: expectedGeneration,
            lifecycleRevision: lifecycleRevisions[extensionID, default: 0]
        )
    }

    func updateGrants(
        _ grants: FloorpWebExtensionPermissionSnapshot,
        authorization: PermissionMutationAuthorization,
        validateSender: @MainActor () -> Bool = { true }
    ) async throws {
        let extensionID = authorization.extensionID
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        guard lifecycleRevisions[extensionID, default: 0] == authorization.lifecycleRevision,
              isCurrentComposition(),
              let previousPackage = await store.installedPackage(for: extensionID),
              previousPackage.isEnabled,
              previousPackage.generation == authorization.packageGeneration,
              isCurrentComposition(),
              validateSender() else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        // Consume the authorization before the first reconciliation await.
        // A second request authorized from the same grant snapshot must not
        // overwrite this transaction and lose permissions it did not observe.
        invalidatePermissionAuthorizations(for: extensionID)

        // Treat every grant replacement as a possible revocation. This avoids
        // a window where an old host grant remains live after user consent.
        try await reconcile(extensionID, nil, .suspend)
        guard isCurrentComposition(), validateSender() else {
            throw FloorpWebExtensionPackageStoreError.stalePackageComposition
        }
        do {
            try await store.updateGrants(
                grants,
                for: extensionID,
                expectedGeneration: authorization.packageGeneration
            )
        } catch {
            // The registry is unchanged, so restore the exact generation that
            // was revoked before the failed durable update.
            do {
                try await reconcile(extensionID, previousPackage, .suspend)
            } catch {
                try? await store.recordActivationFailure(
                    for: extensionID,
                    expectedGeneration: previousPackage.generation
                )
            }
            throw error
        }
        if let package = await store.installedPackage(for: extensionID), package.isEnabled {
            do {
                try await reconcile(extensionID, package, .suspend)
            } catch {
                try? await store.recordActivationFailure(
                    for: extensionID,
                    expectedGeneration: package.generation
                )
                throw error
            }
        }
    }

    /// Serializes startup restoration with every Settings/API lifecycle
    /// mutation. The full captured record is compared, not only its immutable
    /// package generation, because grants and durable DNR state may change
    /// without replacing the package directory.
    @discardableResult
    func restoreInstalledPackageIfCurrent(
        _ expectedPackage: FloorpWebExtensionInstalledPackage
    ) async throws -> Bool {
        let extensionID = expectedPackage.extensionID
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        guard isCurrentComposition(),
              let currentPackage = await store.installedPackage(for: extensionID),
              currentPackage == expectedPackage,
              currentPackage.isEnabled,
              isCurrentComposition() else {
            return false
        }
        invalidatePermissionAuthorizations(for: extensionID)
        do {
            try await reconcile(extensionID, currentPackage, .suspend)
            guard isCurrentComposition(),
                  await store.installedPackage(for: extensionID) == currentPackage else {
                throw FloorpWebExtensionPackageStoreError.stalePackageComposition
            }
            return true
        } catch {
            if isCurrentComposition() {
                try? await store.recordActivationFailure(
                    for: extensionID,
                    expectedGeneration: currentPackage.generation
                )
            }
            throw error
        }
    }

    func uninstall(_ extensionID: FloorpWebExtensionID) async throws {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        invalidatePermissionAuthorizations(for: extensionID)

        let installedPackage = await store.installedPackage(for: extensionID)
        let hasPendingPurge = await store.hasPendingDataPurge(for: extensionID)
        guard installedPackage != nil || hasPendingPurge else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }

        // Phase 1 is reversible and retains every durable byte. If the package
        // registry commit fails, restore the captured immutable generation so
        // package, data, and live state remain consistent.
        try await reconcile(extensionID, nil, .suspend)
        if let installedPackage {
            do {
                try await store.uninstall(extensionID)
            } catch {
                do {
                    try await reconcile(extensionID, installedPackage, .suspend)
                } catch {
                    try? await store.recordActivationFailure(
                        for: extensionID,
                        expectedGeneration: installedPackage.generation
                    )
                }
                throw error
            }
        }

        // Phase 2 runs only while a durable tombstone makes the extension
        // non-loadable. Any cleanup failure is surfaced and leaves that
        // tombstone available for an idempotent retry.
        try await reconcile(extensionID, nil, .uninstall)
        try await store.completeUninstallCleanup(extensionID)
    }

    /// Rebuilds one already-enabled package from its immutable generation.
    /// `runtime.reload()` never re-enables a disabled package and, if the
    /// reactivation fails, preserves the same fail-closed state as an enable
    /// or package update failure.
    func reload(_ extensionID: FloorpWebExtensionID) async throws {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        invalidatePermissionAuthorizations(for: extensionID)

        guard let package = await store.installedPackage(for: extensionID) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        guard package.isEnabled else {
            throw FloorpWebExtensionError.unsupported("Cannot reload a disabled extension")
        }

        try await reconcile(extensionID, nil, .suspend)
        do {
            try await reconcile(extensionID, package, .suspend)
        } catch {
            try? await store.recordActivationFailure(
                for: extensionID,
                expectedGeneration: package.generation
            )
            throw error
        }
    }

    private func lifecycleMutationGate(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionLifecycleMutationGate {
        if let existing = lifecycleMutationGates[extensionID] {
            return existing
        }
        let gate = FloorpWebExtensionLifecycleMutationGate()
        lifecycleMutationGates[extensionID] = gate
        return gate
    }

    private func invalidatePermissionAuthorizations(
        for extensionID: FloorpWebExtensionID
    ) {
        lifecycleRevisions[extensionID, default: 0] &+= 1
    }

    private static func settingsPermissionCategories(
        for grants: FloorpWebExtensionPermissionSnapshot
    ) -> [FloorpWebExtensionPermissionCategory] {
        var categories = [FloorpWebExtensionPermissionCategory]()
        if !grants.requestedHosts.isEmpty {
            categories.append(.siteData)
        }
        if grants.apiPermissions.contains(.tabs) || grants.apiPermissions.contains(.activeTab) {
            categories.append(.tabs)
        }
        if grants.apiPermissions.contains(.storage) {
            categories.append(.storage)
        }
        if grants.apiPermissions.contains(.declarativeNetRequest) {
            categories.append(.networkBlocking)
        }
        if grants.apiPermissions.contains(.scripting) {
            categories.append(.browserAutomation)
        }
        return categories
    }

    private static func optionsPage(
        for package: FloorpWebExtensionInstalledPackage
    ) -> FloorpWebExtensionSettingsOptionsPage? {
        guard package.isEnabled,
              package.preflight.isActivationAllowed,
              let optionsUI = package.preflight.manifest.optionsUI,
              let entryPoint = try? FloorpWebExtensionActionResource(optionsUI.page.path),
              let packageGeneration = try? FloorpWebExtensionPagePackageGeneration(
                installedPackage: package
              ) else {
            return nil
        }
        return .init(packageGeneration: packageGeneration, entryPoint: entryPoint)
    }

    private static func siteAccessDescription(
        _ access: FloorpWebExtensionHostAccess,
        requestedHosts: Set<FloorpWebExtensionMatchPattern>
    ) -> String {
        switch access {
        case .denied:
            return "No site access"
        case .allRequestedSites:
            return "All \(requestedHosts.count) requested site\(requestedHosts.count == 1 ? "" : "s")"
        case .selectedSites(let sites):
            return "\(sites.count) selected site\(sites.count == 1 ? "" : "s")"
        }
    }
}
