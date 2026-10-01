//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import HAPKit
import WBKit

// Stable HAP ids across restarts and edits, so HomeKit automations keep working.
struct IDAllocator: Sendable, Equatable, Codable {
    var accessories: [String: Int] = [:]
    var characteristics: [String: [String: Int]] = [:]

    mutating func aid(_ widget: String) -> Int {
        if let aid = accessories[widget] { return aid }
        let aid = max(1, accessories.values.max() ?? 1) + 1
        accessories[widget] = aid
        return aid
    }

    // iids 1-7 are reserved for the accessory information service.
    mutating func iid(_ widget: String, _ key: String) -> Int {
        if let iid = characteristics[widget]?[key] { return iid }
        let iid = max(7, characteristics[widget]?.values.max() ?? 7) + 1
        characteristics[widget, default: [:]][key] = iid
        return iid
    }

    mutating func prune(keeping widgets: Set<String>) {
        accessories = accessories.filter { widgets.contains($0.key) }
        characteristics = characteristics.filter { widgets.contains($0.key) }
    }
}

struct Mapping: Sendable {
    var accessories: [HAPAccessory] = []
    var sources: [HAPCharacteristicID: Source] = [:]
    var issues: [WidgetIssue] = []

    // Hash of the structure without values; a change means controllers must refetch /accessories.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(accessories)) ?? Data()
        // FNV-1a: stable across runs, unlike Hasher.
        let hash = bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

struct AccessoryMapper {
    static let maxAccessories = 149

    struct Spec {
        let type: String
        let format: HAPFormat
        let permissions: HAPPermissions
        let source: Source
        var unit: String?
        var min: Double?
        var max: Double?
        var step: Double?
        var valid: [Int]?
    }

    var ids: IDAllocator
    let kinds: (Cell) -> CellKind?
    let version: String
    private(set) var mapping = Mapping()

    init(ids: IDAllocator, version: String, kinds: @escaping (Cell) -> CellKind?) {
        self.ids = ids
        self.version = version
        self.kinds = kinds
    }

    mutating func map(widgets: [WebUIConfig.Widget], roles: [String: AccessoryRole], bridge: HAPAccessory) {
        mapping = Mapping(accessories: [bridge])
        for widget in widgets {
            guard mapping.accessories.count <= Self.maxAccessories else {
                mapping.issues.append(WidgetIssue(widget: nil, issue: .limitReached(Self.maxAccessories)))
                break
            }
            let name = NameSanitizer.clean(widget.name)
            guard !name.isEmpty else {
                mapping.issues.append(WidgetIssue(widget: widget.id, issue: .unusableName))
                continue
            }
            map(widget, name: name, role: roles[widget.id] ?? .auto)
        }
        ids.prune(keeping: Set(widgets.map(\.id)))
    }

    private mutating func map(_ widget: WebUIConfig.Widget, name: String, role: AccessoryRole) {
        var cells: [(cell: Cell, name: String, kind: CellKind)] = []
        for item in widget.cells where WBTopic.isValidName(item.device) && WBTopic.isValidName(item.control) {
            let cell = Cell(device: item.device, control: item.control)
            guard let kind = kinds(cell) else {
                mapping.issues.append(WidgetIssue(widget: widget.id, issue: .missingDevice(cell.id)))
                continue
            }
            cells.append((cell, NameSanitizer.clean(item.name).isEmpty ? name : NameSanitizer.clean(item.name), kind))
        }

        var builder = Builder(widget: widget.id, name: name, ids: ids)
        var roleIssue: RoleProblem?
        switch role {
        case .auto, .info:
            for item in cells {
                builder.addCell(item.cell, name: item.name, kind: item.kind, readOnly: role == .info)
            }
        default:
            roleIssue = builder.addRole(role, cells: cells)
            if let roleIssue {
                mapping.issues.append(WidgetIssue(widget: widget.id, issue: .roleMismatch(role, roleIssue)))
                builder = Builder(widget: widget.id, name: name, ids: ids)
                for item in cells {
                    builder.addCell(item.cell, name: item.name, kind: item.kind, readOnly: false)
                }
            }
        }
        ids = builder.ids
        guard !builder.services.isEmpty else {
            mapping.issues.append(WidgetIssue(widget: widget.id, issue: .nothingToShow))
            return
        }

        let aid = ids.aid(widget.id)
        let model = cells.first?.cell.device ?? "Wiren Board"
        var services = [Self.information(name: name, model: model, serial: widget.id, version: version)]
        services += builder.services
        mapping.accessories.append(HAPAccessory(aid: aid, services: services))
        for (iid, source) in builder.sources {
            mapping.sources[HAPCharacteristicID(aid: aid, iid: iid)] = source
        }
    }

