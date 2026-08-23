// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

/// A permission category shown before a bundled package is enabled.
///
/// The UI deliberately uses these product-level categories rather than raw
/// manifest permission strings so the confirmation remains understandable.
enum FloorpWebExtensionPermissionCategory: String, CaseIterable, Hashable, Sendable {
    case siteData
    case tabs
    case storage
    case networkBlocking
    case browserAutomation

    var title: String {
        switch self {
        case .siteData:
            return "Read and change data on selected sites"
        case .tabs:
            return "Read tab metadata and open or reload tabs"
        case .storage:
            return "Store extension settings on this device"
        case .networkBlocking:
            return "Block supported network requests"
        case .browserAutomation:
            return "Run approved page scripts and styles"
        }
    }
}

/// Immutable product metadata for a package that ships inside the app bundle.
///
/// This is intentionally separate from an installed package record.  The
/// catalog describes provenance and requested capabilities before installation;
/// the package store owns all mutable install state.
struct FloorpWebExtensionBundledCatalogItem: Hashable, Sendable, Identifiable {
    let id: FloorpWebExtensionID
    let name: String
    let version: String
    let summary: String
    let source: String
    let license: String
    let packageDirectoryName: String
    let requestedPermissions: [FloorpWebExtensionPermissionCategory]

    /// Resolves the directory after the fixture has been copied as a folder
    /// resource into the application bundle.  It intentionally only accepts
    /// the actual bundle resource location so missing resources fail closed.
    func packageURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: packageDirectoryName, withExtension: nil)
    }
}

enum FloorpWebExtensionBundledCatalog {
    static let demandingMV3Fixture = FloorpWebExtensionBundledCatalogItem(
        id: FloorpWebExtensionID(rawValue: "floorp.fixture.demanding-mv3")!,
        name: "Floorp MV3 Compatibility Fixture",
        version: "1.0.0",
        summary: "Tests supported content scripts, cosmetic filtering, and safe network blocking.",
        source: "Floorp iOS compatibility fixture",
        license: "MPL-2.0",
        packageDirectoryName: "demanding-mv3",
        requestedPermissions: [.siteData, .tabs, .storage, .networkBlocking, .browserAutomation]
    )

    /// The App Store MVP intentionally exposes only pinned bundled packages.
    /// Remote sources and arbitrary file import remain independently gated.
    static let items = [demandingMV3Fixture]
}
