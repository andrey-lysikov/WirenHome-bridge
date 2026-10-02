//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import WBKit

public enum AccessoryRole: String, CaseIterable, Sendable, Codable {
    case auto, light, outlet, fan, thermostat, blinds, valve, leak, motion, contact, info, gate

    // Codes are stored in the WB enum control; never renumber them.
    public var code: Int {
        switch self {
        case .auto: 0
        case .light: 1
        case .outlet: 2
        case .fan: 3
        case .thermostat: 4
        case .blinds: 5
        case .valve: 6
        case .leak: 7
        case .motion: 8
        case .contact: 9
        case .info: 10
        case .gate: 11
        }
    }

    public init?(code: Int) {
        guard let role = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = role
    }

    // Kept short: the WB dropdown is narrow.
    public var title: Translations {
        switch self {
        case .auto: ["ru": "Авто", "en": "Auto"]
        case .light: ["ru": "Свет", "en": "Light"]
        case .outlet: ["ru": "Розетка", "en": "Outlet"]
        case .fan: ["ru": "Вентилятор", "en": "Fan"]
        case .thermostat: ["ru": "Термостат", "en": "Thermostat"]
        case .blinds: ["ru": "Шторы", "en": "Blinds"]
        case .valve: ["ru": "Кран", "en": "Valve"]
        case .leak: ["ru": "Протечка", "en": "Leak"]
        case .motion: ["ru": "Движение", "en": "Motion"]
        case .contact: ["ru": "Открытие", "en": "Contact"]
        case .info: ["ru": "Инфо", "en": "Info"]
        case .gate: ["ru": "Ворота", "en": "Gate"]
        }
    }
}
