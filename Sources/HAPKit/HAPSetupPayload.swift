//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// What a HomeKit QR code carries and how iOS finds the accessory after scanning it.
public enum HAPSetupPayload {
    static let setupIDAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    // Category, "supports IP" flag and the 8-digit code in base36, followed by the 4-character setup ID.
    public static func uri(setupCode: String, setupID: String, category: Int = 2) -> String {
        let code = UInt64(setupCode.filter(\.isNumber)) ?? 0
        let value = UInt64(category) << 31 | 1 << 28 | code
        let payload = String(value, radix: 36, uppercase: true)
        return "X-HM://" + String(repeating: "0", count: max(0, 9 - payload.count)) + payload + setupID
    }

    // The "sh" TXT value: first 4 bytes of SHA-512 over setup ID and device ID, in base64.
    public static func setupHash(setupID: String, deviceID: String) -> String {
        Data(SHA512.hash(data: Data((setupID + deviceID).utf8)).prefix(4)).base64EncodedString()
    }

    public static func generateSetupID() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<4).map { _ in setupIDAlphabet.randomElement(using: &generator)! })
    }

    public static func isValidSetupID(_ id: String) -> Bool {
        id.count == 4 && id.allSatisfy { setupIDAlphabet.contains($0) }
    }
}
