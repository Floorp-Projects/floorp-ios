#!/usr/bin/env python3
"""Run the production workspace copy core and persistence XCTest cases on macOS.

UIKit adapters still require the Client simulator target. Only the unrelated
Common logging/app-group configuration dependency is replaced in this harness.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WorkspaceCopyTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Common", path: "Common"),
    .target(name: "TabDataStore", dependencies: ["Common"], path: "TabDataStore"),
    .testTarget(name: "WorkspaceCopyTests", path: "CopyTests"),
    .testTarget(name: "PersistenceTests", dependencies: ["TabDataStore"], path: "PersistenceTests")
])
"""
COMMON = """import Foundation
public typealias WindowUUID = UUID
public enum LoggerLevel { case debug, info, warning, fatal }
public enum LoggerCategory { case tabs }
public protocol Logger: Sendable {
    func log(_ message: String, level: LoggerLevel, category: LoggerCategory, extra: [String: String]?)
}
public extension Logger {
    func log(_ message: String, level: LoggerLevel, category: LoggerCategory, extra: [String: String]? = nil) {}
}
public struct DefaultLogger: Logger {
    public static let shared = DefaultLogger()
}
public final class BrowserKitInformation: @unchecked Sendable {
    public static let shared = BrowserKitInformation()
    public var sharedContainerIdentifier: String?
}
extension FileManager: @unchecked @retroactive Sendable {}
"""


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="floorp-workspace-copy-tests-") as temporary:
        package = Path(temporary)
        for directory in ["Common", "TabDataStore", "CopyTests", "PersistenceTests"]:
            (package / directory).mkdir()
        (package / "Package.swift").write_text(MANIFEST)
        (package / "Common/Common.swift").write_text(COMMON)
        for name in ["TabDataStore.swift", "TabData.swift", "WindowData.swift", "TabFileManager.swift"]:
            shutil.copy2(ROOT / "BrowserKit/Sources/TabDataStore" / name, package / "TabDataStore" / name)
        shutil.copy2(ROOT / "firefox-ios/Floorp/FloorpWorkspaceCopyService.swift", package / "CopyTests")
        shutil.copy2(ROOT / "firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpWorkspaceCopyTests.swift",
                     package / "CopyTests")
        shutil.copy2(ROOT / "BrowserKit/Tests/TabDataStoreTests/WorkspaceCopyPersistenceTests.swift",
                     package / "PersistenceTests")
        subprocess.run(["swift", "test", "--package-path", str(package)], check=True)


if __name__ == "__main__":
    main()
