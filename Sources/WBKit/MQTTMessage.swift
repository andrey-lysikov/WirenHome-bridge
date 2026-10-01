//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public struct MQTTMessage: Sendable, Equatable {
    public let topic: String
    public let payload: String
    public let retain: Bool

    public init(topic: String, payload: String, retain: Bool = true) {
        self.topic = topic
        self.payload = payload
        self.retain = retain
    }
}

public enum MQTTEvent: Sendable, Equatable {
    case connected
    case message(MQTTMessage)
    case disconnected
}

public protocol MQTTPublisher: Sendable {
    func publish(_ message: MQTTMessage) async
}

extension MQTTPublisher {
    public func publish(_ messages: [MQTTMessage]) async {
        for message in messages {
            await publish(message)
        }
    }
}
