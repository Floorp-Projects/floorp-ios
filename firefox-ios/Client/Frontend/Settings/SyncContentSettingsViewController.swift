// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import Sync
import Account

/// The sync manager owns persistence for this kill switch so it can publish
/// OFF only after the in-flight component barrier has completed.
final class FloorpNotesRuntimeSetting: BoolSetting {
    override func writeBool(_ control: UISwitch) {}
}

final class ManageFxAccountSetting: Setting {
    private var notification: NSObjectProtocol?

    let profile: Profile?

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "Manage" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile

        let theme = settings.themeManager.getCurrentTheme(for: settings.windowUUID)
        super.init(
            title: NSAttributedString(
                string: .FxAManageAccount,
                attributes: [
                    NSAttributedString.Key.foregroundColor: theme.colors.textPrimary
                ]
            )
        )

        notification = NotificationCenter.default.addObserver(
            forName: .accountLoggedOut,
            object: nil,
            queue: .main
        ) { _ in
            ensureMainThread { [weak settings] in
                settings?.dismiss(animated: true, completion: nil)
            }
        }
    }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let profile else { return }
        let fxaParams = FxALaunchParams(entrypoint: .manageFxASetting, query: [:])
        let viewController = FxAWebViewController(pageType: .settingsPage,
                                                  profile: profile,
                                                  dismissalStyle: .popToRootVC,
                                                  deepLinkParams: fxaParams)
        navigationController?.pushViewController(viewController, animated: true)
    }

    deinit {
        // TODO: FXIOS-13097 This is a work around until we can leverage isolated deinits
        guard Thread.isMainThread else {
            assertionFailure("ManageFxAccountSetting was not deallocated on the main thread. Observer was not removed")
            return
        }

        MainActor.assumeIsolated {
            if let notification = notification {
                NotificationCenter.default.removeObserver(notification)
            }
        }
    }
}

class DisconnectSetting: Setting {
    let settingsVC: SettingsTableViewController
    let profile: Profile?
    override var accessoryType: UITableViewCell.AccessoryType { return .none }

    init(settings: SettingsTableViewController) {
        self.settingsVC = settings
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: .SettingsDisconnectSyncButton))
    }

    override var accessibilityIdentifier: String? { return "SignOut" }

    override func onClick(_ navigationController: UINavigationController?) {
        let alertController = UIAlertController(
            title: .SettingsDisconnectSyncAlertTitle,
            message: .SettingsDisconnectSyncAlertBody,
            preferredStyle: UIAlertController.Style.alert)

        alertController.addAction(
            UIAlertAction(title: .SettingsDisconnectCancelAction, style: .default) { _ in
                // Do nothing.
            }
        )

        alertController.addAction(
            UIAlertAction(title: .SettingsDisconnectDestructiveAction, style: .destructive) { _ in
                guard let profile = self.profile else { return }
                let completion: @MainActor @Sendable (Bool) -> Void = { [weak self, weak navigationController] didRemove in
                    guard let self else { return }
                    guard didRemove else {
                        let error = UIAlertController(
                            title: FloorpStrings.Notes.syncDisconnectFailedTitle,
                            message: FloorpStrings.Notes.syncDisconnectFailedMessage,
                            preferredStyle: .alert
                        )
                        error.addAction(UIAlertAction(title: .OKString, style: .default))
                        navigationController?.present(error, animated: true)
                        return
                    }
                    TelemetryWrapper.recordEvent(
                        category: .firefoxAccount,
                        method: .tap,
                        object: .syncUserLoggedOut
                    )

                    // If there is more than one view controller in the navigation controller, we can pop.
                    // Otherwise, assume that we got here directly from the App Menu and dismiss the VC.
                    if let navigationController,
                       navigationController.viewControllers.count > 1 {
                        _ = navigationController.popViewController(animated: true)
                    } else {
                        self.settingsVC.dismiss(animated: true, completion: nil)
                    }
                }
                profile.removeAccount().upon { result in
                    let didRemove = result.isSuccess
                    Task { @MainActor in
                        completion(didRemove)
                    }
                }
            }
        )

        navigationController?.present(alertController, animated: true, completion: nil)
    }
}

