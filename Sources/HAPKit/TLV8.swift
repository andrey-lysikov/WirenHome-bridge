//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public enum TLVType: UInt8, Sendable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
}

public enum TLVError: UInt8, Sendable {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

public enum TLVDecodingError: Error, Equatable {
    case truncated
}

// Type-length-value list; values over 255 bytes are split into consecutive same-type fragments.
public struct TLV8: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let type: UInt8
        public let value: [UInt8]
    }

    public private(set) var items: [Item] = []

    public init() {}

    public init(_ pairs: [(TLVType, [UInt8])]) {
        for (type, value) in pairs {
            append(type, value)
        }
    }

    public init(decoding bytes: [UInt8]) throws {
        var index = 0
        var lastFragmentFull = false
        while index < bytes.count {
            guard index + 2 <= bytes.count else { throw TLVDecodingError.truncated }
            let type = bytes[index]
            let length = Int(bytes[index + 1])
            guard index + 2 + length <= bytes.count else { throw TLVDecodingError.truncated }
            let value = Array(bytes[(index + 2)..<(index + 2 + length)])
            if lastFragmentFull, let last = items.last, last.type == type {
                items[items.count - 1] = Item(type: type, value: last.value + value)
            } else {
                items.append(Item(type: type, value: value))
            }
            lastFragmentFull = length == 255
            index += 2 + length
        }
    }

    public mutating func append(_ type: TLVType, _ value: [UInt8]) {
        items.append(Item(type: type.rawValue, value: value))
    }

    public mutating func append(_ type: TLVType, byte: UInt8) {
        append(type, [byte])
    }

    public subscript(_ type: TLVType) -> [UInt8]? {
        items.first { $0.type == type.rawValue }?.value
    }

    public func byte(_ type: TLVType) -> UInt8? {
        self[type]?.first
    }

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        for item in items {
            var offset = 0
            repeat {
                let chunk = min(255, item.value.count - offset)
                bytes.append(item.type)
                bytes.append(UInt8(chunk))
                bytes.append(contentsOf: item.value[offset..<(offset + chunk)])
                offset += chunk
            } while offset < item.value.count
        }
        return bytes
    }

    // Lists such as ListPairings separate records with an empty separator item.
    public static func joined(_ records: [TLV8]) -> TLV8 {
        var result = TLV8()
        for (index, record) in records.enumerated() {
            if index > 0 {
                result.append(.separator, [])
            }
            result.items.append(contentsOf: record.items)
        }
        return result
    }

    public func split() -> [TLV8] {
        var records = [TLV8()]
        for item in items {
            if item.type == TLVType.separator.rawValue {
                records.append(TLV8())
            } else {
                records[records.count - 1].items.append(item)
            }
        }
        return records
    }
}
