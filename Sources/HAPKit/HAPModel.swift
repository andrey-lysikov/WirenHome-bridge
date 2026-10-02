//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public enum HAPValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int.self) {
            self = .int(value)
        } else if let value = try? c.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }

    // Controllers send booleans as true/false or 1/0.
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .bool(let value): value ? 1 : 0
        case .int(let value): Double(value)
        case .double(let value): value
        case .string(let value): Double(value)
        case .null: nil
        }
    }
}

public enum HAPStatus: Int, Sendable, Error {
    case success = 0
    case insufficientPrivileges = -70401
    case communicationFailure = -70402
    case busy = -70403
    case readOnly = -70404
    case writeOnly = -70405
    case notificationNotSupported = -70406
    case outOfResources = -70407
    case timeout = -70408
    case notFound = -70409
    case invalidValue = -70410
    case insufficientAuthorization = -70411
}

public enum HAPFormat: String, Sendable, Encodable {
    case bool, uint8, uint16, uint32, uint64, int, float, string, tlv8, data
}

public struct HAPPermissions: OptionSet, Sendable, Encodable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = HAPPermissions(rawValue: 1 << 0)
    public static let write = HAPPermissions(rawValue: 1 << 1)
    public static let events = HAPPermissions(rawValue: 1 << 2)
    public static let hidden = HAPPermissions(rawValue: 1 << 3)

    public static let readEvents: HAPPermissions = [.read, .events]
    public static let readWriteEvents: HAPPermissions = [.read, .write, .events]

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        let names: [(HAPPermissions, String)] = [(.read, "pr"), (.write, "pw"), (.events, "ev"), (.hidden, "hd")]
        try c.encode(names.filter { contains($0.0) }.map(\.1))
    }
}

public struct HAPCharacteristic: Sendable, Encodable {
    public let iid: Int
    public let type: String
    public let format: HAPFormat
    public let permissions: HAPPermissions
    public var value: HAPValue?
    public var unit: String?
    public var minValue: Double?
    public var maxValue: Double?
    public var minStep: Double?
    public var validValues: [Int]?
    public var maxLength: Int?

    public init(
        iid: Int, type: String, format: HAPFormat, permissions: HAPPermissions, value: HAPValue? = nil,
        unit: String? = nil, minValue: Double? = nil, maxValue: Double? = nil, minStep: Double? = nil,
        validValues: [Int]? = nil, maxLength: Int? = nil
    ) {
        self.iid = iid
        self.type = type
        self.format = format
        self.permissions = permissions
        self.value = value
        self.unit = unit
        self.minValue = minValue
        self.maxValue = maxValue
        self.minStep = minStep
        self.validValues = validValues
        self.maxLength = maxLength
    }

    enum CodingKeys: String, CodingKey {
        case iid, type, format, perms, value, unit, minValue, maxValue, minStep
        case validValues = "valid-values"
        case maxLength = "maxLen"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(iid, forKey: .iid)
        try c.encode(type, forKey: .type)
        try c.encode(format, forKey: .format)
        try c.encode(permissions, forKey: .perms)
        // Write-only characteristics must not carry a value.
        if permissions.contains(.read) {
            try c.encode(value ?? .null, forKey: .value)
        }
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(minValue, forKey: .minValue)
        try c.encodeIfPresent(maxValue, forKey: .maxValue)
        try c.encodeIfPresent(minStep, forKey: .minStep)
        try c.encodeIfPresent(validValues, forKey: .validValues)
        try c.encodeIfPresent(maxLength, forKey: .maxLength)
    }
}

public struct HAPService: Sendable, Encodable {
    public let iid: Int
    public let type: String
    public var primary: Bool
    public var hidden: Bool
    public var characteristics: [HAPCharacteristic]
    public var linked: [Int]

