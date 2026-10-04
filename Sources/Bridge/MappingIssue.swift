//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import WBKit

// Why a role could not be applied to a widget's cells.
enum RoleProblem: Sendable, Equatable {
    case needsLightControl
    case needsSwitch
    case needsFanControl
    case needsTemperature
    case needsSetpoint
    case setpointOutOfRange
    case needsPosition
    case needsInput
    case needsInputOrValue
    case needsGateControl
    case needsInputAndSwitch

    var title: Translations {
        switch self {
        case .needsLightControl: ["ru": "нужен выключатель, диммер или RGB", "en": "needs a switch, dimmer or RGB"]
        case .needsSwitch: ["ru": "нужен выключатель", "en": "needs a switch"]
        case .needsFanControl: ["ru": "нужен выключатель или регулятор", "en": "needs a switch or speed control"]
        case .needsTemperature: ["ru": "нужен датчик температуры", "en": "needs a temperature sensor"]
        case .needsSetpoint: ["ru": "нужна записываемая уставка", "en": "needs a writable setpoint"]
        case .setpointOutOfRange: ["ru": "уставка вне 10–38 °C", "en": "setpoint outside 10–38 °C"]
        case .needsPosition: ["ru": "нужно положение или два выключателя", "en": "needs a position or two switches"]
        case .needsInput: ["ru": "нужен вход", "en": "needs an input"]
        case .needsInputOrValue: ["ru": "нужен вход или значение", "en": "needs an input or a value"]
        case .needsGateControl: ["ru": "нужна кнопка или выключатель", "en": "needs a button or a switch"]
        case .needsInputAndSwitch: ["ru": "нужны вход и выключатель", "en": "needs an input and a switch"]
        }
    }
}

// Problems are kept as data and rendered per language, because WB translates titles in the browser.
enum MappingIssue: Sendable, Equatable {
    case missingDevice(String)
    case unusableName
    case nothingToShow
    case roleMismatch(AccessoryRole, RoleProblem)
    case limitReached(Int)

    var title: Translations {
        switch self {
        case .missingDevice(let cell):
            ["ru": "нет устройства \(cell)", "en": "no device \(cell)"]
        case .unusableName:
            ["ru": "имя не подходит для HomeKit", "en": "name is not valid for HomeKit"]
        case .nothingToShow:
            ["ru": "нет ячеек для HomeKit", "en": "no cells HomeKit can show"]
        case .roleMismatch(let role, let problem):
            [
                "ru": "\(role.title["ru"] ?? ""): \(problem.title["ru"] ?? ""), показан как «Авто»",
                "en": "\(role.title["en"] ?? ""): \(problem.title["en"] ?? ""), shown as Auto"
            ]
        case .limitReached(let limit):
            ["ru": "превышен лимит HomeKit в \(limit) аксессуаров", "en": "HomeKit limit of \(limit) accessories reached"]
        }
    }
}

struct WidgetIssue: Sendable, Equatable {
    let widget: String?
    let issue: MappingIssue
}