    static func information(name: String, model: String, serial: String, version: String) -> HAPService {
        typealias C = HAPType.Characteristic
        return HAPService(iid: 1, type: HAPType.Service.accessoryInformation, characteristics: [
            HAPCharacteristic(iid: 2, type: C.identify, format: .bool, permissions: .write),
            HAPCharacteristic(iid: 3, type: C.manufacturer, format: .string, permissions: .read, value: .string("WirenHome")),
            HAPCharacteristic(iid: 4, type: C.model, format: .string, permissions: .read, value: .string(model)),
            HAPCharacteristic(iid: 5, type: C.name, format: .string, permissions: .read, value: .string(name)),
            HAPCharacteristic(iid: 6, type: C.serialNumber, format: .string, permissions: .read, value: .string(serial)),
            HAPCharacteristic(iid: 7, type: C.firmwareRevision, format: .string, permissions: .read, value: .string(version))
        ])
    }
}

// Builds the services of one accessory.
private struct Builder {
    typealias S = HAPType.Service
    typealias C = HAPType.Characteristic
    typealias Spec = AccessoryMapper.Spec

    let widget: String
    let name: String
    var ids: IDAllocator
    var services: [HAPService] = []
    var sources: [Int: Source] = [:]

    init(widget: String, name: String, ids: IDAllocator) {
        self.widget = widget
        self.name = name
        self.ids = ids
    }

    mutating func service(_ type: String, slot: String, name: String, _ specs: [Spec]) {
        let serviceID = ids.iid(widget, "s:\(slot):\(type)")
        // iOS 16+ labels services inside an accessory by ConfiguredName, not Name.
        let configuredID = ids.iid(widget, "c:\(slot):\(type):\(C.configuredName)")
        sources[configuredID] = .configuredName(name)
        var characteristics = [
            HAPCharacteristic(iid: ids.iid(widget, "c:\(slot):\(type):\(C.name)"), type: C.name, format: .string, permissions: .read, value: .string(name)),
            HAPCharacteristic(iid: configuredID, type: C.configuredName, format: .string, permissions: .readWriteEvents, maxLength: 64)
        ]
        for spec in specs {
            let iid = ids.iid(widget, "c:\(slot):\(type):\(spec.type)")
            characteristics.append(HAPCharacteristic(
                iid: iid, type: spec.type, format: spec.format, permissions: spec.permissions,
                unit: spec.unit, minValue: spec.min, maxValue: spec.max, minStep: spec.step, validValues: spec.valid
            ))
            sources[iid] = spec.source
        }
        services.append(HAPService(iid: serviceID, type: type, primary: services.isEmpty, characteristics: characteristics))
    }