    public init(iid: Int, type: String, primary: Bool = false, hidden: Bool = false, characteristics: [HAPCharacteristic], linked: [Int] = []) {
        self.iid = iid
        self.type = type
        self.primary = primary
        self.hidden = hidden
        self.characteristics = characteristics
        self.linked = linked
    }
}

public struct HAPAccessory: Sendable, Encodable {
    public let aid: Int
    public var services: [HAPService]

    public init(aid: Int, services: [HAPService]) {
        self.aid = aid
        self.services = services
    }

    public func characteristic(_ iid: Int) -> HAPCharacteristic? {
        for service in services {
            if let found = service.characteristics.first(where: { $0.iid == iid }) {
                return found
            }
        }
        return nil
    }
}

public struct HAPCharacteristicID: Sendable, Hashable, Comparable {
    public let aid: Int
    public let iid: Int

    public init(aid: Int, iid: Int) {
        self.aid = aid
        self.iid = iid
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.aid, lhs.iid) < (rhs.aid, rhs.iid)
    }
}

public struct HAPConnectionID: Sendable, Hashable {
    let value: Int
}

// The bridge side: accessory database, values and writes.
public protocol HAPAccessoryDelegate: Sendable {
    func accessories() async -> [HAPAccessory]
    func read(_ id: HAPCharacteristicID) async -> Result<HAPValue, HAPStatus>
    func write(_ id: HAPCharacteristicID, value: HAPValue, origin: HAPConnectionID) async -> HAPStatus
    func identify() async
}

// Short forms of Apple-defined UUIDs (base 0000-1000-8000-0026BB765291).
public enum HAPType {
    public enum Service {
        public static let accessoryInformation = "3E"
        public static let protocolInformation = "A2"
        public static let lightbulb = "43"
        public static let `switch` = "49"
        public static let outlet = "47"
        public static let fan = "B7"
        public static let thermostat = "4A"
        public static let windowCovering = "8C"
        public static let garageDoorOpener = "41"
        public static let valve = "D0"
        public static let leakSensor = "83"
        public static let motionSensor = "85"
        public static let contactSensor = "80"
        public static let occupancySensor = "86"
        public static let temperatureSensor = "8A"
        public static let humiditySensor = "82"
        public static let carbonDioxideSensor = "97"
        public static let lightSensor = "84"
        public static let statelessProgrammableSwitch = "89"
    }

    public enum Characteristic {
        public static let identify = "14"
        public static let manufacturer = "20"
        public static let model = "21"
        public static let name = "23"
        public static let serialNumber = "30"
        public static let firmwareRevision = "52"
        public static let version = "37"
        public static let on = "25"
        public static let brightness = "8"
        public static let hue = "13"
        public static let saturation = "2F"
        public static let outletInUse = "26"
        public static let active = "B0"
        public static let rotationSpeed = "29"
        public static let currentTemperature = "11"
        public static let targetTemperature = "35"
        public static let currentHeatingCoolingState = "F"
        public static let targetHeatingCoolingState = "33"
        public static let temperatureDisplayUnits = "36"
        public static let currentPosition = "6D"
        public static let targetPosition = "7C"
        public static let positionState = "72"
        public static let currentDoorState = "E"
        public static let targetDoorState = "32"
        public static let obstructionDetected = "24"
        public static let inUse = "D2"
        public static let valveType = "D5"
        public static let leakDetected = "70"
        public static let motionDetected = "22"
        public static let occupancyDetected = "71"
        public static let contactSensorState = "6A"
        public static let currentRelativeHumidity = "10"
        public static let carbonDioxideDetected = "92"
        public static let carbonDioxideLevel = "93"
        public static let currentAmbientLightLevel = "6B"
        public static let programmableSwitchEvent = "73"
        public static let statusFault = "77"
        public static let configuredName = "E3"
    }

    // Eve app extensions; the Home app ignores them.
    public enum Eve {
        public static let power = "E863F10D-079E-48FF-8F27-9C2605A29F52"
    }
}
