//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import Bridge

@Test func commandLineOverridesConfigFile() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("wirenhome-bridge.conf")
    try Data(#"{"advanced":{"mqtt":{"host":"wb.local","port":1884,"username":"bridge","password":"secret"}},"dataDirectory":"/srv/hk"}"#.utf8).write(to: config)

    let settings = try Settings.load(arguments: ["--config", config.path, "--mqtt-host", "172.30.212.48"])
    #expect(settings.mqtt.host == "172.30.212.48")
    #expect(settings.mqtt.port == 1884)
    #expect(settings.mqtt.username == "bridge")
    #expect(settings.mqtt.password == "secret")
    // The data directory is not configurable from the file.
    #expect(settings.dataDirectory == Settings.defaultDataDirectory)
}

@Test func emptyCredentialsMeanAnonymous() throws {
    let settings = try Settings.load(arguments: ["--mqtt-user", "", "--mqtt-password", ""])
    #expect(settings.mqtt.username == nil)
    #expect(settings.mqtt.password == nil)
}

@Test func rejectsBadArguments() {
    #expect(throws: SettingsError.unknownArgument("--verbose")) { try Settings.load(arguments: ["--verbose"]) }
    #expect(throws: SettingsError.missingValue("--mqtt-host")) { try Settings.load(arguments: ["--mqtt-host"]) }
    #expect(throws: SettingsError.badValue("--mqtt-port", "70000")) { try Settings.load(arguments: ["--mqtt-port", "70000"]) }
    #expect(throws: SettingsError.unreadableConfig("/nonexistent.conf", "file not found")) {
        try Settings.load(arguments: ["--config", "/nonexistent.conf"])
    }
}

@Test func readsTheBrokerFromTheAdvancedSection() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("wirenhome-bridge.conf")
    try Data(#"{"pairing":{"reset":false},"advanced":{"mqtt":{"host":"wb.local","port":1884}}}"#.utf8).write(to: config)

    let settings = try Settings.load(arguments: ["--config", config.path])
    #expect(settings.mqtt.host == "wb.local")
    #expect(settings.mqtt.port == 1884)
    #expect(settings.configPath == config.path)
}
