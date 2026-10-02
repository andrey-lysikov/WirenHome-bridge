//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HAPKit
import WBKit

struct Cell: Sendable, Hashable {
    let device: String
    let control: String

    var id: String { "\(device)/\(control)" }
}

typealias ControlLookup = (Cell) -> WBControl?

// How one HAP characteristic reads from and writes to WB controls.
enum Source: Sendable, Equatable {
    case constant(HAPValue)
    case configuredName(String)
    case ignoredWrite(HAPValue)
    case onOff(Cell)
    case onFromRange(Cell, max: Double)
    case onFromRGB(Cell)
    case active(Cell)
    case activeFromRange(Cell, max: Double)
    case percent(Cell, min: Double, max: Double)
    case number(Cell, min: Double, max: Double)
    case threshold(Cell, above: Double, asBool: Bool)
    case contact(Cell)
    case heating(Cell?)
    case setpoint(Cell, min: Double, max: Double)
    case hue(Cell)
    case saturation(Cell)
    case rgbBrightness(Cell)
    case momentary(Cell)
    case buttonEvent(Cell, event: Int)
    case blinds(up: Cell, down: Cell)
    case doorCurrent(Gate)
    case doorTarget(Gate)

    var cells: [Cell] {
        switch self {
        case .constant, .ignoredWrite, .configuredName: []
        case .onOff(let c), .onFromRange(let c, _), .onFromRGB(let c), .active(let c), .activeFromRange(let c, _),
             .percent(let c, _, _), .number(let c, _, _), .threshold(let c, _, _), .contact(let c), .setpoint(let c, _, _),
             .hue(let c), .saturation(let c), .rgbBrightness(let c), .momentary(let c), .buttonEvent(let c, _):
            [c]
        case .heating(let c): c.map { [$0] } ?? []
        case .blinds(let up, let down): [up, down]
        case .doorCurrent(let gate), .doorTarget(let gate): gate.cells
        }
    }

    func read(_ lookup: ControlLookup) -> Result<HAPValue, HAPStatus> {
        switch self {
        case .constant(let value), .ignoredWrite(let value):
            return .success(value)
        case .configuredName(let name):
            return .success(.string(name))
        case .momentary:
            return .success(.bool(false))
        case .buttonEvent:
            return .success(.null)
        case .blinds:
            return .success(.int(100))
        case .heating(nil):
            return .success(.int(1))
        case .doorCurrent(let gate):
            return .success(.int(gate.current(remembered: nil, lookup)))
        case .doorTarget(let gate):
            return .success(.int(gate.target(remembered: nil, lookup)))
        default:
            break
        }
        guard let cell = cells.first, let raw = Self.value(cell, lookup) else {
            return .failure(.communicationFailure)
        }
        let number = Double(raw.replacing(",", with: ".")) ?? 0
        switch self {
        case .onOff:
            return .success(.bool(number != 0))
        case .onFromRange, .onFromRGB:
            return .success(.bool(Self.rgb(raw).map { $0.contains { $0 > 0 } } ?? (number > 0)))
        case .active, .activeFromRange:
            return .success(.int(number > 0 ? 1 : 0))
        case .percent(_, let min, let max):
            return .success(.int(Int(((number - min) / Swift.max(max - min, 1) * 100).rounded().clamped(0, 100))))
        case .number(_, let min, let max), .setpoint(_, let min, let max):
            return .success(.double(number.clamped(min, max)))
        case .threshold(_, let above, let asBool):
            return .success(asBool ? .bool(number > above) : .int(number > above ? 1 : 0))
        case .contact:
            // A closed input ("1") means the contact is detected.
            return .success(.int(number != 0 ? 0 : 1))
        case .heating:
            return .success(.int(number != 0 ? 1 : 0))
        case .hue, .saturation, .rgbBrightness:
            let hsv = HSV(rgb: Self.rgb(raw) ?? [0, 0, 0])
            switch self {
            case .hue: return .success(.double(hsv.hue))
            case .saturation: return .success(.double(hsv.saturation))
            default: return .success(.int(Int(hsv.value.rounded())))
            }
        default:
            return .failure(.communicationFailure)
        }
    }

