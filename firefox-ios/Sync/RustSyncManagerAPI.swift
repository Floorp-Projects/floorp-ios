// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Common

import class MozillaAppServices.SyncManagerComponent
import enum MozillaAppServices.SyncManagerError
import enum MozillaAppServices.ServiceStatus
import struct MozillaAppServices.SyncParams
import struct MozillaAppServices.SyncResult

protocol RustSyncManagerComponentProtocol: Sendable {
    func disconnect()
    func disconnectChecked() throws
    func sync(params: SyncParams) throws -> SyncResult
    func getAvailableEngines() -> [String]
}

extension SyncManagerComponent: RustSyncManagerComponentProtocol {}

typealias RustSyncManagerComponentFactory = @Sendable () -> any RustSyncManagerComponentProtocol

private final class OnceCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Value) -> Void)?

    init(_ callback: @escaping @Sendable (Value) -> Void) {
        self.callback = callback
    }

    func resolve(_ value: Value) {
        lock.lock()
        let callback = callback
        self.callback = nil
        lock.unlock()
        callback?(value)
    }
}

public final class RustSyncManagerAPI: Sendable {
    public enum CheckedDisconnectResult: Equatable, Sendable {
        case success
        case failure
    }

    private final class ComponentState: @unchecked Sendable {
        private let lock = NSLock()
        private let factory: RustSyncManagerComponentFactory
        private var component: any RustSyncManagerComponentProtocol

        init(factory: @escaping RustSyncManagerComponentFactory) {
            self.factory = factory
            self.component = factory()
        }

        func disconnect() {
            lock.lock()
            defer { lock.unlock() }
            component.disconnect()
        }

        func disconnectChecked(
            prepare: @Sendable () throws -> Void
        ) -> CheckedDisconnectResult {
            lock.lock()
            defer { lock.unlock() }
            do {
                try prepare()
                try component.disconnectChecked()
                component = factory()
                return .success
            } catch {
                return .failure
            }
        }

        func sync(
            params: SyncParams,
            shouldStart: @Sendable () -> Bool,
            prepareParams: @Sendable (SyncParams) -> SyncParams?
        ) throws -> SyncResult? {
            lock.lock()
            defer { lock.unlock() }
            guard shouldStart(),
                  let preparedParams = prepareParams(params) else {
                return nil
            }
            return try component.sync(params: preparedParams)
        }

        func synchronize<Value: Sendable>(
            _ operation: @Sendable () -> Value
        ) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }

