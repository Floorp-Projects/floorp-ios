// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Account
import Shared
import Storage
import Sync
import AuthenticationServices
import Common

import enum MozillaAppServices.OAuthScope
import enum MozillaAppServices.ServiceStatus
import enum MozillaAppServices.SyncEngineSelection
import enum MozillaAppServices.SyncReason
import struct MozillaAppServices.DeviceSettings
import struct MozillaAppServices.SyncAuthInfo
import struct MozillaAppServices.SyncParams
import struct MozillaAppServices.SyncResult
import struct MozillaAppServices.Device
import struct MozillaAppServices.ScopedKey
import struct MozillaAppServices.AccessTokenInfo
import class MozillaAppServices.FxAccountManager
import struct MozillaAppServices.DeviceConfig

public enum FloorpNotesSyncAccountAvailability: Equatable, Sendable {
    case available
    case accountMismatch
}

public protocol FloorpNotesSyncEngineProviding: AnyObject, Sendable {
    func resumePendingDisconnectCleanup() throws
    func allowsSync(accountID: String) -> Bool
    func register(accountID: String) throws
    func prepareForDisconnect(
        accountID: String?
    ) throws -> FloorpNotesSyncAccountAvailability
    func finalizeDisconnect() throws
    @discardableResult func cancelDisconnect() -> Bool
    func invalidate()
}

struct FloorpNotesSyncRequestPolicy: Equatable, Sendable {
    let compiledEvidenceAllows: Bool
    let runtimeKillSwitchAllows: Bool
    let productionEndpointAllows: Bool
    let accountAvailability: FloorpNotesSyncAccountAvailability

    var allowsRequest: Bool {
        compiledEvidenceAllows
            && runtimeKillSwitchAllows
            && productionEndpointAllows
            && accountAvailability == .available
    }
}

struct FloorpNotesSyncEndpointSettings: Equatable, Sendable {
    let usesStage: Bool
    let usesChina: Bool
    let usesCustomFxAContent: Bool
    let usesCustomTokenServer: Bool
}

enum FloorpNotesSyncEndpointAuthority {
    static func allowsProduction(_ settings: FloorpNotesSyncEndpointSettings) -> Bool {
        !settings.usesStage
            && !settings.usesChina
            && !settings.usesCustomFxAContent
            && !settings.usesCustomTokenServer
    }

    static func allowsProductionTokenServer(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "token.services.mozilla.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.percentEncodedPath == "/1.0/sync/1.5"
            && components.percentEncodedQuery == nil
            && components.fragment == nil
    }
}

enum FloorpNotesSyncRetryPolicy {
    static let baseDelay: TimeInterval = 180
    static let maximumDelay: TimeInterval = 3_600

    static func delay(
        status: ServiceStatus,
        nextSyncAllowedAt: Date?,
        now: Date,
        attempt: Int
    ) -> TimeInterval? {
        if status == .ok || status == .authError {
            return nil
        }
        if let nextSyncAllowedAt, nextSyncAllowedAt > now {
            return nextSyncAllowedAt.timeIntervalSince(now)
        }
        guard [.backedOff, .networkError, .serviceError, .otherError].contains(status) else {
            return nil
        }
        let exponent = min(max(attempt, 0), 5)
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

enum FloorpNotesSyncEngineSelection {
    static let engineName = "prefs"

    struct Partition: Equatable, Sendable {
        let togglable: [RustSyncManagerAPI.TogglableEngine]
        let requestsFloorpPrefs: Bool
    }

    static func partition(requested: [String]) -> Partition {
        var seen = Set<String>()
        var togglable = [RustSyncManagerAPI.TogglableEngine]()
        var requestsFloorpPrefs = false
        for name in requested where seen.insert(name).inserted {
            if name == engineName {
                requestsFloorpPrefs = true
            } else if let engine = RustSyncManagerAPI.TogglableEngine(rawValue: name) {
                togglable.append(engine)
            }
        }
        return Partition(
            togglable: togglable,
            requestsFloorpPrefs: requestsFloorpPrefs
        )
    }

    static func syncEverythingEngines(policy: FloorpNotesSyncRequestPolicy) -> [String] {
        var engines = RustSyncManagerAPI.TogglableEngine.allCases.map(\.rawValue)
        if policy.allowsRequest {
            engines.append(engineName)
        }
        return engines
    }
}

final class FloorpNotesSyncExecutionContext: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGeneration: UInt64?
    private var storedRequestSequence: UInt64?

    var generation: UInt64? {
        lock.withLock { storedGeneration }
    }

    var requestSequence: UInt64? {
        lock.withLock { storedRequestSequence }
    }

    func record(generation: UInt64, requestSequence: UInt64) {
        lock.withLock {
            storedGeneration = generation
            storedRequestSequence = requestSequence
        }
    }
}

private enum FloorpNotesDisconnectPhase {
    case idle
    case preparing(provider: (any FloorpNotesSyncEngineProviding)?)
    case preparedAwaitingDisconnect(
        provider: (any FloorpNotesSyncEngineProviding)?,
        finalizeNotes: Bool
    )
    case prepared(
        provider: (any FloorpNotesSyncEngineProviding)?,
        finalizeNotes: Bool
    )
    case resolving
}

// Extends NSObject so we can use timers.
// TODO: FXIOS-14225 - RustSyncManager shouldn't be @unchecked Sendable
public class RustSyncManager: NSObject, SyncManager, @unchecked Sendable {
    // We shouldn't live beyond our containing BrowserProfile, either in the main app
    // or in an extension.
    // But it's possible that we'll finish a side-effect sync after we've ditched the
    // profile as a whole, so we hold on to our Prefs, potentially for a little while
    // longer. This is safe as a strong reference, because there's no cycle.
    private weak var profile: BrowserProfile?
    private let logins: SyncLoginProvider
    private let autofill: SyncAutofillProvider
    private let places: SyncPlacesProvider
    private let tabs: SyncTabsProvider
    private let prefs: Prefs
    private var syncTimer: Timer?
    private var backgrounded = true
    private let logger: Logger
    private let fxaDeclinedEngines = "fxa.cwts.declinedSyncEngines"
    private var notificationCenter: NotificationProtocol
    private var syncBackOffTimer: Timer?
    private let syncBackOffDelay = 180.0 // 3 Minutes
    private var floorpNotesEngineProvider: (any FloorpNotesSyncEngineProviding)?
    private var floorpNotesAccountID: String?
    private let floorpNotesStateLock = NSRecursiveLock()
    private let floorpNotesRetryLock = NSLock()
    private let floorpNotesRetryScheduler: @Sendable (
        TimeInterval,
        DispatchWorkItem
    ) -> Void
    private let syncableAccountOverride: (@Sendable () -> Bool)?
    private let delayedSyncScheduler: (@Sendable (
        Int64,
        @escaping @Sendable () -> Void
    ) -> Void)?
    private let syncRequestObserver: @Sendable (SyncReason, [String]) -> Void
    private let timedSyncResumeScheduler: @Sendable (
        @escaping @Sendable () -> Void
    ) -> Void
    private var floorpNotesRetryWorkItem: DispatchWorkItem?
    private var floorpNotesRetryAttempt = 0
    private var floorpNotesRetryGeneration: UInt64 = 0
    private var floorpNotesLatestResultSequence: UInt64 = 0
    private let syncLifecycleLock = NSLock()
    private var syncLifecycleGeneration: UInt64 = 0
    private var floorpNotesLifecycleGeneration: UInt64 = 0
    private var floorpNotesRequestSequence: UInt64 = 0
    private var floorpNotesPolicyMutationSequence: UInt64 = 0
    private var floorpNotesProviderInstallLease: UInt64 = 0
    private var accountRemovalInProgress = false
    private var floorpNotesDisconnectPhase = FloorpNotesDisconnectPhase.idle
    private var floorpNotesCompiledEvidenceAllows = false

