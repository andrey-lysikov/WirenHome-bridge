//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import HAPKit
import Testing
import WBKit
@testable import Bridge

// Meta and values as published by a WB 8.5 with WB-MSW v4, WB-MR6C v3 and WB-MDM3.
let controllerMessages: [(String, String)] = [
    ("/devices/wb-msw-v4_147/controls/Temperature/meta", #"{"order":1,"readonly":true,"type":"value","units":"deg C"}"#),
    ("/devices/wb-msw-v4_147/controls/Temperature", "23.4"),
    ("/devices/wb-msw-v4_147/controls/Humidity/meta", #"{"order":2,"readonly":true,"type":"value","units":"%, RH"}"#),
    ("/devices/wb-msw-v4_147/controls/Humidity", "41.2"),
    ("/devices/wb-msw-v4_147/controls/CO2/meta", #"{"order":3,"readonly":true,"type":"concentration"}"#),
    ("/devices/wb-msw-v4_147/controls/CO2", "1250"),
    ("/devices/wb-msw-v4_147/controls/Sound Level/meta", #"{"order":5,"readonly":true,"type":"sound_level"}"#),
    ("/devices/wb-msw-v4_147/controls/Sound Level", "40"),
    ("/devices/wb-msw-v4_147/controls/Illuminance/meta", #"{"order":6,"readonly":true,"type":"lux"}"#),
    ("/devices/wb-msw-v4_147/controls/Illuminance", "0"),
    ("/devices/wb-msw-v4_147/controls/Current Motion/meta", #"{"order":8,"readonly":true,"type":"value"}"#),
    ("/devices/wb-msw-v4_147/controls/Current Motion", "12"),
    ("/devices/wb-mr6cv3_46/controls/Input 0/meta", #"{"order":1,"readonly":true,"type":"switch"}"#),
    ("/devices/wb-mr6cv3_46/controls/Input 0", "1"),
    ("/devices/wb-mr6cv3_46/controls/K1/meta", #"{"order":15,"readonly":false,"type":"switch"}"#),
    ("/devices/wb-mr6cv3_46/controls/K1", "0"),
    ("/devices/wb-mdm3_223/controls/K1/meta", #"{"order":25,"readonly":false,"type":"switch"}"#),
    ("/devices/wb-mdm3_223/controls/K1", "1"),
    ("/devices/wb-mdm3_223/controls/Channel 1/meta", #"{"max":100.0,"order":26,"readonly":false,"type":"range"}"#),
    ("/devices/wb-mdm3_223/controls/Channel 1", "40"),
    ("/devices/wb-mdm3_223/controls/Input 1 Single Press Counter/meta", #"{"order":3,"readonly":true,"type":"value"}"#),
    ("/devices/wb-mdm3_223/controls/Input 1 Single Press Counter", "5"),
    // wb-community scripts: floor heating (wb-mrwm2), Vakio OpenAir, flat emulator; DALI broadcast group.
    ("/devices/Heating/controls/Tmin/meta", #"{"order":10,"readonly":false,"type":"temperature"}"#),
    ("/devices/Heating/controls/Tmin", "26"),
    ("/devices/Heating/controls/OnOff1/meta", #"{"order":1,"readonly":false,"type":"switch"}"#),
    ("/devices/Heating/controls/OnOff1", "1"),
    ("/devices/Heating/controls/IsOn1/meta", #"{"order":3,"readonly":true,"type":"switch"}"#),
    ("/devices/Heating/controls/IsOn1", "0"),
    ("/devices/Heating/controls/Temp1/meta", #"{"order":5,"readonly":true,"type":"temperature"}"#),
    ("/devices/Heating/controls/Temp1", "27.5"),
    ("/devices/Heating/controls/Pmax1/meta", #"{"order":11,"readonly":true,"type":"power"}"#),
    ("/devices/Heating/controls/Pmax1", "1000"),
    ("/devices/vakio/controls/Smart_Temp/meta", #"{"min":-20,"max":40,"readonly":false,"type":"range"}"#),
    ("/devices/vakio/controls/Smart_Temp", "5"),
    ("/devices/flat/controls/temperature/meta", #"{"readonly":true,"type":"value","units":"°C"}"#),
    ("/devices/flat/controls/temperature", "21"),
    ("/devices/dali/controls/wanted_level/meta", #"{"type":"range","readonly":false,"min":0,"max":100,"units":"%"}"#),
    ("/devices/dali/controls/wanted_level", "60"),
    ("/devices/dali/controls/go_to_scene/meta", #"{"type":"value","readonly":false,"enum":{"0":{"en":"0"},"1":{"en":"1"}}}"#),
    ("/devices/dali/controls/go_to_scene", "0"),
    // wb-community wb-mr6c-gate-controlling.
    ("/devices/GateControlling/controls/GateOpen/meta", #"{"type":"pushbutton","readonly":false}"#),
    ("/devices/GateControlling/controls/GateClose/meta", #"{"type":"pushbutton","readonly":false}"#),
    ("/devices/GateControlling/controls/GateStop/meta", #"{"type":"pushbutton","readonly":false}"#),
    ("/devices/GateControlling/controls/isOpen/meta", #"{"type":"switch","readonly":true}"#),
    ("/devices/GateControlling/controls/isOpen", "0"),
    ("/devices/GateControlling/controls/isClosed/meta", #"{"type":"switch","readonly":true}"#),
    ("/devices/GateControlling/controls/isClosed", "1"),
    ("/devices/GateControlling/controls/Alarm/meta", #"{"type":"alarm","readonly":true}"#),
    ("/devices/GateControlling/controls/Alarm", "0")
]

func controllerRegistry() -> DeviceRegistry {
    var registry = DeviceRegistry()
    for (topic, payload) in controllerMessages {
        registry.apply(MQTTMessage(topic: topic, payload: payload))
    }
    return registry
}

func widget(_ id: String, _ name: String, _ cells: [(String, String)]) -> WebUIConfig.Widget {
    WebUIConfig.Widget(id: id, name: name, cells: cells.map { WebUIConfig.Cell(id: $0.0, name: $0.1) })
}

let sensorWidget = widget("widget13", "Мультидатчик", [
    ("wb-msw-v4_147/Temperature", "Температура"), ("wb-msw-v4_147/Humidity", "Влажность"),
    ("wb-msw-v4_147/CO2", "Уровень CO₂"), ("wb-msw-v4_147/Sound Level", "Уровень шума"),
    ("wb-msw-v4_147/Illuminance", "Освещенность"), ("wb-msw-v4_147/Current Motion", "Текущее движение")
])
let bathWidget = widget("widget14", "Свет в ванной", [("wb-mr6cv3_46/Input 0", "Выключатель"), ("wb-mr6cv3_46/K1", "Свет")])
let dimmerWidget = widget("dimmer", "Люстра", [("wb-mdm3_223/K1", "Канал"), ("wb-mdm3_223/Channel 1", "Яркость")])

func map(_ widgets: [WebUIConfig.Widget], roles: [String: AccessoryRole] = [:], ids: IDAllocator = IDAllocator()) -> (Mapping, IDAllocator) {
    let registry = controllerRegistry()
    var mapper = AccessoryMapper(ids: ids, version: "0.1") { cell in
        registry.control(device: cell.device, control: cell.control).map(CellKind.classify)
    }
    mapper.map(widgets: widgets, roles: roles, bridge: HAPAccessory(aid: 1, services: []))
    return (mapper.mapping, mapper.ids)
}

func serviceTypes(_ accessory: HAPAccessory) -> [String] {
    accessory.services.dropFirst().map(\.type)
}

func value(_ mapping: Mapping, _ aid: Int, _ type: String) -> HAPValue? {
    let registry = controllerRegistry()
    guard let accessory = mapping.accessories.first(where: { $0.aid == aid }) else { return nil }
    for service in accessory.services {
        if let characteristic = service.characteristics.first(where: { $0.type == type }),
           case .success(let value) = mapping.sources[HAPCharacteristicID(aid: aid, iid: characteristic.iid)]?.read({ registry.control(device: $0.device, control: $0.control) }) {
            return value
        }
    }
    return nil
}

@Test func cleansNamesForHomeKit() {
    #expect(NameSanitizer.clean("Уровень CO₂") == "Уровень CO2")
    #expect(NameSanitizer.clean("Качество воздуха (VOC)") == "Качество воздуха VOC")
    #expect(NameSanitizer.clean("  'Свет'  в  ванной! ") == "Свет' в ванной")
    #expect(NameSanitizer.clean("()") == "")
}

@Test func classifiesControllerControls() {
    let registry = controllerRegistry()
    func kind(_ device: String, _ control: String) -> CellKind? {
        registry.control(device: device, control: control).map(CellKind.classify)
    }
    #expect(kind("wb-msw-v4_147", "Temperature") == .temperature)
    #expect(kind("wb-msw-v4_147", "Humidity") == .humidity)
    #expect(kind("wb-msw-v4_147", "CO2") == .carbonDioxide)
    #expect(kind("wb-msw-v4_147", "Illuminance") == .illuminance)
    #expect(kind("wb-msw-v4_147", "Sound Level") == .number)
    #expect(kind("wb-mr6cv3_46", "Input 0") == .state)
    #expect(kind("wb-mr6cv3_46", "K1") == .toggle)
    #expect(kind("wb-mdm3_223", "Channel 1") == .range(min: 0, max: 100))
    #expect(kind("wb-mdm3_223", "Input 1 Single Press Counter") == .pressCounter(event: 0))
    #expect(kind("Heating", "Tmin") == .setpoint(min: 10, max: 38))
    #expect(kind("Heating", "Temp1") == .temperature)
    #expect(kind("Heating", "Pmax1") == .power)
    #expect(kind("flat", "temperature") == .temperature)
    #expect(kind("vakio", "Smart_Temp") == .range(min: -20, max: 40))
    #expect(kind("dali", "wanted_level") == .range(min: 0, max: 100))
    #expect(kind("dali", "go_to_scene") == .unsupported)
}

@Test func floorHeatingBecomesThermostat() {
    let floor = widget("floor", "Теплый пол", [
        ("Heating/Tmin", "Температура"), ("Heating/OnOff1", "Включить"), ("Heating/Pmax1", "Мощность"),
        ("Heating/Temp1", "Пол"), ("Heating/IsOn1", "Нагрев")
    ])
    let (mapping, _) = map([floor], roles: ["floor": .thermostat])
    typealias C = HAPType.Characteristic
    #expect(mapping.issues.isEmpty)
    #expect(serviceTypes(mapping.accessories[1]) == [HAPType.Service.thermostat])
    #expect(value(mapping, 2, C.currentTemperature) == .double(27.5))
    #expect(value(mapping, 2, C.targetTemperature) == .double(26))
    #expect(value(mapping, 2, C.currentHeatingCoolingState) == .int(0))
    #expect(value(mapping, 2, C.targetHeatingCoolingState) == .int(1))
    // Power rides on the thermostat service for the Eve app.
    #expect(mapping.accessories[1].services[1].characteristics.last?.type == HAPType.Eve.power)
    #expect(value(mapping, 2, HAPType.Eve.power) == .double(1000))
}

@Test func autoSkipsSettingsThatAreNotDimmers() {
    let (mapping, _) = map([
        widget("bedroom", "Свет спальня", [("dali/wanted_level", "Яркость"), ("dali/go_to_scene", "Сцена")]),
        widget("vent", "Вентиляция", [("vakio/Smart_Temp", "Порог"), ("flat/temperature", "Температура")]),
        widget("floor", "Теплый пол", [("Heating/Tmin", "Температура")])
    ])
    typealias S = HAPType.Service
    #expect(serviceTypes(mapping.accessories[1]) == [S.lightbulb])
    #expect(serviceTypes(mapping.accessories[2]) == [S.temperatureSensor])
    #expect(serviceTypes(mapping.accessories[3]) == [S.temperatureSensor])
}

@Test func autoRoleMapsEachCell() throws {
    let (mapping, _) = map([sensorWidget, bathWidget])
    #expect(mapping.accessories.map(\.aid) == [1, 2, 3])

    let sensor = mapping.accessories[1]
    typealias S = HAPType.Service
    #expect(serviceTypes(sensor) == [S.temperatureSensor, S.humiditySensor, S.carbonDioxideSensor, S.lightSensor])
    #expect(value(mapping, 2, HAPType.Characteristic.currentTemperature) == .double(23.4))
    #expect(value(mapping, 2, HAPType.Characteristic.carbonDioxideDetected) == .int(1))
    #expect(value(mapping, 2, HAPType.Characteristic.currentAmbientLightLevel) == .double(0.0001))
    let names = sensor.services.dropFirst().compactMap { $0.characteristics.first?.value }
    #expect(names.contains(.string("Уровень CO2")))

    #expect(serviceTypes(mapping.accessories[2]) == [S.contactSensor, S.switch])
    #expect(value(mapping, 3, HAPType.Characteristic.contactSensorState) == .int(0))
    #expect(value(mapping, 3, HAPType.Characteristic.on) == .bool(false))
}

@Test func rolesBuildCompositeAccessories() {
    let (mapping, _) = map([bathWidget, dimmerWidget, sensorWidget], roles: ["widget14": .light, "dimmer": .light, "widget13": .motion])
    typealias S = HAPType.Service
    #expect(serviceTypes(mapping.accessories[1]) == [S.lightbulb])
    #expect(serviceTypes(mapping.accessories[2]) == [S.lightbulb])
    #expect(value(mapping, 3, HAPType.Characteristic.on) == .bool(true))
    #expect(value(mapping, 3, HAPType.Characteristic.brightness) == .int(40))
    #expect(serviceTypes(mapping.accessories[3]) == [S.motionSensor])
    #expect(value(mapping, 4, HAPType.Characteristic.motionDetected) == .bool(true))
}

@Test func infoRoleIsReadOnly() {
    let (mapping, _) = map([bathWidget], roles: ["widget14": .info])
    #expect(serviceTypes(mapping.accessories[1]) == [HAPType.Service.contactSensor, HAPType.Service.contactSensor])
    #expect(mapping.sources.values.allSatisfy {
        if case .failure(.readOnly) = $0.commands(for: .bool(true), { _ in nil }) { return true }
        if case .ignoredWrite = $0 { return true }
        if case .configuredName = $0 { return true }
        return false
    })
}

@Test func unfitRoleFallsBackToAutoWithWarning() {
    let (mapping, _) = map([bathWidget], roles: ["widget14": .thermostat])
    #expect(serviceTypes(mapping.accessories[1]) == [HAPType.Service.contactSensor, HAPType.Service.switch])
    #expect(mapping.issues == [WidgetIssue(widget: "widget14", issue: .roleMismatch(.thermostat, .needsTemperature))])
    #expect(mapping.issues[0].issue.title["ru"] == "Термостат: нужен датчик температуры, показан как «Авто»")
    #expect(mapping.issues[0].issue.title["en"] == "Thermostat: needs a temperature sensor, shown as Auto")
}

@Test func reportsMissingDevicesAndEmptyWidgets() {
    let ghost = widget("w11", "Мультидатчик 1", [("wb-modbus-2-0/Температура", "Температура")])
    let (mapping, _) = map([ghost])
    #expect(mapping.accessories.count == 1)
    #expect(mapping.issues.contains(WidgetIssue(widget: "w11", issue: .missingDevice("wb-modbus-2-0/Температура"))))
}

@Test func idsStayStableAcrossRemaps() {
    let (first, ids) = map([sensorWidget, bathWidget])
    let (second, _) = map([bathWidget, sensorWidget], ids: ids)
    #expect(first.fingerprint.count > 0)
    let firstIDs = Set(first.sources.keys)
    #expect(Set(second.sources.keys) == firstIDs)
    #expect(second.accessories.first { $0.aid == 3 }.map(serviceTypes) == [HAPType.Service.contactSensor, HAPType.Service.switch])
}

@Test func convertsWrites() throws {
    let registry = controllerRegistry()
    let lookup: ControlLookup = { registry.control(device: $0.device, control: $0.control) }
    let channel = Cell(device: "wb-mdm3_223", control: "Channel 1")

    let dim = try Source.percent(channel, min: 0, max: 100).commands(for: .int(75), lookup).get()
    #expect(dim.map(\.1) == ["75"])
    let on = try Source.onFromRange(channel, max: 100).commands(for: .bool(true), lookup).get()
    #expect(on.isEmpty)
    let off = try Source.onFromRange(channel, max: 100).commands(for: .bool(false), lookup).get()
    #expect(off.map(\.1) == ["0"])
    let setpoint = try Source.setpoint(channel, min: 10, max: 38).commands(for: .double(45), lookup).get()
    #expect(setpoint.map(\.1) == ["38"])
    #expect(throws: HAPStatus.readOnly) { try Source.contact(channel).commands(for: .int(1), lookup).get() }
}

@Test func convertsRGB() {
    #expect(HSV(rgb: [255, 0, 0]) == HSV(rgb: [255, 0, 0]))
    let red = HSV(rgb: [255, 0, 0])
    #expect(red.hue == 0 && red.saturation == 100 && red.value == 100)
    for rgb in [[255, 128, 0], [10, 200, 30], [0, 0, 255], [128, 128, 128]] {
        #expect(HSV(rgb: rgb).rgb == rgb)
    }
}

let gateWidget = widget("gate", "Ворота", [
    ("GateControlling/GateOpen", "Открыть"), ("GateControlling/GateClose", "Закрыть"), ("GateControlling/GateStop", "Стоп"),
    ("GateControlling/isOpen", "Открыты"), ("GateControlling/isClosed", "Закрыты"), ("GateControlling/Alarm", "Авария")
])

@Test func gateRoleUsesButtonsAndEndSensors() throws {
    let (mapping, _) = map([gateWidget], roles: ["gate": .gate])
    typealias C = HAPType.Characteristic
    #expect(mapping.issues.isEmpty)
    #expect(serviceTypes(mapping.accessories[1]) == [HAPType.Service.garageDoorOpener])
    #expect(value(mapping, 2, C.currentDoorState) == .int(1))
    #expect(value(mapping, 2, C.targetDoorState) == .int(1))
    #expect(value(mapping, 2, C.obstructionDetected) == .bool(false))

    let registry = controllerRegistry()
    let lookup: ControlLookup = { registry.control(device: $0.device, control: $0.control) }
    let target = try #require(mapping.sources.values.first { if case .doorTarget = $0 { true } else { false } })
    #expect(try target.commands(for: .int(0), lookup).get().map(\.0.control) == ["GateOpen"])
    #expect(try target.commands(for: .int(1), lookup).get().map(\.0.control) == ["GateClose"])
}

@Test func gateStatesWithoutNames() {
    func cell(_ name: String) -> Cell { Cell(device: "g", control: name) }
    var registry = DeviceRegistry()
    func set(_ control: String, _ value: String) {
        registry.apply(MQTTMessage(topic: "/devices/g/controls/\(control)/meta", payload: #"{"type":"switch"}"#))
        registry.apply(MQTTMessage(topic: "/devices/g/controls/\(control)", payload: value))
    }
    let lookup: ControlLookup = { registry.control(device: $0.device, control: $0.control) }
    set("opened", "0")
    set("closed", "0")
    set("relay", "1")

    // Both end sensors off: moving towards a known target, otherwise stopped half-way.
    let twoButtons = Gate(buttons: [cell("up"), cell("down")], toggle: nil, sensors: [cell("opened"), cell("closed")])
    #expect(twoButtons.current(remembered: 0, lookup) == 2)
    #expect(twoButtons.current(remembered: 1, lookup) == 3)
    #expect(twoButtons.current(remembered: nil, lookup) == 4)

    // One button is an impulse input; one sensor means "closed".
    let impulse = Gate(buttons: [cell("pulse")], toggle: nil, sensors: [cell("closed")])
    set("closed", "1")
    #expect(impulse.commands(target: 1, lookup).isEmpty)
    #expect(impulse.commands(target: 0, lookup).map(\.1) == ["1"])
    set("closed", "0")
    #expect(impulse.current(remembered: nil, lookup) == 0)

    // A held relay is both the command and the target.
    let relay = Gate(buttons: [], toggle: cell("relay"), sensors: [])
    #expect(!relay.remembersTarget)
    #expect(relay.target(remembered: 1, lookup) == 0)
    #expect(relay.commands(target: 1, lookup).map(\.1) == ["0"])
}

@Test func gateNeedsSomethingToPress() {
    let sensorsOnly = widget("gate", "Ворота", [("GateControlling/isOpen", "Открыты"), ("GateControlling/isClosed", "Закрыты")])
    let (mapping, _) = map([sensorsOnly], roles: ["gate": .gate])
    #expect(mapping.issues == [WidgetIssue(widget: "gate", issue: .roleMismatch(.gate, .needsGateControl))])
    #expect(mapping.issues[0].issue.title["ru"] == "Ворота: нужна кнопка или выключатель, показан как «Авто»")
}
