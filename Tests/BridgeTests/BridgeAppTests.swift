//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import HAPKit
import WBKit
@testable import Bridge

actor FakeBroker: MQTTPublisher {
    private(set) var retained: [String: String] = [:]
    private(set) var published: [MQTTMessage] = []

    func publish(_ message: MQTTMessage) async {
        published.append(message)
        retained[message.topic] = message.payload.isEmpty ? nil : message.payload
    }
}

actor FakeWebUI: WebUIConfigSource {
    var config: WebUIConfig

    init(_ config: WebUIConfig) {
        self.config = config
    }

    func set(_ config: WebUIConfig) {
        self.config = config
    }

    func load() async throws -> WebUIConfig {
        config
    }
}

actor FakeHomeKit: HomeKitControl {
    private(set) var resets: [(code: String, setupID: String)] = []
    private(set) var events: [(changes: [HAPCharacteristicID: HAPValue], except: HAPConnectionID?)] = []
    private(set) var directed: [[HAPCharacteristicID: HAPValue]] = []
    private(set) var structureChanges = 0

    func accessoriesChanged() async {
        structureChanges += 1
    }

    func notify(_ changes: [HAPCharacteristicID: HAPValue], except origin: HAPConnectionID?) async {
        events.append((changes, origin))
    }

    func notify(_ changes: [HAPCharacteristicID: HAPValue], only target: HAPConnectionID) async {
        directed.append(changes)
    }

    func reset(setupCode: String, setupID: String) async {
        resets.append((setupCode, setupID))
    }
}

// The confed side: the generated schema and the settings file the form saves.
actor FakePage: SettingsPageStore {
    private(set) var schema: Data?
    var settings: Data?

    func writeSchema(_ data: Data) async {
        schema = data
    }

    func readSettings() async -> Data? {
        settings
    }

    func writeSettings(_ data: Data) async {
        settings = data
    }

    func save(_ json: String) {
        settings = Data(json.utf8)
    }

    // Text of a description or title key in one language, as the form shows it.
    func text(_ key: String, _ language: String) throws -> String? {
        let translations = try json(schema)["translations"] as? [String: [String: String]]
        return translations?[language]?[key]
    }
}

func json(_ data: Data?) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: #require(data)) as! [String: Any]
}

struct FakeQR: QRRenderer {
    func svg(for text: String) async -> String? {
        "<svg data-text=\"\(text)\"></svg>"
    }
}

struct Harness {
    let broker = FakeBroker()
    let webUI = FakeWebUI(sampleConfig)
    let page = FakePage()
    let store = StateStore(directory: temporaryDirectory())
    let app: BridgeApp

    init(state: BridgeState = BridgeState(pinCode: "031-45-154")) {
        app = BridgeApp(publisher: broker, source: webUI, store: store, state: state, version: "0.1", page: page, qr: FakeQR())
    }

    func dashboards() async throws -> [String: Any] {
        let properties = try json(await page.schema)["properties"] as? [String: Any]
        let dashboards = properties?["dashboards"] as? [String: Any]
        return dashboards?["properties"] as? [String: Any] ?? [:]
    }

    func roles(_ dashboard: String) async throws -> [String: Any] {
        let entry = try await dashboards()[dashboard] as? [String: Any]
        let roles = (entry?["properties"] as? [String: Any])?["roles"] as? [String: Any]
        return roles?["properties"] as? [String: Any] ?? [:]
    }
}

@Test func publishesTheSettingsPageOnConnect() async throws {
    var state = BridgeState(pinCode: "031-45-154")
    state.setupID = "WB12"
    let h = Harness(state: state)
    await h.app.handle(.connected)

    let schema = try json(await h.page.schema)
    #expect(schema["title"] as? String == "Apple HomeKit bridge")
    #expect((schema["configFile"] as? [String: Any])?["validate"] as? Bool == false)
    let info = try #require(try await h.page.text("wb-homekit-info", "ru"))
    #expect(info.contains("Загрузка"))
    #expect(info.contains("031-45-154"))
    let uri = HAPSetupPayload.uri(setupCode: "031-45-154", setupID: "WB12")
    #expect(info.contains("<svg data-text=\"\(uri)\"></svg>"))
    #expect(try await h.page.text("wb-homekit-info", "en")?.contains("Version") == false)
    #expect(try await h.page.text("wb-homekit-info", "en")?.contains("App version:</b> 0.1") == true)
}

