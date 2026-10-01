//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import WBKit

@Test(arguments: [
    ("/devices/wb-msw-v4_147/meta", WBTopic.deviceMeta(device: "wb-msw-v4_147")),
    ("/devices/wb-msw-v4_147/meta/name", .deviceMetaField(device: "wb-msw-v4_147", field: "name")),
    ("/devices/wb-msw-v4_147/controls/Air Quality (VOC)", .controlValue(device: "wb-msw-v4_147", control: "Air Quality (VOC)")),
    ("/devices/wb-mr6cv3_46/controls/K1/meta", .controlMeta(device: "wb-mr6cv3_46", control: "K1")),
    ("/devices/wb-mr6cv3_46/controls/K1/meta/error", .controlMetaField(device: "wb-mr6cv3_46", control: "K1", field: "error")),
    ("/devices/wb-mr6cv3_46/controls/K1/on", .controlCommand(device: "wb-mr6cv3_46", control: "K1"))
])
func parsesTopic(topic: String, expected: WBTopic) {
    #expect(WBTopic(topic) == expected)
    #expect(expected.path == topic)
}

@Test(arguments: ["devices/x/meta", "/rpc/v1/confed/Editor/Load", "/devices//meta", "/devices/x/controls", "/devices/x/controls/c/other"])
func rejectsForeignTopic(topic: String) {
    #expect(WBTopic(topic) == nil)
}

@Test func validatesNames() {
    #expect(WBTopic.isValidName("dashboard1"))
    #expect(!WBTopic.isValidName(""))
    #expect(!WBTopic.isValidName("a/b"))
    #expect(!WBTopic.isValidName("a+"))
}