    // Translates a HomeKit write into commands for WB controls.
    func commands(for value: HAPValue, _ lookup: ControlLookup) -> Result<[(Cell, String)], HAPStatus> {
        switch self {
        case .ignoredWrite:
            return .success([])
        case .configuredName:
            return value.stringValue == nil ? .failure(.invalidValue) : .success([])
        case .onOff(let cell), .active(let cell):
            guard let on = value.boolValue else { return .failure(.invalidValue) }
            return .success([(cell, on ? "1" : "0")])
        case .onFromRange(let cell, let max), .activeFromRange(let cell, let max):
            guard let on = value.boolValue else { return .failure(.invalidValue) }
            let current = Double(Self.value(cell, lookup) ?? "0") ?? 0
            if on {
                return .success(current > 0 ? [] : [(cell, Self.format(max))])
            }
            return .success([(cell, "0")])
        case .onFromRGB(let cell):
            guard let on = value.boolValue else { return .failure(.invalidValue) }
            let current = Self.rgb(Self.value(cell, lookup) ?? "") ?? [0, 0, 0]
            if on {
                return .success(current.contains { $0 > 0 } ? [] : [(cell, "255;255;255")])
            }
            return .success([(cell, "0;0;0")])
        case .percent(let cell, let min, let max):
            guard let percent = value.doubleValue else { return .failure(.invalidValue) }
            let raw = min + percent.clamped(0, 100) / 100 * (max - min)
            return .success([(cell, Self.format(max - min >= 10 ? raw.rounded() : (raw * 100).rounded() / 100))])
        case .setpoint(let cell, let min, let max):
            guard let target = value.doubleValue else { return .failure(.invalidValue) }
            return .success([(cell, Self.format(target.clamped(min, max)))])
        case .heating(let cell):
            guard let mode = value.doubleValue else { return .failure(.invalidValue) }
            guard let cell else { return mode == 1 ? .success([]) : .failure(.invalidValue) }
            return .success([(cell, mode == 0 ? "0" : "1")])
        case .hue(let cell), .saturation(let cell), .rgbBrightness(let cell):
            guard let number = value.doubleValue else { return .failure(.invalidValue) }
            var hsv = HSV(rgb: Self.rgb(Self.value(cell, lookup) ?? "") ?? [0, 0, 0])
            switch self {
            case .hue: hsv.hue = number.clamped(0, 360)
            case .saturation: hsv.saturation = number.clamped(0, 100)
            default: hsv.value = number.clamped(0, 100)
            }
            return .success([(cell, hsv.rgb.map(String.init).joined(separator: ";"))])
        case .momentary(let cell):
            guard let on = value.boolValue else { return .failure(.invalidValue) }
            return .success(on ? [(cell, "1")] : [])
        case .blinds(let up, let down):
            guard let target = value.doubleValue else { return .failure(.invalidValue) }
            return .success([(target >= 50 ? up : down, "1")])
        case .doorTarget(let gate):
            guard let target = value.doubleValue, target == 0 || target == 1 else { return .failure(.invalidValue) }
            return .success(gate.commands(target: Int(target), lookup))
        default:
            return .failure(.readOnly)
        }
    }

    // Missing control, missing value or a read error all mean "no response".
    static func value(_ cell: Cell, _ lookup: ControlLookup) -> String? {
        guard let control = lookup(cell), control.meta.error?.contains("r") != true else { return nil }
        return control.value
    }

    static func rgb(_ raw: String) -> [Int]? {
        let parts = raw.split(separator: ";").compactMap { Int($0.trimmed) }
        return parts.count == 3 ? parts.map { $0.clamped(0, 255) } : nil
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

struct HSV: Equatable {
    var hue: Double
    var saturation: Double
    var value: Double

    init(rgb: [Int]) {
        let r = Double(rgb[0]) / 255, g = Double(rgb[1]) / 255, b = Double(rgb[2]) / 255
        let maximum = max(r, g, b), delta = maximum - min(r, g, b)
        var h = 0.0
        if delta > 0 {
            if maximum == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        hue = h < 0 ? h + 360 : h
        saturation = maximum == 0 ? 0 : delta / maximum * 100
        value = maximum * 100
    }

    var rgb: [Int] {
        let v = value / 100, s = saturation / 100
        let c = v * s, x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return [r, g, b].map { Int((($0 + m) * 255).rounded()) }
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