        func getAvailableEngines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return component.getAvailableEngines()
        }
    }

    private let logger: Logger
    private let dispatchQueue: DispatchQueueInterface
    private let componentState: ComponentState

    // Names of collections that can be enabled/disabled locally.
    public enum TogglableEngine: String, CaseIterable, Sendable {
        case tabs
        case passwords
        case bookmarks
        case history
        case creditcards
        case addresses
    }

    public let rustTogglableEngines: [TogglableEngine] = [.tabs, .passwords, .bookmarks, .history, .creditcards, .addresses]

    public convenience init(
        logger: Logger = DefaultLogger.shared,
        dispatchQueue: DispatchQueueInterface = DispatchQueue.global()
    ) {
        self.init(
            logger: logger,
            dispatchQueue: dispatchQueue,
            componentFactory: { SyncManagerComponent() }
        )
    }

    init(
        logger: Logger = DefaultLogger.shared,
        dispatchQueue: DispatchQueueInterface = DispatchQueue.global(),
        componentFactory: @escaping RustSyncManagerComponentFactory
    ) {
        self.logger = logger
        self.dispatchQueue = dispatchQueue
        self.componentState = ComponentState(factory: componentFactory)
    }

    public func disconnect() {
        dispatchQueue.async { [componentState] in
            componentState.disconnect()
        }
    }

    public func disconnectChecked(
        prepare: @escaping @Sendable () throws -> Void = {},
        completion: @escaping @Sendable (CheckedDisconnectResult) -> Void
    ) {
        let onceCompletion = OnceCompletion(completion)
        dispatchQueue.async { [componentState, logger] in
            let result = componentState.disconnectChecked(prepare: prepare)
            if result == .failure {
                logger.log(
                    "Rust SyncManager checked disconnect failed.",
                    level: .warning,
                    category: .sync
                )
            }
            onceCompletion.resolve(result)
        }
    }

    public func synchronizeComponentState(
        _ operation: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        dispatchQueue.async { [componentState] in
            componentState.synchronize(operation)
            completion()
        }
    }

    public func synchronizeComponentStateAndWait<Value: Sendable>(
        _ operation: @Sendable () -> Value
    ) -> Value {
        componentState.synchronize(operation)
    }

    public func sync(
        params: SyncParams,
        shouldStart: @escaping @Sendable () -> Bool = { true },
        prepareParams: @escaping @Sendable (SyncParams) -> SyncParams? = { $0 },
        completion: @escaping @Sendable (SyncResult) -> Void
    ) {
        dispatchQueue.async { [componentState, logger] in
            completion(
                Self.performSync(
                    params: params,
                    shouldStart: shouldStart,
                    prepareParams: prepareParams,
                    componentState: componentState,
                    logger: logger
                )
            )
        }
    }

    private static func performSync(
        params: SyncParams,
        shouldStart: @Sendable () -> Bool,
        prepareParams: @Sendable (SyncParams) -> SyncParams?,
        componentState: ComponentState,
        logger: Logger
    ) -> SyncResult {
        do {
            guard let result = try componentState.sync(
                params: params,
                shouldStart: shouldStart,
                prepareParams: prepareParams
            ) else {
                return failedSyncResult(reason: "cancelled")
            }
            return result
        } catch let error as NSError {
            logSyncError(error, logger: logger)
            return failedSyncResult(reason: "ffi-error")
        }
    }

    private static func logSyncError(_ error: NSError, logger: Logger) {
        if let syncError = error as? SyncManagerError {
            logger.log(
                "Rust SyncManager sync error: \(syncError.localizedDescription)",
                level: .warning,
                category: .sync
            )
        } else {
            logger.log(
                "Unknown error when attempting a rust SyncManager sync: \(error.localizedDescription)",
                level: .warning,
                category: .sync
            )
        }
    }

    private static func failedSyncResult(reason: String) -> SyncResult {
        SyncResult(
            status: ServiceStatus.otherError,
            successful: [],
            failures: ["syncmanager": reason],
            persistedState: "",
            declined: nil,
            nextSyncAllowedAt: nil,
            telemetryJson: nil
        )
    }

    public func reportSyncTelemetry(syncResult: SyncResult,
                                    completion: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global().async { [unowned self] in
            do {
                try SyncManagerComponent.reportSyncTelemetry(syncResult: syncResult)
            } catch let err as NSError {
                let description = err.localizedDescription
                self.logger.log("""
                    Unknown error when reporting telemetry for the Rust SyncManager:
                    \(description)
                    """,
                    level: .warning,
                    category: .sync)
                completion(description)
            }
        }
    }

    public func reportOpenSyncSettingsMenuTelemetry() {
        DispatchQueue.global().async {
            SyncManagerComponent.reportOpenSyncSettingsMenuTelemetry()
        }
    }

    public func reportSaveSyncSettingsTelemetry(enabledEngines: [String], disabledEngines: [String]) {
        DispatchQueue.global().async {
            SyncManagerComponent.reportSaveSyncSettingsTelemetry(enabledEngines: enabledEngines,
                                                                 disabledEngines: disabledEngines)
        }
    }

    public func getAvailableEngines(completion: @escaping @Sendable ([String]) -> Void) {
        DispatchQueue.global().async { [componentState] in
            completion(componentState.getAvailableEngines())
        }
    }
}
