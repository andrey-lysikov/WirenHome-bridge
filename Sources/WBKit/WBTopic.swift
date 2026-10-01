//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public enum WBTopic: Sendable, Equatable {
    case deviceMeta(device: String)
    case deviceMetaField(device: String, field: String)
    case controlValue(device: String, control: String)
    case controlMeta(device: String, control: String)
    case controlMetaField(device: String, control: String, field: String)
    case controlCommand(device: String, control: String)

    public init?(_ topic: String) {
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "devices", !parts[2].isEmpty else { return nil }
        let device = parts[2]
        switch (parts.count, parts[3]) {
        case (4, "meta"):
            self = .deviceMeta(device: device)
        case (5, "meta"):
            self = .deviceMetaField(device: device, field: parts[4])
        case (5, "controls"):
            self = .controlValue(device: device, control: parts[4])
        case (6, "controls") where parts[5] == "meta":
            self = .controlMeta(device: device, control: parts[4])
        case (6, "controls") where parts[5] == "on":
            self = .controlCommand(device: device, control: parts[4])
        case (7, "controls") where parts[5] == "meta":
            self = .controlMetaField(device: device, control: parts[4], field: parts[6])
        default:
            return nil
        }
    }

    public var path: String {
        switch self {
        case .deviceMeta(let device):
            "/devices/\(device)/meta"
        case .deviceMetaField(let device, let field):
            "/devices/\(device)/meta/\(field)"
        case .controlValue(let device, let control):
            "/devices/\(device)/controls/\(control)"
        case .controlMeta(let device, let control):
            "/devices/\(device)/controls/\(control)/meta"
        case .controlMetaField(let device, let control, let field):
            "/devices/\(device)/controls/\(control)/meta/\(field)"
        case .controlCommand(let device, let control):
            "/devices/\(device)/controls/\(control)/on"
        }
    }

    // MQTT topic levels must not carry wildcards or separators.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: { $0 == "/" || $0 == "+" || $0 == "#" })
    }
}