    static let floorpNotesRuntimeEnabledPref = "floorp.notes.sync.runtime-enabled"
    // The first enabled FloorpRelease build must not inherit the false value
    // written by older builds whose compiled policy deliberately disabled
    // Notes Sync. Once this version is recorded, the user's toggle is kept.
    static let floorpNotesRuntimePolicyVersionPref =
        "floorp.notes.sync.runtime-policy-version"
    static let floorpNotesRuntimePolicyVersion: Int32 = 1

    let fifteenMinutesInterval = TimeInterval(60 * 15)

    public var lastSyncFinishTime: Timestamp? {
        get {
            return prefs.timestampForKey(PrefsKeys.KeyLastSyncFinishTime)
        }

        set(value) {
            if let value = value {
                prefs.setTimestamp(value,
                                   forKey: PrefsKeys.KeyLastSyncFinishTime)
            } else {
                prefs.removeObjectForKey(PrefsKeys.KeyLastSyncFinishTime)
            }
        }
    }

    lazy var syncManagerAPI = RustSyncManagerAPI(logger: logger, dispatchQueue: DispatchQueue.global())

    public var isSyncing: Bool {
        return syncDisplayState != nil && syncDisplayState! == .inProgress
    }

    var hasActiveSyncTimer: Bool { syncTimer != nil }

    public var syncDisplayState: SyncDisplayState?

    var prefsForSync: Prefs {
        return prefs.branch("sync")
    }

    init(profile: BrowserProfile,
         creditCardAutofillEnabled: Bool = false,
         logger: Logger = DefaultLogger.shared,
         logins: SyncLoginProvider? = nil,
         autofill: SyncAutofillProvider? = nil,
         places: SyncPlacesProvider? = nil,
         tabs: SyncTabsProvider? = nil,
         notificationCenter: NotificationProtocol = NotificationCenter.default,
         floorpNotesRetryScheduler: @escaping @Sendable (
            TimeInterval,
            DispatchWorkItem
         ) -> Void = { delay, workItem in
             DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delay,
                execute: workItem
             )
         },
         syncableAccountOverride: (@Sendable () -> Bool)? = nil,
         delayedSyncScheduler: (@Sendable (
            Int64,
            @escaping @Sendable () -> Void
         ) -> Void)? = nil,
         syncRequestObserver: @escaping @Sendable (SyncReason, [String]) -> Void = { _, _ in },
         timedSyncResumeScheduler: @escaping @Sendable (
            @escaping @Sendable () -> Void
         ) -> Void = { work in
            DispatchQueue.main.async(execute: work)
         }) {
        self.profile = profile
        self.prefs = profile.prefs
        self.logger = logger
        self.notificationCenter = notificationCenter
        self.logins = logins ?? profile.logins
        self.autofill = autofill ?? profile.autofill
        self.places = places ?? profile.places
        self.tabs = tabs ?? profile.tabs
        self.floorpNotesRetryScheduler = floorpNotesRetryScheduler
        self.syncableAccountOverride = syncableAccountOverride
        self.delayedSyncScheduler = delayedSyncScheduler
        self.syncRequestObserver = syncRequestObserver
        self.timedSyncResumeScheduler = timedSyncResumeScheduler

        super.init()
    }

    @objc
    func syncOnTimer() {
        guard activeSyncLifecycleGeneration() != nil else { return }
        syncEverything(why: .scheduled)
        profile?.pollCommands()
    }

    private func repeatingTimerAtInterval(
        _ interval: TimeInterval,
        selector: Selector
    ) -> Timer {
        return Timer.scheduledTimer(timeInterval: interval,
                                    target: self,
                                    selector: selector,
                                    userInfo: nil,
                                    repeats: true)
    }

    func syncEverythingSoon() {
        guard let generation = activeSyncLifecycleGeneration() else { return }
        doInBackgroundAfter(SyncConstants.SyncOnForegroundAfterMillis) {
            guard self.isCurrentSyncLifecycleGeneration(generation) else { return }
            self.logger.log("Running delayed startup sync.",
                            level: .debug,
                            category: .sync)
            self.syncEverything(why: .startup)
        }
    }

    private func beginTimedSyncs() {
        if syncTimer != nil {
            logger.log("Already running sync timer.",
                       level: .debug,
                       category: .sync)
            return
        }

        let interval = fifteenMinutesInterval
        let selector = #selector(syncOnTimer)
        logger.log("Starting sync timer.",
                   level: .info,
                   category: .sync)
        syncTimer = repeatingTimerAtInterval(interval, selector: selector)
    }

    /**
     * The caller is responsible for calling this on the same thread on which it called
     * beginTimedSyncs.
     */
    public func endTimedSyncs() {
        if let timer = syncTimer {
            logger.log("Stopping sync timer.",
                       level: .info,
                       category: .sync)
            syncTimer = nil
            timer.invalidate()
        }
    }

    public func applicationDidBecomeActive() {
        backgrounded = false
        setPreferenceForSignIn()
        guard activeSyncLifecycleGeneration() != nil else { return }
        guard profileHasSyncableAccount() else { return }
        beginTimedSyncs()

        // Sync now if it's been more than our threshold.
        let now = Date.now()
        let then = lastSyncFinishTime ?? 0
        guard now >= then else {
            logger.log("Time was modified since last sync.",
                       level: .debug,
                       category: .sync)
            syncEverythingSoon()
            return
        }
        let since = now - then
        logger.log("\(since)msec since last sync.",
                   level: .debug,
                   category: .sync)
        if since > SyncConstants.SyncOnForegroundMinimumDelayMillis {
            syncEverythingSoon()
        }
    }

    public func applicationDidEnterBackground() {
        backgrounded = true
    }

    private func setPreferenceForSignIn() {
        let signedInFxaAccountValue = profile?.prefs.boolForKey(PrefsKeys.Sync.signedInFxaAccount)
        // We only want to set the prefs if it has not been set (nil)
        // There is a case where a user has a syncable account, but returns
        // false so we check if nil here.
        guard signedInFxaAccountValue == nil else { return }
        let userHasSyncableAccount = profileHasSyncableAccount()
        profile?.prefs.setBool(userHasSyncableAccount, forKey: PrefsKeys.Sync.signedInFxaAccount)
    }

    private func profileHasSyncableAccount() -> Bool {
        syncableAccountOverride?() ?? profile?.hasSyncableAccount() ?? false
    }

    private func resetUserSyncPreferences() {
        profile?.prefs.setBool(false, forKey: PrefsKeys.Sync.signedInFxaAccount)
        profile?.prefs.setInt(0, forKey: PrefsKeys.Sync.numberOfSyncedDevices)
    }

