//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import WBKit

@Test func collectsDeviceFromMessages() throws {
    var registry = DeviceRegistry()
    registry.apply(MQTTMessage(topic: "/devices/relay/meta", payload: #"{"driver":"wb-modbus","title":{"en":"Relay"}}"#))
    registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1/meta", payload: #"{"type":"switch","readonly":false}"#))
    let change = registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1", payload: "1"))

    #expect(change == .value(device: "relay", control: "K1", value: "1"))
    let device = try #require(registry.device("relay"))
    #expect(device.meta?.title == ["en": "Relay"])
    #expect(device.controls["K1"]?.value == "1")
    #expect(device.controls["K1"]?.meta.type == "switch")
}

@Test func ignoresCommands() {
    var registry = DeviceRegistry()
    #expect(registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1/on", payload: "1")) == nil)
    #expect(registry.deviceIDs.isEmpty)
}

@Test func legacyErrorOverridesJSONMeta() {
    var registry = DeviceRegistry()
    registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1/meta", payload: #"{"type":"switch"}"#))
    registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1/meta/error", payload: "r"))
    #expect(registry.control(device: "relay", control: "K1")?.meta.error == "r")
    #expect(registry.control(device: "relay", control: "K1")?.meta.type == "switch")

    registry.apply(MQTTMessage(topic: "/devices/relay/controls/K1/meta/error", payload: ""))
    #expect(registry.control(device: "relay", control: "K1")?.meta.error == nil)
}

@Test func emptyPayloadsRemoveControlAndDevice() {
    var registry = DeviceRegistry()
    registry.apply(MQTTMessage(topic: "/devices/test/controls/role/meta", payload: #"{"type":"value"}"#))
    registry.apply(MQTTMessage(topic: "/devices/test/controls/role", payload: "0"))

    #expect(registry.apply(MQTTMessage(topic: "/devices/test/controls/role", payload: "")) == .meta(device: "test", control: "role"))
    #expect(registry.apply(MQTTMessage(topic: "/devices/test/controls/role/meta", payload: "")) == .removed(device: "test", control: "role"))
    #expect(registry.device("test") == nil)
}
