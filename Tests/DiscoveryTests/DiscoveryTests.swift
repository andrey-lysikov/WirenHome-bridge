//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import Discovery

@Test func encodesTXTRecord() {
    #expect(TXTRecord.encode([("c#", "1"), ("sf", "1")]) == [4, 0x63, 0x23, 0x3D, 0x31, 4, 0x73, 0x66, 0x3D, 0x31])
    #expect(TXTRecord.encode([]) == [])
}

@Test func describesMissingLibrary() {
    #expect(DiscoveryError.libraryMissing("libdns_sd.so.1").description.contains("apt install libavahi-compat-libdnssd1"))
}

#if os(macOS)
@Test func registersAndUpdatesOnMac() throws {
    let advertiser = try ServiceAdvertiser()
    try advertiser.register(name: "WirenHome Test", type: "_wirenhome-test._tcp", port: 50999, txt: [("sf", "1")])
    #expect(advertiser.isRegistered)
    try advertiser.update(txt: [("sf", "0")])
    advertiser.stop()
    #expect(!advertiser.isRegistered)
    #expect(throws: DiscoveryError.notRegistered) { try advertiser.update(txt: []) }
}
#endif
