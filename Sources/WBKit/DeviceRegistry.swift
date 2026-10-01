//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public struct WBControl: Sendable, Equatable {
    public let id: String
    public let value: String?
    public let meta: WBControlMeta
}

public struct WBDevice: Sendable, Equatable {
    public let id: String
    public let meta: WBDeviceMeta?
    public let controls: [String: WBControl]
}

public enum WBChange: Sendable, Equatable {
    case value(device: String, control: String, value: String)
    case meta(device: String, control: String)
    case removed(device: String, control: String)
    case device(device: String)
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

    private struct DeviceState: Sendable {
        var meta: WBDeviceMeta?
        var controls: [String: ControlState] = [:]
    }

    private var devices: [String: DeviceState] = [:]

    public init() {}

    public var deviceIDs: [String] { devices.keys.sorted() }

    public func device(_ id: String) -> WBDevice? {
        guard let state = devices[id] else { return nil }
        let controls = state.controls.reduce(into: [String: WBControl]()) { result, item in
            result[item.key] = WBControl(id: item.key, value: item.value.value, meta: item.value.meta)
        }
        return WBDevice(id: id, meta: state.meta, controls: controls)
    }

    public func control(device: String, control: String) -> WBControl? {
        guard let state = devices[device]?.controls[control] else { return nil }
        return WBControl(id: control, value: state.value, meta: state.meta)
    }

    // An empty payload clears a retained topic, so the matching part is dropped.
    @discardableResult
    public mutating func apply(_ message: MQTTMessage) -> WBChange? {
        guard let topic = WBTopic(message.topic) else { return nil }
        let payload = message.payload
        switch topic {
        case .deviceMeta(let device):
            devices[device, default: DeviceState()].meta = payload.isEmpty ? nil : WBDeviceMeta.decode(payload)
            cleanUp(device)
            return .device(device: device)
        case .deviceMetaField, .controlCommand:
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
        var state = devices[device, default: DeviceState()].controls[control] ?? ControlState()
        mutate(&state)
        if state.isEmpty {
            let existed = devices[device]?.controls.removeValue(forKey: control) != nil
            cleanUp(device)
            return existed ? .removed(device: device, control: control) : nil
        }
        devices[device, default: DeviceState()].controls[control] = state
        return change(state)
    }

    private mutating func cleanUp(_ device: String) {
        if let state = devices[device], state.meta == nil, state.controls.isEmpty {
            devices.removeValue(forKey: device)
        }
    }
}
