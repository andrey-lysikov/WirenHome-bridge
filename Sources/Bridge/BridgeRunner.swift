//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import Discovery
import Foundation
import HAPKit
import WBKit

// Wires MQTT, RPC and the bridge together and drives them.
public final class BridgeRunner: Sendable {
    private let connection: MQTTConnection
    private let rpc: RPCClient
    private let app: BridgeApp
    private let homeKit: HomeKitService
    private let bridge: HAPAccessory

    static var clientID: String {
        #if os(macOS)
        "wb-homekit-dev"
        #else
        "wb-homekit"
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
            subscriptions: ["/devices/#", RPCClient.replyFilter(for: Self.clientID)],
            will: PluginModel.stoppedMessage
        )
        rpc = RPCClient(publisher: connection, clientID: Self.clientID)
        app = BridgeApp(publisher: connection, source: ConfedWebUISource(rpc: rpc), store: store, state: state, version: version)

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
        homeKit = HomeKitService(controller: controller, advertiser: advertiser, name: Self.bridgeName(deviceID))
    }

    // A stable, distinguishable name: "WirenHome 3A7F" from the device id tail.
    static func bridgeName(_ deviceID: String) -> String {
        let tail = deviceID.replacingOccurrences(of: ":", with: "").suffix(4)
        return "WirenHome \(tail)"
    }

    public func run() async {
        let controller = homeKit.controller
        await app.attach(homeKit, paired: await controller.isPaired, bridge: bridge)
        await controller.setPairingChangeHandler { [homeKit, app] paired in
            await homeKit.pairingChanged()
            await app.setPaired(paired)
        }
        let updates = AptUpdater.isAvailable
        if updates {
            await app.attach(updater: AptUpdater())
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
                    if case .message(let message) = event, await self.rpc.handle(message) {
                        continue
                    }
                    if event == .disconnected {
                        await self.rpc.failAll()
                    }
                    await self.app.handle(event)
                }
            }
            if updates {
                group.addTask {
                    // First check shortly after start, then once a day.
                    try? await Task.sleep(for: .seconds(60))
                    while !Task.isCancelled {
                        await self.app.checkForUpdates()
                        try? await Task.sleep(for: .seconds(24 * 3600))
                    }
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
