//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct BridgeState: Sendable, Equatable, Codable {
    public var pinCode: String
    public var dashboards: Set<String>
    public var roles: [String: AccessoryRole]
    var ids = IDAllocator()
    var configuredNames: [String: String] = [:]
    var structure = ""

    public init(pinCode: String = PinCode.generate(), dashboards: Set<String> = [], roles: [String: AccessoryRole] = [:]) {
        self.pinCode = pinCode
        self.dashboards = dashboards
        self.roles = roles
    }

    public func role(of widget: String) -> AccessoryRole {
        roles[widget] ?? .auto
    }

    enum CodingKeys: String, CodingKey {
        case pinCode, dashboards, roles, ids, configuredNames, structure
    }

    // Missing or unknown values fall back to defaults so older files still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pin = try? c.decodeIfPresent(String.self, forKey: .pinCode)
        pinCode = pin.flatMap { PinCode.isValid($0) ? $0 : nil } ?? PinCode.generate()
        dashboards = Set((try? c.decodeIfPresent([String].self, forKey: .dashboards)) ?? [])
        let rawRoles = (try? c.decodeIfPresent([String: String].self, forKey: .roles)) ?? [:]
        roles = rawRoles.compactMapValues(AccessoryRole.init(rawValue:))
        ids = (try? c.decodeIfPresent(IDAllocator.self, forKey: .ids)) ?? IDAllocator()
        configuredNames = (try? c.decodeIfPresent([String: String].self, forKey: .configuredNames)) ?? [:]
        structure = (try? c.decodeIfPresent(String.self, forKey: .structure)) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pinCode, forKey: .pinCode)
        try c.encode(dashboards.sorted(), forKey: .dashboards)
        try c.encode(roles.mapValues(\.rawValue), forKey: .roles)
        try c.encode(ids, forKey: .ids)
        try c.encode(configuredNames, forKey: .configuredNames)
        try c.encode(structure, forKey: .structure)
    }
}

public struct StateStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var file: URL { directory.appendingPathComponent("state.json") }

    public func load() throws -> BridgeState? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(BridgeState.self, from: Data(contentsOf: file))
    }

    // Written atomically and readable by root only: it will hold pairing keys.
    public func save(_ state: BridgeState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
