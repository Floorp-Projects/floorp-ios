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

/// Presents one normal-profile catalog as a product setting while making
/// private browsing an explicit, independent installation into the ephemeral
/// private profile. This prevents private runtime, DNR, storage, and package
/// directories from sharing normal-profile state.
@MainActor
final class FloorpWebExtensionProfileSettingsManager: FloorpWebExtensionSettingsManaging {
    private let normalManager: FloorpWebExtensionLivePackageManager
    private let privateManager: FloorpWebExtensionLivePackageManager

    init(
        normalManager: FloorpWebExtensionLivePackageManager,
        privateManager: FloorpWebExtensionLivePackageManager
    ) {
        self.normalManager = normalManager
        self.privateManager = privateManager
    }

    func settingsPackages() async -> [FloorpWebExtensionSettingsInstalledPackage] {
        let normalPackages = await normalManager.settingsPackages()
        let privatePackages = await privateManager.settingsPackages()
        let privateByID = Dictionary(uniqueKeysWithValues: privatePackages.map { ($0.id, $0) })
        return normalPackages.map { package in
            mergedPackage(package, privatePackage: privateByID[package.id])
        }
    }

    private func mergedPackage(
        _ normalPackage: FloorpWebExtensionSettingsInstalledPackage,
        privatePackage: FloorpWebExtensionSettingsInstalledPackage?
    ) -> FloorpWebExtensionSettingsInstalledPackage {
        guard let privatePackage else { return normalPackage }
        return .init(
            id: normalPackage.id,
            name: normalPackage.name,
            version: normalPackage.version,
            catalogGeneration: normalPackage.catalogGeneration,
            catalogDescription: normalPackage.catalogDescription,
            catalogSource: normalPackage.catalogSource,
            catalogLicense: normalPackage.catalogLicense,
            catalogHomepage: normalPackage.catalogHomepage,
            catalogCategory: normalPackage.catalogCategory,
            catalogModificationStatus: normalPackage.catalogModificationStatus,
            catalogPublisher: normalPackage.catalogPublisher,
            catalogAttribution: normalPackage.catalogAttribution,
            catalogPrivacySummary: normalPackage.catalogPrivacySummary,
            catalogRetentionPolicy: normalPackage.catalogRetentionPolicy,
            catalogReviewedAt: normalPackage.catalogReviewedAt,
            privateProfileCapability: normalPackage.privateProfileCapability,
            isEnabled: normalPackage.isEnabled,
            isCatalogRevoked: normalPackage.isCatalogRevoked || privatePackage.isCatalogRevoked,
            permissions: normalPackage.permissions,
            siteAccessDescription: normalPackage.siteAccessDescription,
            requestedSites: normalPackage.requestedSites,
            normalHostAccess: normalPackage.normalHostAccess,
            privateHostAccess: privatePackage.privateHostAccess,
            isPrivateBrowsingEnabled: privatePackage.isPrivateBrowsingEnabled,
            privateAccessDescription: privatePackage.isPrivateBrowsingEnabled
                ? privatePackage.privateAccessDescription
                : "Not allowed",
            errorDescription: normalPackage.errorDescription ?? privatePackage.errorDescription,
            optionsPage: normalPackage.optionsPage,
            dnrStatus: normalPackage.dnrStatus,
            privateDNRStatus: privatePackage.dnrStatus,
            updateHistory: normalPackage.updateHistory
        )
    }

    func catalogItems() async -> [FloorpWebExtensionBundledCatalogItem] {
        await normalManager.catalogItems()
    }

    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws {
        try await normalManager.installBundledPackage(item)
    }

    func setNormalSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        try await normalManager.setNormalSiteAccess(access, for: extensionID)
    }

    func setPrivateBrowsingEnabled(
        _ isEnabled: Bool,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        if !isEnabled {
            guard let installed = await privateManager.store.installedPackage(for: extensionID) else {
                return
            }
            guard installed.grants.privateBrowsingEnabled else { return }
            try await privateManager.setPrivateBrowsingEnabled(false, for: extensionID)
            return
        }

        guard let normalPackage = await normalManager.store.installedPackage(for: extensionID),
              let normalRecord = normalPackage.catalogRecord,
              let privateProfileCapability = normalRecord.metadata?.privateProfileCapability,
              privateProfileCapability != .notSupported else {
            throw FloorpWebExtensionError.unsupported(
                "this extension is not approved for private browsing"
            )
        }
        if let privatePackage = await privateManager.store.installedPackage(for: extensionID) {
            guard privatePackage.catalogRecord != nil else {
                throw FloorpWebExtensionError.unsupported(
                    "private browsing requires a signed catalog package"
                )
            }
            if !privatePackage.grants.privateBrowsingEnabled {
                try await privateManager.setPrivateBrowsingEnabled(true, for: extensionID)
            }
            return
        }

        let candidates = await normalManager.catalogItems().filter { item in
            item.id == normalRecord.extensionID && item.catalogRecord != nil
        }
        // Catalogs with two installable generations require the normal
        // Settings update control to choose one; private setup never guesses.
        guard candidates.count == 1, let item = candidates.first else {
            throw FloorpWebExtensionCatalogError.updateConsentRequired
        }
        try await privateManager.installBundledPackage(item)
    }

    func setPrivateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        try await privateManager.setPrivateSiteAccess(access, for: extensionID)
    }

    func setNormalDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        try await normalManager.setNormalDNRExcludedTopLevelDomains(domains, for: extensionID)
    }

    func setPrivateDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        try await privateManager.setPrivateDNRExcludedTopLevelDomains(domains, for: extensionID)
    }

    func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) async throws {
        if !isEnabled {
            if let normalPackage = await normalManager.store.installedPackage(for: extensionID),
               normalPackage.isEnabled {
                try await normalManager.setEnabled(false, for: extensionID)
            }
            if let privatePackage = await privateManager.store.installedPackage(for: extensionID),
               privatePackage.isEnabled {
                try await privateManager.setEnabled(false, for: extensionID)
            }
            return
        }

        try await normalManager.setEnabled(true, for: extensionID)
        if let privatePackage = await privateManager.store.installedPackage(for: extensionID),
           privatePackage.grants.privateBrowsingEnabled,
           !privatePackage.isEnabled {
            try await privateManager.setEnabled(true, for: extensionID)
        }
    }

    func uninstall(_ extensionID: FloorpWebExtensionID) async throws {
        // Suspend both profile runtimes before touching durable state. If a
        // later disk operation fails, neither profile remains executing.
        try await setEnabled(false, for: extensionID)
        try await normalManager.uninstall(extensionID)
        if await privateManager.store.installedPackage(for: extensionID) != nil {
            try await privateManager.uninstall(extensionID)
        }
    }
}

/// A product-owned summary of a DNR policy. It exposes no rule bodies or
/// package resource paths, only the state needed for a user to understand the
/// active fixed ruleset and manage their own exclusions.
struct FloorpWebExtensionSettingsDNRStatus: Hashable, Sendable {
    let enabledStaticRuleSetIDs: [String]
    let policyGeneration: UInt64
    let excludedTopLevelDomains: [String]
}

struct FloorpWebExtensionSettingsInstalledPackage: Hashable, Sendable {
    let id: FloorpWebExtensionID
    let name: String
    let version: String
    /// Product-owned immutable generation for an installed signed catalog
    /// package. It is display/control metadata only; Settings never receives
    /// an artifact URL or package bytes.
    let catalogGeneration: String?
    /// The signed catalog's product description and provenance. These are
    /// safe for the native UI to display, but deliberately exclude artifact
    /// locations and any installation transport.
    let catalogDescription: String?
    let catalogSource: String?
    let catalogLicense: String?
    let catalogHomepage: URL?
    private(set) var catalogCategory: String? = .none
    private(set) var catalogModificationStatus:
        FloorpWebExtensionCatalogPackageMetadata.ModificationStatus? = .none
    private(set) var catalogPublisher: String? = .none
    private(set) var catalogAttribution: String? = .none
    private(set) var catalogPrivacySummary: String? = .none
    private(set) var catalogRetentionPolicy: String? = .none
    private(set) var catalogReviewedAt: String? = .none
    private(set) var privateProfileCapability:
        FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability? = .none
    let isEnabled: Bool
    let isCatalogRevoked: Bool
    let permissions: [FloorpWebExtensionPermissionCategory]
    let siteAccessDescription: String
    /// Declared site patterns, exposed only as product-owned consent choices.
    /// The Settings screen never reads an extension-supplied page to obtain
    /// these values.
    let requestedSites: [FloorpWebExtensionMatchPattern]
    let normalHostAccess: FloorpWebExtensionHostAccess
    let privateHostAccess: FloorpWebExtensionHostAccess
    /// Private browsing is an independent, opt-in installation in the
    /// ephemeral private profile. A normal-profile package never grants it by
    /// itself.
    let isPrivateBrowsingEnabled: Bool
    let privateAccessDescription: String
    let errorDescription: String?
    /// Present only for an enabled, manifest-declared options page. The
    /// immutable generation prevents an already-open page from seeing files
    /// belonging to a later package update.
    let optionsPage: FloorpWebExtensionSettingsOptionsPage?
    let dnrStatus: FloorpWebExtensionSettingsDNRStatus?
    let privateDNRStatus: FloorpWebExtensionSettingsDNRStatus?
    /// Normal-profile immutable update audit history. Private-profile package
    /// state is ephemeral by design and disappears with the private profile.
    let updateHistory: [FloorpWebExtensionCatalogUpdateHistoryEntry]
}

/// Product-owned consent for `permissions.request`. Extension documents do
/// not supply text, a view controller, or a success callback; they only name
/// an already-declared optional capability that the API host authenticated.
@MainActor
final class FloorpWebExtensionNativePermissionConsentPresenter {
    struct RequestPresentation: Sendable {
        let extensionName: String
        let extensionID: FloorpWebExtensionID
        let packageGeneration: String
        let apiPermissions: [FloorpWebExtensionAPIGrant]
        let origins: [FloorpWebExtensionMatchPattern]
        let isPrivateBrowsing: Bool