    // One cell becomes one service in the "Auto" and "Info" roles.
    mutating func addCell(_ cell: Cell, name: String, kind: CellKind, readOnly: Bool) {
        let slot = cell.id
        switch kind {
        case .toggle where !readOnly:
            service(S.switch, slot: slot, name: name, [Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .onOff(cell))])
        case .toggle, .state:
            service(S.contactSensor, slot: slot, name: name, [contact(cell)])
        case .alarm:
            service(S.contactSensor, slot: slot, name: name, [
                Spec(type: C.contactSensorState, format: .uint8, permissions: .readEvents, source: .threshold(cell, above: 0, asBool: false), min: 0, max: 1, step: 1)
            ])
        case .pushbutton where !readOnly:
            service(S.switch, slot: slot, name: name, [Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .momentary(cell))])
        case .range(let min, let max) where !readOnly:
            service(S.lightbulb, slot: slot, name: name, [
                Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .onFromRange(cell, max: max)),
                brightness(.percent(cell, min: min, max: max))
            ])
        case .rgb where !readOnly:
            addRGBLight(cell, name: name, on: nil, brightness: nil, slot: slot)
        case .temperature:
            service(S.temperatureSensor, slot: slot, name: name, [temperature(cell)])
        case .humidity:
            service(S.humiditySensor, slot: slot, name: name, [
                Spec(type: C.currentRelativeHumidity, format: .float, permissions: .readEvents, source: .number(cell, min: 0, max: 100), unit: "percentage", min: 0, max: 100, step: 0.1)
            ])
        case .carbonDioxide:
            service(S.carbonDioxideSensor, slot: slot, name: name, [
                Spec(type: C.carbonDioxideDetected, format: .uint8, permissions: .readEvents, source: .threshold(cell, above: 1000, asBool: false), min: 0, max: 1, step: 1),
                Spec(type: C.carbonDioxideLevel, format: .float, permissions: .readEvents, source: .number(cell, min: 0, max: 100_000), min: 0, max: 100_000)
            ])
        case .illuminance:
            service(S.lightSensor, slot: slot, name: name, [
                Spec(type: C.currentAmbientLightLevel, format: .float, permissions: .readEvents, source: .number(cell, min: 0.0001, max: 100_000), unit: "lux", min: 0.0001, max: 100_000)
            ])
        case .pressCounter(let event):
            service(S.statelessProgrammableSwitch, slot: slot, name: name, [
                Spec(type: C.programmableSwitchEvent, format: .uint8, permissions: .readEvents, source: .buttonEvent(cell, event: event), min: 0, max: 2, step: 1, valid: [event])
            ])
        default:
            break
        }
    }

    // Returns a reason when the widget's cells do not fit the role.
    mutating func addRole(_ role: AccessoryRole, cells: [(cell: Cell, name: String, kind: CellKind)]) -> RoleProblem? {
        func first(_ match: (CellKind) -> Bool) -> Cell? { cells.first { match($0.kind) }?.cell }
        let toggles = cells.filter { $0.kind == .toggle }.map(\.cell)
        let range: (Cell, Double, Double)? = cells.lazy.compactMap { item in
            if case .range(let min, let max) = item.kind { return (item.cell, min, max) }
            return nil
        }.first
        let rgb = first { $0 == .rgb }
        let sensor = first { [.state, .alarm].contains($0) }
        let slot = role.rawValue

        switch role {
        case .light:
            guard toggles.first != nil || range != nil || rgb != nil else { return .needsLightControl }
            if let rgb {
                let on: Source? = toggles.first.map { .onOff($0) }
                addRGBLight(rgb, name: name, on: on, brightness: range.map { .percent($0.0, min: $0.1, max: $0.2) }, slot: slot)
                return nil
            }
            var specs: [Spec] = []
            if let toggle = toggles.first {
                specs.append(Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .onOff(toggle)))
            } else if let range {
                specs.append(Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .onFromRange(range.0, max: range.2)))
            }
            if let range {
                specs.append(brightness(.percent(range.0, min: range.1, max: range.2)))
            }
            service(S.lightbulb, slot: slot, name: name, specs)

        case .outlet:
            guard let toggle = toggles.first else { return .needsSwitch }
            service(S.outlet, slot: slot, name: name, [
                Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: .onOff(toggle)),
                Spec(type: C.outletInUse, format: .bool, permissions: .readEvents, source: .onOff(toggle))
            ])

        case .fan:
            guard toggles.first != nil || range != nil else { return .needsFanControl }
            var specs: [Spec] = []
            if let toggle = toggles.first {
                specs.append(Spec(type: C.active, format: .uint8, permissions: .readWriteEvents, source: .active(toggle), min: 0, max: 1, step: 1))
            } else if let range {
                specs.append(Spec(type: C.active, format: .uint8, permissions: .readWriteEvents, source: .activeFromRange(range.0, max: range.2), min: 0, max: 1, step: 1))
            }
            if let range {
                specs.append(Spec(type: C.rotationSpeed, format: .float, permissions: .readWriteEvents, source: .percent(range.0, min: range.1, max: range.2), unit: "percentage", min: 0, max: 100, step: 1))
            }
            service(S.fan, slot: slot, name: name, specs)

        case .thermostat:
            guard let current = first({ $0 == .temperature || $0 == .number }) else { return .needsTemperature }
            guard let target = range else { return .needsSetpoint }
            let low = max(10, target.1), high = min(38, target.2)
            guard low < high else { return .setpointOutOfRange }
            let modes: [Int] = toggles.first == nil ? [1] : [0, 1]
            service(S.thermostat, slot: slot, name: name, [
                Spec(type: C.currentHeatingCoolingState, format: .uint8, permissions: .readEvents, source: .heating(toggles.first), min: 0, max: 2, step: 1, valid: modes),
                Spec(type: C.targetHeatingCoolingState, format: .uint8, permissions: .readWriteEvents, source: .heating(toggles.first), min: 0, max: 3, step: 1, valid: modes),
                temperature(current),
                Spec(type: C.targetTemperature, format: .float, permissions: .readWriteEvents, source: .setpoint(target.0, min: low, max: high), unit: "celsius", min: low, max: high, step: 0.5),
                Spec(type: C.temperatureDisplayUnits, format: .uint8, permissions: .readWriteEvents, source: .ignoredWrite(.int(0)), min: 0, max: 1, step: 1)
            ])

        case .blinds:
            let current: Source, target: Source
            if let range {
                current = .percent(range.0, min: range.1, max: range.2)
                target = current
            } else if toggles.count >= 2 {
                current = .blinds(up: toggles[0], down: toggles[1])
                target = current
            } else {
                return .needsPosition
            }
            service(S.windowCovering, slot: slot, name: name, [
                Spec(type: C.currentPosition, format: .uint8, permissions: .readEvents, source: current, unit: "percentage", min: 0, max: 100, step: 1),
                Spec(type: C.targetPosition, format: .uint8, permissions: .readWriteEvents, source: target, unit: "percentage", min: 0, max: 100, step: 1),
                Spec(type: C.positionState, format: .uint8, permissions: .readEvents, source: .constant(.int(2)), min: 0, max: 2, step: 1)
            ])

        case .valve:
            guard let toggle = toggles.first else { return .needsSwitch }
            service(S.valve, slot: slot, name: name, [
                Spec(type: C.active, format: .uint8, permissions: .readWriteEvents, source: .active(toggle), min: 0, max: 1, step: 1),
                Spec(type: C.inUse, format: .uint8, permissions: .readEvents, source: .active(toggle), min: 0, max: 1, step: 1),
                Spec(type: C.valveType, format: .uint8, permissions: .readEvents, source: .constant(.int(0)), min: 0, max: 3, step: 1)
            ])

        case .leak:
            guard let input = sensor ?? toggles.first else { return .needsInput }
            service(S.leakSensor, slot: slot, name: name, [
                Spec(type: C.leakDetected, format: .uint8, permissions: .readEvents, source: .threshold(input, above: 0, asBool: false), min: 0, max: 1, step: 1)
            ])

        case .motion:
            guard let input = sensor ?? first({ $0 == .number }) else { return .needsInputOrValue }
            service(S.motionSensor, slot: slot, name: name, [
                Spec(type: C.motionDetected, format: .bool, permissions: .readEvents, source: .threshold(input, above: 0, asBool: true))
            ])

        case .contact:
            guard let input = sensor ?? toggles.first else { return .needsInput }
            service(S.contactSensor, slot: slot, name: name, [contact(input)])

        case .auto, .info:
            break
        }
        return nil
    }

    mutating func addRGBLight(_ cell: Cell, name: String, on: Source?, brightness level: Source?, slot: String) {
        service(S.lightbulb, slot: slot, name: name, [
            Spec(type: C.on, format: .bool, permissions: .readWriteEvents, source: on ?? .onFromRGB(cell)),
            brightness(level ?? .rgbBrightness(cell)),
            Spec(type: C.hue, format: .float, permissions: .readWriteEvents, source: .hue(cell), unit: "arcdegrees", min: 0, max: 360, step: 1),
            Spec(type: C.saturation, format: .float, permissions: .readWriteEvents, source: .saturation(cell), unit: "percentage", min: 0, max: 100, step: 1)
        ])
    }

    func brightness(_ source: Source) -> Spec {
        Spec(type: C.brightness, format: .int, permissions: .readWriteEvents, source: source, unit: "percentage", min: 0, max: 100, step: 1)
    }

    func temperature(_ cell: Cell) -> Spec {
        Spec(type: C.currentTemperature, format: .float, permissions: .readEvents, source: .number(cell, min: -100, max: 200), unit: "celsius", min: -100, max: 200, step: 0.1)
    }

    func contact(_ cell: Cell) -> Spec {
        Spec(type: C.contactSensorState, format: .uint8, permissions: .readEvents, source: .contact(cell), min: 0, max: 1, step: 1)
    }
}
