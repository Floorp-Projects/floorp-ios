// swift-tools-version: 5.10
import PackageDescription
import Foundation

let checksum = "08de90069071dbae4e5f0cf83f304ce59f0b3d03ef31b27cb38bf5d3a1ca457d"
let version = "155.0.20260731050244"
let url = "https://github.com/Floorp-Projects/application-services/releases/download/floorp-ios-155.20260731050244.6/MozillaRustComponents.xcframework.zip"

// Focus xcframework
let focusChecksum = "4e6ef6c18cab4e9b3118a5d198f7eb7d1958ec4616a6e56532086e3630c7ba9d"
let focusUrl = "https://github.com/Floorp-Projects/application-services/releases/download/floorp-ios-155.20260731050244.6/FocusRustComponents.xcframework.zip"

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let pinURL = packageDirectory.appendingPathComponent("FloorpApplicationServicesPin.json")
guard let pinData = try? Data(contentsOf: pinURL),
      let pin = (try? JSONSerialization.jsonObject(with: pinData)) as? [String: Any] else {
    fatalError("FloorpApplicationServicesPin.json must be readable and valid JSON")
}
let pinnedWorkspaceSupport = (pin["capabilities"] as? [String: Any])?["floorpWorkspaces"] as? Bool == true
let localMozillaFramework = ProcessInfo.processInfo.environment["FLOORP_APPLICATION_SERVICES_XCFRAMEWORK"]
let mozillaBinaryTarget: Target
if let localMozillaFramework {
    let localURL = URL(fileURLWithPath: localMozillaFramework).standardizedFileURL
    guard localMozillaFramework.hasPrefix("/"), localURL.pathExtension == "xcframework",
          FileManager.default.fileExists(atPath: localURL.appendingPathComponent("Info.plist").path) else {
        fatalError("FLOORP_APPLICATION_SERVICES_XCFRAMEWORK must be an absolute path to an unzipped XCFramework")
    }
    let files = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: nil)
    let containsWorkspaceHeader = files?.contains { item in
        guard let file = item as? URL, file.lastPathComponent == "floorp_workspaces_syncFFI.h",
              let header = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return header.contains("ffi_floorp_workspaces_sync_uniffi_contract_version")
    } ?? false
    guard containsWorkspaceHeader else {
        fatalError("The local XCFramework does not contain the floorp_workspaces_sync UniFFI header")
    }
    let packageParts = packageDirectory.standardizedFileURL.pathComponents
    let frameworkParts = localURL.pathComponents
    let sharedParts = zip(packageParts, frameworkParts).prefix { $0 == $1 }.count
    let relativeParts = Array(repeating: "..", count: packageParts.count - sharedParts)
        + frameworkParts.dropFirst(sharedParts)
    mozillaBinaryTarget = .binaryTarget(name: "MozillaRustComponents", path: relativeParts.joined(separator: "/"))
} else {
    mozillaBinaryTarget = .binaryTarget(name: "MozillaRustComponents", url: url, checksum: checksum)
}
let supportsWorkspaces = localMozillaFramework != nil || pinnedWorkspaceSupport
let excludedMozillaSources = supportsWorkspaces
    ? ["FloorpWorkspaceRuntimeLegacy.swift"]
    : ["Generated/floorp_workspaces_sync.swift"].filter {
        FileManager.default.fileExists(atPath: packageDirectory
            .appendingPathComponent("Sources/MozillaRustComponentsWrapper").appendingPathComponent($0).path)
    }
let mozillaSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .unsafeFlags(["-enable-testing"]),
] + (supportsWorkspaces ? [.define("FLOORP_WORKSPACES_RUNTIME")] : [])

let package = Package(
    name: "MozillaRustComponentsSwift",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MozillaRustComponents", targets: ["MozillaAppServices"]),
        .library(name: "FocusRustComponents", targets: ["FocusAppServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mozilla/glean-swift", from: "69.0.0")
    ],
    targets: [
        // A wrapper around our binary target that combines + any swift files we want to expose to the user
        .target(
            name: "MozillaAppServices",
            dependencies: [
                "MozillaRustComponents", .product(name: "Glean", package: "glean-swift"),
            ],
            path: "Sources/MozillaRustComponentsWrapper",
            exclude: excludedMozillaSources,
            swiftSettings: mozillaSwiftSettings,
        ),
        .target(
            name: "FocusAppServices",
            dependencies: [
                .target(name: "FocusRustComponents", condition: .when(platforms: [.iOS]))
            ],
            path: "Sources/FocusRustComponentsWrapper"
        ),
        mozillaBinaryTarget,
        .binaryTarget(
            name: "FocusRustComponents",
            //
            // For release artifacts, reference the MozillaRustComponents as a URL with checksum.
            // IMPORTANT: The checksum has to be on the line directly after the `url`
            // this is important for our release script so that all values are updated correctly
            url: focusUrl,
            checksum: focusChecksum

                // For local testing, you can point at an (unzipped) XCFramework that's part of the repo.
                // Note that you have to actually check it in and make a tag for it to work correctly.
                //
                //path: "./FocusRustComponents.xcframework"
        ),
        // Tests
        .testTarget(
            name: "MozillaRustComponentsTests",
            dependencies: ["MozillaAppServices"]
        ),
    ]
)
