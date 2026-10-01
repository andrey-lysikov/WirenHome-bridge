//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import HAPKit

@Test func encodesAndDecodesSimpleItems() throws {
    let tlv = TLV8([(.state, [1]), (.method, [0])])
    #expect(tlv.encoded() == [0x06, 0x01, 0x01, 0x00, 0x01, 0x00])
    #expect(try TLV8(decoding: tlv.encoded()) == tlv)
    #expect(tlv.byte(.state) == 1)
    #expect(tlv[.salt] == nil)
}

@Test func fragmentsLongValues() throws {
    let key = (0..<384).map { UInt8($0 & 0xFF) }
    let tlv = TLV8([(.publicKey, key), (.state, [2])])
    let bytes = tlv.encoded()
    #expect(bytes[0...1] == [0x03, 0xFF])
    #expect(bytes[257...258] == [0x03, 129])
    #expect(bytes.count == 2 + 255 + 2 + 129 + 3)

    let decoded = try TLV8(decoding: bytes)
    #expect(decoded[.publicKey] == key)
    #expect(decoded.byte(.state) == 2)
}

@Test func exactly255BytesIsFollowedByEmptyFragment() throws {
    let value = [UInt8](repeating: 7, count: 255)
    let bytes = TLV8([(.encryptedData, value)]).encoded()
    #expect(bytes.count == 257)
    #expect(try TLV8(decoding: bytes)[.encryptedData] == value)
}

@Test func keepsEmptyValuesAndSplitsRecords() throws {
    let joined = TLV8.joined([TLV8([(.identifier, [1])]), TLV8([(.identifier, [2])])])
    #expect(joined.encoded() == [0x01, 0x01, 0x01, 0xFF, 0x00, 0x01, 0x01, 0x02])
    let records = try TLV8(decoding: joined.encoded()).split()
    #expect(records.map { $0[.identifier] } == [[1], [2]])
}

@Test func rejectsTruncatedInput() {
    #expect(throws: TLVDecodingError.truncated) { try TLV8(decoding: [0x06, 0x02, 0x01]) }
    #expect(throws: TLVDecodingError.truncated) { try TLV8(decoding: [0x06]) }
}