@Test func listsDashboardsWithTheirWidgetRoles() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen"]))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    // kitchen: light, sensor; hall: door (sensor is already listed under kitchen); the blank one is skipped.
    #expect(try await Set(h.dashboards().keys) == ["kitchen", "hall"])
    #expect(try await Set(h.roles("kitchen").keys) == ["light", "sensor"])
    #expect(try await Set(h.roles("hall").keys) == ["door"])
    let light = try #require(try await h.roles("kitchen")["light"] as? [String: Any])
    #expect(light["title"] as? String == "Свет")
    #expect(light["description"] as? String == "warning-light")
    #expect(try await h.page.text("warning-light", "ru") == "⚠ нет устройства wb-mdm3_223/K1; нет ячеек для HomeKit")
    #expect(try await h.page.text("Thermostat", "ru") == "Термостат")
    #expect(try await h.page.text("wb-homekit-info", "ru")?.contains("Ожидание сопряжения") == true)
}

@Test func movesOldChoicesIntoTheSettingsFile() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen"], roles: ["light": .light, "door": .contact]))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    let dashboards = try json(await h.page.settings)["dashboards"] as? [String: [String: Any]]
    #expect(dashboards?["kitchen"]?["enabled"] as? Bool == true)
    #expect(dashboards?["kitchen"]?["roles"] as? [String: Int] == ["light": AccessoryRole.light.code])
    #expect(dashboards?["hall"]?["enabled"] as? Bool == false)
    #expect(dashboards?["hall"]?["roles"] as? [String: Int] == ["door": AccessoryRole.contact.code])
}

