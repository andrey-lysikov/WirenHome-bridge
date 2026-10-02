//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import Discovery
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HAPKit
import WBKit

// Wires MQTT, the web UI and the bridge together and drives them.
public final class BridgeRunner: Sendable {
    private let connection: MQTTConnection
    private let app: BridgeApp
    private let homeKit: HomeKitService
    private let bridge: HAPAccessory

    static var clientID: String {
        #if os(macOS)
        "wirenhome-bridge-dev"
        #else
        "wirenhome-bridge"
        #endif
    }

    public init(settings: Settings, version: String) throws {
        let store = StateStore(directory: URL(fileURLWithPath: settings.dataDirectory))
        // Checked first so a missing mDNS library stops startup with an install hint.
        let advertiser = try ServiceAdvertiser()
        let state = try store.load() ?? BridgeState()
        try store.save(state)

        connection = MQTTConnection(
            settings: settings.mqtt,
            clientID: Self.clientID,
            subscriptions: ["/devices/#"]
        )
        // The web UI lives on the same host as the broker: localhost on the controller, its IP from Xcode.
        let dashboards = WebUIDashboardsSource(host: settings.mqtt.host)
        app = BridgeApp(
            publisher: connection, source: dashboards, store: store, state: state, version: version,
            page: FileSettingsPage(settingsPath: settings.configPath), configPath: settings.configPath
        )

        let storage = FileHAPStorage(url: store.directory.appendingPathComponent("homekit.json"))
        // Created here so the bridge name is known before the controller starts.
        let identity = try storage.load() ?? HAPIdentity.generate()
        try storage.save(identity)
        let deviceID = identity.deviceID
        let controller = try HAPController(
            storage: storage,
            delegate: BridgeAccessories(app: app),
            setupCode: state.pinCode
        )
        bridge = BridgeAccessories.bridge(name: Self.bridgeName(deviceID), serial: deviceID, version: version)
        homeKit = HomeKitService(controller: controller, advertiser: advertiser, name: Self.bridgeName(deviceID), setupID: state.setupID)
    }

    // A stable, distinguishable name: "WirenHome 3A7F" from the device id tail.
    static func bridgeName(_ deviceID: String) -> String {
        let tail = deviceID.filter { $0 != ":" }.suffix(4)
        return "WirenHome \(tail)"
    }

    public func run() async {
        let controller = homeKit.controller
        await app.attach(homeKit, paired: await controller.isPaired, bridge: bridge)
        await controller.setPairingChangeHandler { [homeKit, app] paired in
            await homeKit.pairingChanged()
            await app.setPaired(paired)
        }

        await withDiscardingTaskGroup { group in
            group.addTask {
                // HomeKit starts only with a real accessory list, never an empty placeholder.
                await self.app.waitUntilReady()
                await self.homeKit.run()
            }
            group.addTask {
                await self.connection.run()
            }
            group.addTask {
                for await event in self.connection.events {
                    await self.app.handle(event)
                }
            }
            group.addTask {
                // The settings page saves /etc/wirenhome-bridge.conf; pick changes up within seconds.
                while !Task.isCancelled {
                    if await self.app.checkSettings() {
                        await self.stop()
                        Terminate.now(0)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                while !Task.isCancelled {
                    await self.app.refreshDashboards()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    public func stop() async {
        await homeKit.stop()
        await app.stop()
        await connection.disconnect()
    }
}
