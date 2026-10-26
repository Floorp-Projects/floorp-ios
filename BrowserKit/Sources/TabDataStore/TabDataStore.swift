// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Common

public protocol TabDataStore: Sendable {
    /// Fetches the previously saved window data matching the provided UUID,
    /// if it exists. This data contains the list of tabs.
    /// - Returns: The window data object if one was previously saved
    func fetchWindowData(uuid: UUID) async -> WindowData?

    /// Saves the window data (contains the list of tabs) to disk
    /// - Parameter window: the window data object to be saved
    func saveWindowData(window: WindowData, forced: Bool) async

    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipt: UUID) async throws
    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipts: Set<UUID>) async throws
    func fetchWorkspaceCopyReceipts(windowID: UUID) async throws -> Set<UUID>
    func resolveWorkspaceCopyReceiptUncertainty(windowID: UUID) async throws

    /// Erases all window data on disk
    func clearAllWindowsData() async

    /// Synchronous function that lists UUIDs for all WindowData currently saved
    /// to disk. Because this requires no decoding (we can just check the list of
    /// saved files in the directory) it is faster than fetchWindowData() and is
    /// preferable when only the UUIDs are needed.
    /// - Returns: a list of UUIDs for any saved WindowData.
    nonisolated func fetchWindowDataUUIDs() -> [WindowUUID]

    /// Erases the on-disk data for tab windows matching the provided UUIDs.
    /// - Parameter forUUIDs: the UUIDs to delete the on-disk tab files for.
    func removeWindowData(forUUIDs: [WindowUUID]) async
}

public enum WorkspaceCopyPersistenceError: Error {
    case unavailable
    case verificationFailed
    case receiptInventoryUncertain
}

public extension TabDataStore {
    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipt: UUID) async throws {
        try await saveWindowDataDurably(window: window, workspaceCopyReceipts: [workspaceCopyReceipt])
    }

    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipts: Set<UUID>) async throws {
        throw WorkspaceCopyPersistenceError.unavailable
    }

    func fetchWorkspaceCopyReceipts(windowID: UUID) async throws -> Set<UUID> {
        throw WorkspaceCopyPersistenceError.unavailable
    }

    func resolveWorkspaceCopyReceiptUncertainty(windowID: UUID) async throws {
        throw WorkspaceCopyPersistenceError.unavailable
    }
}

