// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

public final class FloorpWorkspacesStore {
    public init(path: String) throws {
        throw FloorpWorkspaceRuntimeError.runtimeUnavailable
    }

    public func bindAccount(uid: String) throws {
        throw FloorpWorkspaceRuntimeError.runtimeUnavailable
    }

    public func invalidate() throws {
        throw FloorpWorkspaceRuntimeError.runtimeUnavailable
    }

    public func snapshotJson() throws -> String {
        throw FloorpWorkspaceRuntimeError.runtimeUnavailable
    }

    public func copyEligibilityJson() throws -> String {
        throw FloorpWorkspaceRuntimeError.runtimeUnavailable
    }

    public func registerWithSyncManager() {
        preconditionFailure("Workspace discovery requires a compatible Application Services runtime")
    }
}