    private func floorpNotesPolicy(accountID: String) -> FloorpNotesSyncRequestPolicy {
        floorpNotesStateLock.withLock {
            let providerAllows = floorpNotesEngineProvider?.allowsSync(accountID: accountID) ?? false
            let compiledEvidenceAllows = syncLifecycleLock.withLock {
                floorpNotesCompiledEvidenceAllows
            }
            let runtimeAllows = prefs.boolForKey(Self.floorpNotesRuntimeEnabledPref) ?? false
            let productionEndpointAllows = FloorpNotesSyncEndpointAuthority.allowsProduction(
                FloorpNotesSyncEndpointSettings(
                    usesStage: prefs.intForKey(PrefsKeys.UseStageServer) == 1,
                    usesChina: prefs.boolForKey(PrefsKeys.KeyEnableChinaSyncService)
                        ?? AppInfo.isChinaEdition,
                    usesCustomFxAContent: prefs.boolForKey(
                        PrefsKeys.KeyUseCustomFxAContentServer
                    ) ?? false,
                    usesCustomTokenServer: prefs.boolForKey(
                        PrefsKeys.KeyUseCustomSyncTokenServerOverride
                    ) ?? false
                )
            )
            return FloorpNotesSyncRequestPolicy(
                compiledEvidenceAllows: compiledEvidenceAllows && providerAllows,
                runtimeKillSwitchAllows: runtimeAllows,
                productionEndpointAllows: productionEndpointAllows,
                accountAvailability: providerAllows ? .available : .accountMismatch
            )
        }
    }

    func disableFloorpNotesEngine() {
        floorpNotesStateLock.withLock {
            disableFloorpNotesEngineLocked()
        }
    }

    private func disableFloorpNotesEngineLocked() {
        let provider = floorpNotesEngineProvider
        let providerInstallLease = floorpNotesProviderInstallLease
        let generation = advanceFloorpNotesLifecycleLocked()
        floorpNotesAccountID = nil
        let shouldDeferInvalidation = syncLifecycleLock.withLock {
            accountRemovalInProgress
        }
        guard !shouldDeferInvalidation, let provider else { return }
        scheduleFloorpNotesProviderInvalidation(
            provider: provider,
            generation: generation,
            providerInstallLease: providerInstallLease
        )
    }

    @discardableResult
    private func advanceFloorpNotesLifecycleLocked() -> UInt64 {
        syncLifecycleLock.lock()
        floorpNotesRetryLock.lock()
        defer {
            floorpNotesRetryLock.unlock()
            syncLifecycleLock.unlock()
        }
        floorpNotesLifecycleGeneration &+= 1
        floorpNotesRetryWorkItem?.cancel()
        floorpNotesRetryWorkItem = nil
        floorpNotesRetryAttempt = 0
        floorpNotesRetryGeneration = floorpNotesLifecycleGeneration
        floorpNotesLatestResultSequence = 0
        return floorpNotesLifecycleGeneration
    }

    private func disableFloorpNotesEngineAssumingComponentLockLocked() {
        _ = advanceFloorpNotesLifecycleLocked()
        floorpNotesEngineProvider?.invalidate()
        floorpNotesAccountID = nil
    }

    private func scheduleFloorpNotesProviderInvalidation(
        provider: any FloorpNotesSyncEngineProviding,
        generation: UInt64,
        providerInstallLease: UInt64
    ) {
        syncManagerAPI.synchronizeComponentState { [weak self] in
            guard let self else { return }
            self.floorpNotesStateLock.withLock {
                let isCurrentProvider = self.floorpNotesEngineProvider === provider
                if isCurrentProvider {
                    let mayInvalidate = self.syncLifecycleLock.withLock {
                        !self.accountRemovalInProgress
                            && self.floorpNotesLifecycleGeneration == generation
                            && self.floorpNotesProviderInstallLease
                                == providerInstallLease
                    }
                    guard mayInvalidate else { return }
                }
                provider.invalidate()
            }
        }
    }

    @discardableResult
    public func installFloorpNotesSyncEngineProvider(
        _ provider: any FloorpNotesSyncEngineProviding
    ) -> Bool {
        syncManagerAPI.synchronizeComponentStateAndWait { [self] in
            floorpNotesStateLock.withLock {
                guard case .idle = floorpNotesDisconnectPhase else {
                    if floorpNotesEngineProvider !== provider {
                        provider.invalidate()
                    }
                    return false
                }
                do {
                    try provider.resumePendingDisconnectCleanup()
                } catch {
                    if floorpNotesEngineProvider === provider {
                        floorpNotesEngineProvider = nil
                        floorpNotesAccountID = nil
                        _ = advanceFloorpNotesLifecycleLocked()
                    }
                    provider.invalidate()
                    return false
                }
                if floorpNotesEngineProvider === provider {
                    floorpNotesProviderInstallLease &+= 1
                    return true
                }
                floorpNotesEngineProvider?.invalidate()
                _ = advanceFloorpNotesLifecycleLocked()
                floorpNotesAccountID = nil
                floorpNotesEngineProvider = provider
                floorpNotesProviderInstallLease &+= 1
                return true
            }
        }
    }

    func bootstrapFloorpNotesRuntimePolicy(compiledEvidenceAllows: Bool) {
        syncLifecycleLock.withLock {
            floorpNotesCompiledEvidenceAllows = compiledEvidenceAllows
        }
        if compiledEvidenceAllows,
           prefs.intForKey(Self.floorpNotesRuntimePolicyVersionPref)
                != Self.floorpNotesRuntimePolicyVersion {
            prefs.setBool(
                true,
                forKey: Self.floorpNotesRuntimeEnabledPref
            )
            prefs.setInt(
                Self.floorpNotesRuntimePolicyVersion,
                forKey: Self.floorpNotesRuntimePolicyVersionPref
            )
        }
        if prefs.boolForKey(Self.floorpNotesRuntimeEnabledPref) == nil {
            prefs.setBool(
                compiledEvidenceAllows,
                forKey: Self.floorpNotesRuntimeEnabledPref
            )
        }
        if !compiledEvidenceAllows
            || prefs.boolForKey(Self.floorpNotesRuntimeEnabledPref) != true {
            applyFloorpNotesRuntimePolicy(enabled: false)
        }
    }

    func applyFloorpNotesRuntimePolicy(
        enabled: Bool,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let policyMutation = syncLifecycleLock.withLock { () -> (Bool, UInt64) in
            floorpNotesPolicyMutationSequence &+= 1
            return (
                floorpNotesCompiledEvidenceAllows && enabled,
                floorpNotesPolicyMutationSequence
            )
        }
        if policyMutation.0 {
            floorpNotesStateLock.withLock {
                guard syncLifecycleLock.withLock({
                    floorpNotesPolicyMutationSequence == policyMutation.1
                }) else {
                    return
                }
                let wasEnabled = prefs.boolForKey(
                    Self.floorpNotesRuntimeEnabledPref
                ) == true
                prefs.setBool(true, forKey: Self.floorpNotesRuntimeEnabledPref)
                if !wasEnabled {
                    _ = advanceFloorpNotesLifecycleLocked()
                    floorpNotesAccountID = nil
                }
            }
            completion()
            return
        }

        syncManagerAPI.synchronizeComponentState({ [self] in
            floorpNotesStateLock.withLock {
                let isLatestMutation = syncLifecycleLock.withLock {
                    floorpNotesPolicyMutationSequence == policyMutation.1
                }
                if isLatestMutation {
                    prefs.setBool(
                        false,
                        forKey: Self.floorpNotesRuntimeEnabledPref
                    )
                    let removalIsActive = syncLifecycleLock.withLock {
                        accountRemovalInProgress
                    }
                    if removalIsActive {
                        _ = advanceFloorpNotesLifecycleLocked()
                        floorpNotesAccountID = nil
                    } else {
                        disableFloorpNotesEngineAssumingComponentLockLocked()
                    }
                }
            }
        }, completion: completion)
    }