        var message: String {
            var lines = [String]()
            if !apiPermissions.isEmpty {
                lines.append(contentsOf: apiPermissions.map { "• \(Self.title(for: $0))" })
            }
            if !origins.isEmpty {
                lines.append("Sites:")
                lines.append(contentsOf: origins.map { "• \($0.original)" })
            }
            lines.append(isPrivateBrowsing
                ? "This permission applies only in private browsing."
                : "This permission applies to this browsing profile.")
            return lines.joined(separator: "\n")
        }

        fileprivate static func title(for permission: FloorpWebExtensionAPIGrant) -> String {
            switch permission {
            case .activeTab: return "Access the active tab after an explicit action"
            case .alarms: return "Schedule extension alarms"
            case .declarativeNetRequest: return "Apply supported network blocking rules"
            case .fontSettings: return "Use the iOS-safe generic font fallback"
            case .scripting: return "Run approved package scripts on the selected sites"
            case .storage: return "Store extension settings on this device"
            case .tabs: return "Read tab metadata and open or reload tabs"
            }
        }
    }

    typealias PackageNameLookup = @MainActor @Sendable (
        FloorpWebExtensionID,
        String
    ) async -> String?
    typealias Confirmation = @MainActor @Sendable (RequestPresentation) async -> Bool

    private let isPrivateBrowsing: Bool
    private let packageNameLookup: PackageNameLookup
    private let confirmation: Confirmation

    init(
        isPrivateBrowsing: Bool,
        packageNameLookup: @escaping PackageNameLookup,
        confirmation: Confirmation? = nil
    ) {
        self.isPrivateBrowsing = isPrivateBrowsing
        self.packageNameLookup = packageNameLookup
        self.confirmation = confirmation ?? { presentation in
            await Self.presentNativeConfirmation(presentation)
        }
    }

    func authorize(_ request: FloorpWebExtensionPermissionRequest) async -> Bool {
        guard let generation = request.packageGeneration,
              !generation.isEmpty,
              !request.apiPermissions.isEmpty || !request.origins.isEmpty,
              let extensionName = await packageNameLookup(request.extensionID, generation) else {
            return false
        }
        return await confirmation(.init(
            extensionName: extensionName,
            extensionID: request.extensionID,
            packageGeneration: generation,
            apiPermissions: request.apiPermissions.sorted { $0.rawValue < $1.rawValue },
            origins: request.origins.sorted { $0.original < $1.original },
            isPrivateBrowsing: isPrivateBrowsing
        ))
    }

    private static func presentNativeConfirmation(_ presentation: RequestPresentation) async -> Bool {
        guard let presenter = topPresenter(),
              !(presenter is UIAlertController),
              presenter.viewIfLoaded?.window != nil else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Allow \(presentation.extensionName)?",
                message: presentation.message,
                preferredStyle: .alert
            )
            alert.view.accessibilityIdentifier = "Floorp.WebExtensions.OptionalPermissionConsent"
            alert.addAction(UIAlertAction(title: "Don’t Allow", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in
                continuation.resume(returning: true)
            })
            // Do not replace UIAlertController's presentation delegate. UIKit
            // owns it and may assert if an unrelated delegate is installed.
            presenter.present(alert, animated: true)
        }
    }

    fileprivate static func topPresenter() -> UIViewController? {
        guard let root = UIWindow.keyWindow?.rootViewController else { return nil }
        return topPresenter(from: root)
    }

    private static func topPresenter(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController,
           !presented.isBeingDismissed {
            return topPresenter(from: presented)
        }
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topPresenter(from: visible)
        }
        if let tab = controller as? UITabBarController,
           let selected = tab.selectedViewController {
            return topPresenter(from: selected)
        }
        return controller
    }
}

