//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import HAPKit

// HAP delegate that forwards to the app, which owns WB state and the accessory mapping.
struct BridgeAccessories: HAPAccessoryDelegate {
    let app: BridgeApp

    func accessories() async -> [HAPAccessory] {
        await app.hapAccessories()
    }

    func read(_ id: HAPCharacteristicID) async -> Result<HAPValue, HAPStatus> {
        await app.hapRead(id)
    }

    func write(_ id: HAPCharacteristicID, value: HAPValue, origin: HAPConnectionID) async -> HAPStatus {
        await app.hapWrite(id, value: value, origin: origin)
    }

    func identify() async {
        Log.info("HomeKit asked the bridge to identify itself")
    }

    // aid 1: the bridge itself.
    static func bridge(name: String, serial: String, version: String) -> HAPAccessory {
        var information = AccessoryMapper.information(name: name, model: "Wiren Board bridge", serial: serial, version: version)
        information.primary = false
        return HAPAccessory(aid: 1, services: [
            information,
            HAPService(iid: 8, type: HAPType.Service.protocolInformation, characteristics: [
                HAPCharacteristic(iid: 9, type: HAPType.Characteristic.version, format: .string, permissions: .read, value: .string("1.1.0"))
            ])
        ])
    }
}
