//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public struct VirtualControl: Sendable, Equatable {
    public let id: String
    public let meta: WBControlMeta
    public let value: String?

    public init(id: String, meta: WBControlMeta, value: String?) {
        self.id = id
        self.meta = meta
        self.value = value
    }
}

// Device published by this process, shown in the WB web UI like any driver's device.
public struct VirtualDevice: Sendable {
    public let id: String
    public let meta: WBDeviceMeta

    public init(id: String, meta: WBDeviceMeta) {
        self.id = id
        self.meta = meta
    }

    public var commandFilter: String { "/devices/\(id)/controls/+/on" }

    public func metaMessage() -> MQTTMessage {
        MQTTMessage(topic: WBTopic.deviceMeta(device: id).path, payload: meta.encoded())
    }

    public func messages(for control: VirtualControl) -> [MQTTMessage] {
        var messages = [MQTTMessage(topic: WBTopic.controlMeta(device: id, control: control.id).path, payload: control.meta.encoded())]
        if let value = control.value {
            messages.append(valueMessage(control.id, value))
        }
        return messages
    }

    public func valueMessage(_ control: String, _ value: String) -> MQTTMessage {
        MQTTMessage(topic: WBTopic.controlValue(device: id, control: control).path, payload: value)
    }

    // Empty retained payloads remove the control from the broker and the UI.
    public func removalMessages(_ control: String) -> [MQTTMessage] {
        [
            MQTTMessage(topic: WBTopic.controlValue(device: id, control: control).path, payload: ""),
            MQTTMessage(topic: WBTopic.controlMeta(device: id, control: control).path, payload: "")
        ]
    }
}
