//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import Discovery
import HAPKit

public protocol HomeKitControl: Sendable {
    func reset(setupCode: String) async
    func accessoriesChanged() async
    func notify(_ changes: [HAPCharacteristicID: HAPValue], except origin: HAPConnectionID?) async
    func notify(_ changes: [HAPCharacteristicID: HAPValue], only target: HAPConnectionID) async
}

// HAP server plus its mDNS advertisement.
actor HomeKitService: HomeKitControl {
    let controller: HAPController
    private let server: HAPServer
    private let advertiser: ServiceAdvertiser
    private let name: String
    private var port: Int?
    private var stopped = false

    init(controller: HAPController, advertiser: ServiceAdvertiser, name: String) {
        self.controller = controller
        server = HAPServer(controller: controller)
        self.advertiser = advertiser
        self.name = name
    }

    func run() async {
        do {
            try await server.run { port in
                await self.listening(on: port)
            }
        } catch {
            Log.error("HomeKit server stopped: \(error)")
        }
    }

    // Called on SIGTERM: leave the network cleanly before the process exits.
    func stop() async {
        stopped = true
        advertiser.stop()
        await controller.closeAll()
    }

    func reset(setupCode: String) async {
        await controller.reset(setupCode: setupCode)
    }

    func pairingChanged() async {
        await advertise()
    }

    func accessoriesChanged() async {
        await controller.accessoriesChanged()
        await advertise()
    }

    func notify(_ changes: [HAPCharacteristicID: HAPValue], except origin: HAPConnectionID?) async {
        await controller.notify(changes, except: origin)
    }

    func notify(_ changes: [HAPCharacteristicID: HAPValue], only target: HAPConnectionID) async {
        await controller.notify(changes, only: target)
    }

    private func listening(on port: Int) async {
        self.port = port
        await advertise()
    }

    private func advertise() async {
        guard !stopped, let port else { return }
        let txt = await txtRecord()
        do {
            if advertiser.isRegistered {
                try advertiser.update(txt: txt)
            } else {
                try advertiser.register(name: name, type: "_hap._tcp", port: port, txt: txt)
            }
        } catch {
            Log.error("\(error)")
        }
    }

    // ci=2 is the Bridge category; sf=1 means "ready for pairing".
    private func txtRecord() async -> [(String, String)] {
        [
            ("c#", String(await controller.configNumber)),
            ("ff", "0"),
            ("id", await controller.deviceID),
            ("md", name),
            ("pv", "1.1"),
            ("s#", "1"),
            ("sf", await controller.isPaired ? "0" : "1"),
            ("ci", "2")
        ]
    }
}
