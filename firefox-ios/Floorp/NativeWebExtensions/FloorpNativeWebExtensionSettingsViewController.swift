// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit
import WebKit

@MainActor
final class FloorpNativeWebExtensionSettingsViewController: ThemedTableViewController {
    private enum Section: Int, CaseIterable {
        case installed
        case available

        var title: String {
            switch self {
            case .installed: return "Installed"
            case .available: return "Available from Floorp"
            }
        }
    }

    private enum Row {
        case installed(FloorpNativeWebExtensionSettingsItem)
        case available(FloorpNativeWebExtensionCatalogItem)
        case empty
        case unavailable
    }

    private weak var host: FloorpNativeWebExtensionHost?
    private weak var tabManager: (any TabManager)?
    private var installedItems = [FloorpNativeWebExtensionSettingsItem]()
    private var isMutating = false

    init(
        windowUUID: WindowUUID,
        host: FloorpNativeWebExtensionHost?,
        tabManager: any TabManager
    ) {
        self.host = host
        self.tabManager = tabManager
        super.init(style: .insetGrouped, windowUUID: windowUUID)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Extensions"
        tableView.accessibilityIdentifier = "Floorp.NativeWebExtensions.Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refresh)
        )
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc
    private func refresh() {
        installedItems = host?.settingsItems().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        } ?? []
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        host == nil ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard host != nil else { return "Extensions" }
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

        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let item):
            cell.textLabel?.text = item.name
            var detail = ["Version \(item.version)", item.isEnabled ? "Enabled" : "Disabled"]
            detail.append(item.hasPrivateAccess ? "Allowed in private browsing" : "Private browsing off")
            if item.hasUpdate {
                detail.append("Update available")
            }
            if !item.diagnostics.isEmpty {
                detail.append("\(item.diagnostics.count) diagnostic(s)")
            }
            if let error = item.errorDescription {
                detail.append(error)
            }
            cell.detailTextLabel?.text = detail.joined(separator: " · ")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "Floorp.NativeWebExtensions.Installed.\(item.identifier)"
        case .available(let item):
            cell.textLabel?.text = item.name
            if item.isAvailableOnCurrentOS {
                cell.detailTextLabel?.text = item.summary
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.detailTextLabel?.text = "Requires \(item.minimumOS.description) or later"
                cell.selectionStyle = .none
            }
            cell.accessibilityIdentifier = "Floorp.NativeWebExtensions.Available.\(item.identifier)"
        case .empty:
            cell.textLabel?.text = "No extensions installed"
            cell.detailTextLabel?.text = "Install a reviewed extension from the Floorp catalog below."
            cell.selectionStyle = .none
        case .unavailable:
            cell.textLabel?.text = "Extensions are unavailable"
            cell.detailTextLabel?.text = "The native WebKit extension host did not start."
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isMutating else { return }
        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let item):
            showActions(for: item)
        case .available(let item):
            confirmInstall(item)
        case .empty, .unavailable:
            break
        }
    }

    private func rows(in sectionIndex: Int) -> [Row] {
        guard host != nil else { return [.unavailable] }
        guard let section = Section(rawValue: sectionIndex) else { return [] }
        switch section {
        case .installed:
            return installedItems.isEmpty ? [.empty] : installedItems.map(Row.installed)
        case .available:
            let installed = Set(installedItems.map(\.identifier))
            return FloorpNativeWebExtensionCatalog.items
                .filter { !installed.contains($0.identifier) }
                .map(Row.available)
        }
    }

    private func confirmInstall(_ item: FloorpNativeWebExtensionCatalogItem) {
        guard item.isAvailableOnCurrentOS else {
            presentError(FloorpNativeWebExtensionError.unsupportedOperatingSystem(required: item.minimumOS))
            return
        }
        guard let host, !isMutating else { return }
        isMutating = true
        tableView.isUserInteractionEnabled = false
        Task { [weak self, host] in
            do {
                let preview = try await host.installationPreview(identifier: item.identifier)
                guard let self else { return }
                isMutating = false
                tableView.isUserInteractionEnabled = true
                presentInstallConfirmation(preview)
            } catch {
                guard let self else { return }
                isMutating = false
                tableView.isUserInteractionEnabled = true
                presentError(error)
            }
        }
    }

    private func presentInstallConfirmation(_ preview: FloorpNativeWebExtensionInstallationPreview) {
        var sections = [
            "Version: \(preview.version)",
            "Source: \(preview.source)",
            "License: \(preview.license)"
        ]
        if !preview.requiredPermissions.isEmpty {
            sections.append("Required permissions:\n• \(preview.requiredPermissions.joined(separator: "\n• "))")
        }
        if !preview.requiredMatchPatterns.isEmpty {
            sections.append("Required website access:\n• \(preview.requiredMatchPatterns.joined(separator: "\n• "))")
        }
        if !preview.optionalPermissions.isEmpty || !preview.optionalMatchPatterns.isEmpty {
            sections.append("Optional access will be requested only when the extension needs it.")
        }
        sections.append(
            "Private browsing remains off until you explicitly enable it. "
                + "Extension settings and storage remain in this profile."
        )
        let verb = preview.isUpdate ? "Update" : "Install"
        let alert = UIAlertController(
            title: "\(verb) \(preview.name)?",
            message: sections.joined(separator: "\n\n"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: verb, style: .default) { [weak self] _ in
            self?.mutate {
                try await $0.installBundledExtension(identifier: preview.identifier)
            }
        })
        present(alert, animated: true)
    }

    private func showActions(for item: FloorpNativeWebExtensionSettingsItem) {
        var detail = [
            "Version: \(item.version)",
            "Source: \(item.source)",
            "License: \(item.license)"
        ]
        if !item.permissions.isEmpty {
            detail.append("Permissions:\n• \(item.permissions.joined(separator: "\n• "))")
        }
        if !item.optionalPermissions.isEmpty {
            detail.append("Optional permissions:\n• \(item.optionalPermissions.joined(separator: "\n• "))")
        }
        if !item.matchPatterns.isEmpty {
            detail.append("Website access:\n• \(item.matchPatterns.joined(separator: "\n• "))")
        }
        if !item.optionalMatchPatterns.isEmpty {
            detail.append("Optional website access:\n• \(item.optionalMatchPatterns.joined(separator: "\n• "))")
        }
        if !item.diagnostics.isEmpty {
            detail.append("Diagnostics:\n• " + item.diagnostics.map {
                "[\($0.phase.rawValue)] \($0.message) (\($0.domain):\($0.code))"
            }.joined(separator: "\n• "))
        }
        if let error = item.errorDescription {
            detail.append("Last error: \(error)")
        }
        let alert = UIAlertController(
            title: item.name,
            message: detail.joined(separator: "\n\n"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: item.isEnabled ? "Disable" : "Enable",
            style: .default
        ) { [weak self] _ in
            self?.mutate { try await $0.setEnabled(!item.isEnabled, identifier: item.identifier) }
        })
        alert.addAction(UIAlertAction(
            title: item.hasPrivateAccess ? "Disable in Private Browsing" : "Allow in Private Browsing",
            style: .default
        ) { [weak self] _ in
            self?.mutate { try $0.setPrivateAccess(!item.hasPrivateAccess, identifier: item.identifier) }
        })
        if item.hasOptionsPage {
            alert.addAction(UIAlertAction(title: "Options", style: .default) { [weak self] _ in
                guard let self, let host else { return }
                do {
                    let options = try host.optionsViewController(identifier: item.identifier)
                    options.modalPresentationStyle = .formSheet
                    present(options, animated: true)
                } catch {
                    presentError(error)
                }
            })
        }
        if item.hasUpdate,
           let catalogItem = FloorpNativeWebExtensionCatalog.item(identifier: item.identifier) {
            alert.addAction(UIAlertAction(title: "Update", style: .default) { [weak self] _ in
                self?.confirmInstall(catalogItem)
            })
        }
        alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
            self?.confirmUninstall(item)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        present(alert, animated: true)
    }

    private func confirmUninstall(_ item: FloorpNativeWebExtensionSettingsItem) {
        let alert = UIAlertController(
            title: "Uninstall \(item.name)?",
            message: "The extension and all WebKit-managed extension storage will be removed from this profile.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
            self?.mutate { try await $0.uninstall(identifier: item.identifier) }
        })
        present(alert, animated: true)
    }

    private func mutate(
        _ operation: @escaping @MainActor (FloorpNativeWebExtensionHost) async throws -> Void
    ) {
        guard let host, !isMutating else { return }
        isMutating = true
        tableView.isUserInteractionEnabled = false
        Task { [weak self, host] in
            do {
                try await operation(host)
                guard let self else { return }
                isMutating = false
                tableView.isUserInteractionEnabled = true
                refresh()
            } catch {
                guard let self else { return }
                isMutating = false
                tableView.isUserInteractionEnabled = true
                presentError(error)
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

@MainActor
final class FloorpNativeWebExtensionPageViewController: UIViewController {
    private let pageTitle: String
    private let url: URL
    private let configuration: WKWebViewConfiguration
    private var webView: WKWebView?

    init(title: String, url: URL, configuration: WKWebViewConfiguration) {
        self.pageTitle = title
        self.url = url
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pageTitle
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView
        webView.load(URLRequest(url: url))
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }
}
