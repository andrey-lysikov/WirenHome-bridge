//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import HAPKit

// Same payload as HAP-NodeJS/homebridge produce for the bridge category and code 031-45-154.
@Test func buildsTheSetupURI() {
    #expect(HAPSetupPayload.uri(setupCode: "031-45-154", setupID: "WB12") == "X-HM://0023ISYWYWB12")
    #expect(HAPSetupPayload.uri(setupCode: "000-00-001", setupID: "0000").count == 20)
}

@Test func hashesSetupIDWithDeviceID() {
    // base64(SHA-512("WB12" + "AA:BB:CC:DD:EE:FF")[0..<4]), computed with Python's hashlib.
    #expect(HAPSetupPayload.setupHash(setupID: "WB12", deviceID: "AA:BB:CC:DD:EE:FF") == "KbhfRg==")
}

@Test func generatesValidSetupIDs() {
    for _ in 0..<100 {
        #expect(HAPSetupPayload.isValidSetupID(HAPSetupPayload.generateSetupID()))
    }
    #expect(!HAPSetupPayload.isValidSetupID("ab12"))
    #expect(!HAPSetupPayload.isValidSetupID("ABCDE"))
}
