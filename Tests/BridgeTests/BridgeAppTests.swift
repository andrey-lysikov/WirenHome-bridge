//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import HAPKit
import WBKit
@testable import Bridge

actor FakeBroker: MQTTPublisher {
    private(set) var retained: [String: String] = [:]

    func publish(_ message: MQTTMessage) async {
        retained[message.topic] = message.payload.isEmpty ? nil : message.payload
    }

    func value(_ control: String) -> String? {
        retained["/devices/wb-homekit/controls/\(control)"]
    }

    func meta(_ control: String) -> WBControlMeta? {
        retained["/devices/wb-homekit/controls/\(control)/meta"].flatMap(WBControlMeta.decode)
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
    private(set) var resets: [String] = []
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

    func reset(setupCode: String) async {
        resets.append(setupCode)
    }
}

struct Harness {
    let broker = FakeBroker()
    let webUI = FakeWebUI(sampleConfig)
    let store = StateStore(directory: temporaryDirectory())
    let app: BridgeApp

    init(state: BridgeState = BridgeState(pinCode: "031-45-154")) {
        app = BridgeApp(publisher: broker, source: webUI, store: store, state: state, version: "0.1")
    }

    func command(_ control: String, _ payload: String) async {
        await app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/controls/\(control)/on", payload: payload, retain: false)))
    }
}

@Test func publishesBaseControlsOnConnect() async {
    let h = Harness()
    await h.app.handle(.connected)

    #expect(await h.broker.retained["/devices/wb-homekit/meta"]?.contains("Мост Apple HomeKit") == true)
    #expect(await h.broker.value("pincode") == "031-45-154")
    #expect(await h.broker.meta("enabled") == nil)
    #expect(await h.broker.value("version") == "0.1")
    #expect(await h.broker.value("status") == "0")
    #expect(await h.broker.meta("status")?.enumTitles?["1"]?["en"] == "Waiting for pairing")
    #expect(await h.broker.meta("reset_pairing")?.type == "pushbutton")
}

@Test func addsDashboardSwitchesAndRolesForSelected() async throws {
    let h = Harness()
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    #expect(await h.broker.meta("dashboard_kitchen")?.title?["ru"] == "Панель «Кухня»")
    #expect(await h.broker.value("dashboard_kitchen") == "0")
    #expect(await h.broker.meta("role_light") == nil)

    await h.command("dashboard_kitchen", "1")
    #expect(await h.broker.value("dashboard_kitchen") == "1")
    let role = try #require(await h.broker.meta("role_light"))
    #expect(role.title?["ru"]?.hasPrefix("Кухня → Свет ⚠ нет устройства wb-mdm3_223/K1") == true)
    #expect(role.order == 101)
    #expect(role.enumTitles?["4"]?["ru"] == "Термостат")
    #expect(await h.broker.value("role_light") == "0")
    #expect(await h.broker.value("status") == "1")
    #expect(try h.store.load()?.dashboards == ["kitchen"])

    await h.command("dashboard_kitchen", "0")
    #expect(await h.broker.meta("role_light") == nil)
}

@Test func storesRoleAndEchoesValue() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen"]))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    await h.command("role_light", "1")
    #expect(await h.broker.value("role_light") == "1")
    #expect(try h.store.load()?.roles == ["light": .light])

    await h.command("role_light", "99")
    #expect(await h.broker.value("role_light") == "1")
}

@Test func resetsPairing() async {
    let h = Harness()
    await h.app.handle(.connected)

    await h.command("reset_pairing", "1")
    let pin = await h.broker.value("pincode")
    #expect(pin != "031-45-154")
    #expect(PinCode.isValid(pin ?? ""))
}

@Test func ignoresRetainedCommands() async {
    let h = Harness()
    await h.app.handle(.connected)
    await h.app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/controls/reset_pairing/on", payload: "1", retain: true)))
    #expect(await h.broker.value("pincode") == "031-45-154")
}

@Test func waitsForDashboardEditsToSettle() async {
    let h = Harness()
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    let edited = WebUIConfig(dashboards: sampleConfig.dashboards + [.init(id: "garage", name: "Гараж", widgets: [])], widgets: sampleConfig.widgets)
    await h.webUI.set(edited)
    await h.app.refreshDashboards()
    #expect(await h.broker.meta("dashboard_garage") == nil)

    await h.app.refreshDashboards()
    #expect(await h.broker.meta("dashboard_garage") != nil)
}