public actor DefaultTabDataStore: TabDataStore {
    enum TabDataError: Error {
        case failedToFetchData
    }

    private let logger: Logger
    private let fileManager: TabFileManager
    private let throttleTime: UInt64
    private var windowDataToSave = [UUID: WindowData]()
    private var scheduledWindowSaves = Set<UUID>()
    private let filePrefix = "window-"
    private var workspaceCopyReceipts = [UUID: Set<UUID>]()
    private var workspaceCopySaveBarriers = [UUID: Set<UUID>]()
    private var uncertainWorkspaceCopyWindows = Set<UUID>()

    public init(logger: Logger = DefaultLogger.shared,
                fileManager: TabFileManager = DefaultTabFileManager(),
                throttleTime: UInt64 = 2 * NSEC_PER_SEC) {
        self.logger = logger
        self.fileManager = fileManager
        self.throttleTime = throttleTime
    }

    // MARK: Fetching Window Data

    public func fetchWindowData(uuid: UUID) async -> WindowData? {
        logger.log("Attempting to fetch window data", level: .debug, category: .tabs)

        // Adding more logging for FXIOS-9517
        var shouldLogFileFailure = false // Whether pulling from the main file failed
        var shouldLogBackupFailure = false // Whether pulling from the backup file failed
        var fileInfoMessage = "" // Specifics of main file failure
        var backupInfoMessage = "" // Specifics of backup file failure
        defer {
            if shouldLogFileFailure {
                let errorMessage: String
                errorMessage = shouldLogBackupFailure
                                ? "Failed to open window data (including backup data)"
                                : "Failed to open window data (but backup recovery worked)"
                logger.log(
                    errorMessage,
                    level: .fatal,
                    category: .tabs,
                    extra: [
                        "windowUUID": uuid.uuidString,
                        "fileInfo": fileInfoMessage,
                        "backupFileInfo": backupInfoMessage
                    ]
                )
            }
        }

        do {
            guard let fileURL = windowURLPath(for: uuid, isBackup: false) else {
                fileInfoMessage += "fileURL nil"
                shouldLogFileFailure = true
                throw TabDataError.failedToFetchData
            }

            guard fileManager.fileExists(atPath: fileURL) else {
                fileInfoMessage += "file doesn't exist"
                shouldLogFileFailure = true
                throw TabDataError.failedToFetchData
            }

            guard let windowData = parseWindowDataFile(fromURL: fileURL) else {
                fileInfoMessage += "file parsing failed"
                shouldLogFileFailure = true
                throw TabDataError.failedToFetchData
            }

            logger.log("Successfully fetched window data", level: .debug, category: .tabs)
            if windowData.id != uuid || windowData.workspaceCopyReceiptInventoryUncertain == true {
                uncertainWorkspaceCopyWindows.insert(uuid)
            }
            workspaceCopyReceipts[uuid, default: []].formUnion(windowData.workspaceCopyReceipts ?? [])
            return windowData
        } catch {
            uncertainWorkspaceCopyWindows.insert(uuid)
            logger.log("Error fetching window data for UUID: \(uuid) Error: \(error)", level: .warning, category: .tabs)

            guard let backupURL = windowURLPath(for: uuid, isBackup: true) else {
                backupInfoMessage += "backup fileURL nil"
                shouldLogBackupFailure = true
                return nil
            }

            guard fileManager.fileExists(atPath: backupURL) else {
                backupInfoMessage += "backup file doesn't exist"
                shouldLogBackupFailure = true
                return nil
            }

            guard let backupWindowData = parseWindowDataFile(fromURL: backupURL) else {
                backupInfoMessage += "backup file parsing failed"
                shouldLogBackupFailure = true
                return nil
            }

            logger.log("Returned backup window data for UUID: \(uuid)", level: .debug, category: .tabs)
            workspaceCopyReceipts[uuid, default: []].formUnion(backupWindowData.workspaceCopyReceipts ?? [])
            return backupWindowData
        }
    }

    nonisolated public func fetchWindowDataUUIDs() -> [WindowUUID] {
        guard let directoryURL = fileManager.windowDataDirectory(isBackup: false) else {
            logger.log("Could not resolve window data directory", level: .warning, category: .tabs)
            return []
        }

        let fileURLs = fileManager.contentsOfDirectory(at: directoryURL)

        return fileURLs.compactMap { windowUUID(fromURL: $0) }
    }

    private func parseWindowDataFile(fromURL url: URL) -> WindowData? {
        return try? fileManager.getWindowDataFromPath(path: url)
    }

    // MARK: - Saving Data

    public func saveWindowData(window: WindowData, forced: Bool) async {
        guard workspaceCopySaveBarriers[window.id, default: []].isSubset(of: Set(window.workspaceCopyReceipts ?? [])) else {
            return
        }
        guard let windowSavingPath = windowURLPath(for: window.id, isBackup: false) else {
            logger.log("Not saving window data. Could not build window saving path.",
                       level: .warning,
                       category: .tabs)
            return
        }

        // Hold onto a copy of the latest window data so whenever the save happens it is using the latest
        windowDataToSave[window.id] = includingWorkspaceCopyReceipts(in: window)

        if let windowDataDirectoryURL = fileManager.windowDataDirectory(isBackup: false),
           !fileManager.fileExists(atPath: windowDataDirectoryURL) {
            fileManager.createDirectoryAtPath(path: windowDataDirectoryURL)
        }

        logger.log("Save window data, is forced: \(forced)",
                   level: .debug,
                   category: .tabs)
        if forced {
            writeWindowDataToFile(windowID: window.id, path: windowSavingPath)
        } else {
            writeWindowDataToFileWithThrottle(windowID: window.id, path: windowSavingPath)
        }
    }

    public func fetchWorkspaceCopyReceipts(windowID: UUID) async throws -> Set<UUID> {
        guard !uncertainWorkspaceCopyWindows.contains(windowID) else {
            throw WorkspaceCopyPersistenceError.receiptInventoryUncertain
        }
        guard let path = windowURLPath(for: windowID, isBackup: false) else {
            throw WorkspaceCopyPersistenceError.unavailable
        }
        if fileManager.fileExists(atPath: path) {
            let data: WindowData
            do {
                guard let decoded = try fileManager.getWindowDataFromPath(path: path), decoded.id == windowID else {
                    throw WorkspaceCopyPersistenceError.verificationFailed
                }
                data = decoded
            } catch {
                uncertainWorkspaceCopyWindows.insert(windowID)
                throw WorkspaceCopyPersistenceError.receiptInventoryUncertain
            }
            guard data.workspaceCopyReceiptInventoryUncertain != true else {
                uncertainWorkspaceCopyWindows.insert(windowID)
                throw WorkspaceCopyPersistenceError.receiptInventoryUncertain
            }
            workspaceCopyReceipts[windowID, default: []].formUnion(data.workspaceCopyReceipts ?? [])
        } else if let backup = windowURLPath(for: windowID, isBackup: true), fileManager.fileExists(atPath: backup) {
            // An older backup cannot establish whether a copy was already committed.
            uncertainWorkspaceCopyWindows.insert(windowID)
            throw WorkspaceCopyPersistenceError.receiptInventoryUncertain
        }
        return workspaceCopyReceipts[windowID, default: []]
    }

    /// Call only after all pending copy operations targeting this window have been discarded.
    public func resolveWorkspaceCopyReceiptUncertainty(windowID: UUID) async throws {
        guard let path = windowURLPath(for: windowID, isBackup: false) else {
            throw WorkspaceCopyPersistenceError.verificationFailed
        }
        let window: WindowData
        if let pending = windowDataToSave[windowID] {
            window = pending
        } else {
            guard let saved = try fileManager.getWindowDataFromPath(path: path), saved.id == windowID else {
                throw WorkspaceCopyPersistenceError.verificationFailed
            }
            window = saved
        }
        let receipts = workspaceCopyReceipts[windowID, default: []].union(window.workspaceCopyReceipts ?? [])
        let resolved = WindowData(id: window.id,
                                  activeTabId: window.activeTabId,
                                  tabData: window.tabData,
                                  workspaceCopyReceipts: receipts.isEmpty ? nil : receipts.sorted {
                                      $0.uuidString < $1.uuidString
                                  })
        try fileManager.writeWindowData(windowData: resolved, to: path)
        windowDataToSave[windowID] = resolved
        guard let verified = try fileManager.getWindowDataFromPath(path: path), verified.id == windowID,
              verified.workspaceCopyReceiptInventoryUncertain != true,
              receipts.isSubset(of: Set(verified.workspaceCopyReceipts ?? [])) else {
            throw WorkspaceCopyPersistenceError.verificationFailed
        }
        workspaceCopyReceipts[windowID] = receipts
        uncertainWorkspaceCopyWindows.remove(windowID)
    }

    public func saveWindowDataDurably(window: WindowData, workspaceCopyReceipt: UUID) async throws {
        try await saveWindowDataDurably(window: window, workspaceCopyReceipts: [workspaceCopyReceipt])
    }

    public func saveWindowDataDurably(window: WindowData, workspaceCopyReceipts newReceipts: Set<UUID>) async throws {
        let normalTabIDs = Set(window.tabData.filter { !$0.isPrivate }.map(\.id))
        guard !newReceipts.isEmpty, newReceipts.isSubset(of: normalTabIDs) else {
            throw WorkspaceCopyPersistenceError.verificationFailed
        }
        _ = try await fetchWorkspaceCopyReceipts(windowID: window.id)
        guard workspaceCopySaveBarriers[window.id, default: []].isSubset(of: Set(window.workspaceCopyReceipts ?? [])) else {
            throw WorkspaceCopyPersistenceError.verificationFailed
        }
        guard let path = windowURLPath(for: window.id, isBackup: false),
              let directory = fileManager.windowDataDirectory(isBackup: false) else {
            throw WorkspaceCopyPersistenceError.unavailable
        }
        if !fileManager.fileExists(atPath: directory) {
            fileManager.createDirectoryAtPath(path: directory)
        }
        let receipts = workspaceCopyReceipts[window.id, default: []]
            .union(window.workspaceCopyReceipts ?? [])
            .union(newReceipts)
        let committed = WindowData(id: window.id,
                                   activeTabId: window.activeTabId,
                                   tabData: window.tabData,
                                   workspaceCopyReceipts: receipts.sorted { $0.uuidString < $1.uuidString })
        try fileManager.writeWindowData(windowData: committed, to: path)
        workspaceCopySaveBarriers[window.id, default: []].formUnion(receipts)
        windowDataToSave[window.id] = committed
        guard let verified = try fileManager.getWindowDataFromPath(path: path),
              verified.id == window.id,
              verified.workspaceCopyReceiptInventoryUncertain != true,
              receipts.isSubset(of: Set(verified.workspaceCopyReceipts ?? [])),
              newReceipts.isSubset(of: Set(verified.tabData.filter { !$0.isPrivate }.map(\.id))) else {
            throw WorkspaceCopyPersistenceError.verificationFailed
        }
        workspaceCopyReceipts[window.id, default: []].formUnion(receipts)
    }

    private func includingWorkspaceCopyReceipts(in window: WindowData) -> WindowData {
        if window.workspaceCopyReceiptInventoryUncertain == true { uncertainWorkspaceCopyWindows.insert(window.id) }
        let receipts = workspaceCopyReceipts[window.id, default: []].union(window.workspaceCopyReceipts ?? [])
        return WindowData(id: window.id,
                          activeTabId: window.activeTabId,
                          tabData: window.tabData,
                          workspaceCopyReceipts: receipts.isEmpty ? nil : receipts.sorted { $0.uuidString < $1.uuidString },
                          workspaceCopyReceiptInventoryUncertain: uncertainWorkspaceCopyWindows.contains(window.id) ? true : nil)
    }

    private func createWindowDataBackup(windowID: UUID, windowPath: URL) {
        guard let backupWindowSavingPath = windowURLPath(for: windowID, isBackup: true) else {
            logger.log("Failed to create window data backup. Could not create windowURLPath.",
                       level: .warning,
                       category: .tabs)
            return
        }

        guard let backupDirectoryPath = fileManager.windowDataDirectory(isBackup: true) else {
            logger.log("Failed to create window data backup. No backup directory path.",
                       level: .warning,
                       category: .tabs)
            return
        }

        if !fileManager.fileExists(atPath: backupDirectoryPath) {
            fileManager.createDirectoryAtPath(path: backupDirectoryPath)
        }
        do {
            try fileManager.copyItem(at: windowPath, to: backupWindowSavingPath)
        } catch {
            logger.log("Failed to create window data backup: \(error)",
                       level: .warning,
                       category: .tabs)
        }
    }

    // Throttles the saving of the data so that it happens every 'throttleTime' nanoseconds
    // as long as their is new data to be saved
    private func writeWindowDataToFileWithThrottle(windowID: UUID, path: URL) {
        // Ignore the request because a save is already scheduled to happen
        guard scheduledWindowSaves.insert(windowID).inserted else { return }

        // Dispatch to a task so as not to block the caller
        Task {
            // Once the throttle time has passed initiate the save for this window
            try? await Task.sleep(nanoseconds: throttleTime)
            scheduledWindowSaves.remove(windowID)
            if fileManager.fileExists(atPath: path) {
                createWindowDataBackup(windowID: windowID, windowPath: path)
            }
            writeWindowDataToFile(windowID: windowID, path: path)
        }
    }

    private func writeWindowDataToFile(windowID: UUID, path: URL) {
        do {
            guard let windowDataToSave = windowDataToSave[windowID] else {
                logger.log("Tried to save window data but found nil",
                           level: .fatal,
                           category: .tabs)
                return
            }
            try fileManager.writeWindowData(windowData: windowDataToSave, to: path)
        } catch {
            logger.log("Failed to save window data: \(error)",
                       level: .warning,
                       category: .tabs)
        }
    }

    // MARK: - Deleting Window Data

    public func clearAllWindowsData() async {
        guard let directoryURL = fileManager.windowDataDirectory(isBackup: false),
              let backupURL = fileManager.windowDataDirectory(isBackup: true) else {
            return
        }
        fileManager.removeAllFilesAt(directory: directoryURL)
        fileManager.removeAllFilesAt(directory: backupURL)
    }

    public func removeWindowData(forUUIDs uuids: [WindowUUID]) async {
        guard let directoryURL = fileManager.windowDataDirectory(isBackup: false) else { return }

        let fileURLs = fileManager.contentsOfDirectory(at: directoryURL)

        for url in fileURLs {
            guard let uuid = windowUUID(fromURL: url) else { continue }
            guard uuids.contains(where: { $0 == uuid }) else {
                logger.log("Will not remove window data for UUID: \(uuid)", level: .info, category: .tabs)
                continue
            }
            logger.log("Removing window data for UUID: \(uuid)", level: .info, category: .tabs)
            fileManager.removeFileAt(path: url)
        }
    }

    // MARK: - URL Utils

    private func windowURLPath(for windowID: UUID, isBackup: Bool) -> URL? {
        guard let baseURL = fileManager.windowDataDirectory(isBackup: isBackup) else { return nil }
        let baseFilePath = filePrefix + windowID.uuidString
        return baseURL.appendingPathComponent(baseFilePath)
    }

    /// For a URL that points to a window tab data file, returns the associated UUID
    /// for that window based on the file name.
    /// - Parameter url: the URL to parse.
    /// - Returns: a window UUID or nil if the URL was invalid.
    nonisolated private func windowUUID(fromURL url: URL) -> WindowUUID? {
        let file = url.lastPathComponent
        guard file.hasPrefix(filePrefix) else { return nil }
        let uuidString = String(file.dropFirst(filePrefix.count))
        return WindowUUID(uuidString: uuidString)
    }
}
