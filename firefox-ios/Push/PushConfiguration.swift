// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

import enum MozillaAppServices.BridgeType
import enum MozillaAppServices.PushHttpProtocol
import struct MozillaAppServices.PushConfiguration

public struct KnownPushHost {
    public static let prod = "updates.push.services.mozilla.com"
    public static let stage = "updates-autopush.stage.mozaws.net"
}

enum PushConfigurationError: Error {
    case unsupportedBundleIdentifier(String)
}

public enum PushConfigurationLabel: String {
    case fennec = "fennec"
    case fennecEnterprise = "fennecenterprise"
    case firefoxBeta = "firefoxbeta"
    case firefox = "firefox"

    static func fromBundleIdentifier(_ bundleIdentifier: String) throws -> PushConfigurationLabel {
        let applicationBundleLabels: [(bundleIdentifier: String, label: PushConfigurationLabel)] = [
            ("org.mozilla.ios.Fennec", .fennec),
            ("org.mozilla.ios.FennecEnterprise", .fennecEnterprise),
            ("org.mozilla.ios.FirefoxBeta", .firefoxBeta),
            ("org.mozilla.ios.Firefox", .firefox)
        ]

        let applicationBundleLabel = applicationBundleLabels.first { applicationBundleLabel in
            let applicationBundleIdentifier = applicationBundleLabel.bundleIdentifier
            return bundleIdentifier == applicationBundleIdentifier
                || bundleIdentifier.hasPrefix("\(applicationBundleIdentifier).")
        }
        guard let applicationBundleLabel else {
            throw PushConfigurationError.unsupportedBundleIdentifier(bundleIdentifier)
        }

        return applicationBundleLabel.label
    }

    public func toConfiguration(dbPath: String) -> PushConfiguration {
        return PushConfiguration(
            serverHost: KnownPushHost.prod,
            httpProtocol: PushHttpProtocol.https,
            bridgeType: BridgeType.apns,
            senderId: self.rawValue,
            databasePath: dbPath,
            verifyConnectionRateLimiter: nil
        )
    }

    public func toStagingConfiguration(dbPath: String) -> PushConfiguration {
        return PushConfiguration(
            serverHost: KnownPushHost.stage,
            httpProtocol: PushHttpProtocol.https,
            bridgeType: BridgeType.apns,
            senderId: self.rawValue,
            databasePath: dbPath,
            verifyConnectionRateLimiter: nil
        )
    }

    public func toLocalConfiguration(host: String, dbPath: String) -> PushConfiguration {
        return PushConfiguration(
            serverHost: host,
            httpProtocol: PushHttpProtocol.http,
            bridgeType: BridgeType.apns,
            senderId: self.rawValue,
            databasePath: dbPath,
            verifyConnectionRateLimiter: nil
        )
    }
}
