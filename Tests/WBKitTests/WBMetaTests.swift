//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import WBKit

// Payloads captured from a WB 8.5 controller.
@Test func decodesControlMeta() throws {
    let payload = #"{"max":100.0,"order":26,"readonly":false,"title":{"ru":"Канал 1"},"type":"range"}"#
    let meta = try #require(WBControlMeta.decode(payload))
    #expect(meta.type == "range")
    #expect(meta.readonly == false)
    #expect(meta.max == 100)
    #expect(meta.order == 26)
    #expect(meta.title == ["ru": "Канал 1"])
}

@Test func decodesEnumMeta() throws {
    let payload = #"{"enum":{"0":{"en":"No voltage"},"1":{"en":"Voltage stable"}},"order":32,"readonly":true,"type":"value"}"#
    let meta = try #require(WBControlMeta.decode(payload))
    #expect(meta.enumTitles?["1"] == ["en": "Voltage stable"])
}

@Test func toleratesLooseTypes() throws {
    let meta = try #require(WBControlMeta.decode(#"{"readonly":1,"max":"10","title":"Temp","order":"3"}"#))
    #expect(meta.readonly == true)
    #expect(meta.max == 10)
    #expect(meta.title == ["en": "Temp"])
    #expect(meta.order == 3)
}

@Test func encodesWithEnumKey() throws {
    let meta = WBControlMeta(type: "value", readonly: false, order: 1, enumTitles: ["0": ["ru": "Авто"]])
    let encoded = meta.encoded()
    #expect(encoded.contains(#""enum":{"0":{"ru":"Авто"}}"#))
    #expect(WBControlMeta.decode(encoded) == meta)
}

@Test func buildsFromLegacyFields() {
    let meta = WBControlMeta(legacy: ["type": "switch", "readonly": "1", "order": "4", "error": "r"])
    #expect(meta.type == "switch")
    #expect(meta.readonly == true)
    #expect(meta.order == 4)
    #expect(meta.error == "r")
}

@Test func decodesDeviceMeta() throws {
    let meta = try #require(WBDeviceMeta.decode(#"{"driver":"wb-modbus","title":{"en":"WB-MSW v.4 147"}}"#))
    #expect(meta.driver == "wb-modbus")
    #expect(meta.title == ["en": "WB-MSW v.4 147"])
}
