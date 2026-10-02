//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import NIOCore
import NIOPosix
import Testing
@testable import WBKit

@Test func encodesConnectAsInTheSpec() {
    // MQTT 3.1.1 §3.1: protocol "MQTT" level 4, clean session, keep alive 60, client id "c".
    #expect(MQTTPacket.connect(clientID: "c", username: nil, password: nil, keepAlive: 60).encoded()
        == [0x10, 13, 0, 4, 0x4D, 0x51, 0x54, 0x54, 4, 0x02, 0, 60, 0, 1, 0x63])
    let auth = MQTTPacket.connect(clientID: "c", username: "u", password: "p", keepAlive: 60).encoded()
    #expect(auth[9] == 0xC2)
    #expect(auth.suffix(6) == [0, 1, 0x75, 0, 1, 0x70])
}

@Test func encodesSubscribeAndControlPackets() {
    #expect(MQTTPacket.subscribe(packetID: 1, filters: ["/d/#"]).encoded() == [0x82, 9, 0, 1, 0, 4, 0x2F, 0x64, 0x2F, 0x23, 0])
    #expect(MQTTPacket.pingreq.encoded() == [0xC0, 0])
    #expect(MQTTPacket.disconnect.encoded() == [0xE0, 0])
    #expect(MQTTPacket.puback(packetID: 0x1234).encoded() == [0x40, 2, 0x12, 0x34])
}

@Test func parsesPacketsAcrossChunks() throws {
    let payload = [UInt8](repeating: 0x41, count: 200)
    let publish = MQTTPacket.publish(topic: "/devices/a/controls/b", payload: payload, retain: true, packetID: 7)
    let bytes = publish.encoded() + MQTTPacket.pingresp.encoded()
    // 200-byte payload needs a two-byte remaining length.
    #expect(bytes[1] & 0x80 != 0)

    var buffer = Array(bytes.prefix(10))
    #expect(try MQTTPacket.parse(&buffer) == nil)
    buffer += bytes.dropFirst(10)
    #expect(try MQTTPacket.parse(&buffer) == publish)
    #expect(try MQTTPacket.parse(&buffer) == .pingresp)
    #expect(buffer.isEmpty)
}

@Test func rejectsAnOverlongLength() {
    var buffer: [UInt8] = [0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    #expect(throws: MQTTPacketError.malformed) { try MQTTPacket.parse(&buffer) }
}

// A broker that accepts, acknowledges the subscription, sends one retained message and records what it gets.
private actor FakeBroker {
    private(set) var received: [MQTTPacket] = []

    func record(_ packet: MQTTPacket) {
        received.append(packet)
    }

    func start() async throws -> Int {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
                }
            }
        let port = server.channel.localAddress!.port!
        Task {
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    try await connection.executeThenClose { inbound, outbound in
                        var pending: [UInt8] = []
                        for try await chunk in inbound {
                            pending += chunk.readableBytesView
                            while let packet = try MQTTPacket.parse(&pending) {
                                await self.record(packet)
                                switch packet {
                                case .other(type: 1):
                                    try await outbound.write(ByteBuffer(bytes: MQTTPacket.connack(returnCode: 0).encoded()))
                                case .other(type: 8):
                                    try await outbound.write(ByteBuffer(bytes: MQTTPacket.suback(packetID: 1).encoded()))
                                    let retained = MQTTPacket.publish(topic: "/devices/a/controls/b", payload: Array("21.5".utf8), retain: true, packetID: 3)
                                    try await outbound.write(ByteBuffer(bytes: retained.encoded()))
                                default:
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
        return port
    }
}

@Test func connectsSubscribesAndExchangesMessages() async throws {
    let broker = FakeBroker()
    let port = try await broker.start()
    let connection = MQTTConnection(settings: MQTTSettings(host: "127.0.0.1", port: port), clientID: "test", subscriptions: ["/devices/#"])
    let run = Task { await connection.run() }
    defer { run.cancel() }

    var events = connection.events.makeAsyncIterator()
    #expect(await events.next() == .connected)
    #expect(await events.next() == .message(MQTTMessage(topic: "/devices/a/controls/b", payload: "21.5", retain: true)))

    await connection.publish(MQTTMessage(topic: "/devices/a/controls/b/on", payload: "1", retain: false))
    await connection.disconnect()
    try await Task.sleep(for: .milliseconds(200))
    let received = await broker.received
    // CONNECT and SUBSCRIBE come back as "other" (the client never parses them), then PUBACK, PUBLISH, DISCONNECT.
    #expect(received.contains(.puback(packetID: 3)))
    #expect(received.contains(.publish(topic: "/devices/a/controls/b/on", payload: Array("1".utf8), retain: false, packetID: nil)))
    #expect(received.last == .other(type: 14))
}
