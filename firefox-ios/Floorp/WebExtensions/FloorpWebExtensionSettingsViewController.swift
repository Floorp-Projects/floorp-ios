// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

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
            self.installedPackages = packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
@MainActor
final class FloorpWebExtensionLivePackageManager: FloorpWebExtensionSettingsManaging {
    typealias Reconciler = @MainActor (
        FloorpWebExtensionID,
        FloorpWebExtensionInstalledPackage?
    ) async throws -> Void

    let store: FloorpWebExtensionPackageStore
    private let reconcile: Reconciler

    init(store: FloorpWebExtensionPackageStore, reconcile: @escaping Reconciler) {
        self.store = store
        self.reconcile = reconcile
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
                errorDescription: package.preflight.isActivationAllowed
                    ? nil
                    : "This extension is incompatible with the current Floorp build.",
                optionsPage: Self.optionsPage(for: package)
            )
        }
    }

    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws {
        guard let packageURL = item.packageURL() else {
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
        let installed = try await store.installBundledPackage(
            at: packageURL,
            expectedExtensionID: item.id,
            initialGrants: initialGrants
        )
        try await reconcile(installed.extensionID, installed)
    }

    func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) async throws {
        if !isEnabled {
            // Revoke live privileges before persisting the disable. If the
            // registry write fails, the extension remains safely inactive.
            try await reconcile(extensionID, nil)
        }
        try await store.setEnabled(isEnabled, for: extensionID)
        if isEnabled {
            guard let package = await store.installedPackage(for: extensionID) else {
                throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
            }
            try await reconcile(extensionID, package)
        }
    }

    func updateGrants(
        _ grants: FloorpWebExtensionPermissionSnapshot,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        // Treat every grant replacement as a possible revocation. This avoids
        // a window where an old host grant remains live after user consent.
        try await reconcile(extensionID, nil)
        try await store.updateGrants(grants, for: extensionID)
        if let package = await store.installedPackage(for: extensionID), package.isEnabled {
            try await reconcile(extensionID, package)
        }
    }

    func uninstall(_ extensionID: FloorpWebExtensionID) async throws {
        try await reconcile(extensionID, nil)
        try await store.uninstall(extensionID)
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
