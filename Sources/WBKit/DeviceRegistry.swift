//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public struct WBControl: Sendable, Equatable {
    public let id: String
    public let value: String?
    public let meta: WBControlMeta
}

public enum WBChange: Sendable, Equatable {
    case value(device: String, control: String, value: String)
    case meta(device: String, control: String)
    case removed(device: String, control: String)
}

// Mirror of /devices/# built from retained and live MQTT messages.
public struct DeviceRegistry: Sendable {
    private struct ControlState: Sendable {
        var value: String?
        var json: WBControlMeta?
        var legacy: [String: String] = [:]

        var isEmpty: Bool { value == nil && json == nil && legacy.isEmpty }

        // JSON meta wins; a separate meta/error topic is still honoured.
        var meta: WBControlMeta {
            var meta = json ?? WBControlMeta(legacy: legacy)
            if let error = legacy["error"] {
                meta.error = error
            }
            if meta.error?.isEmpty == true {
                meta.error = nil
            }
            return meta
        }
    }

    // Controls by device; device meta is not needed by the bridge.
    private var devices: [String: [String: ControlState]] = [:]

    public init() {}

    public var isEmpty: Bool { devices.isEmpty }

    public func control(device: String, control: String) -> WBControl? {
        guard let state = devices[device]?[control] else { return nil }
        return WBControl(id: control, value: state.value, meta: state.meta)
    }

    // An empty payload clears a retained topic, so the matching part is dropped.
    @discardableResult
    public mutating func apply(_ message: MQTTMessage) -> WBChange? {
        guard let topic = WBTopic(message.topic) else { return nil }
        let payload = message.payload
        switch topic {
        case .deviceMeta, .deviceMetaField, .controlCommand:
            return nil
        case .controlValue(let device, let control):
            return update(device, control) { state in
                state.value = payload.isEmpty ? nil : payload
            } change: { state in
                // A cleared value leaves the control without state, reported as a meta change.
                state.value.map { .value(device: device, control: control, value: $0) } ?? .meta(device: device, control: control)
            }
        case .controlMeta(let device, let control):
            return update(device, control) { state in
                state.json = payload.isEmpty ? nil : WBControlMeta.decode(payload)
            } change: { _ in .meta(device: device, control: control) }
        case .controlMetaField(let device, let control, let field):
            return update(device, control) { state in
                state.legacy[field] = payload.isEmpty ? nil : payload
            } change: { _ in .meta(device: device, control: control) }
        }
    }

    private mutating func update(
        _ device: String, _ control: String,
        _ mutate: (inout ControlState) -> Void,
        change: (ControlState) -> WBChange?
    ) -> WBChange? {
        var state = devices[device]?[control] ?? ControlState()
        mutate(&state)
        if state.isEmpty {
            let existed = devices[device]?.removeValue(forKey: control) != nil
            if devices[device]?.isEmpty == true {
                devices.removeValue(forKey: device)
            }
            return existed ? .removed(device: device, control: control) : nil
        }
        devices[device, default: [:]][control] = state
        return change(state)
    }
}
