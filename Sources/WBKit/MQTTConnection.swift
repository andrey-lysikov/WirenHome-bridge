//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import MQTTNIO
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
    private let will: MQTTMessage?
    private var client: MQTTClient?

    public init(settings: MQTTSettings, clientID: String, subscriptions: [String], will: MQTTMessage?) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.settings = settings
        self.clientID = clientID
        self.subscriptions = subscriptions
        self.will = will
    }

    // Keeps the session up, reconnecting after failures until the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            await session()
            try? await Task.sleep(for: .seconds(3))
        }
        continuation.finish()
    }

    public func publish(_ message: MQTTMessage) async {
        guard let client else { return }
        do {
            try await client.publish(to: message.topic, payload: ByteBuffer(string: message.payload), qos: .atLeastOnce, retain: message.retain)
        } catch {
            Log.warning("MQTT publish to \(message.topic) failed: \(error)")
        }
    }

    public func disconnect() async {
        guard let client else { return }
        try? await client.disconnect()
    }

    private func session() async {
        let client = MQTTClient(
            host: settings.host,
            port: settings.port,
            identifier: clientID,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(userName: settings.username, password: settings.password)
        )
        do {
            let will = self.will.map { (topicName: $0.topic, payload: ByteBuffer(string: $0.payload), qos: MQTTQoS.atLeastOnce, retain: $0.retain) }
            try await client.connect(cleanSession: true, will: will)
            // Listener goes first so retained messages sent right after SUBACK are not lost.
            let listener = client.createPublishListener()
            _ = try await client.subscribe(to: subscriptions.map { MQTTSubscribeInfo(topicFilter: $0, qos: .atLeastOnce) })
            self.client = client
            Log.info("MQTT connected to \(settings.host):\(settings.port)")
            continuation.yield(.connected)
            for await result in listener {
                if case .success(let info) = result {
                    continuation.yield(.message(MQTTMessage(topic: info.topicName, payload: String(buffer: info.payload), retain: info.retain)))
                }
            }
            Log.warning("MQTT connection closed")
        } catch {
            Log.warning("MQTT connection to \(settings.host):\(settings.port) failed: \(error)")
        }
        if self.client != nil {
            self.client = nil
            continuation.yield(.disconnected)
        }
        try? await client.shutdown()
    }
}
