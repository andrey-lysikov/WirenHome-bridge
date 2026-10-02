//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public enum MQTTPacketError: Error, Equatable {
    case malformed
    case refused(UInt8)
}

// The MQTT 3.1.1 packets the bridge needs; everything else from the broker is skipped.
public enum MQTTPacket: Equatable, Sendable {
    case connect(clientID: String, username: String?, password: String?, keepAlive: UInt16)
    case connack(returnCode: UInt8)
    case publish(topic: String, payload: [UInt8], retain: Bool, packetID: UInt16?)
    case puback(packetID: UInt16)
    case subscribe(packetID: UInt16, filters: [String])
    case suback(packetID: UInt16)
    case pingreq
    case pingresp
    case disconnect
    case other(type: UInt8)

    public func encoded() -> [UInt8] {
        var body: [UInt8] = []
        let header: UInt8
        switch self {
        case .connect(let clientID, let username, let password, let keepAlive):
            header = 0x10
            body += Self.string("MQTT") + [4]
            // Clean session; username and password flags when given.
            var flags: UInt8 = 0x02
            if username != nil { flags |= 0x80 }
            if password != nil { flags |= 0x40 }
            body += [flags] + Self.uint16(keepAlive) + Self.string(clientID)
            if let username { body += Self.string(username) }
            if let password { body += Self.string(password) }
        case .connack(let returnCode):
            header = 0x20
            body = [0, returnCode]
        case .publish(let topic, let payload, let retain, let packetID):
            header = 0x30 | (packetID == nil ? 0 : 0x02) | (retain ? 0x01 : 0)
            body = Self.string(topic) + (packetID.map(Self.uint16) ?? []) + payload
        case .puback(let packetID):
            header = 0x40
            body = Self.uint16(packetID)
        case .subscribe(let packetID, let filters):
            header = 0x82
            body = Self.uint16(packetID)
            for filter in filters {
                body += Self.string(filter) + [0]
            }
        case .suback(let packetID):
            header = 0x90
            body = Self.uint16(packetID) + [0]
        case .pingreq:
            header = 0xC0
        case .pingresp:
            header = 0xD0
        case .disconnect:
            header = 0xE0
        case .other(let type):
            header = type << 4
        }
        return [header] + Self.length(body.count) + body
    }

    // Takes one complete packet off the front of the buffer; nil until enough bytes have arrived.
    public static func parse(_ buffer: inout [UInt8]) throws -> MQTTPacket? {
        guard buffer.count >= 2 else { return nil }
        var length = 0
        var multiplier = 1
        var index = 1
        while true {
            guard index < buffer.count else { return nil }
            guard index <= 4 else { throw MQTTPacketError.malformed }
            let byte = buffer[index]
            length += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            index += 1
            if byte & 0x80 == 0 { break }
        }
        guard buffer.count >= index + length else { return nil }
        let header = buffer[0]
        let body = Array(buffer[index..<(index + length)])
        buffer.removeFirst(index + length)
        return try decode(header: header, body: body)
    }

    static func decode(header: UInt8, body: [UInt8]) throws -> MQTTPacket {
        switch header >> 4 {
        case 2:
            guard body.count == 2 else { throw MQTTPacketError.malformed }
            return .connack(returnCode: body[1])
        case 3:
            guard body.count >= 2 else { throw MQTTPacketError.malformed }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var offset = 2 + topicLength
            guard body.count >= offset else { throw MQTTPacketError.malformed }
            let topic = String(decoding: body[2..<offset], as: UTF8.self)
            var packetID: UInt16?
            if (header >> 1) & 0x03 > 0 {
                guard body.count >= offset + 2 else { throw MQTTPacketError.malformed }
                packetID = UInt16(body[offset]) << 8 | UInt16(body[offset + 1])
                offset += 2
            }
            return .publish(topic: topic, payload: Array(body[offset...]), retain: header & 0x01 != 0, packetID: packetID)
        case 4:
            guard body.count >= 2 else { throw MQTTPacketError.malformed }
            return .puback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]))
        case 9:
            guard body.count >= 3 else { throw MQTTPacketError.malformed }
            return .suback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]))
        case 13:
            return .pingresp
        default:
            return .other(type: header >> 4)
        }
    }

    static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return uint16(UInt16(clamping: bytes.count)) + bytes
    }

    static func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    // Remaining length: 7 bits per byte, high bit means "more follows".
    static func length(_ value: Int) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            result.append(byte)
        } while value > 0
        return result
    }
}
