// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

public enum FloorpWorkspaceRuntimeSupport {
    #if FLOORP_WORKSPACES_RUNTIME
    public static let isAvailable = true
    #else
    public static let isAvailable = false
    #endif
}

public enum FloorpWorkspaceRuntimeError: Error, Sendable {
    case runtimeUnavailable
}