class DeviceNamePersister: SettingValuePersister {
    func readPersistedValue() -> String? {
        guard let val = RustFirefoxAccounts.shared.accountManager?.deviceConstellation()?
            .state()?.localDevice?.displayName else {
                return UserDefaults.standard.string(forKey: RustFirefoxAccounts.prefKeyLastDeviceName)
        }
        UserDefaults.standard.set(val, forKey: RustFirefoxAccounts.prefKeyLastDeviceName)
        return val
    }

    func writePersistedValue(value: String?) {
        guard let newName = value,
            let deviceConstellation = RustFirefoxAccounts.shared.accountManager?.deviceConstellation() else {
            return
        }
        UserDefaults.standard.set(newName, forKey: RustFirefoxAccounts.prefKeyLastDeviceName)

        deviceConstellation.setLocalDeviceName(name: newName)
    }
}

class DeviceNameSetting: StringSetting {
    weak var tableView: UITableViewController?

    private var notification: NSObjectProtocol?

    init(settings: SettingsTableViewController) {
        tableView = settings
        let settingsIsValid: (String?) -> Bool = { !($0?.isEmpty ?? true) }
        super.init(
            defaultValue: DeviceInfo.defaultClientName(),
            placeholder: "",
            accessibilityIdentifier: "DeviceNameSetting",
            persister: DeviceNamePersister(),
            settingIsValid: settingsIsValid
        )

        notification = NotificationCenter.default.addObserver(
            forName: Notification.Name.constellationStateUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard Thread.isMainThread else {
                assertionFailure("This must be called main thread")
                return
            }

            // We have set the queue to `.main` on the observer, so theoretically this is safe to call here
            MainActor.assumeIsolated {
                self?.tableView?.tableView.reloadData()
            }
        }
    }

    override func onConfigureCell(_ cell: UITableViewCell, theme: Theme) {
        super.onConfigureCell(cell, theme: theme)
        alignTextFieldToNatural()
    }

    deinit {
        // TODO: FXIOS-13097 This is a work around until we can leverage isolated deinits
        guard Thread.isMainThread else {
            assertionFailure("DeviceNameSetting was not deallocated on the main thread. Observer was not removed")
            return
        }

        MainActor.assumeIsolated {
            if let notification = notification {
                NotificationCenter.default.removeObserver(notification)
            }
        }
    }
}

class SyncContentSettingsViewController: SettingsTableViewController {
    fileprivate var enginesToSyncOnExit: Set<String> = Set()
    private let notesSyncAvailable: () -> Bool

    init(
        windowUUID: WindowUUID,
        notesSyncAvailable: @escaping () -> Bool = {
            FloorpNotesSyncReleaseGate.isNetworkSyncEnabled
        }
    ) {
        self.notesSyncAvailable = notesSyncAvailable
        super.init(style: .grouped, windowUUID: windowUUID)

        self.title = .FxASettingsTitle

        RustFirefoxAccounts.shared.accountManager?.deviceConstellation()?.refreshState()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.profile?.syncManager?.reportOpenSyncSettingsMenuTelemetry()
    }

    override func viewWillDisappear(_ animated: Bool) {
        if !enginesToSyncOnExit.isEmpty {
            self.profile?.syncManager?.syncPostSyncSettingsChange(
                why: .enabledChange,
                names: Array(enginesToSyncOnExit)
            )
            enginesToSyncOnExit.removeAll()
        }
        super.viewWillDisappear(animated)
    }

    func engineSettingChanged(_ engineName: RustSyncManagerAPI.TogglableEngine) -> (Bool) -> Void {
        let prefName = "sync.engine.\(engineName.rawValue).enabledStateChanged"
        return { [unowned self] enabled in
            if engineName == .creditcards {
                self.creditCardSyncEnabledTelemetry(status: enabled)
            } else if engineName == .passwords {
                self.loginsSyncEnabledTelemetry(status: enabled)
            }

            if self.profile?.prefs.boolForKey(prefName) != nil { // Switch it back to not-changed
                self.profile?.prefs.removeObjectForKey(prefName)
                self.enginesToSyncOnExit.remove(engineName.rawValue)
            } else {
                self.profile?.prefs.setBool(true, forKey: prefName)
                self.enginesToSyncOnExit.insert(engineName.rawValue)
            }
        }
    }

    private func creditCardSyncEnabledTelemetry(status: Bool) {
        TelemetryWrapper.recordEvent(
            category: .action,
            method: .tap,
            object: .creditCardSyncToggle,
            extras: [
                TelemetryWrapper.ExtraKey.isCreditCardSyncToggleEnabled.rawValue: status
            ]
        )
    }

