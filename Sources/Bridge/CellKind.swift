//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import WBKit

// What a WB control is, as far as HomeKit mapping cares.
enum CellKind: Sendable, Equatable {
    case toggle
    case state
    case pushbutton
    case range(min: Double, max: Double)
    case temperature
    // A writable temperature, e.g. a heating threshold set by wb-rules.
    case setpoint(min: Double, max: Double)
    case humidity
    case carbonDioxide
    case illuminance
    case power
    case alarm
    case rgb
    case pressCounter(event: Int)
    case number
    case unsupported

    static func classify(_ control: WBControl) -> CellKind {
        let meta = control.meta
        let type = meta.type ?? ""
        let units = meta.units ?? ""
        // WB defaults: switches, ranges, buttons and rgb are writable, everything else is read-only.
        let writable = !(meta.readonly ?? !["switch", "range", "pushbutton", "rgb"].contains(type))
        let setpoint = CellKind.setpoint(min: meta.min ?? 10, max: meta.max ?? 38)
        // Enumerated values (DALI scenes, modes) are choices, not a scale HomeKit can slide.
        if writable, meta.enumTitles?.isEmpty == false, ["range", "value"].contains(type) {
            return .unsupported
        }

        switch type {
        case "switch":
            return writable ? .toggle : .state
        case "pushbutton":
            return writable ? .pushbutton : .unsupported
        case "range":
            return writable ? .range(min: meta.min ?? 0, max: meta.max ?? 100) : .number
        case "rgb":
            return writable ? .rgb : .unsupported
        case "alarm":
            return .alarm
        case "temperature":
            return writable ? setpoint : .temperature
        case "rel_humidity":
            return .humidity
        case "concentration":
            return .carbonDioxide
        case "lux", "illuminance":
            return .illuminance
        case "power":
            return .power
        case "value":
            for (suffix, event) in [("Single Press Counter", 0), ("Double Press Counter", 1), ("Long Press Counter", 2)] where control.id.hasSuffix(suffix) {
                return .pressCounter(event: event)
            }
            switch units {
            case "deg C", "°C": return writable ? setpoint : .temperature
            case "%, RH": return .humidity
            case "ppm": return .carbonDioxide
            case "lx": return .illuminance
            case "W": return .power
            default: return writable ? .range(min: meta.min ?? 0, max: meta.max ?? 100) : .number
            }
        case "text", "":
            return .unsupported
        default:
            return .number
        }
    }
}

// iOS accepts names of letters, digits, spaces and apostrophes that start and end with a letter or digit.
enum NameSanitizer {
    private static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        "⁰": "0", "¹": "1", "²": "2", "³": "3"
    ]

    static func clean(_ name: String) -> String {
        var result = ""
        for character in name {
            let mapped = subscripts[character] ?? character
            if mapped.isLetter || mapped.isNumber && mapped.isASCII || mapped == "'" {
                result.append(mapped)
            } else {
                result.append(" ")
            }
        }
        var words = result.split(separator: " ").map(String.init)
        while let first = words.first, first.hasPrefix("'") {
            words[0] = String(first.drop { $0 == "'" })
            if words[0].isEmpty { words.removeFirst() }
        }
        while let last = words.last, last.hasSuffix("'") {
            words[words.count - 1] = String(last.reversed().drop { $0 == "'" }.reversed())
            if words[words.count - 1].isEmpty { words.removeLast() }
        }
        return words.joined(separator: " ")
    }
}
