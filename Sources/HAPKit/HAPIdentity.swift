//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto
import Foundation

public struct HAPPairing: Sendable, Equatable, Codable {
    public let identifier: String
    public let publicKey: Data
    public var isAdmin: Bool
}

// Long-term accessory identity and paired controllers; losing it means re-pairing.
public struct HAPIdentity: Sendable, Equatable, Codable {
    public let deviceID: String
    public let privateKey: Data
    public var pairings: [HAPPairing]
    public var configNumber: UInt32

    public static func generate() -> HAPIdentity {
        var generator = SystemRandomNumberGenerator()
        let id = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255, using: &generator)) }.joined(separator: ":")
        return HAPIdentity(deviceID: id, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, pairings: [], configNumber: 1)
    }

    public var isPaired: Bool { !pairings.isEmpty }

    var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) }
    }

    // c# must stay within 1...65535 for older controllers.
    public mutating func bumpConfigNumber() {
        configNumber = configNumber >= 65535 ? 1 : configNumber + 1
    }
}

public protocol HAPStorage: Sendable {
    func load() throws -> HAPIdentity?
    func save(_ identity: HAPIdentity) throws
}

public struct FileHAPStorage: HAPStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> HAPIdentity? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HAPIdentity.self, from: Data(contentsOf: url))
    }

    public func save(_ identity: HAPIdentity) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identity).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
