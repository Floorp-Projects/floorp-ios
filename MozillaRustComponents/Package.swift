// swift-tools-version: 5.10
import PackageDescription

let checksum = "579b00cd5823a94101145a4deef7df44e1eeb3929cbe849f53a0f6d008e6f268"
let version = "155.0.20260731050244"
let url = "https://github.com/Floorp-Projects/application-services/releases/download/floorp-ios-155.20260731050244.4/MozillaRustComponents.xcframework.zip"

// Focus xcframework
let focusChecksum = "d996835e76b7b66e516c4b7ddf6c401d815a1ce60466fbbdca73edd2f2ff2b0a"
let focusUrl = "https://github.com/Floorp-Projects/application-services/releases/download/floorp-ios-155.20260731050244.4/FocusRustComponents.xcframework.zip"

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
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"]),
            ],
        ),
        .target(
            name: "FocusAppServices",
            dependencies: [
                .target(name: "FocusRustComponents", condition: .when(platforms: [.iOS]))
            ],
            path: "Sources/FocusRustComponentsWrapper"
        ),
        .binaryTarget(
            name: "MozillaRustComponents",
            //
            // For release artifacts, reference the MozillaRustComponents as a URL with checksum.
            // IMPORTANT: The checksum has to be on the line directly after the `url`
            // this is important for our release script so that all values are updated correctly
            url: url,
            checksum: checksum

                // For local testing, you can point at an (unzipped) XCFramework that's part of the repo.
                // Note that you have to actually check it in and make a tag for it to work correctly.
                //
                //path: "./MozillaRustComponents.xcframework"
        ),
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