@Test func removesLeftoverControlsAndForgetsDeletedDashboards() async throws {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen", "gone"], roles: ["light": .light, "old": .fan]))
    await h.app.handle(.message(MQTTMessage(topic: "/devices/wb-homekit/controls/dashboard_gone/meta", payload: #"{"type":"switch"}"#)))
    await h.broker.publish(MQTTMessage(topic: "/devices/wb-homekit/controls/dashboard_gone/meta", payload: #"{"type":"switch"}"#))

    await h.app.handle(.connected)
    #expect(await h.broker.meta("dashboard_gone") != nil)

    await h.app.refreshDashboards()
    #expect(await h.broker.meta("dashboard_gone") == nil)
    let state = try #require(try h.store.load())
    #expect(state.dashboards == ["kitchen"])
    #expect(state.roles == ["light": .light])
}

@Test func drivesHomeKitFromPluginControls() async {
    let h = Harness()
    let homeKit = FakeHomeKit()
    await h.app.attach(homeKit, paired: false, bridge: HAPAccessory(aid: 1, services: []))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    await h.command("reset_pairing", "1")
    let pin = await h.broker.value("pincode")
    #expect(await homeKit.resets == [pin ?? ""])

    await h.app.setPaired(true)
    #expect(await h.broker.value("status") == "2")
}

struct LiveHarness {
    let h: Harness
    let homeKit = FakeHomeKit()

    init(roles: [String: AccessoryRole] = [:]) async {
        let buttons = widget("buttons", "Кнопки", [("wb-mdm3_223/Input 1 Single Press Counter", "Кнопка")])
        let config = WebUIConfig(dashboards: [.init(id: "home", name: "Дом", widgets: ["widget14", "dimmer", "buttons"])], widgets: [bathWidget, dimmerWidget, buttons])
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
    #expect(await live.h.broker.value("status") == "2")
    #expect(await live.h.broker.value("accessories") == "3")
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

@Test func pressCounterBecomesButtonEvent() async throws {
    let live = await LiveHarness()
    let button = await live.id(4, HAPType.Characteristic.programmableSwitchEvent)
    #expect(await live.homeKit.events.isEmpty)
    await live.h.app.handle(.message(MQTTMessage(topic: "/devices/wb-mdm3_223/controls/Input 1 Single Press Counter", payload: "6")))
    #expect(await live.homeKit.events.last?.changes == [button: .int(0)])
}

@Test func roleChangeRebuildsAccessories() async {
    let live = await LiveHarness()
    let before = await live.homeKit.structureChanges
    await live.h.command("role_widget14", String(AccessoryRole.light.code))
    #expect(await live.homeKit.structureChanges == before + 1)
    let services = await live.h.app.hapAccessories().first { $0.aid == 2 }.map(serviceTypes)
    #expect(services == [HAPType.Service.lightbulb])
}

actor FakeUpdater: Updater {
    var version: String?
    private(set) var upgrades = 0

    init(_ version: String?) {
        self.version = version
    }

    func availableVersion() async -> String? {
        version
    }

    func startUpgrade() async -> Bool {
        upgrades += 1
        return true
    }
}

@Test func reportsAndInstallsUpdates() async {
    let h = Harness()
    let updater = FakeUpdater("0.2")
    await h.app.attach(updater: updater)
    await h.app.handle(.connected)
    #expect(await h.broker.value("available_version") == "—")

    await h.app.checkForUpdates()
    #expect(await h.broker.value("available_version") == "0.2")
    await h.command("update", "1")
    #expect(await updater.upgrades == 1)
    #expect(await h.broker.value("status") == "3")
}

@Test func ignoresUpdateWhenCurrent() async {
    let h = Harness()
    let updater = FakeUpdater("0.1")
    await h.app.attach(updater: updater)
    await h.app.handle(.connected)
    await h.app.checkForUpdates()
    #expect(await h.broker.value("available_version") == "—")
    await h.command("update", "1")
    #expect(await updater.upgrades == 0)
}

@Test func parsesAptPolicy() {
    let policy = """
    wb-homekit:
      Installed: 0.1
      Candidate: 0.3
      Version table:
    """
    #expect(AptUpdater.candidate(in: policy) == "0.3")
    #expect(AptUpdater.candidate(in: "wb-homekit:\n  Candidate: (none)") == nil)
    #expect(AppVersionOrder.isNewer("0.10", than: "0.9"))
    #expect(!AppVersionOrder.isNewer("0.1", than: "0.1"))
    #expect(!AppVersionOrder.isNewer("0.9", than: "1.0"))
}

@Test func groupsRolesUnderTheirDashboard() async {
    let h = Harness(state: BridgeState(pinCode: "031-45-154", dashboards: ["kitchen", "hall"]))
    await h.app.handle(.connected)
    await h.app.refreshDashboards()

    // kitchen: switch, light, sensor; hall: switch, door (sensor is already listed under kitchen).
    #expect(await h.broker.meta("dashboard_kitchen")?.order == 100)
    #expect(await h.broker.meta("role_light")?.order == 101)
    #expect(await h.broker.meta("role_sensor")?.order == 102)
    #expect(await h.broker.meta("dashboard_hall")?.order == 103)
    #expect(await h.broker.meta("role_door")?.order == 104)
    #expect(await h.broker.meta("role_door")?.title?["ru"] == "Холл → Дверь ⚠ нет ячеек для HomeKit")
}

@Test func translatesWarningsIntoRoleTitles() async {
    let live = await LiveHarness(roles: ["widget14": .thermostat])
    #expect(await live.h.broker.value("warnings") == "1")
    let title = await live.h.broker.meta("role_widget14")?.title
    #expect(title?["ru"] == "Дом → Свет в ванной ⚠ Термостат: нужен датчик температуры, показан как «Авто»")
    #expect(title?["en"] == "Дом → Свет в ванной ⚠ Thermostat: needs a temperature sensor, shown as Auto")
}
