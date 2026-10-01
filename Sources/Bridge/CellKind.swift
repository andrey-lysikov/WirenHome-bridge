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
    case humidity
    case carbonDioxide
    case illuminance
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
            return .temperature
        case "rel_humidity":
            return .humidity
        case "concentration":
            return .carbonDioxide
        case "lux", "illuminance":
            return .illuminance
        case "value":
            for (suffix, event) in [("Single Press Counter", 0), ("Double Press Counter", 1), ("Long Press Counter", 2)] where control.id.hasSuffix(suffix) {
                return .pressCounter(event: event)
            }
            switch units {
            case "deg C": return .temperature
            case "%, RH": return .humidity
            case "ppm": return .carbonDioxide
            case "lx": return .illuminance
            default: return writable ? .range(min: meta.min ?? 0, max: meta.max ?? 100) : .number
            }
        case "text", "":
            return .unsupported
        default:
            return .number
        }
    }

    var isWritable: Bool {
        switch self {
        case .toggle, .pushbutton, .range, .rgb: true
        default: false
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