    private func loginsSyncEnabledTelemetry(status: Bool) {
        TelemetryWrapper.recordEvent(
            category: .action,
            method: .tap,
            object: .loginsSyncEnabled,
            extras: [
                TelemetryWrapper.ExtraKey.isLoginSyncEnabled.rawValue: status
            ]
        )
    }

    override func generateSettings() -> [SettingSection] {
        let manage = ManageFxAccountSetting(settings: self)
        let manageSection = SettingSection(title: nil, footerTitle: nil, children: [manage])
        guard let profile else { return [manageSection] }

        let bookmarks = BoolSetting(
            prefs: profile.prefs,
            prefKey: "sync.engine.bookmarks.enabled",
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncBookmarksEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.bookmarks))
        let history = BoolSetting(
            prefs: profile.prefs,
            prefKey: "sync.engine.history.enabled",
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncHistoryEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.history))
        let tabs = BoolSetting(
            prefs: profile.prefs,
            prefKey: PrefsKeys.TabSyncEnabled,
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncTabsEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.tabs))
        let passwords = BoolSetting(
            prefs: profile.prefs,
            prefKey: "sync.engine.passwords.enabled",
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncLoginsEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.passwords))

        let creditCards = BoolSetting(
            prefs: profile.prefs,
            prefKey: "sync.engine.creditcards.enabled",
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncCreditCardsEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.creditcards))

        let addresses = BoolSetting(
            prefs: profile.prefs,
            prefKey: "sync.engine.addresses.enabled",
            defaultValue: true,
            attributedTitleText: NSAttributedString(string: .FirefoxSyncAddressesEngine),
            attributedStatusText: nil,
            settingDidChange: engineSettingChanged(.addresses))

        let notes = FloorpNotesRuntimeSetting(
            prefs: profile.prefs,
            prefKey: RustSyncManager.floorpNotesRuntimeEnabledPref,
            defaultValue: false,
            attributedTitleText: NSAttributedString(
                string: FloorpStrings.Notes.syncSettingTitle
            ),
            attributedStatusText: NSAttributedString(
                string: FloorpStrings.Notes.syncSettingDescription
            ),
            settingDidChange: { [weak self] enabled in
                self?.applyNotesSyncRuntimePolicy(enabled: enabled)
            }
        )

        var engineSectionChildren: [Setting] = [bookmarks, history, tabs, passwords, creditCards]

        if notesSyncAvailable() {
            engineSectionChildren.append(notes)
        }

        if AddressLocaleFeatureValidator.isValidRegion(for: SystemLocaleProvider().regionCode()) {
            engineSectionChildren.append(addresses)
        }

        let enginesSection = SettingSection(
            title: NSAttributedString(string: .FxASettingsSyncSettings),
            footerTitle: nil,
            children: engineSectionChildren)

        let deviceName = DeviceNameSetting(settings: self)
        let deviceNameSection = SettingSection(
            title: NSAttributedString(string: .FxASettingsDeviceName),
            footerTitle: nil,
            children: [deviceName])

        let disconnect = DisconnectSetting(settings: self)
        let disconnectSection = SettingSection(title: nil, footerTitle: nil, children: [disconnect])

        return [manageSection, enginesSection, deviceNameSection, disconnectSection]
    }

    func applyNotesSyncRuntimePolicy(
        enabled: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let profile,
              let syncManager = profile.syncManager as? RustSyncManager else {
            profile?.prefs.setBool(
                false,
                forKey: RustSyncManager.floorpNotesRuntimeEnabledPref
            )
            tableView.reloadData()
            completion?()
            return
        }
        let updateUI: @MainActor @Sendable () -> Void = { [weak self, weak syncManager] in
            defer { completion?() }
            guard let self, let syncManager else { return }
            let isEffectivelyEnabled = self.profile?.prefs.boolForKey(
                RustSyncManager.floorpNotesRuntimeEnabledPref
            ) == true
            if enabled && isEffectivelyEnabled {
                _ = syncManager.syncNamedCollections(
                    why: .enabledChange,
                    names: [FloorpNotesSyncEngineSelection.engineName]
                )
            }
            self.tableView.reloadData()
        }
        syncManager.applyFloorpNotesRuntimePolicy(enabled: enabled) {
            Task { @MainActor in
                updateUI()
            }
        }
    }
}