    func handleFloorpNotesSyncResult(
        _ result: SyncResult,
        why: SyncReason,
        floorpNotesGeneration: UInt64,
        requestSequence: UInt64
    ) {
        let lifecycleGeneration = activeSyncLifecycleGeneration()
        let didSucceed = result.successful.contains(FloorpNotesSyncEngineSelection.engineName)
        let status = result.status == .ok ? ServiceStatus.otherError : result.status
        let workItem = lifecycleGeneration.map {
            makeFloorpNotesRetryWorkItem(
                why: why,
                lifecycleGeneration: $0,
                floorpNotesGeneration: floorpNotesGeneration
            )
        }
        let scheduledRetry = floorpNotesRetryLock.withLock {
            () -> (TimeInterval, DispatchWorkItem)? in
            guard floorpNotesRetryGeneration == floorpNotesGeneration,
                  requestSequence > floorpNotesLatestResultSequence else {
                return nil
            }
            floorpNotesLatestResultSequence = requestSequence
            guard !didSucceed,
                  let workItem,
                  let delay = FloorpNotesSyncRetryPolicy.delay(
                    status: status,
                    nextSyncAllowedAt: result.nextSyncAllowedAt,
                    now: Date(),
                    attempt: floorpNotesRetryAttempt
                  ) else {
                clearFloorpNotesRetryLocked()
                return nil
            }
            floorpNotesRetryWorkItem?.cancel()
            floorpNotesRetryWorkItem = workItem
            floorpNotesRetryAttempt += 1
            return (delay, workItem)
        }
        guard let scheduledRetry else { return }
        floorpNotesRetryScheduler(scheduledRetry.0, scheduledRetry.1)
    }

