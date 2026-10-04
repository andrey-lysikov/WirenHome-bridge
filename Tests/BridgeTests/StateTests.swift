//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import Bridge

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wirehome-\(UUID().uuidString)")
}

@Test func generatedPinCodesAreValid() {
    for _ in 0..<200 {
        let code = PinCode.generate()
        #expect(PinCode.isValid(code), "\(code)")
    }
}

@Test(arguments: ["111-11-111", "123-45-678", "876-54-321", "12345678", "123-456-78", "12a-45-679", ""])
func rejectsInvalidPinCode(code: String) {
    #expect(!PinCode.isValid(code))
}

@Test func storesStateRoundTrip() throws {
    let store = StateStore(directory: temporaryDirectory())
    defer { try? FileManager.default.removeItem(at: store.directory) }
    #expect(try store.load() == nil)

    let state = BridgeState(pinCode: "031-45-154", dashboards: ["d1"], roles: ["w1": .thermostat])
    try store.save(state)
    #expect(try store.load() == state)

    let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func loadsOlderOrDamagedFields() throws {
    let json = #"{"pinCode":"111-11-111","roles":{"w1":"light","w2":"spaceship"}}"#
    let state = try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8))
    #expect(PinCode.isValid(state.pinCode))
    #expect(state.dashboards.isEmpty)
    #expect(state.roles == ["w1": .light])
}

@Test func roleCodesAreStable() {
    #expect(AccessoryRole.allCases.map(\.code) == Array(0...12))
    for role in AccessoryRole.allCases {
        #expect(AccessoryRole(code: role.code) == role)
    }
    #expect(AccessoryRole(code: 42) == nil)
}
