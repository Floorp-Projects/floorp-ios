#!/usr/bin/env python3
"""Run actual receive-model/provider and legacy-runtime XCTest cases on macOS.

The app coordinator and UIKit still require Client simulator tests. The store
interface is injected in these tests, so no account or network is used.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WorkspaceDiscoveryTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "WorkspaceDiscovery", path: "Discovery"),
    .target(name: "RuntimeCompatibility", path: "Runtime"),
    .testTarget(name: "WorkspaceDiscoveryTests", dependencies: ["WorkspaceDiscovery"], path: "DiscoveryTests"),
    .testTarget(name: "RuntimeCompatibilityTests", dependencies: ["RuntimeCompatibility"], path: "RuntimeTests")
])
"""
INTERFACE = """
enum ServiceStatus: Sendable { case ok, networkError }
protocol FloorpWorkspaceSyncEngineProviding: AnyObject, Sendable {
    func prepare(accountID: String) throws -> UInt64
    func didFinishSync(successful: Bool, status: ServiceStatus, generation: UInt64)
    func suspend()
    func clear() throws
}
"""
RUNTIME_TEST = """import XCTest
import RuntimeCompatibility
final class RuntimeCompatibilityTests: XCTestCase {
    func testLegacyRuntimeCannotCreateAStore() {
        XCTAssertFalse(FloorpWorkspaceRuntimeSupport.isAvailable)
        XCTAssertThrowsError(try FloorpWorkspacesStore(path: "/unused")) {
            guard case FloorpWorkspaceRuntimeError.runtimeUnavailable = $0 else {
                return XCTFail("Expected explicit unavailable-runtime failure")
            }
        }
    }
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="floorp-workspace-discovery-tests-") as temporary:
        package = Path(temporary)
        for directory in ["Discovery", "Runtime", "DiscoveryTests", "RuntimeTests"]:
            (package / directory).mkdir()
        (package / "Package.swift").write_text(MANIFEST)
        source = (ROOT / "firefox-ios/Floorp/FloorpWorkspaceDiscovery.swift").read_text()
        source = source.split("@MainActor\nfinal class FloorpWorkspaceDiscoveryCoordinator", 1)[0]
        for module in ["Account", "MozillaAppServices", "Shared", "UIKit"]:
            source = source.replace(f"import {module}\n", "")
        source = source.replace("extension FloorpWorkspacesStore: FloorpWorkspaceStoreProtocol {}", "")
        (package / "Discovery/Discovery.swift").write_text(source + INTERFACE)
        tests = (ROOT / "firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpWorkspaceDiscoveryTests.swift").read_text()
        tests = tests.replace("import MozillaAppServices\n", "")
        tests = tests.replace("@testable import Client", "@testable import WorkspaceDiscovery")
        (package / "DiscoveryTests/DiscoveryTests.swift").write_text(tests)
        runtime = ROOT / "MozillaRustComponents/Sources/MozillaRustComponentsWrapper"
        for name in ["FloorpWorkspaceRuntimeSupport.swift", "FloorpWorkspaceRuntimeLegacy.swift"]:
            shutil.copy2(runtime / name, package / "Runtime" / name)
        (package / "RuntimeTests/RuntimeTests.swift").write_text(RUNTIME_TEST)
        subprocess.run(["swift", "test", "--package-path", str(package)], check=True)


if __name__ == "__main__":
    main()
