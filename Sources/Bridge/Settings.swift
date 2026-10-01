//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import WBKit

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case badValue(String, String)
    case unreadableConfig(String, String)

    public var description: String {
        switch self {
        case .unknownArgument(let arg): "Unknown argument \(arg)"
        case .missingValue(let arg): "Missing value for \(arg)"
        case .badValue(let arg, let value): "Bad value '\(value)' for \(arg)"
        case .unreadableConfig(let path, let reason): "Cannot read config \(path): \(reason)"
        }
    }
}

public struct Settings: Sendable, Equatable {
    public static let defaultConfigPath = "/etc/wb-homekit.conf"

    // Fixed on the controller so pairing data is always found after a firmware reflash; --data-dir is for development.
    public static var defaultDataDirectory: String {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WirenHome").path
        #else
        "/mnt/data/wb-homekit"
        #endif
    }

    public var mqtt = MQTTSettings()
    public var dataDirectory = Settings.defaultDataDirectory

    public init() {}

    // Config file first, then command line overrides it.
    public static func load(arguments: [String]) throws -> Settings {
        var settings = Settings()
        var overrides: [(String, String)] = []
        var configPath = defaultConfigPath
        var explicitConfig = false

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            guard ["--config", "--mqtt-host", "--mqtt-port", "--mqtt-user", "--mqtt-password", "--data-dir"].contains(arg) else {
                throw SettingsError.unknownArgument(arg)
            }
            guard let value = iterator.next() else { throw SettingsError.missingValue(arg) }
            if arg == "--config" {
                configPath = value
                explicitConfig = true
            } else {
                overrides.append((arg, value))
            }
        }

        if FileManager.default.fileExists(atPath: configPath) {
            try settings.apply(file: configPath)
        } else if explicitConfig {
            throw SettingsError.unreadableConfig(configPath, "file not found")
        }

        for (arg, value) in overrides {
            switch arg {
            case "--mqtt-host": settings.mqtt.host = value
            case "--mqtt-port":
                guard let port = Int(value), (1...65535).contains(port) else { throw SettingsError.badValue(arg, value) }
                settings.mqtt.port = port
            case "--mqtt-user": settings.mqtt.username = value.isEmpty ? nil : value
            case "--mqtt-password": settings.mqtt.password = value.isEmpty ? nil : value
            default: settings.dataDirectory = value
            }
        }
        return settings
    }

    private mutating func apply(file path: String) throws {
        let file: ConfigFile
        do {
            file = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw SettingsError.unreadableConfig(path, "\(error)")
        }
        if let host = file.mqtt?.host, !host.isEmpty { mqtt.host = host }
        if let port = file.mqtt?.port { mqtt.port = port }
        if let user = file.mqtt?.username, !user.isEmpty { mqtt.username = user }
        if let password = file.mqtt?.password, !password.isEmpty { mqtt.password = password }
    }

    private struct ConfigFile: Decodable {
        struct MQTT: Decodable {
            let host: String?
            let port: Int?
            let username: String?
            let password: String?
        }

        let mqtt: MQTT?
    }
}
