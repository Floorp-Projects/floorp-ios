// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import TabDataStore
import Common

final class MockTabDataStore: TabDataStore, @unchecked Sendable {
    var fetchWindowDataCalledCount = 0
    var saveWindowDataCalledCount = 0
    var saveWindowDataForcedValue = false
    var fetchTabWindowData: WindowData?
    var saveWindowData: WindowData?
    var clearAllWindowsDataCalled = 0
    var removeWindowDataCalled = 0
    private var persistedTabWindowUUIDs: [UUID] = []
    var durableWorkspaceCopyWindows: [WindowData] = []
    var committedWorkspaceCopyReceipts = Set<UUID>()
    var failWorkspaceCopySaves = false

    enum WorkspaceCopySaveError: Error {
        case injectedFailure
    }

    func fetchWindowDataUUIDs() -> [UUID] {
        return persistedTabWindowUUIDs
    }

    func fetchWindowData(uuid: UUID) async -> WindowData? {
        fetchWindowDataCalledCount += 1
        return fetchTabWindowData
    }

    func saveWindowData(window: WindowData, forced: Bool) async {
        saveWindowDataCalledCount += 1
        saveWindowDataForcedValue = forced
        saveWindowData = window
    }

    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipt: UUID) async throws {
        try await saveWindowDataDurably(window: window, workspaceCopyReceipts: [workspaceCopyReceipt])
    }

    func saveWindowDataDurably(window: WindowData, workspaceCopyReceipts: Set<UUID>) async throws {
        durableWorkspaceCopyWindows.append(window)
        if failWorkspaceCopySaves { throw WorkspaceCopySaveError.injectedFailure }
        committedWorkspaceCopyReceipts.formUnion(workspaceCopyReceipts)
        committedWorkspaceCopyReceipts.formUnion(window.workspaceCopyReceipts ?? [])
    }

    func fetchWorkspaceCopyReceipts(windowID: UUID) async throws -> Set<UUID> {
        committedWorkspaceCopyReceipts
    }

    func clearAllWindowsData() async {
        clearAllWindowsDataCalled += 1
    }

    func removeWindowData(forUUIDs: [WindowUUID]) async {
        removeWindowDataCalled += 1
    }
}

// Utilities for mocking available tab window UUIDs in unit tests.
extension MockTabDataStore {
    func resetMockTabWindowUUIDs() {
        persistedTabWindowUUIDs.removeAll()
    }

    func injectMockTabWindowUUID(_ uuid: UUID) {
        persistedTabWindowUUIDs.append(uuid)
    }
}
