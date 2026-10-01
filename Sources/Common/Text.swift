//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

// Small string helpers so the bridge needs only FoundationEssentials, not full Foundation.
extension StringProtocol {
    public var trimmed: String {
        String(drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }

    // %XX sequences decoded as UTF-8; nil when a sequence is malformed.
    public var percentDecoded: String? {
        var bytes: [UInt8] = []
        var iterator = utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next(), let low = iterator.next(),
                  let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
            else {
                return nil
            }
            bytes.append(value)
        }
        return String(validating: bytes, as: UTF8.self)
    }
}

extension UInt8 {
    public var hex: String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(self >> 4)], digits[Int(self & 0x0F)]])
    }
}
