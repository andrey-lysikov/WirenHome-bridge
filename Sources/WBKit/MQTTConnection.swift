//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import NIOCore
import NIOPosix

public struct MQTTSettings: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(host: String = "localhost", port: Int = 1883, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public actor MQTTConnection: MQTTPublisher {
    public nonisolated let events: AsyncStream<MQTTEvent>
    private let continuation: AsyncStream<MQTTEvent>.Continuation
    private let settings: MQTTSettings
    private let clientID: String
    private let subscriptions: [String]
    private var outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    private var connected = false
    private var lastInbound = ContinuousClock.now
    private var lastWrite: Task<Void, any Error>?

    static let keepAlive: UInt16 = 60
    // A larger packet than this is treated as a broken stream, not buffered forever.
    static let maxPacket = 16 * 1024 * 1024

    public init(settings: MQTTSettings, clientID: String, subscriptions: [String]) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.settings = settings
        self.clientID = clientID
        self.subscriptions = subscriptions
    }

    // Keeps the session up, reconnecting after failures until the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            await session()
            try? await Task.sleep(for: .seconds(3))
        }
        continuation.finish()
    }

    // QoS 0: the broker is local, and QoS 1 without a resend store would add nothing.
    public func publish(_ message: MQTTMessage) async {
        guard connected, let outbound else { return }
        do {
            try await send(.publish(topic: message.topic, payload: Array(message.payload.utf8), retain: message.retain, packetID: nil), outbound)
        } catch {
            Log.warning("MQTT publish to \(message.topic) failed: \(error)")
        }
    }

    public func disconnect() async {
        guard let outbound else { return }
        try? await send(.disconnect, outbound)
        outbound.finish()
    }

    private func session() async {
        do {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(5))
                .connect(host: settings.host, port: settings.port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
            try await channel.executeThenClose { inbound, outbound in
                try await self.serve(inbound, outbound)
            }
            Log.warning("MQTT connection closed")
        } catch {
            Log.warning("MQTT connection to \(settings.host):\(settings.port) failed: \(error)")
        }
        outbound = nil
        if connected {
            connected = false
            continuation.yield(.disconnected)
        }
    }

    private func serve(_ inbound: NIOAsyncChannelInboundStream<ByteBuffer>, _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws {
        self.outbound = outbound
        lastInbound = .now
        lastWrite = nil
        try await send(.connect(
            clientID: clientID, username: settings.username, password: settings.password, keepAlive: Self.keepAlive
        ), outbound)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var pending: [UInt8] = []
                for try await chunk in inbound {
                    pending += chunk.readableBytesView
                    guard pending.count <= Self.maxPacket else { throw MQTTPacketError.malformed }
                    while let packet = try MQTTPacket.parse(&pending) {
                        try await self.handle(packet, outbound)
                    }
                    await self.touch()
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(Int(Self.keepAlive) / 2))
                    try await self.ping(outbound)
                }
            }
            // Whichever ends first (stream closed, error, silent broker) ends the session.
            try await group.next()
            group.cancelAll()
        }
    }

    private func handle(_ packet: MQTTPacket, _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws {
        switch packet {
        case .connack(let code):
            guard code == 0 else { throw MQTTPacketError.refused(code) }
            try await send(.subscribe(packetID: 1, filters: subscriptions), outbound)
        case .suback:
            // Retained messages follow the SUBACK, so the bridge hears "connected" before them.
            connected = true
            Log.info("MQTT connected to \(settings.host):\(settings.port)")
            continuation.yield(.connected)
        case .publish(let topic, let payload, let retain, let packetID):
            if let packetID {
                try await send(.puback(packetID: packetID), outbound)
            }
            continuation.yield(.message(MQTTMessage(topic: topic, payload: String(decoding: payload, as: UTF8.self), retain: retain)))
        default:
            break
        }
    }

    private func touch() {
        lastInbound = .now
    }

    private func ping(_ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws {
        guard ContinuousClock.now - lastInbound < .seconds(Int(Self.keepAlive) * 3 / 2) else {
            throw MQTTConnectionError.timeout
        }
        try await send(.pingreq, outbound)
    }

    // Packets go out in call order: two commands to one topic must not swap on the wire.
    private func send(_ packet: MQTTPacket, _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws {
        let previous = lastWrite
        let write = Task {
            _ = try? await previous?.value
            try await outbound.write(Self.buffer(packet))
        }
        lastWrite = write
        try await write.value
    }

    static func buffer(_ packet: MQTTPacket) -> ByteBuffer {
        ByteBuffer(bytes: packet.encoded())
    }
}

public enum MQTTConnectionError: Error, Equatable {
    case timeout
}