@Test func appliesTheSavedForm() async throws {
    let h = Harness()
    let homeKit = FakeHomeKit()
    await h.app.attach(homeKit, paired: true, bridge: HAPAccessory(aid: 1, services: []))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    await h.page.save(#"{"mqtt":{"host":"localhost","port":1883,"username":"","password":""},"reset_pairing":false,"dashboards":{"kitchen":{"enabled":true,"roles":{"light":1,"sensor":0}},"hall":{"enabled":false}}}"#)
    #expect(await h.app.checkSettings() == false)
    let state = try #require(try h.store.load())
    #expect(state.dashboards == ["kitchen"])
    #expect(state.roles == ["light": .light])
    #expect(await homeKit.structureChanges > 0)
}

@Test func resetsPairingFromTheForm() async throws {
    let h = Harness()
    let homeKit = FakeHomeKit()
    await h.app.attach(homeKit, paired: true, bridge: HAPAccessory(aid: 1, services: []))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()
    let setupID = await h.app.currentState.setupID

    await h.page.save(#"{"reset_pairing":true,"dashboards":{}}"#)
    await h.app.checkSettings()
    let state = await h.app.currentState
    #expect(state.pinCode != "031-45-154")
    #expect(PinCode.isValid(state.pinCode))
    #expect(await homeKit.resets.map(\.code) == [state.pinCode])
    #expect(await homeKit.resets.map(\.setupID) == [state.setupID])
    #expect(state.setupID != setupID || state.pinCode != "031-45-154")
    #expect(try json(await h.page.settings)["reset_pairing"] as? Bool == false)
    #expect(try await h.page.text("wb-homekit-info", "ru")?.contains(state.pinCode) == true)
}

@Test func restartsWhenTheBrokerSettingsChange() async {
    let h = Harness()
    await h.app.handle(.connected)
    await h.page.save(#"{"mqtt":{"host":"localhost"},"dashboards":{}}"#)
    #expect(await h.app.checkSettings() == false)
    await h.page.save(#"{"mqtt":{"host":"localhost"},"dashboards":{"kitchen":{"enabled":true}}}"#)
    #expect(await h.app.checkSettings() == false)
    await h.page.save(#"{"mqtt":{"host":"192.168.1.10"},"dashboards":{}}"#)
    #expect(await h.app.checkSettings() == true)
}

@Test func keepsSettingsWhenTheFileIsBroken() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen"]))
    await h.app.handle(.connected)
    await h.page.save("{ not json")
    #expect(await h.app.checkSettings() == false)
    #expect(await h.app.currentState.dashboards == ["kitchen"])
    #expect(await h.page.settings == Data("{ not json".utf8))
}

@Test func clearsTheOldDevicePage() async {
    let h = Harness()
    await h.app.handle(.connected)
    await h.app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/controls/pincode", payload: "031-45-154")))
    await h.app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/meta", payload: #"{"driver":"wb-homekit"}"#)))
    // Our own removal echoes back empty and is left alone.
    await h.app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/meta", payload: "")))
    let cleared = await h.broker.published.filter { $0.payload.isEmpty && $0.retain }.map(\.topic)
    #expect(cleared == ["/devices/wb-homekit/controls/pincode", "/devices/wb-homekit/meta"])
}

@Test func waitsForDashboardEditsToSettle() async throws {
    let h = Harness()
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    let edited = WebUIConfig(dashboards: sampleConfig.dashboards + [.init(id: "garage", name: "Гараж", widgets: [])], widgets: sampleConfig.widgets)
    await h.webUI.set(edited)
    await h.app.refreshDashboards()
    #expect(try await h.dashboards()["garage"] == nil)

    await h.app.refreshDashboards()
    #expect(try await h.dashboards()["garage"] != nil)
}

@Test func forgetsDeletedDashboards() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen", "gone"], roles: ["light": .light, "old": .fan]))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()
    let state = try #require(try h.store.load())
    #expect(state.dashboards == ["kitchen"])
    #expect(state.roles == ["light": .light])
}

@Test func reportsPairingOnTheSettingsPage() async throws {
    let h = Harness()
    await h.app.attach(FakeHomeKit(), paired: false, bridge: HAPAccessory(aid: 1, services: []))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()
    #expect(try await h.page.text("wb-homekit-info", "en")?.contains("Waiting for pairing") == true)

    await h.app.setPaired(true)
    #expect(try await h.page.text("wb-homekit-info", "en")?.contains("Running") == true)
    await h.app.stop()
    #expect(try await h.page.text("wb-homekit-info", "ru")?.contains("Остановлен") == true)
}

struct LiveHarness {
    let h: Harness
    let homeKit = FakeHomeKit()

    init(roles: [String: AccessoryRole] = [:], extra: [WebUIConfig.Widget] = []) async {
        let buttons = widget("buttons", "Кнопки", [("wb-mdm3_223/Input 1 Single Press Counter", "Кнопка")])
        let widgets = [bathWidget, dimmerWidget, buttons] + extra
        let config = WebUIConfig(dashboards: [.init(id: "home", name: "Дом", widgets: widgets.map(\.id))], widgets: widgets)
        h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["home"], roles: roles))
        await h.webUI.set(config)
        await h.app.attach(homeKit, paired: true, bridge: HAPAccessory(aid: 1, services: []))
        await h.app.handle(.connected)
        for (topic, payload) in controllerMessages {
            await h.app.handle(.message(MQTTMessage(topic: topic, payload: payload)))
        }
        await h.app.refreshDashboards()
    }

    func id(_ aid: Int, _ type: String) async -> HAPCharacteristicID {
        let accessory = await h.app.hapAccessories().first { $0.aid == aid }!
        let iid = accessory.services.dropFirst().flatMap(\.characteristics).first { $0.type == type }!.iid
        return HAPCharacteristicID(aid: aid, iid: iid)
    }
}

@Test func homeKitWriteBecomesWBCommandAndEventForOthers() async throws {
    let live = await LiveHarness()
    #expect(try await live.h.page.text("wb-homekit-info", "en")?.contains("Accessories:</b> 3") == true)
    let on = await live.id(2, HAPType.Characteristic.on)
    let origin = HAPConnectionID(value: 7)

    #expect(await live.h.app.hapWrite(on, value: .bool(true), origin: origin) == .success)
    #expect(await live.h.broker.retained["/devices/wb-mr6cv3_46/controls/K1/on"] == "1")
    let event = try #require(await live.homeKit.events.last)
    #expect(event.changes[on] == .bool(true))
    #expect(event.except == origin)
    #expect(await live.h.app.hapRead(on) == .success(.bool(true)))

    // WB confirms the same value: no duplicate event.
    let before = await live.homeKit.events.count
    await live.h.app.handle(.message(MQTTMessage(topic: "/devices/wb-mr6cv3_46/controls/K1", payload: "1")))
    #expect(await live.homeKit.events.count == before)
}

@Test func wbChangeBecomesHomeKitEvent() async throws {
    let live = await LiveHarness(roles: ["dimmer": .light])
    let brightness = await live.id(3, HAPType.Characteristic.brightness)
    await live.h.app.handle(.message(MQTTMessage(topic: "/devices/wb-mdm3_223/controls/Channel 1", payload: "80")))
    let event = try #require(await live.homeKit.events.last)
    #expect(event.changes == [brightness: .int(80)])
    #expect(event.except == nil)
}

@Test func wbEventsAreLimitedToOnePerSecond() async throws {
    let live = await LiveHarness(roles: ["dimmer": .light])
    let brightness = await live.id(3, HAPType.Characteristic.brightness)
    func dim(_ value: String) async {
        await live.h.app.handle(.message(MQTTMessage(topic: "/devices/wb-mdm3_223/controls/Channel 1", payload: value)))
    }
    await dim("50")
    await dim("60")
    await dim("70")
    let sent = await live.homeKit.events.filter { $0.changes[brightness] != nil }
    #expect(sent.map { $0.changes[brightness] } == [.int(50)])

    try await Task.sleep(for: .milliseconds(1300))
    let later = await live.homeKit.events.filter { $0.changes[brightness] != nil }
    #expect(later.map { $0.changes[brightness] } == [.int(50), .int(70)])
}

@Test func pressCounterBecomesButtonEvent() async throws {
    let live = await LiveHarness()
    let button = await live.id(4, HAPType.Characteristic.programmableSwitchEvent)
    #expect(await live.homeKit.events.isEmpty)
    await live.h.app.handle(.message(MQTTMessage(topic: "/devices/wb-mdm3_223/controls/Input 1 Single Press Counter", payload: "6")))
    #expect(await live.homeKit.events.last?.changes == [button: .int(0)])
}

@Test func gateKeepsTargetUntilEndSensor() async throws {
    let live = await LiveHarness(roles: ["gate": .gate], extra: [gateWidget])
    typealias C = HAPType.Characteristic
    let target = await live.id(5, C.targetDoorState)
    let current = await live.id(5, C.currentDoorState)
    func sensor(_ control: String, _ value: String) async {
        await live.h.app.handle(.message(MQTTMessage(topic: "/devices/GateControlling/controls/\(control)", payload: value)))
    }

    #expect(await live.h.app.hapWrite(target, value: .int(0), origin: HAPConnectionID(value: 7)) == .success)
    #expect(await live.h.broker.retained["/devices/GateControlling/controls/GateOpen/on"] == "1")
    #expect(await live.h.app.hapRead(target) == .success(.int(0)))
    #expect(await live.h.app.hapRead(current) == .success(.int(1)))

    await sensor("isClosed", "0")
    #expect(await live.h.app.hapRead(current) == .success(.int(2)))
    await sensor("isOpen", "1")
    #expect(await live.h.app.hapRead(current) == .success(.int(0)))

    // Closed by a remote: the bridge follows the sensors.
    await sensor("isOpen", "0")
    await sensor("isClosed", "1")
    #expect(await live.h.app.hapRead(target) == .success(.int(1)))
    #expect(await live.h.app.hapRead(current) == .success(.int(1)))
}

@Test func roleChangeRebuildsAccessories() async throws {
    let live = await LiveHarness()
    let before = await live.homeKit.structureChanges
    await live.h.page.save(#"{"dashboards":{"home":{"enabled":true,"roles":{"widget14":\#(AccessoryRole.light.code)}}}}"#)
    await live.h.app.checkSettings()
    #expect(await live.homeKit.structureChanges == before + 1)
    let services = await live.h.app.hapAccessories().first { $0.aid == 2 }.map(serviceTypes)
    #expect(services == [HAPType.Service.lightbulb])
}

@Test func translatesWarningsNextToTheRole() async throws {
    let live = await LiveHarness(roles: ["widget14": .thermostat])
    #expect(try await live.h.page.text("wb-homekit-info", "ru")?.contains("Предупреждений:</b> 1") == true)
    #expect(try await live.h.page.text("warning-widget14", "ru") == "⚠ Термостат: нужен датчик температуры, показан как «Авто»")
    #expect(try await live.h.page.text("warning-widget14", "en") == "⚠ Thermostat: needs a temperature sensor, shown as Auto")
}