    private func makeFloorpNotesRetryWorkItem(
        why: SyncReason,
        lifecycleGeneration: UInt64,
        floorpNotesGeneration: UInt64
    ) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self,
                  self.isCurrentSyncLifecycleGeneration(lifecycleGeneration),
                  self.isCurrentFloorpNotesLifecycleGeneration(
                    floorpNotesGeneration
                  ) else {
                return
            }
            guard let accountID = self.floorpNotesStateLock.withLock({
                self.floorpNotesAccountID
            }), self.floorpNotesPolicy(accountID: accountID).allowsRequest else {
                self.disableFloorpNotesEngine()
                return
            }
            _ = self.syncNamedCollections(
                why: why,
                names: [FloorpNotesSyncEngineSelection.engineName],
                expectedFloorpNotesGeneration: floorpNotesGeneration
            )
        }
    }

    private func clearFloorpNotesRetryLocked() {
        floorpNotesRetryWorkItem?.cancel()
        floorpNotesRetryWorkItem = nil
        floorpNotesRetryAttempt = 0
    }

    func activeSyncLifecycleGeneration() -> UInt64? {
        syncLifecycleLock.withLock {
            accountRemovalInProgress ? nil : syncLifecycleGeneration
        }
    }

    private func isCurrentSyncLifecycleGeneration(_ generation: UInt64) -> Bool {
        syncLifecycleLock.withLock {
            !accountRemovalInProgress && syncLifecycleGeneration == generation
        }
    }

    func currentFloorpNotesLifecycleGeneration() -> UInt64 {
        syncLifecycleLock.withLock { floorpNotesLifecycleGeneration }
    }

    private func isCurrentFloorpNotesLifecycleGeneration(
        _ generation: UInt64
    ) -> Bool {
        syncLifecycleLock.withLock {
            floorpNotesLifecycleGeneration == generation
        }
    }

    @discardableResult
    private func beginAccountRemoval() -> UInt64 {
        syncLifecycleLock.withLock {
            accountRemovalInProgress = true
            syncLifecycleGeneration &+= 1
            return syncLifecycleGeneration
        }
    }

    private func beginSyncing() {
        syncDisplayState = .inProgress
        notifySyncing(notification: .ProfileDidStartSyncing)
        AppEventQueue.started(.profileSyncing)
    }

    private func resolveSyncState(result: SyncResult) -> SyncDisplayState {
        let hasSynced = !result.successful.isEmpty
        let status = result.status

        // This is similar to the old `SyncStatusResolver.resolveResults` call. If none of
        // the engines successfully synced and a network issue occurred we return `.bad`.
        // If none of the engines successfully synced and an auth error occurred we return
        // `.warning`. Otherwise we return `.good`.

        if !hasSynced && status == .authError {
            return .warning(message: .FirefoxSyncOfflineTitle)
        } else if !hasSynced && status == .networkError {
            return .bad(message: .FirefoxSyncOfflineTitle)
        } else {
            return .good
        }
    }

    private func endSyncing(_ result: SyncResult) {
        logger.log("Ending all syncs.",
                   level: .info,
                   category: .sync)

        syncDisplayState = resolveSyncState(result: result)

        if let syncState = syncDisplayState, syncState == .good {
            lastSyncFinishTime = Date.now()
        }

        if canSendUsageData() {
            self.syncManagerAPI.reportSyncTelemetry(syncResult: result) { _ in }
        } else {
            logger.log("Profile isn't sending usage data. Not sending sync status event.",
                       level: .debug,
                       category: .sync)
        }

        // Don't notify if we are performing a sync in the background. This prevents more
        // db access from happening
        if !backgrounded {
            notifySyncing(notification: .ProfileDidFinishSyncing)
            AppEventQueue.completed(.profileSyncing)
        }
    }

    func canSendUsageData() -> Bool {
        return profile?.prefs.boolForKey(AppConstants.prefSendUsageData) ?? true
    }

    private func notifySyncing(notification: Notification.Name) {
        notificationCenter.post(name: notification)
    }

    func doInBackgroundAfter(_ millis: Int64, _ block: @Sendable @escaping () -> Void) {
        if let delayedSyncScheduler {
            delayedSyncScheduler(millis, block)
            return
        }
        let queue = DispatchQueue.global(qos: DispatchQoS.background.qosClass)
        queue.asyncAfter(
            deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(millis)),
            execute: block)
    }

    public func onAddedAccount() -> Success {
        // Only sync if we're green lit. This makes sure that we don't sync unverified
        // accounts.
        guard profileHasSyncableAccount() else { return succeed() }
        setPreferenceForSignIn()
        beginTimedSyncs()
        return syncEverything(why: .enabledChange)
    }

    public func onRemovedAccount() -> Success {
        let removal = Success()
        let didBeginRemoval = floorpNotesStateLock.withLock { () -> Bool in
            guard case .idle = floorpNotesDisconnectPhase else { return false }
            beginAccountRemoval()
            floorpNotesDisconnectPhase = .preparing(
                provider: floorpNotesEngineProvider
            )
            _ = advanceFloorpNotesLifecycleLocked()
            floorpNotesAccountID = nil
            return true
        }
        guard didBeginRemoval else {
            removal.fill(Maybe(failure: AccountRemovalError()))
            return removal
        }
        endTimedSyncs()
        syncBackOffTimer?.invalidate()
        syncBackOffTimer = nil

        let accountID = RustFirefoxAccounts.shared.accountManager?.accountProfile()?.uid
            ?? RustFirefoxAccounts.shared.userProfile?.uid
        syncManagerAPI.disconnectChecked(prepare: { [self] in
            do {
                try floorpNotesStateLock.withLock {
                    guard case .preparing(let provider) =
                            floorpNotesDisconnectPhase else {
                        throw AccountRemovalError()
                    }
                    let availability = try provider?
                        .prepareForDisconnect(accountID: accountID)
                    floorpNotesDisconnectPhase = .preparedAwaitingDisconnect(
                        provider: provider,
                        finalizeNotes: availability == .available
                    )
                }
            } catch {
                logger.log(
                    "Floorp Notes Sync could not prepare for checked disconnect.",
                    level: .warning,
                    category: .sync
                )
                throw error
            }
        }) { [self] result in
            guard result == .success else {
                cancelAccountRemovalAfterCheckedDisconnectFailure()
                removal.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                return
            }
            let didCompleteDisconnect = floorpNotesStateLock.withLock {
                guard case .preparedAwaitingDisconnect(
                    let provider,
                    let shouldFinalizeNotes
                ) = floorpNotesDisconnectPhase else {
                    return false
                }
                floorpNotesDisconnectPhase = .prepared(
                    provider: provider,
                    finalizeNotes: shouldFinalizeNotes
                )
                return true
            }
            guard didCompleteDisconnect else {
                removal.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                return
            }
            removal.fillIfUnfilled(Maybe(success: ()))
        }
        return removal
    }

    @discardableResult
    public func finalizeAccountRemoval() -> Success {
        let removal = Success()
        floorpNotesStateLock.lock()
        defer { floorpNotesStateLock.unlock() }
        guard case .prepared(let provider, let shouldFinalizeNotes) =
                floorpNotesDisconnectPhase else {
            removal.fill(Maybe(failure: AccountRemovalError()))
            return removal
        }
        floorpNotesDisconnectPhase = .resolving
        var notesFinalizationFailed = false
        do {
            if shouldFinalizeNotes {
                try provider?.finalizeDisconnect()
            }
        } catch {
            logger.log(
                "Floorp Notes Sync could not finalize checked disconnect.",
                level: .warning,
                category: .sync
            )
            notesFinalizationFailed = true
        }

        endTimedSyncs()
        resetUserSyncPreferences()
        if let keyLabel = prefsForSync
            .branch("scratchpad")
            .stringForKey("keyLabel") {
            RustKeychain.sharedClientAppContainerKeychain.removeObject(key: keyLabel)
        }
        prefsForSync.clearAll()
        prefs.removeObjectForKey(PrefsKeys.RustSyncManagerPersistedState)
        completeAccountRemovalLifecycle()
        floorpNotesDisconnectPhase = .idle
        disableFloorpNotesEngineLocked()
        if notesFinalizationFailed {
            removal.fill(Maybe(failure: AccountRemovalError()))
        } else {
            removal.fill(Maybe(success: ()))
        }
        return removal
    }

    public func cancelAccountRemoval() {
        let didCancel = floorpNotesStateLock.withLock {
            cancelAccountRemovalLocked()
        }
        if didCancel {
            scheduleTimedSyncResumeAfterAccountRemovalCancellation()
        }
    }

    private func cancelAccountRemovalAfterCheckedDisconnectFailure() {
        let didCancel = floorpNotesStateLock.withLock {
            cancelAccountRemovalLocked(allowAwaitingDisconnect: true)
        }
        if didCancel {
            scheduleTimedSyncResumeAfterAccountRemovalCancellation()
        }
    }

    @discardableResult
    private func cancelAccountRemovalLocked(
        allowAwaitingDisconnect: Bool = false
    ) -> Bool {
        let provider: (any FloorpNotesSyncEngineProviding)?
        let shouldRestoreNotes: Bool
        switch floorpNotesDisconnectPhase {
        case .preparing(let preparedProvider):
            provider = preparedProvider
            shouldRestoreNotes = false
        case .preparedAwaitingDisconnect(
            let preparedProvider,
            let finalizeNotes
        ) where allowAwaitingDisconnect:
            provider = preparedProvider
            shouldRestoreNotes = finalizeNotes
        case .preparedAwaitingDisconnect:
            return false
        case .prepared(let preparedProvider, let finalizeNotes):
            provider = preparedProvider
            shouldRestoreNotes = finalizeNotes
        case .idle, .resolving:
            return false
        }
        floorpNotesDisconnectPhase = .resolving
        var mustDisableNotes = false
        if shouldRestoreNotes {
            let didRestore = provider?.cancelDisconnect() == true
            if !didRestore {
                mustDisableNotes = true
            }
        }
        completeAccountRemovalLifecycle()
        floorpNotesDisconnectPhase = .idle
        let runtimeAllows = prefs.boolForKey(
            Self.floorpNotesRuntimeEnabledPref
        ) == true
        let compiledEvidenceAllows = syncLifecycleLock.withLock {
            floorpNotesCompiledEvidenceAllows
        }
        if mustDisableNotes || !runtimeAllows || !compiledEvidenceAllows {
            disableFloorpNotesEngineLocked()
        }
        return true
    }

    private func scheduleTimedSyncResumeAfterAccountRemovalCancellation() {
        guard !backgrounded else { return }
        timedSyncResumeScheduler { [weak self] in
            guard let self,
                  !self.backgrounded,
                  self.activeSyncLifecycleGeneration() != nil,
                  self.profileHasSyncableAccount() else {
                return
            }
            self.beginTimedSyncs()
        }
    }

    private func completeAccountRemovalLifecycle() {
        syncLifecycleLock.withLock {
            accountRemovalInProgress = false
            syncLifecycleGeneration &+= 1
        }
    }

    public func checkCreditCardEngineEnablement() -> Bool {
        let engine = RustSyncManagerAPI.TogglableEngine.creditcards.rawValue
        guard let declined = UserDefaults.standard.stringArray(forKey: fxaDeclinedEngines),
              !declined.isEmpty,
              declined.contains(engine)
        else {
            let engineEnabled = prefsForSync.boolForKey("engine.\(engine).enabled") ?? false
            return engineEnabled
        }
        return false
    }

    public func getEngineEnablementChangesForAccount(withStateChange: Bool = true) -> [String: Bool] {
        var engineEnablements: [String: Bool] = [:]

        let engines = syncManagerAPI.rustTogglableEngines

        // We just created the account, the user went through the Choose What to Sync
        // screen on FxA.
        if let declined = UserDefaults.standard.stringArray(forKey: fxaDeclinedEngines) {
            engines.forEach { engineEnablements[$0.rawValue] = !declined.contains($0.rawValue) }
            if withStateChange {
                UserDefaults.standard.removeObject(forKey: fxaDeclinedEngines)
            }
        } else {
            // Bundle in authState the engines the user activated/disabled since the
            // last sync.
            engines.forEach { engine in
                let stateChangedPref = "engine.\(engine).enabledStateChanged"
                if prefsForSync.boolForKey(stateChangedPref) != nil,
                   let enabled = prefsForSync.boolForKey("engine.\(engine).enabled") {
                    engineEnablements[engine.rawValue] = enabled
                }
            }
        }

        if !engineEnablements.isEmpty {
            let enabled = engineEnablements.compactMap { $0.value ? $0.key : nil }
            logger.log("engines to enable: \(enabled)",
                       level: .info,
                       category: .sync)

            let disabled = engineEnablements.compactMap { !$0.value ? $0.key : nil }
            let msg = "engines to disable: \(disabled)"
            logger.log(msg,
                       level: .info,
                       category: .sync)
        }
        return engineEnablements
    }

    public struct ScopedKeyError: MaybeErrorType {
        public let description = "No key data found for scope."
    }

    public struct DeviceIdError: MaybeErrorType {
        public let description = "Failed to get deviceId."
    }

    public struct NoTokenServerURLError: MaybeErrorType {
        public let description = "Failed to get token server endpoint url."
    }

    public struct AccountRemovalError: MaybeErrorType {
        public let description = "Checked Sync disconnect did not complete."
    }

    func shouldSyncLogins(_ passwordEngineIncluded: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        guard passwordEngineIncluded else {
            completion(false)
            return
        }
        if !(self.prefs.boolForKey(PrefsKeys.LoginsHaveBeenVerified) ?? false) {
            // We should only sync logins when the verification step has completed successfully.
            // Otherwise logins could exist in the database that can't be decrypted and would
            // prevent logins from syncing if they are not removed.

            self.logins.verifyLogins { successfullyVerified in
                self.prefs.setBool(successfullyVerified, forKey: PrefsKeys.LoginsHaveBeenVerified)
                completion(successfullyVerified)
            }
        } else {
            // Successful logins verification already occurred so login syncing can proceed
            completion(true)
        }
    }

    func shouldSyncCreditCards(_ creditCardEngineIncluded: Bool,
                               key: String?,
                               completion: @escaping @Sendable (Bool) -> Void) {
        guard creditCardEngineIncluded, let encKey = key else {
            completion(false)
            return
        }
        if !(self.prefs.boolForKey(PrefsKeys.CreditCardsHaveBeenVerified) ?? false) {
            // We should only sync credit cards when the verification step has completed
            // successfully. Otherwise records could exist in the database that can't be decrypted
            // and would prevent credit cards from syncing if they are not scrubbed.

            self.autofill.verifyCreditCards(key: encKey) { successfullyVerified in
                self.prefs.setBool(successfullyVerified, forKey: PrefsKeys.CreditCardsHaveBeenVerified)
                completion(successfullyVerified)
            }
        } else {
            // Successful credit cards verification already occurred so credit card syncing can proceed
            completion(true)
        }
    }

    private func registerSyncEngines(engines: [RustSyncManagerAPI.TogglableEngine],
                                     loginKey: String?,
                                     creditCardKey: String?,
                                     completion: @escaping @Sendable (([String], [String: String])) -> Void) {
        let passwordEngineIncluded = engines.contains(.passwords)
        let creditCardEngineIncluded = engines.contains(.creditcards)
        self.shouldSyncLogins(passwordEngineIncluded) { syncLogins in
            self.shouldSyncCreditCards(creditCardEngineIncluded, key: creditCardKey) { syncCreditCards in
                self.doRegisterSyncEngines(engines,
                                           syncLogins,
                                           loginKey,
                                           syncCreditCards,
                                           creditCardKey) { registeredEngineData in completion(registeredEngineData) }
            }
        }
    }

    private func doRegisterSyncEngines(_ engines: [RustSyncManagerAPI.TogglableEngine],
                                       _ syncLogins: Bool,
                                       _ loginKey: String?,
                                       _ syncCreditCards: Bool,
                                       _ creditCardKey: String?,
                                       completion: @escaping @Sendable (([String], [String: String])) -> Void) {
        var localEncryptionKeys: [String: String] = [:]
        var rustEngines: [String] = []
        var registeredAutofill = false
        var registeredPlaces = false

        for engine in engines.filter({ self.syncManagerAPI.rustTogglableEngines.contains($0) }) {
            switch engine {
            case .tabs:
                self.tabs.registerWithSyncManager()
                rustEngines.append(engine.rawValue)
            case .passwords:
                if syncLogins, loginKey != nil {
                    self.logins.registerWithSyncManager()
                    rustEngines.append(engine.rawValue)
                }
            case .creditcards:
                if syncCreditCards, let key = creditCardKey {
                    // checking if autofill was already registered with addresses
                    if !registeredAutofill {
                        self.autofill.registerWithSyncManager()
                        registeredAutofill = true
                    }
                    localEncryptionKeys[engine.rawValue] = key
                    rustEngines.append(engine.rawValue)
                }
            case .addresses:
                // checking if autofill was already registered with credit cards
                if !registeredAutofill {
                    self.autofill.registerWithSyncManager()
                    registeredAutofill = true
                }
                rustEngines.append(engine.rawValue)
            case .bookmarks, .history:
                if !registeredPlaces {
                    self.places.registerWithSyncManager()
                    registeredPlaces = true
                }
                rustEngines.append(engine.rawValue)
            }
        }
        completion((rustEngines, localEncryptionKeys))
    }

    func getEnginesAndKeys(engines: [RustSyncManagerAPI.TogglableEngine],
                           completion: @escaping @Sendable (([String], [String: String])) -> Void) {
        logins.getStoredKey { loginResult in
            let loginKey: String?

            switch loginResult {
            case .success(let key):
                loginKey = key
            case .failure(let err):
                self.logger.log(
                    "Login encryption key could not be retrieved for syncing: \(err)",
                    level: .warning,
                    category: .sync
                )
                loginKey = nil
                self.logins.reportPreSyncKeyRetrievalFailure(err: err.localizedDescription)
            }

            self.autofill.getStoredKey { creditCardResult in
                var creditCardKey: String?
                switch creditCardResult {
                case .success(let key):
                    creditCardKey = key
                case .failure(let err):
                    self.logger.log(
                        "Credit card encryption key could not be retrieved for syncing: \(err)",
                        level: .warning,
                        category: .sync
                    )
                    creditCardKey = nil
                    self.autofill.reportPreSyncKeyRetrievalFailure(err: err.localizedDescription)
                }

                // calling `getEnginesWithRetrievedKeys` to remove engines that will fail to sync because
                // the encryption key is missing
                let enginesToSync = self.getEnginesWithRetrievedKeys(creditCardKey, loginKey, engines)
                self.registerSyncEngines(engines: enginesToSync,
                                         loginKey: loginKey,
                                         creditCardKey: creditCardKey,
                                         completion: completion)
            }
        }
    }

   func getEnginesWithRetrievedKeys(_ creditCardKey: String?,
                                    _ loginKey: String?,
                                    _ engines: [RustSyncManagerAPI.TogglableEngine]
                                   ) -> [RustSyncManagerAPI.TogglableEngine] {
       var enginesToSync = engines

       if loginKey == nil {
           enginesToSync = enginesToSync.filter { $0 != RustSyncManagerAPI.TogglableEngine.passwords }
       }

       if creditCardKey == nil {
           enginesToSync = enginesToSync.filter { $0 != RustSyncManagerAPI.TogglableEngine.creditcards }
       }

       return enginesToSync
    }

    func prepareSyncParamsForExecution(
        _ params: SyncParams,
        lifecycleGeneration: UInt64,
        accountID: String?,
        expectedFloorpNotesGeneration: UInt64?,
        executionContext: FloorpNotesSyncExecutionContext
    ) -> SyncParams? {
        guard isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
            return nil
        }
        guard case .some(let engines) = params.engines,
              engines.contains(FloorpNotesSyncEngineSelection.engineName) else {
            return params
        }

        return floorpNotesStateLock.withLock {
            guard isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                return nil
            }
            let currentGeneration = currentFloorpNotesLifecycleGeneration()
            if let expectedFloorpNotesGeneration,
               expectedFloorpNotesGeneration != currentGeneration {
                return Self.removingFloorpNotes(from: params)
            }
            guard let accountID,
                  let provider = floorpNotesEngineProvider,
                  let tokenServerURL = URL(
                    string: params.authInfo.tokenserverUrl
                  ),
                  FloorpNotesSyncEndpointAuthority
                    .allowsProductionTokenServer(tokenServerURL),
                  floorpNotesPolicy(accountID: accountID).allowsRequest else {
                disableFloorpNotesEngineAssumingComponentLockLocked()
                return Self.removingFloorpNotes(from: params)
            }

            guard registerFloorpNotesProviderIfNeeded(
                provider,
                accountID: accountID
            ) else {
                return Self.removingFloorpNotes(from: params)
            }

            floorpNotesRequestSequence &+= 1
            executionContext.record(
                generation: currentFloorpNotesLifecycleGeneration(),
                requestSequence: floorpNotesRequestSequence
            )
            return params
        }
    }

    private func registerFloorpNotesProviderIfNeeded(
        _ provider: any FloorpNotesSyncEngineProviding,
        accountID: String
    ) -> Bool {
        guard floorpNotesAccountID != accountID else { return true }
        disableFloorpNotesEngineAssumingComponentLockLocked()
        do {
            try provider.register(accountID: accountID)
            floorpNotesAccountID = accountID
            return true
        } catch {
            logger.log(
                "Floorp Notes Sync engine registration failed closed.",
                level: .warning,
                category: .sync
            )
            disableFloorpNotesEngineAssumingComponentLockLocked()
            return false
        }
    }

    func doSync(
        params: SyncParams,
        lifecycleGeneration: UInt64,
        floorpNotesAccountID: String?,
        expectedFloorpNotesGeneration: UInt64?,
        floorpNotesExecutionContext: FloorpNotesSyncExecutionContext,
        completion: @escaping @Sendable (SyncResult) -> Void
    ) {
        beginSyncing()
        syncManagerAPI.sync(
            params: params,
            shouldStart: { [weak self] in
                self?.isCurrentSyncLifecycleGeneration(lifecycleGeneration) == true
            },
            prepareParams: { [weak self] params in
                self?.prepareSyncParamsForExecution(
                    params,
                    lifecycleGeneration: lifecycleGeneration,
                    accountID: floorpNotesAccountID,
                    expectedFloorpNotesGeneration: expectedFloorpNotesGeneration,
                    executionContext: floorpNotesExecutionContext
                )
            }
        ) { syncResult in
            guard self.isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                self.syncDisplayState = nil
                if !self.backgrounded {
                    self.notifySyncing(notification: .ProfileDidFinishSyncing)
                    AppEventQueue.completed(.profileSyncing)
                }
                completion(syncResult)
                return
            }
            // Save the persisted state
            if !syncResult.persistedState.isEmpty {
                self.prefs
                    .setString(syncResult.persistedState,
                               forKey: PrefsKeys.RustSyncManagerPersistedState)
            }

            let declinedEngines = String(describing: syncResult.declined ?? [])
            let telemetryData = syncResult.telemetryJson ??
                "(No telemetry data was returned)"
            let telemetryMessage = "\(String(describing: telemetryData))"

            self.logger.log("Finished syncing with status: \(syncResult.status), declined engines: \(declinedEngines)",
                            level: .info,
                            category: .sync,
                            extra: ["telemetry": telemetryMessage])

            if let declined = syncResult.declined {
                self.updateEnginePrefs(declined: declined)
            }

            self.endSyncing(syncResult)
            completion(syncResult)
        }
    }

    func updateEnginePrefs(declined: [String]) {
        // Save declined/enabled engines - we assume the engines
        // not included in the returned `declined` property of the
        // result of the sync manager `sync` are enabled.

        let updateEnginePref: (String, Bool) -> Void = { engine, enabled in
            let enabledPref = "engine.\(engine).enabled"
            self.prefsForSync.setBool(enabled, forKey: enabledPref)

            let stateChangedPref = "engine.\(engine).enabledStateChanged"
            self.prefsForSync.setObject(nil, forKey: stateChangedPref)

            let enablementDetails = [enabledPref: String(enabled)]
            self.logger.log("Finished setting \(engine) enablement prefs",
                            level: .info,
                            category: .sync,
                            extra: enablementDetails)
        }

        syncManagerAPI.rustTogglableEngines.forEach({
            if declined.contains($0.rawValue) {
                updateEnginePref($0.rawValue, false)
            } else {
                updateEnginePref($0.rawValue, true)
            }
        })
    }

    private func syncRustEngines(
        why: SyncReason,
        engines: [String],
        expectedFloorpNotesGeneration: UInt64? = nil
    ) -> Deferred<Maybe<SyncResult>> {
        let deferred = Deferred<Maybe<SyncResult>>()
        let engineSelection = FloorpNotesSyncEngineSelection.partition(requested: engines)
        syncRequestObserver(why, engines)
        guard let lifecycleGeneration = activeSyncLifecycleGeneration() else {
            deferred.fill(Maybe(failure: AccountRemovalError()))
            return deferred
        }

        logger.log("Syncing \(engines)", level: .info, category: .sync)
        guard let accountManager = RustFirefoxAccounts.shared.accountManager else {
            deferred.fill(Maybe(failure: AccountRemovalError()))
            return deferred
        }

        // Prefer accountState over deviceConstellation for the current
        // device ID to avoid a possible server round-trip. This runs off the
        // main thread so the blocking FFI call can't hang the UI.
        // swiftlint:disable closure_body_length
        accountManager.getCurrentDeviceId { deviceIDResult in
            guard self.isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                deferred.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                return
            }
            guard case .success(let deviceId) = deviceIDResult else {
                self.logger.log("Device Id could not be retrieved",
                                level: .warning,
                                category: .sync)
                deferred.fill(Maybe(failure: DeviceIdError()))
                return
            }

            accountManager.getAccessToken(scope: OAuthScope.oldSync) { result in
                guard self.isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                    deferred.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                    return
                }
                guard let accessTokenInfo = try? result.get(),
                      let key = accessTokenInfo.key else {
                    deferred.fill(Maybe(failure: ScopedKeyError()))
                    return
                }

                accountManager.getTokenServerEndpointURL { result in
                    guard self.isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                        deferred.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                        return
                    }
                    guard case .success(let tokenServerEndpointURL) = result else {
                        deferred.fill(Maybe(failure: NoTokenServerURLError()))
                        return
                    }

                    self.getEnginesAndKeys(
                        engines: engineSelection.togglable
                    ) { standardEngines, localEncryptionKeys in
                        guard self.isCurrentSyncLifecycleGeneration(lifecycleGeneration) else {
                            deferred.fillIfUnfilled(Maybe(failure: AccountRemovalError()))
                            return
                        }
                        var rustEngines = standardEngines
                        if engineSelection.requestsFloorpPrefs {
                            rustEngines.append(FloorpNotesSyncEngineSelection.engineName)
                        }
                        let floorpNotesAccountID = accountManager.accountProfile()?.uid
                        let params = SyncParams(
                            reason: why,
                            engines: SyncEngineSelection.some(engines: rustEngines),
                            enabledChanges: self.getEngineEnablementChangesForAccount(),
                            localEncryptionKeys: localEncryptionKeys,
                            authInfo: self.createSyncAuthInfo(key: key,
                                                              accessTokenInfo: accessTokenInfo,
                                                              tokenServerEndpointURL: tokenServerEndpointURL),
                            persistedState:
                                self.prefs
                                    .stringForKey(PrefsKeys.RustSyncManagerPersistedState),
                            deviceSettings: self.createDeviceSettings(
                                deviceId: deviceId,
                                accountManager: accountManager))

                        let floorpNotesExecutionContext = FloorpNotesSyncExecutionContext()
                        self.doSync(
                            params: params,
                            lifecycleGeneration: lifecycleGeneration,
                            floorpNotesAccountID: floorpNotesAccountID,
                            expectedFloorpNotesGeneration: expectedFloorpNotesGeneration,
                            floorpNotesExecutionContext: floorpNotesExecutionContext
                        ) { syncResult in
                            guard self.isCurrentSyncLifecycleGeneration(
                                lifecycleGeneration
                            ) else {
                                deferred.fillIfUnfilled(
                                    Maybe(failure: AccountRemovalError())
                                )
                                return
                            }
                            if let registeredFloorpNotesGeneration =
                                floorpNotesExecutionContext.generation,
                               let registeredRequestSequence =
                                floorpNotesExecutionContext.requestSequence,
                               self.isCurrentFloorpNotesLifecycleGeneration(
                                registeredFloorpNotesGeneration
                               ) {
                                self.handleFloorpNotesSyncResult(
                                    syncResult,
                                    why: why,
                                    floorpNotesGeneration: registeredFloorpNotesGeneration,
                                    requestSequence: registeredRequestSequence
                                )
                            }
                            deferred.fill(Maybe(success: syncResult))
                        }
                    }
                }
            }
        }
        // swiftlint:enable closure_body_length
        return deferred
    }

    private static func removingFloorpNotes(
        from params: SyncParams
    ) -> SyncParams? {
        guard case .some(let engines) = params.engines else { return nil }
        let standardEngines = engines.filter {
            $0 != FloorpNotesSyncEngineSelection.engineName
        }
        guard !standardEngines.isEmpty else { return nil }
        var standardOnly = params
        standardOnly.engines = .some(engines: standardEngines)
        return standardOnly
    }

    private func createSyncAuthInfo(key: ScopedKey,
                                    accessTokenInfo: AccessTokenInfo,
                                    tokenServerEndpointURL: URL) -> SyncAuthInfo {
        return SyncAuthInfo(
            kid: key.kid,
            fxaAccessToken: accessTokenInfo.token,
            syncKey: key.k,
            tokenserverUrl: tokenServerEndpointURL.absoluteString)
    }

    private func createDeviceSettings(deviceId: String, accountManager: FxAccountManager) -> DeviceSettings {
        return DeviceSettings(
            fxaDeviceId: deviceId,
            name: accountManager.deviceConfig.name,
            kind: accountManager.deviceConfig.deviceType)
    }

    @discardableResult
    public func syncEverything(why: SyncReason) -> Success {
        // Convert Deferred<Maybe<SyncResult>> into Deferred<Maybe<Void>>:
        // - If sync succeeds, return success with ().
        // - If sync fails, propagate the same failure.
        return syncRustEngines(
            why: why,
            engines: syncManagerAPI.rustTogglableEngines.map(\.rawValue)
                + [FloorpNotesSyncEngineSelection.engineName]
        ).map { $0.map { _ in () } }
    }

    /**
     * Allows selective sync of different collections, for use by external APIs.
     * Some help is given to callers who use different namespaces (specifically: `passwords` is mapped to `logins`)
     * and to preserve some ordering rules.
     */
    public func syncNamedCollections(why: SyncReason, names: [String]) -> Deferred<Maybe<SyncResult>> {
        syncNamedCollections(
            why: why,
            names: names,
            expectedFloorpNotesGeneration: nil
        )
    }

    private func syncNamedCollections(
        why: SyncReason,
        names: [String],
        expectedFloorpNotesGeneration: UInt64?
    ) -> Deferred<Maybe<SyncResult>> {
        // Massage the list of names into engine identifiers.var engines = [String]()
        var engines = [String]()

        // There may be duplicates in `names` so we are removing them here
        for name in names where !engines.contains(name) {
            engines.append(name)
        }

        return syncRustEngines(
            why: why,
            engines: engines,
            expectedFloorpNotesGeneration: expectedFloorpNotesGeneration
        )
    }

    /**
     * A specialized version of `syncNamedCollections` for execution after a sync settings change. Allows selective
     * sync of different collections and retries the sync if the initial call is backed off.
     */
    public func syncPostSyncSettingsChange(why: SyncReason, names: [String]) {
        let enablements = getEngineEnablementChangesForAccount(withStateChange: false)
        let enabledEngines = Array(enablements.filter({ $0.value }).keys)
        let disabledEngines = Array(enablements.filter({ !$0.value }).keys)

        // report sync settings telemetry changes
        self.syncManagerAPI.reportSaveSyncSettingsTelemetry(enabledEngines: enabledEngines,
                                                            disabledEngines: disabledEngines)

        syncNamedCollections(why: why, names: names).upon { result in
            guard result.isSuccess, let syncResult = result.successValue else {
                return
            }

            // If the sync was backed off, retry it after a delay.
            if syncResult.status == .backedOff {
                self.retrySyncAfterDelay(why: why, names: names)
            }
        }
    }

    public func reportOpenSyncSettingsMenuTelemetry() {
        self.syncManagerAPI.reportOpenSyncSettingsMenuTelemetry()
    }

    private func retrySyncAfterDelay(why: SyncReason, names: [String]) {
        self.syncBackOffTimer?.invalidate()
        guard let generation = activeSyncLifecycleGeneration() else { return }

        self.syncBackOffTimer = Timer.scheduledTimer(withTimeInterval: self.syncBackOffDelay,
                                                     repeats: false) { _ in
            guard self.isCurrentSyncLifecycleGeneration(generation) else { return }
            _ = self.syncNamedCollections(why: why, names: names)
        }
    }

    public func syncTabs() -> Deferred<Maybe<SyncResult>> {
        return syncRustEngines(why: .user, engines: ["tabs"])
    }

    public func syncHistory() -> Deferred<Maybe<SyncResult>> {
        return syncRustEngines(why: .user, engines: ["history"])
    }
}