/// A native, product-owned confirmation for every catalog replacement. It is
/// intentionally unavailable when Settings is not visible, so the known-good
/// generation remains active until the user opens this confirmation flow.
@MainActor
enum FloorpWebExtensionNativeCatalogUpdateConsentPresenter {
    static func confirm(
        _ request: FloorpWebExtensionLivePackageManager.CatalogUpdateConfirmationRequest
    ) async -> Bool {
        guard let presenter = FloorpWebExtensionNativePermissionConsentPresenter.topPresenter(),
              !(presenter is UIAlertController),
              presenter.viewIfLoaded?.window != nil else {
            return false
        }
        let message = confirmationMessage(for: request)
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Allow update for \(request.extensionName)?",
                message: message,
                preferredStyle: .alert
            )
            alert.view.accessibilityIdentifier = "Floorp.WebExtensions.CatalogUpdateConsent"
            alert.addAction(UIAlertAction(title: "Keep Current Version", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "Allow Update", style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    private static func confirmationMessage(
        for request: FloorpWebExtensionLivePackageManager.CatalogUpdateConfirmationRequest
    ) -> String {
        var sections = ["Update \(request.installedVersion) to \(request.replacementVersion)?"]
        if request.addedRequiredAPIPermissions.isEmpty &&
            request.addedRequiredHostPermissions.isEmpty {
            sections.append(
                "This signed update adds no required capabilities or site access. Confirm the exact replacement."
            )
        } else {
            sections.append(
                "This update adds the following access. Keep the current version unless you want to allow it."
            )
        }
        if !request.addedRequiredAPIPermissions.isEmpty {
            let permissions = request.addedRequiredAPIPermissions.map {
                "• \(FloorpWebExtensionNativePermissionConsentPresenter.RequestPresentation.title(for: $0))"
            }.joined(separator: "\n")
            sections.append("New capabilities:\n\(permissions)")
        }
        if !request.addedRequiredHostPermissions.isEmpty {
            let hosts = request.addedRequiredHostPermissions.map {
                "• \($0.original)"
            }.joined(separator: "\n")
            sections.append("New site access:\n\(hosts)")
        }
        sections.append("Generation: \(request.replacementCatalogGeneration)")
        sections.append("Artifact SHA-256: \(request.replacementArtifactSHA256)")
        return sections.joined(separator: "\n\n")
    }
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
    func catalogItems() async -> [FloorpWebExtensionBundledCatalogItem]
    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws
    func setNormalSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws
    func setPrivateBrowsingEnabled(
        _ isEnabled: Bool,
        for extensionID: FloorpWebExtensionID
    ) async throws
    func setPrivateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws
    func setNormalDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws
    func setPrivateDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws
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
            case .installed: return FloorpStrings.WebExtensions.installedSection
            case .available: return FloorpStrings.WebExtensions.availableSection
            }
        }
    }

    private enum Row {
        case installed(FloorpWebExtensionSettingsInstalledPackage)
        case available(FloorpWebExtensionBundledCatalogItem)
        case installedLoading
        case emptyInstalled
        case catalogLoading
        case catalogUnavailable
        case unavailable
    }

    private let packageManager: (any FloorpWebExtensionSettingsManaging)?
    private let pageResourceResolver: FloorpWebExtensionPageResourceResolver?
    private let pageMessageRuntime: FloorpWebExtensionMessageRuntime?
    private let openExternalURL: FloorpWebExtensionPageViewController.ExternalNavigationHandler
    private let clock: () -> Date
    private var installedPackages = [FloorpWebExtensionSettingsInstalledPackage]()
    // Never seed the visible catalog with Stage 3 fixtures. The catalog is
    // allowed to become visible only after the profile composition returns a
    // currently accepted signed result; a missing or rejected catalog must
    // remain non-installable from the first rendered frame.
    private var catalogItems = [FloorpWebExtensionBundledCatalogItem]()
    private var hasLoadedInstalledPackages = false
    private var hasLoadedCatalog = false
    private var isLoading = false
    private var needsRefreshAfterCurrentLoad = false
    private var busyExtensionIDs = Set<FloorpWebExtensionID>()
    private var pendingInstalledDetail: (id: FloorpWebExtensionID, showsSiteAccessGuidance: Bool)?
    private weak var catalogInstallConsentController: UIViewController?
    private weak var installedDetailNavigationController: UINavigationController?
    private let overviewHeaderView = FloorpWebExtensionOverviewHeaderView()
    private var catalogExpiryTask: Task<Void, Never>?

    init(
        windowUUID: WindowUUID,
        packageManager: (any FloorpWebExtensionSettingsManaging)?,
        pageResourceResolver: FloorpWebExtensionPageResourceResolver? = nil,
        pageMessageRuntime: FloorpWebExtensionMessageRuntime? = nil,
        openExternalURL: @escaping FloorpWebExtensionPageViewController.ExternalNavigationHandler = { _ in },
        clock: @escaping () -> Date = { Date() },
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default
    ) {
        self.packageManager = packageManager
        self.pageResourceResolver = pageResourceResolver
        self.pageMessageRuntime = pageMessageRuntime
        self.openExternalURL = openExternalURL
        self.clock = clock
        super.init(
            style: .insetGrouped,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        catalogExpiryTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FloorpStrings.WebExtensions.title
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refresh)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "Floorp.WebExtensions.Refresh"
        tableView.accessibilityIdentifier = "Floorp.WebExtensions.Settings"
        tableView.register(
            FloorpWebExtensionCardCell.self,
            forCellReuseIdentifier: FloorpWebExtensionCardCell.reuseIdentifier
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 116
        tableView.separatorStyle = .none
        tableView.tableHeaderView = overviewHeaderView
        configureOverviewHeader()
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeOverviewHeaderIfNeeded()
    }

    override func applyTheme() {
        super.applyTheme()
        configureOverviewHeader()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc
    private func refresh() {
        guard let packageManager else {
            tableView.reloadData()
            return
        }
        guard !isLoading else {
            needsRefreshAfterCurrentLoad = true
            tableView.reloadData()
            return
        }
        needsRefreshAfterCurrentLoad = false
        catalogExpiryTask?.cancel()
        catalogExpiryTask = nil
        isLoading = true
        // Do not leave a previously accepted listing actionable while the
        // current profile composition is being checked again. An installation
        // still performs its own catalog authorization, but the UI must not
        // advertise an old result as currently trusted.
        hasLoadedCatalog = false
        catalogItems = []
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.reloadData()
        Task { [weak self, packageManager] in
            let packages = await packageManager.settingsPackages()
            let catalogItems = await packageManager.catalogItems()
            guard let self, !Task.isCancelled else { return }
            self.installedPackages = packages.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.hasLoadedInstalledPackages = true
            self.catalogItems = catalogItems
            self.hasLoadedCatalog = true
            self.isLoading = false
            if self.needsRefreshAfterCurrentLoad {
                self.needsRefreshAfterCurrentLoad = false
                self.refresh()
                return
            }
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            self.scheduleCatalogExpiryInvalidation(for: catalogItems)
            self.tableView.reloadData()
            if let pending = self.pendingInstalledDetail,
               let installed = self.installedPackages.first(where: { $0.id == pending.id }) {
                self.pendingInstalledDetail = nil
                DispatchQueue.main.async { [weak self] in
                    self?.showInstalledPackage(
                        installed,
                        showsSiteAccessGuidance: pending.showsSiteAccessGuidance
                    )
                }
            }
        }
    }

    private func configureOverviewHeader() {
        guard isViewLoaded else { return }
        overviewHeaderView.configure(
            title: FloorpStrings.WebExtensions.introTitle,
            message: FloorpStrings.WebExtensions.introMessage,
            theme: themeManager.getCurrentTheme(for: windowUUID)
        )
        resizeOverviewHeaderIfNeeded()
    }

    private func resizeOverviewHeaderIfNeeded() {
        guard tableView.tableHeaderView === overviewHeaderView else { return }
        let fittingSize = CGSize(
            width: tableView.bounds.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let height = overviewHeaderView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard height > 0, abs(overviewHeaderView.frame.height - height) > 0.5 else { return }
        overviewHeaderView.frame.size.height = height
        tableView.tableHeaderView = overviewHeaderView
    }

    private func scheduleCatalogExpiryInvalidation(
        for items: [FloorpWebExtensionBundledCatalogItem]
    ) {
        catalogExpiryTask?.cancel()
        guard let expiresAt = items.compactMap(\.catalogExpiresAt).min() else { return }
        let interval = expiresAt.timeIntervalSince(clock())
        guard interval > 0 else {
            invalidateExpiredCatalogItems()
            return
        }
        let maximumInterval = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = UInt64(min(interval, maximumInterval) * 1_000_000_000)
        catalogExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.invalidateExpiredCatalogItems()
        }
    }

    private func invalidateExpiredCatalogItems() {
        guard catalogItems.contains(where: { !isCurrentCatalogItem($0) }) else { return }
        catalogItems.removeAll(where: { !isCurrentCatalogItem($0) })
        catalogInstallConsentController?.dismiss(animated: true)
        catalogInstallConsentController = nil
        tableView.reloadData()
        refresh()
    }

    private func isCurrentCatalogItem(_ item: FloorpWebExtensionBundledCatalogItem) -> Bool {
        guard let expiresAt = item.catalogExpiresAt else { return true }
        // The verifier admits the exact expiry instant. The Settings surface
        // is deliberately one-sided: treating that boundary as unavailable
        // ensures the scheduled invalidation cannot miss an exact-timestamp
        // wake-up and keeps UI affordances fail-closed.
        return clock() < expiresAt
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        packageManager == nil ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard packageManager != nil else { return FloorpStrings.WebExtensions.title }
        return Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let row = rows(in: indexPath.section)[indexPath.row]

        switch row {
        case .installed(let package):
            return extensionCardCell(
                in: tableView,
                at: indexPath,
                presentation: cardPresentation(for: package),
                theme: theme
            )
        case .available(let item):
            return extensionCardCell(
                in: tableView,
                at: indexPath,
                presentation: cardPresentation(for: item),
                theme: theme
            )
        case .installedLoading, .emptyInstalled, .catalogLoading, .catalogUnavailable, .unavailable:
            return stateCell(for: row, theme: theme)
        }
    }

    private func stateCell(for row: Row, theme: Theme) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = theme.colors.layer2
        cell.textLabel?.textColor = theme.colors.textPrimary
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = theme.colors.textSecondary
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.isUserInteractionEnabled = false
        cell.imageView?.tintColor = theme.colors.iconSecondary

        switch row {
        case .installedLoading:
            cell.textLabel?.text = FloorpStrings.WebExtensions.loading
            cell.imageView?.image = UIImage(systemName: "hourglass")
            cell.accessoryView = loadingIndicator(theme: theme)
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Installed.Loading"
        case .emptyInstalled:
            cell.textLabel?.text = FloorpStrings.WebExtensions.noInstalledTitle
            cell.detailTextLabel?.text = FloorpStrings.WebExtensions.noInstalledMessage
            cell.imageView?.image = UIImage(systemName: "puzzlepiece.extension")
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Installed.Empty"
        case .catalogLoading:
            cell.textLabel?.text = FloorpStrings.WebExtensions.loading
            cell.imageView?.image = UIImage(systemName: "checkmark.shield")
            cell.accessoryView = loadingIndicator(theme: theme)
            cell.accessibilityIdentifier = "Floorp.WebExtensions.CatalogLoading"
        case .catalogUnavailable:
            cell.textLabel?.text = FloorpStrings.WebExtensions.noAvailableTitle
            cell.detailTextLabel?.text = FloorpStrings.WebExtensions.noAvailableMessage
            cell.imageView?.image = UIImage(systemName: "checkmark.shield")
            cell.accessibilityIdentifier = "Floorp.WebExtensions.CatalogUnavailable"
        case .unavailable:
            cell.textLabel?.text = FloorpStrings.WebExtensions.packageStoreUnavailableTitle
            cell.detailTextLabel?.text = FloorpStrings.WebExtensions.packageStoreUnavailableMessage
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Unavailable"
        case .installed, .available:
            preconditionFailure("Card rows return before state-cell configuration")
        }
        return cell
    }

    private func loadingIndicator(theme: Theme) -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.color = theme.colors.iconAccent
        indicator.startAnimating()
        return indicator
    }

    private func extensionCardCell(
        in tableView: UITableView,
        at indexPath: IndexPath,
        presentation: FloorpWebExtensionCardPresentation,
        theme: Theme
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: FloorpWebExtensionCardCell.reuseIdentifier,
            for: indexPath
        ) as? FloorpWebExtensionCardCell else {
            assertionFailure("Unexpected extension card registration")
            return UITableViewCell()
        }
        cell.configure(with: presentation, theme: theme)
        return cell
    }

    private func cardPresentation(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> FloorpWebExtensionCardPresentation {
        FloorpWebExtensionCardPresentation(
            extensionID: package.id,
            title: package.name,
            summary: package.catalogDescription ?? package.siteAccessDescription,
            version: package.version,
            status: cardStatus(for: package),
            accessibilityIdentifier: "Floorp.WebExtensions.Installed.\(package.id.rawValue)",
            accessibilityHint: FloorpStrings.WebExtensions.manage,
            isBusy: busyExtensionIDs.contains(package.id)
        )
    }

    private func cardPresentation(
        for item: FloorpWebExtensionBundledCatalogItem
    ) -> FloorpWebExtensionCardPresentation {
        FloorpWebExtensionCardPresentation(
            extensionID: item.id,
            title: item.name,
            summary: item.summary,
            version: item.version,
            status: .available,
            accessibilityIdentifier: "Floorp.WebExtensions.Available.\(item.id.rawValue)",
            accessibilityHint: FloorpStrings.WebExtensions.add,
            isBusy: busyExtensionIDs.contains(item.id)
        )
    }

    private func cardStatus(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> FloorpWebExtensionCardPresentation.Status {
        if package.isCatalogRevoked { return .revoked }
        if package.errorDescription != nil { return .error }
        if updateItem(for: package) != nil { return .updateAvailable }
        return package.isEnabled ? .enabled : .disabled
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let package):
            guard !busyExtensionIDs.contains(package.id) else { return }
            showInstalledPackage(package)
        case .available(let item):
            guard !busyExtensionIDs.contains(item.id) else { return }
            confirmInstall(item)
        case .installedLoading, .emptyInstalled, .catalogLoading, .catalogUnavailable, .unavailable:
            break
        }
    }

    private func rows(in section: Int) -> [Row] {
        guard packageManager != nil else { return [.unavailable] }
        guard let section = Section(rawValue: section) else { return [] }
        switch section {
        case .installed:
            guard hasLoadedInstalledPackages else { return [.installedLoading] }
            return installedPackages.isEmpty ? [.emptyInstalled] : installedPackages.map(Row.installed)
        case .available:
            guard hasLoadedCatalog else { return [.catalogLoading] }
            let installedIDs = Set(installedPackages.map(\.id))
            let availableItems = catalogItems
                .filter { !installedIDs.contains($0.id) && isCurrentCatalogItem($0) }
                .map(Row.available)
            return availableItems.isEmpty ? [.catalogUnavailable] : availableItems
        }
    }

    private func updateItem(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> FloorpWebExtensionBundledCatalogItem? {
        catalogItems.first { item in
            isCurrentCatalogItem(item) &&
                item.id == package.id &&
                item.catalogRecord?.generation != package.catalogGeneration
        }
    }

    private func confirmInstall(_ item: FloorpWebExtensionBundledCatalogItem) {
        guard !busyExtensionIDs.contains(item.id) else { return }
        guard isCurrentCatalogItem(item) else {
            invalidateExpiredCatalogItems()
            return
        }
        let metadata = item.catalogRecord?.metadata
        let disclosure = metadata?.disclosure
        let isUpdate = installedPackages.contains(where: { $0.id == item.id })
        let requestedSites = (metadata?.hostPermissions ?? [])
            .map(\.original)
            .map(Self.displayName(forRequestedSite:))
            .sorted()
        let presentation = FloorpWebExtensionInstallPresentation(
            extensionID: item.id,
            name: item.name,
            summary: item.summary,
            version: item.version,
            catalogPublisher: disclosure?.publisherDisplayName,
            catalogAttribution: disclosure?.attribution,
            catalogPrivacySummary: disclosure?.privacySummary,
            catalogRetentionPolicy: disclosure?.retentionPolicy,
            catalogReviewedAt: disclosure?.reviewedAt,
            source: item.source,
            license: item.license,
            permissions: item.requestedPermissions,
            requestedSites: requestedSites,
            privateProfileCapability: metadata?.privateProfileCapability,
            mode: isUpdate ? .update : .install
        )
        let controller = FloorpWebExtensionInstallConfirmationViewController(
            presentation: presentation,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter,
            onCancel: { [weak self] in
                self?.dismiss(animated: true) { [weak self] in
                    self?.catalogInstallConsentController = nil
                }
            },
            onInstall: { [weak self] in
                self?.dismiss(animated: true) { [weak self] in
                    self?.catalogInstallConsentController = nil
                    self?.performInstall(
                        item,
                        showsSiteAccessGuidance: !isUpdate && !requestedSites.isEmpty
                    )
                }
            }
        )
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.sheetPresentationController?.detents = [.large()]
        navigationController.sheetPresentationController?.prefersGrabberVisible = true
        catalogInstallConsentController = navigationController
        present(navigationController, animated: true)
    }

    private static func displayName(forRequestedSite pattern: String) -> String {
        pattern == "*://*/*" ? "HTTP(S) · All requested websites" : pattern
    }

    private func showInstalledPackage(
        _ package: FloorpWebExtensionSettingsInstalledPackage,
        showsSiteAccessGuidance: Bool = false
    ) {
        guard installedDetailNavigationController == nil,
              !busyExtensionIDs.contains(package.id) else {
            return
        }
        let update = package.isCatalogRevoked ? nil : updateItem(for: package)
        let controller = FloorpWebExtensionInstalledDetailViewController(
            presentation: installedDetailPresentation(
                for: package,
                update: update,
                showsSiteAccessGuidance: showsSiteAccessGuidance
            ),
            actions: installedDetailActions(for: package, update: update),
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter
        )
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeInstalledDetail)
        )
        controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "Floorp.WebExtensions.Detail.Close.\(package.id.rawValue)"
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.sheetPresentationController?.detents = [.medium(), .large()]
        navigationController.sheetPresentationController?.selectedDetentIdentifier = .large
        navigationController.sheetPresentationController?.prefersGrabberVisible = true
        installedDetailNavigationController = navigationController
        present(navigationController, animated: true)
    }

    private func installedDetailPresentation(
        for package: FloorpWebExtensionSettingsInstalledPackage,
        update: FloorpWebExtensionBundledCatalogItem?,
        showsSiteAccessGuidance: Bool
    ) -> FloorpWebExtensionInstalledDetailPresentation {
        FloorpWebExtensionInstalledDetailPresentation(
            extensionID: package.id,
            name: package.name,
            summary: package.catalogDescription,
            version: package.version,
            isEnabled: package.isEnabled,
            isCatalogRevoked: package.isCatalogRevoked,
            errorDescription: package.errorDescription,
            permissions: package.permissions,
            siteAccessDescription: package.siteAccessDescription,
            privateAccessDescription: package.privateAccessDescription,
            isPrivateBrowsingEnabled: package.isPrivateBrowsingEnabled,
            privateProfileCapability: package.privateProfileCapability,
            catalogPublisher: package.catalogPublisher,
            catalogAttribution: package.catalogAttribution,
            catalogPrivacySummary: package.catalogPrivacySummary,
            catalogRetentionPolicy: package.catalogRetentionPolicy,
            catalogReviewedAt: package.catalogReviewedAt,
            catalogSource: package.catalogSource,
            catalogLicense: package.catalogLicense,
            updateVersion: update?.version,
            postInstallMessage: showsSiteAccessGuidance
                ? FloorpStrings.WebExtensions.postInstallSiteAccessGuidance
                : nil
        )
    }

    private func installedDetailActions(
        for package: FloorpWebExtensionSettingsInstalledPackage,
        update: FloorpWebExtensionBundledCatalogItem?
    ) -> FloorpWebExtensionInstalledDetailActions {
        FloorpWebExtensionInstalledDetailActions(
            onEnabledChanged: enabledAction(for: package),
            onOpenOptions: optionsAction(for: package),
            onManageSiteAccess: siteAccessAction(for: package),
            onTogglePrivateBrowsing: privateBrowsingAction(for: package),
            onManagePrivateSiteAccess: privateSiteAccessAction(for: package),
            onManageNetworkProtection: networkAction(for: package, isPrivateBrowsing: false),
            onManagePrivateNetworkProtection: networkAction(for: package, isPrivateBrowsing: true),
            onOpenWebsite: websiteAction(for: package),
            onViewUpdateHistory: updateHistoryAction(for: package),
            onUpdate: catalogUpdateAction(update),
            onUninstall: uninstallAction(for: package)
        )
    }

    private func enabledAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (Bool) -> Void {
        { [weak self] isEnabled in
            self?.dismissInstalledDetail {
                self?.setEnabled(isEnabled, for: package.id)
            }
        }
    }

    private func optionsAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (() -> Void)? {
        guard package.optionsPage != nil,
              pageResourceResolver != nil,
              pageMessageRuntime != nil,
              !package.isCatalogRevoked else {
            return nil
        }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.openOptionsPage(for: package) }
        }
    }

    private func siteAccessAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (() -> Void)? {
        guard package.isEnabled,
              !package.requestedSites.isEmpty,
              !package.isCatalogRevoked else {
            return nil
        }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.showSiteAccess(package) }
        }
    }

    private func privateBrowsingAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> ((Bool) -> Void)? {
        guard !package.isCatalogRevoked,
              package.privateProfileCapability.map({ $0 != .notSupported }) == true else {
            return nil
        }
        return { [weak self] isEnabled in
            self?.dismissInstalledDetail {
                self?.confirmPrivateBrowsingChange(enabled: isEnabled, package: package)
            }
        }
    }

    private func privateSiteAccessAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (() -> Void)? {
        guard package.isPrivateBrowsingEnabled,
              !package.requestedSites.isEmpty,
              !package.isCatalogRevoked else {
            return nil
        }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.showPrivateSiteAccess(package) }
        }
    }

    private func networkAction(
        for package: FloorpWebExtensionSettingsInstalledPackage,
        isPrivateBrowsing: Bool
    ) -> (() -> Void)? {
        let isActive = isPrivateBrowsing ? package.isPrivateBrowsingEnabled : package.isEnabled
        let status = isPrivateBrowsing ? package.privateDNRStatus : package.dnrStatus
        guard isActive, status != nil, !package.isCatalogRevoked else { return nil }
        return { [weak self] in
            self?.dismissInstalledDetail {
                self?.showDNRExclusions(package, isPrivateBrowsing: isPrivateBrowsing)
            }
        }
    }

    private func websiteAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (() -> Void)? {
        guard let homepage = package.catalogHomepage else { return nil }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.openExternalURL(homepage) }
        }
    }

    private func updateHistoryAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> (() -> Void)? {
        guard !package.updateHistory.isEmpty else { return nil }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.showUpdateHistory(package) }
        }
    }

    private func catalogUpdateAction(
        _ update: FloorpWebExtensionBundledCatalogItem?
    ) -> (() -> Void)? {
        guard let update else { return nil }
        return { [weak self] in
            self?.dismissInstalledDetail { self?.confirmInstall(update) }
        }
    }

    private func uninstallAction(
        for package: FloorpWebExtensionSettingsInstalledPackage
    ) -> () -> Void {
        { [weak self] in
            self?.dismissInstalledDetail { self?.confirmUninstall(package) }
        }
    }

    @objc
    private func closeInstalledDetail() {
        dismissInstalledDetail()
    }

    private func dismissInstalledDetail(then action: (() -> Void)? = nil) {
        guard let controller = installedDetailNavigationController else {
            action?()
            return
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.installedDetailNavigationController = nil
            action?()
        }
    }

    private func showUpdateHistory(_ package: FloorpWebExtensionSettingsInstalledPackage) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let entries = package.updateHistory.reversed().map { entry -> String in
            let method = switch entry.method {
            case .userApproved:
                "Installed after confirmation"
            }
            return [
                "\(entry.previousVersion) → \(entry.replacementVersion)",
                method,
                "Generation: \(entry.replacementCatalogGeneration)",
                formatter.string(from: entry.occurredAt)
            ].joined(separator: "\n")
        }
        let alert = UIAlertController(
            title: "Update History",
            message: entries.joined(separator: "\n\n"),
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "Floorp.WebExtensions.UpdateHistory.\(package.id.rawValue)"
        alert.addAction(UIAlertAction(title: "Done", style: .default))
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

    private func showSiteAccess(_ package: FloorpWebExtensionSettingsInstalledPackage) {
        showSiteAccess(package, isPrivateBrowsing: false)
    }

    private func showSiteAccess(
        _ package: FloorpWebExtensionSettingsInstalledPackage,
        isPrivateBrowsing: Bool
    ) {
        let currentAccess = isPrivateBrowsing ? package.privateHostAccess : package.normalHostAccess
        let profileTitle = isPrivateBrowsing ? "Private site access" : "Site access"
        let profileMessage = isPrivateBrowsing
            ? "Choose exactly where this separately installed private extension may read or change page data."
            : "Choose exactly where this extension may read or change page data."
        let alert = UIAlertController(
            title: "\(profileTitle) for \(package.name)",
            message: profileMessage,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "No sites", style: .destructive) { [weak self] _ in
            self?.setSiteAccess(.denied, for: package.id, isPrivateBrowsing: isPrivateBrowsing)
        })
        alert.addAction(UIAlertAction(title: "All requested sites", style: .default) { [weak self] _ in
            self?.setSiteAccess(.allRequestedSites, for: package.id, isPrivateBrowsing: isPrivateBrowsing)
        })
        for site in package.requestedSites {
            alert.addAction(UIAlertAction(title: "Only \(site.original)", style: .default) { [weak self] _ in
                self?.setSiteAccess(
                    .selectedSites([site]),
                    for: package.id,
                    isPrivateBrowsing: isPrivateBrowsing
                )
            })
        }
        if case .allRequestedSites = currentAccess {
            // No narrower controls are needed: every declared site is already
            // authorized. The explicit "No sites" and "Only" actions above
            // remain available to reduce access.
        } else {
            alert.addAction(UIAlertAction(title: "Add a site…", style: .default) { [weak self] _ in
                self?.promptForSelectedSite(package, isPrivateBrowsing: isPrivateBrowsing)
            })
            for site in Self.selectedSites(from: currentAccess).sorted(by: { $0.original < $1.original }) {
                alert.addAction(UIAlertAction(
                    title: "Remove \(site.original)",
                    style: .destructive
                ) { [weak self] _ in
                    guard let self else { return }
                    var selectedSites = Self.selectedSites(from: currentAccess)
                    selectedSites.remove(site)
                    self.setSiteAccess(
                        selectedSites.isEmpty ? .denied : .selectedSites(selectedSites),
                        for: package.id,
                        isPrivateBrowsing: isPrivateBrowsing
                    )
                })
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        present(alert, animated: true)
    }

    private func confirmPrivateBrowsingChange(
        enabled: Bool,
        package: FloorpWebExtensionSettingsInstalledPackage
    ) {
        if !enabled {
            setPrivateBrowsingEnabled(false, for: package.id)
            return
        }
        let privateBrowsingMessage = [
            "This installs a separate ephemeral copy for private browsing.",
            "Its site access starts disabled and private data is removed when the private session ends."
        ].joined(separator: " ")
        let alert = UIAlertController(
            title: "Allow \(package.name) in Private Browsing?",
            message: privateBrowsingMessage,
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "Floorp.WebExtensions.PrivateBrowsingConsent"
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in
            self?.setPrivateBrowsingEnabled(true, for: package.id)
        })
        present(alert, animated: true)
    }

    private func showPrivateSiteAccess(_ package: FloorpWebExtensionSettingsInstalledPackage) {
        showSiteAccess(package, isPrivateBrowsing: true)
    }

    private func promptForSelectedSite(
        _ package: FloorpWebExtensionSettingsInstalledPackage,
        isPrivateBrowsing: Bool
    ) {
        let alert = UIAlertController(
            title: "Add a site",
            message: "Enter a hostname or HTTPS URL. This authorizes only that site, not every requested site.",
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "Floorp.WebExtensions.AddSelectedSite"
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let input = alert?.textFields?.first?.text,
                  let selectedSite = Self.selectedSitePattern(from: input) else {
                self?.presentSiteInputError(
                    "Enter a hostname or HTTP(S) URL without a path, port, query, or credentials."
                )
                return
            }
            guard package.requestedSites.contains(where: { $0.covers(selectedSite) }) else {
                self.presentSiteInputError(
                    "This extension did not request access to \(selectedSite.original)."
                )
                return
            }
            let currentAccess = isPrivateBrowsing ? package.privateHostAccess : package.normalHostAccess
            var selectedSites = Self.selectedSites(from: currentAccess)
            selectedSites.insert(selectedSite)
            self.setSiteAccess(
                .selectedSites(selectedSites),
                for: package.id,
                isPrivateBrowsing: isPrivateBrowsing
            )
        })
        present(alert, animated: true)
    }

    private func showDNRExclusions(
        _ package: FloorpWebExtensionSettingsInstalledPackage,
        isPrivateBrowsing: Bool
    ) {
        guard let status = isPrivateBrowsing ? package.privateDNRStatus : package.dnrStatus else {
            return
        }
        let profile = isPrivateBrowsing ? "Private" : "Standard"
        let ruleSets = status.enabledStaticRuleSetIDs.isEmpty
            ? "None"
            : status.enabledStaticRuleSetIDs.joined(separator: ", ")
        let exclusionNotice = status.excludedTopLevelDomains.isEmpty
            ? "No site exclusions."
            : "\(status.excludedTopLevelDomains.count) site exclusion\(status.excludedTopLevelDomains.count == 1 ? "" : "s")."
        let alert = UIAlertController(
            title: "\(profile) network protection",
            message: [
                "Active rulesets: \(ruleSets)",
                "Rules generation: \(status.policyGeneration)",
                exclusionNotice,
                "A site exclusion keeps fixed block rules active everywhere else."
            ].joined(separator: "\n\n"),
            preferredStyle: .actionSheet
        )
        alert.view.accessibilityIdentifier = isPrivateBrowsing
            ? "Floorp.WebExtensions.PrivateDNRExclusions"
            : "Floorp.WebExtensions.DNRExclusions"
        alert.addAction(UIAlertAction(title: "Exclude a site…", style: .default) { [weak self] _ in
            self?.promptForDNRExclusion(package, status: status, isPrivateBrowsing: isPrivateBrowsing)
        })
        for domain in status.excludedTopLevelDomains {
            alert.addAction(UIAlertAction(
                title: "Remove \(domain)",
                style: .destructive
            ) { [weak self] _ in
                self?.setDNRExcludedTopLevelDomains(
                    status.excludedTopLevelDomains.filter { $0 != domain },
                    for: package.id,
                    isPrivateBrowsing: isPrivateBrowsing
                )
            })
        }
        if !status.excludedTopLevelDomains.isEmpty {
            alert.addAction(UIAlertAction(
                title: "Remove all site exclusions",
                style: .destructive
            ) { [weak self] _ in
                self?.setDNRExcludedTopLevelDomains(
                    [],
                    for: package.id,
                    isPrivateBrowsing: isPrivateBrowsing
                )
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        present(alert, animated: true)
    }

    private func promptForDNRExclusion(
        _ package: FloorpWebExtensionSettingsInstalledPackage,
        status: FloorpWebExtensionSettingsDNRStatus,
        isPrivateBrowsing: Bool
    ) {
        let alert = UIAlertController(
            title: "Exclude a site from blocking",
            message: "Enter a hostname or HTTP(S) URL. The exemption applies to that host and its subdomains only.",
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "Floorp.WebExtensions.AddDNRExclusion"
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Exclude", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let input = alert?.textFields?.first?.text,
                  let domain = FloorpWebExtensionDNRExcludedTopLevelDomain.normalizeUserInput(input) else {
                self?.presentSiteInputError(
                    "Enter a hostname or HTTP(S) URL without a path, port, query, or credentials."
                )
                return
            }
            let domains = Array(Set(status.excludedTopLevelDomains + [domain])).sorted()
            self.setDNRExcludedTopLevelDomains(
                domains,
                for: package.id,
                isPrivateBrowsing: isPrivateBrowsing
            )
        })
        present(alert, animated: true)
    }

    private static func selectedSites(
        from access: FloorpWebExtensionHostAccess
    ) -> Set<FloorpWebExtensionMatchPattern> {
        guard case .selectedSites(let sites) = access else { return [] }
        return sites
    }

    private static func selectedSitePattern(from input: String) -> FloorpWebExtensionMatchPattern? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else {
            return nil
        }
        return try? FloorpWebExtensionMatchPattern("\(scheme)://\(host)/*")
    }

    private func presentSiteInputError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(
                title: "Site could not be added",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
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

    private func performInstall(
        _ item: FloorpWebExtensionBundledCatalogItem,
        showsSiteAccessGuidance: Bool = false
    ) {
        guard isCurrentCatalogItem(item) else {
            invalidateExpiredCatalogItems()
            return
        }
        pendingInstalledDetail = (item.id, showsSiteAccessGuidance)
        mutate(for: item.id, onFailure: { [weak self] in
            guard self?.pendingInstalledDetail?.id == item.id else { return }
            self?.pendingInstalledDetail = nil
        }) { manager in
            try await manager.installBundledPackage(item)
        }
    }

    private func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) {
        mutate(for: extensionID) { manager in
            try await manager.setEnabled(isEnabled, for: extensionID)
        }
    }

    private func setSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID,
        isPrivateBrowsing: Bool = false
    ) {
        mutate(for: extensionID) { manager in
            if isPrivateBrowsing {
                try await manager.setPrivateSiteAccess(access, for: extensionID)
            } else {
                try await manager.setNormalSiteAccess(access, for: extensionID)
            }
        }
    }

    private func setPrivateBrowsingEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) {
        mutate(for: extensionID) { manager in
            try await manager.setPrivateBrowsingEnabled(isEnabled, for: extensionID)
        }
    }

    private func setPrivateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) {
        mutate(for: extensionID) { manager in
            try await manager.setPrivateSiteAccess(access, for: extensionID)
        }
    }

    private func setDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID,
        isPrivateBrowsing: Bool
    ) {
        mutate(for: extensionID) { manager in
            if isPrivateBrowsing {
                try await manager.setPrivateDNRExcludedTopLevelDomains(domains, for: extensionID)
            } else {
                try await manager.setNormalDNRExcludedTopLevelDomains(domains, for: extensionID)
            }
        }
    }

    private func performUninstall(_ extensionID: FloorpWebExtensionID) {
        pendingInstalledDetail = nil
        mutate(for: extensionID) { manager in
            try await manager.uninstall(extensionID)
        }
    }

    private func mutate(
        for extensionID: FloorpWebExtensionID,
        onFailure: (@MainActor () -> Void)? = nil,
        _ operation: @escaping @Sendable (any FloorpWebExtensionSettingsManaging) async throws -> Void
    ) {
        guard let packageManager, busyExtensionIDs.insert(extensionID).inserted else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.reloadData()
        Task { [weak self, packageManager] in
            do {
                try await operation(packageManager)
                guard let self, !Task.isCancelled else { return }
                self.busyExtensionIDs.remove(extensionID)
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.refresh()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.busyExtensionIDs.remove(extensionID)
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                onFailure?()
                self.tableView.reloadData()
                self.presentError(error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.loadErrorTitle,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "Floorp.WebExtensions.Error"
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

    /// One-use, in-memory authority for a catalog update. The fields bind a
    /// user's confirmation to both sides of the immutable transition; a stale
    /// dialog cannot approve another package or digest.
    struct CatalogUpdateAuthorization: Sendable, Equatable {
        fileprivate let extensionID: FloorpWebExtensionID
        fileprivate let installedGeneration: String
        fileprivate let replacementCatalogGeneration: String
        fileprivate let replacementArtifactSHA256: String
        fileprivate let lifecycleRevision: UInt64
    }

    /// Product-owned UI receives the before/after immutable identities and
    /// the exact new authority. It must not accept text, callbacks, or URLs
    /// from an extension document.
    struct CatalogUpdateConfirmationRequest: Sendable, Equatable {
        let extensionID: FloorpWebExtensionID
        let extensionName: String
        let installedVersion: String
        let installedGeneration: String
        let replacementVersion: String
        let replacementCatalogGeneration: String
        let replacementArtifactSHA256: String
        let addedRequiredAPIPermissions: [FloorpWebExtensionAPIGrant]
        let addedRequiredHostPermissions: [FloorpWebExtensionMatchPattern]
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
    typealias CatalogItemsProvider = @MainActor @Sendable () async -> [FloorpWebExtensionBundledCatalogItem]
    typealias SignedBundledCatalogInstaller = @MainActor @Sendable (
        FloorpWebExtensionLivePackageManager,
        FloorpWebExtensionBundledCatalogItem
    ) async throws -> Void
    typealias CurrentCompositionCheck = @MainActor () -> Bool
    typealias CatalogUpdateConfirmation = @MainActor (
        CatalogUpdateConfirmationRequest
    ) async -> Bool
    /// A catalog package can be restored or re-enabled only when the P0
    /// composition can still authorize its record against device-bound
    /// catalog state. An unsigned fixture has no catalog record, but is only
    /// eligible under the explicit test-only activation policy below.
    typealias CatalogRecordAuthorization = @MainActor @Sendable (
        FloorpWebExtensionCatalogPackageRecord
    ) throws -> Void
    /// Supplies the signed catalog lifetime after the same device-bound
    /// authorization check. A normal catalog mutation must carry this value
    /// into the package-store actor; a missing provider is fail-closed.
    typealias CatalogRecordExpirationProvider = @MainActor @Sendable (
        FloorpWebExtensionCatalogPackageRecord
    ) throws -> Date
    /// Unsigned fixtures exist only to support the pre-catalog compatibility
    /// harness. A production composition must never restore, enable, or
    /// install one: an app upgrade must not turn a persisted Stage 3 fixture
    /// into a bypass around the signed catalog acceptance state.
    enum UnsignedPackageActivationPolicy: Sendable, Equatable {
        case reject
        case allowVerifiedFixtureForTesting
    }
    typealias DNRExcludedTopLevelDomainsUpdater = @MainActor @Sendable (
        FloorpWebExtensionID,
        [String]
    ) async throws -> Bool

    let store: FloorpWebExtensionPackageStore
    private let isCurrentComposition: CurrentCompositionCheck
    private let reconcile: Reconciler
    private let reconcilePrepared: PreparedReconciler?
    private let bundledPackageURL: BundledPackageURLResolver
    private let catalogItemsProvider: CatalogItemsProvider
    private let signedBundledCatalogInstaller: SignedBundledCatalogInstaller
    private let catalogUpdateConfirmation: CatalogUpdateConfirmation
    private let catalogRecordAuthorization: CatalogRecordAuthorization
    private let catalogRecordExpirationProvider: CatalogRecordExpirationProvider
    /// Startup restoration is the one offline path allowed to continue using
    /// an already-enabled package after catalog expiry. The production
    /// composition injects a narrower authorization closure here; all other
    /// lifecycle operations retain `catalogRecordAuthorization`.
    private let catalogRecordRestoreAuthorization: CatalogRecordAuthorization
    private let unsignedPackageActivationPolicy: UnsignedPackageActivationPolicy
    private let dnrExcludedTopLevelDomainsUpdater: DNRExcludedTopLevelDomainsUpdater
    private var lifecycleMutationGates = [FloorpWebExtensionID: FloorpWebExtensionLifecycleMutationGate]()
    private var lifecycleRevisions = [FloorpWebExtensionID: UInt64]()

    init(
        store: FloorpWebExtensionPackageStore,
        isCurrentComposition: @escaping CurrentCompositionCheck = { true },
        reconcile: @escaping Reconciler,
        // Fixture package resolution is injected by focused tests only. A
        // production composition has no unsigned bundled-install fallback.
        bundledPackageURL: @escaping BundledPackageURLResolver = { _ in nil },
        // A missing composition must fail closed rather than publishing the
        // legacy Stage 3 fixture catalog.
        catalogItemsProvider: @escaping CatalogItemsProvider = { [] },
        signedBundledCatalogInstaller: @escaping SignedBundledCatalogInstaller = { _, _ in
            throw FloorpWebExtensionCatalogError.remoteCatalogDisabled
        },
        reconcilePrepared: PreparedReconciler? = nil,
        catalogUpdateConfirmation: @escaping CatalogUpdateConfirmation = { _ in false },
        catalogRecordAuthorization: @escaping CatalogRecordAuthorization = { _ in
            throw FloorpWebExtensionCatalogError.remoteCatalogDisabled
        },
        catalogRecordExpirationProvider: @escaping CatalogRecordExpirationProvider = { _ in
            throw FloorpWebExtensionCatalogError.remoteCatalogDisabled
        },
        catalogRecordRestoreAuthorization: CatalogRecordAuthorization? = nil,
        unsignedPackageActivationPolicy: UnsignedPackageActivationPolicy = .reject,
        dnrExcludedTopLevelDomainsUpdater: @escaping DNRExcludedTopLevelDomainsUpdater = { _, _ in
            throw FloorpWebExtensionError.unsupported("DNR settings are unavailable")
        }
    ) {
        self.store = store
        self.isCurrentComposition = isCurrentComposition
        self.reconcile = reconcile
        self.reconcilePrepared = reconcilePrepared
        self.bundledPackageURL = bundledPackageURL
        self.catalogItemsProvider = catalogItemsProvider
        self.signedBundledCatalogInstaller = signedBundledCatalogInstaller
        self.catalogUpdateConfirmation = catalogUpdateConfirmation
        self.catalogRecordAuthorization = catalogRecordAuthorization
        self.catalogRecordExpirationProvider = catalogRecordExpirationProvider
        self.catalogRecordRestoreAuthorization = catalogRecordRestoreAuthorization ?? catalogRecordAuthorization
        self.unsignedPackageActivationPolicy = unsignedPackageActivationPolicy
        self.dnrExcludedTopLevelDomainsUpdater = dnrExcludedTopLevelDomainsUpdater
    }

    func settingsPackages() async -> [FloorpWebExtensionSettingsInstalledPackage] {
        let packages = await store.installedPackages()
        var settingsPackages = [FloorpWebExtensionSettingsInstalledPackage]()
        settingsPackages.reserveCapacity(packages.count)
        for package in packages {
            let updateHistory = await store.catalogUpdateHistory(for: package.extensionID)
            let catalogMetadata = package.catalogRecord?.metadata
            settingsPackages.append(.init(
                id: package.extensionID,
                name: package.name,
                version: package.version,
                catalogGeneration: package.catalogRecord?.generation,
                catalogDescription: catalogMetadata?.description,
                catalogSource: catalogMetadata.map { "\($0.upstream) @ \($0.upstreamRevision)" },
                catalogLicense: catalogMetadata?.license,
                catalogHomepage: catalogMetadata?.sourceURL,
                catalogCategory: catalogMetadata?.category,
                catalogModificationStatus: catalogMetadata?.modificationStatus,
                catalogPublisher: catalogMetadata?.disclosure?.publisherDisplayName,
                catalogAttribution: catalogMetadata?.disclosure?.attribution,
                catalogPrivacySummary: catalogMetadata?.disclosure?.privacySummary,
                catalogRetentionPolicy: catalogMetadata?.disclosure?.retentionPolicy,
                catalogReviewedAt: catalogMetadata?.disclosure?.reviewedAt,
                privateProfileCapability: catalogMetadata?.privateProfileCapability,
                isEnabled: package.isEnabled,
                isCatalogRevoked: package.isCatalogRevoked,
                permissions: Self.settingsPermissionCategories(for: package.grants),
                siteAccessDescription: Self.siteAccessDescription(
                    package.grants.normalHostAccess,
                    requestedHosts: package.grants.requestedHosts
                ),
                requestedSites: package.grants.requestedHosts.sorted {
                    $0.original < $1.original
                },
                normalHostAccess: package.grants.normalHostAccess,
                privateHostAccess: package.grants.privateHostAccess,
                isPrivateBrowsingEnabled: package.grants.privateBrowsingEnabled,
                privateAccessDescription: package.grants.privateBrowsingEnabled
                    ? Self.siteAccessDescription(
                        package.grants.privateHostAccess,
                        requestedHosts: package.grants.requestedHosts
                    )
                    : "Not allowed",
                errorDescription: package.activationError ?? (package.preflight.isActivationAllowed
                    ? nil
                    : "This extension is incompatible with the current Floorp build."),
                optionsPage: Self.optionsPage(for: package),
                dnrStatus: Self.settingsDNRStatus(for: package),
                privateDNRStatus: nil,
                updateHistory: updateHistory
            ))
        }
        return settingsPackages
    }

    func catalogItems() async -> [FloorpWebExtensionBundledCatalogItem] {
        await catalogItemsProvider()
    }

    func setNormalSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard let package = await store.installedPackage(for: extensionID) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        let authorization = try await authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: package.generation
        )
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: package.grants.apiPermissions,
            requestedHosts: package.grants.requestedHosts,
            normalHostAccess: access,
            privateHostAccess: package.grants.privateHostAccess,
            privateBrowsingEnabled: package.grants.privateBrowsingEnabled
        )
        try await updateGrants(grants, authorization: authorization)
    }

    func setNormalDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard !store.profileKey.isPrivateBrowsing else {
            throw FloorpWebExtensionError.unsupported("normal DNR settings are owned by the normal profile")
        }
        try await updateDNRExcludedTopLevelDomains(domains, for: extensionID)
    }

    func setPrivateDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard store.profileKey.isPrivateBrowsing,
              let package = await store.installedPackage(for: extensionID),
              package.grants.privateBrowsingEnabled else {
            throw FloorpWebExtensionError.unsupported("private browsing is not enabled for this extension")
        }
        try await updateDNRExcludedTopLevelDomains(domains, for: extensionID)
    }

    /// The concrete private-profile manager owns only its ephemeral package
    /// store. Cross-profile installation is coordinated by
    /// `FloorpWebExtensionProfileSettingsManager`; this method merely changes
    /// the already-installed private copy after an explicit native consent.
    func setPrivateBrowsingEnabled(
        _ isEnabled: Bool,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard store.profileKey.isPrivateBrowsing else {
            throw FloorpWebExtensionError.unsupported("private browsing is owned by the private profile")
        }
        guard let package = await store.installedPackage(for: extensionID) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        let authorization = try await authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: package.generation
        )
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: package.grants.apiPermissions,
            requestedHosts: package.grants.requestedHosts,
            normalHostAccess: package.grants.normalHostAccess,
            privateHostAccess: isEnabled ? package.grants.privateHostAccess : .denied,
            privateBrowsingEnabled: isEnabled
        )
        try await updateGrants(grants, authorization: authorization)
    }

    func setPrivateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard store.profileKey.isPrivateBrowsing,
              let package = await store.installedPackage(for: extensionID),
              package.grants.privateBrowsingEnabled else {
            throw FloorpWebExtensionError.unsupported("private browsing is not enabled for this extension")
        }
        let authorization = try await authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: package.generation
        )
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: package.grants.apiPermissions,
            requestedHosts: package.grants.requestedHosts,
            normalHostAccess: package.grants.normalHostAccess,
            privateHostAccess: access,
            privateBrowsingEnabled: true
        )
        try await updateGrants(grants, authorization: authorization)
    }

    // swiftlint:disable:next function_body_length
    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws {
        if item.catalogRecord != nil {
            try await signedBundledCatalogInstaller(self, item)
            return
        }
        guard unsignedPackageActivationPolicy == .allowVerifiedFixtureForTesting else {
            throw FloorpWebExtensionCatalogError.unsignedPackageRejected
        }
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
            normalHostAccess: .denied,
            privateHostAccess: .denied,
            privateBrowsingEnabled: false
        )
        let transaction = try await store.installBundledPackageTransaction(
            at: packageURL,
            expectedExtensionID: item.id,
            initialGrants: initialGrants
        )
        try await activatePreparedPackageTransaction(transaction, extensionID: item.id)
    }

    // swiftlint:disable function_body_length
    /// The managed source is intentionally not exposed by Settings. This
    /// lifecycle endpoint exists only for the P0-gated catalog composition,
    /// and receives a lifecycle-authorized, verifier-produced artifact rather
    /// than a URL or file. The opaque authorization can only be minted by the
    /// catalog lifecycle coordinator after it rechecks current device state.
    func installVerifiedCatalogPackage(
        _ artifact: FloorpWebExtensionVerifiedCatalogArtifact,
        catalogAuthorization: FloorpWebExtensionCatalogInstallationAuthorization,
        initialGrants: FloorpWebExtensionPermissionSnapshot? = nil,
        updateAuthorization: CatalogUpdateAuthorization? = nil,
        source: FloorpWebExtensionCatalogSource = .managedRemote
    ) async throws {
        try source.requireEnabled()
        guard catalogAuthorization.authorizes(artifact) else {
            throw FloorpWebExtensionCatalogError.artifactRejected(
                "catalog installation authorization does not match artifact"
            )
        }
        guard !store.profileKey.isPrivateBrowsing ||
                artifact.record.metadata?.privateProfileCapability != .notSupported else {
            throw FloorpWebExtensionCatalogError.artifactRejected(
                "catalog package is not approved for private browsing"
            )
        }
        let extensionID = artifact.record.extensionID
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        let installed = await store.installedPackage(for: extensionID)
        if let installed {
            guard installed.catalogRecord != nil else {
                throw FloorpWebExtensionCatalogError.updateConsentRequired
            }
            guard let authorization = updateAuthorization,
                  authorization.extensionID == extensionID,
                  authorization.installedGeneration == installed.generation,
                  authorization.replacementCatalogGeneration == artifact.record.generation,
                  authorization.replacementArtifactSHA256 == artifact.record.artifactSHA256,
                  authorization.lifecycleRevision == lifecycleRevisions[extensionID, default: 0],
                  isCurrentComposition() else {
                throw FloorpWebExtensionCatalogError.updateConsentRequired
            }
        }
        invalidatePermissionAuthorizations(for: extensionID)

        if await store.hasPendingDataPurge(for: extensionID) {
            try await reconcile(extensionID, nil, .suspend)
            try await reconcile(extensionID, nil, .uninstall)
            try await store.completeUninstallCleanup(extensionID)
        }
        let updateConsent = updateAuthorization.map {
            FloorpWebExtensionCatalogUpdateConsent(
                extensionID: $0.extensionID,
                installedGeneration: $0.installedGeneration,
                replacementCatalogGeneration: $0.replacementCatalogGeneration,
                replacementArtifactSHA256: $0.replacementArtifactSHA256
            )
        }
        let transaction = try await store.installVerifiedCatalogPackageTransaction(
            artifact,
            initialGrants: initialGrants,
            updateConsent: updateConsent,
            catalogExpiresAt: catalogAuthorization.expiresAt
        )
        try await activatePreparedPackageTransaction(
            transaction,
            extensionID: extensionID,
            catalogExpiresAt: catalogAuthorization.expiresAt
        )
    }
    // swiftlint:enable function_body_length

    /// Shows the product-owned update confirmation for every immutable catalog
    /// replacement. A signed catalog never substitutes for this explicit
    /// confirmation, even when the authority delta is empty.
    func authorizeCatalogUpdate(
        for artifact: FloorpWebExtensionVerifiedCatalogArtifact,
        source: FloorpWebExtensionCatalogSource = .managedRemote
    ) async throws -> CatalogUpdateAuthorization {
        try source.requireEnabled()
        let extensionID = artifact.record.extensionID
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard isCurrentComposition(),
              let installed = await store.installedPackage(for: extensionID),
              installed.catalogRecord != nil,
              installed.generation != artifact.record.localGeneration else {
            throw FloorpWebExtensionCatalogError.updateConsentRequired
        }
        guard FloorpWebExtensionCatalogVerifier.semanticVersionIsStrictlyGreater(
            artifact.record.version,
            than: installed.version
        ), let permissionDelta = try await store.catalogUpdatePermissionDelta(for: artifact) else {
            throw FloorpWebExtensionCatalogError.updateConsentRequired
        }
        let request = CatalogUpdateConfirmationRequest(
            extensionID: extensionID,
            extensionName: installed.name,
            installedVersion: installed.version,
            installedGeneration: installed.generation,
            replacementVersion: artifact.record.version,
            replacementCatalogGeneration: artifact.record.generation,
            replacementArtifactSHA256: artifact.record.artifactSHA256,
            addedRequiredAPIPermissions: permissionDelta.addedRequiredAPIPermissions,
            addedRequiredHostPermissions: permissionDelta.addedRequiredHostPermissions
        )
        guard await catalogUpdateConfirmation(request),
              isCurrentComposition(),
              let current = await store.installedPackage(for: extensionID),
              current.generation == installed.generation else {
            throw FloorpWebExtensionCatalogError.updateConsentRequired
        }
        return .init(
            extensionID: extensionID,
            installedGeneration: installed.generation,
            replacementCatalogGeneration: artifact.record.generation,
            replacementArtifactSHA256: artifact.record.artifactSHA256,
            lifecycleRevision: lifecycleRevisions[extensionID, default: 0]
        )
    }

    /// Stops an installed catalog generation in the same order used for a
    /// user disable: live policy first, then the durable registry. It does not
    /// delete storage or select a rollback target.
    func revokeCatalogGeneration(
        extensionID: FloorpWebExtensionID,
        catalogGeneration: String
    ) async throws {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        invalidatePermissionAuthorizations(for: extensionID)
        guard let package = await store.installedPackage(for: extensionID),
              package.catalogRecord?.generation == catalogGeneration else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        if package.isEnabled {
            try await reconcile(extensionID, nil, .suspend)
        }
        do {
            try await store.recordCatalogRevocation(
                for: extensionID,
                catalogGeneration: catalogGeneration
            )
        } catch {
            if package.isEnabled {
                try? await reconcile(extensionID, package, .suspend)
            }
            throw error
        }
    }

    /// Applies the complete, signature-verified device acceptance state before
    /// it is committed to Keychain. This is deliberately stronger than
    /// applying just the signed revocation entries: a locally altered registry
    /// record must not keep running merely because its substituted leaf key is
    /// absent from the catalog's revocation list. A package continues only if
    /// its exact generation/digest/key binding is accepted and non-revoked.
    /// Neither rejection path selects a fallback package.
    func applySignedCatalogAcceptanceState(
        _ state: FloorpWebExtensionCatalogAcceptanceState,
        source: FloorpWebExtensionCatalogSource = .managedRemote
    ) async throws {
        try source.requireEnabled()
        let targets = await store.installedPackages().compactMap { package -> (FloorpWebExtensionID, String)? in
            guard let record = package.catalogRecord else { return nil }
            let generation = FloorpWebExtensionCatalogGeneration(
                extensionID: record.extensionID,
                generation: record.generation
            )
            let binding = FloorpWebExtensionCatalogGenerationArtifactDigest(
                catalogGeneration: generation,
                artifactSHA256: record.artifactSHA256,
                signingKeyID: record.signingKeyID
            )
            guard !state.currentGenerationArtifacts.contains(binding) ||
                    state.revokedGenerations.contains(generation) ||
                    state.revokedKeyIDs.contains(record.signingKeyID) else {
                return nil
            }
            return (record.extensionID, record.generation)
        }.sorted { lhs, rhs in
            lhs.0.rawValue == rhs.0.rawValue
                ? lhs.1 < rhs.1
                : lhs.0.rawValue < rhs.0.rawValue
        }
        for target in targets {
            try await revokeCatalogGeneration(
                extensionID: target.0,
                catalogGeneration: target.1
            )
        }
    }

    // swiftlint:disable:next function_body_length
    private func activatePreparedPackageTransaction(
        _ transaction: FloorpWebExtensionPackageStore.BundledPackageInstallationTransaction,
        extensionID: FloorpWebExtensionID,
        catalogExpiresAt: Date? = nil
    ) async throws {
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
                extensionID: extensionID,
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
                    extensionID: extensionID,
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
                    extensionID: extensionID,
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
                extensionID: extensionID,
                replacementGeneration: installed.generation,
                catalogExpiresAt: catalogExpiresAt
            )
        } catch {
            if installed.isEnabled {
                try? await reconcile(installed.extensionID, nil, .suspend)
            }
            try? await store.abortPreparedBundledPackageUpdate(
                extensionID: extensionID,
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

        let catalogExpiresAt: Date?
        if !isEnabled {
            catalogExpiresAt = nil
            // Revoke live privileges before persisting the disable. If the
            // registry write fails, the extension remains safely inactive.
            try await reconcile(extensionID, nil, .suspend)
        } else {
            guard let package = await store.installedPackage(for: extensionID) else {
                throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
            }
            catalogExpiresAt = try catalogAuthorizationExpiry(for: package)
        }
        try await store.setEnabled(
            isEnabled,
            for: extensionID,
            catalogExpiresAt: catalogExpiresAt
        )
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
        try await authorizePermissionMutationWithPackageSnapshot(
            for: extensionID,
            expectedGeneration: expectedGeneration
        ).authorization
    }

    /// Captures both the one-use mutation authority and the grants shown by a
    /// product-owned consent prompt while holding the same lifecycle gate.
    /// Callers must build the prompt and its replacement snapshot from the
    /// returned package, never from an earlier package listing.
    func authorizePermissionMutationWithPackageSnapshot(
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String
    ) async throws -> (
        authorization: PermissionMutationAuthorization,
        package: FloorpWebExtensionInstalledPackage
    ) {
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
        try authorizeCatalogRecord(package)
        let authorization = PermissionMutationAuthorization(
            extensionID: extensionID,
            packageGeneration: expectedGeneration,
            lifecycleRevision: lifecycleRevisions[extensionID, default: 0]
        )
        return (authorization, package)
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
        // Native permission consent may have remained visible across catalog
        // expiry. Recheck the immutable record immediately before mutating
        // grants so an authorization captured before the prompt cannot add
        // capabilities after the signed catalog lifetime ends.
        _ = try catalogAuthorizationExpiry(for: previousPackage)
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
            // Revalidate after the async runtime suspension. The Store then
            // repeats this signed lifetime check inside its actor immediately
            // before its durable registry write.
            let catalogExpiresAt = try catalogAuthorizationExpiry(for: previousPackage)
            try await store.updateGrants(
                grants,
                for: extensionID,
                expectedGeneration: authorization.packageGeneration,
                catalogExpiresAt: catalogExpiresAt
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

    /// Keeps the native DNR-exemption mutation on the same lifecycle gate as
    /// disable, uninstall, update, and catalog revocation. The coordinator
    /// performs its own compile/persist transaction; this wrapper prevents a
    /// stale Settings sheet from applying that transaction to a superseded
    /// immutable generation.
    private func updateDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        let gate = lifecycleMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        guard isCurrentComposition(),
              let package = await store.installedPackage(for: extensionID),
              package.isEnabled,
              package.grants.apiPermissions.contains(.declarativeNetRequest),
              isCurrentComposition() else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        do {
            try authorizeCatalogRecord(package)
        } catch {
            // A rejected package may have reached this lifecycle endpoint
            // before startup restoration runs (for example immediately after
            // an app upgrade). Stop its live DNR policy before returning the
            // error, then persist the same fail-closed state as reload.
            try? await reconcile(extensionID, nil, .suspend)
            if isCurrentComposition() {
                await persistCatalogAuthorizationFailureIfNeeded(
                    error,
                    for: package
                )
            }
            throw error
        }
        guard try await dnrExcludedTopLevelDomainsUpdater(extensionID, domains),
              isCurrentComposition(),
              let currentPackage = await store.installedPackage(for: extensionID),
              currentPackage.generation == package.generation,
              currentPackage.isEnabled else {
            throw FloorpWebExtensionPackageStoreError.stalePackageComposition
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
            try authorizeCatalogRecordForOfflineRestore(currentPackage)
            try await reconcile(extensionID, currentPackage, .suspend)
            guard isCurrentComposition(),
                  await store.installedPackage(for: extensionID) == currentPackage else {
                throw FloorpWebExtensionPackageStoreError.stalePackageComposition
            }
            return true
        } catch {
            if isCurrentComposition() {
                await persistCatalogAuthorizationFailureIfNeeded(
                    error,
                    for: currentPackage
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
        do {
            try authorizeCatalogRecord(package)
        } catch {
            // A reload begins while this package is already live. Unlike
            // startup restoration, an authorization failure must first stop
            // that live policy before persisting the fail-closed state.
            try await reconcile(extensionID, nil, .suspend)
            if isCurrentComposition() {
                await persistCatalogAuthorizationFailureIfNeeded(
                    error,
                    for: package
                )
            }
            throw error
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

    private func authorizeCatalogRecord(
        _ package: FloorpWebExtensionInstalledPackage
    ) throws {
        try authorizeCatalogRecord(package, with: catalogRecordAuthorization)
    }

    private func authorizeCatalogRecordForOfflineRestore(
        _ package: FloorpWebExtensionInstalledPackage
    ) throws {
        try authorizeCatalogRecord(package, with: catalogRecordRestoreAuthorization)
    }

    /// Normal catalog mutations need more than a successful pre-await
    /// authorization: they also carry the verified expiry to the package
    /// store, which rechecks it at the durable commit boundary. Unsigned
    /// fixtures may reach this only under the explicit test-only policy and
    /// have no catalog lifetime to enforce.
    private func catalogAuthorizationExpiry(
        for package: FloorpWebExtensionInstalledPackage
    ) throws -> Date? {
        guard let record = package.catalogRecord else {
            guard unsignedPackageActivationPolicy == .allowVerifiedFixtureForTesting,
                  package.fixture != nil else {
                throw FloorpWebExtensionCatalogError.unsignedPackageRejected
            }
            return nil
        }
        guard !package.isCatalogRevoked else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        try catalogRecordAuthorization(record)
        return try catalogRecordExpirationProvider(record)
    }

    private func authorizeCatalogRecord(
        _ package: FloorpWebExtensionInstalledPackage,
        with authorization: CatalogRecordAuthorization
    ) throws {
        guard let record = package.catalogRecord else {
            guard unsignedPackageActivationPolicy == .allowVerifiedFixtureForTesting,
                  package.fixture != nil else {
                throw FloorpWebExtensionCatalogError.unsignedPackageRejected
            }
            return
        }
        guard !package.isCatalogRevoked else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        try authorization(record)
    }

    /// A restart can observe a package that was persisted before a process
    /// interruption but whose latest device-wide catalog state now revokes it.
    /// Preserve that as a durable kill-switch state, not merely a retryable
    /// activation error. Other startup failures retain the normal diagnostic
    /// path and remain disabled until an explicit retry.
    private func persistCatalogAuthorizationFailureIfNeeded(
        _ error: Error,
        for package: FloorpWebExtensionInstalledPackage
    ) async {
        guard case .revoked = error as? FloorpWebExtensionCatalogError,
              let catalogGeneration = package.catalogRecord?.generation else {
            try? await store.recordActivationFailure(
                for: package.extensionID,
                expectedGeneration: package.generation
            )
            return
        }
        try? await store.recordCatalogRevocation(
            for: package.extensionID,
            catalogGeneration: catalogGeneration
        )
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
        if grants.apiPermissions.contains(.alarms) {
            categories.append(.alarms)
        }
        if grants.apiPermissions.contains(.fontSettings) {
            categories.append(.fontSettings)
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

    private static func settingsDNRStatus(
        for package: FloorpWebExtensionInstalledPackage
    ) -> FloorpWebExtensionSettingsDNRStatus? {
        let declaredResources = package.preflight.manifest.dnrRuleResources
        guard !declaredResources.isEmpty || package.dnrConfiguration != nil else {
            return nil
        }
        let configuration = package.dnrConfiguration
        return .init(
            enabledStaticRuleSetIDs: (configuration?.enabledStaticRuleSetIDs
                ?? Set(declaredResources.filter { $0.enabled }.map(\.identifier))
            ).sorted(),
            policyGeneration: configuration?.policyGeneration ?? 1,
            excludedTopLevelDomains: configuration?.excludedTopLevelDomains ?? []
        )
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
