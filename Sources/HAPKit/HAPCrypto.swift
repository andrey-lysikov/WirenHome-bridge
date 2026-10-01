//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum HAPCryptoError: Error {
    case authenticationFailed
    case frameTooLarge
}

enum HAPCrypto {
    static func hkdf(_ input: [UInt8], salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    // Pairing messages use a fixed 8-byte label left-padded to the 12-byte ChaCha nonce.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8))
    }

    static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + withUnsafeBytes(of: counter.littleEndian, Array.init))
    }

    static func seal(_ plaintext: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: [UInt8] = []) -> [UInt8] {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ sealed: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: [UInt8] = []) throws -> [UInt8] {
        guard sealed.count >= 16 else { throw HAPCryptoError.authenticationFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return Array(try ChaChaPoly.open(box, using: key, authenticating: aad))
        } catch {
            throw HAPCryptoError.authenticationFailed
        }
    }
}

struct SessionKeys: Sendable {
    let accessoryToController: SymmetricKey
    let controllerToAccessory: SymmetricKey

    init(sharedSecret: [UInt8]) {
        accessoryToController = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        controllerToAccessory = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
    }

    init(accessoryToController: SymmetricKey, controllerToAccessory: SymmetricKey) {
        self.accessoryToController = accessoryToController
        self.controllerToAccessory = controllerToAccessory
    }
}

// Encrypted HAP session frames: 2-byte little-endian length (also the AAD), ciphertext, 16-byte tag.
struct FrameEncryptor: Sendable {
    let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func encrypt(_ plaintext: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        repeat {
            let length = min(1024, plaintext.count - offset)
            let aad = [UInt8(length & 0xFF), UInt8(length >> 8)]
            output += aad
            output += HAPCrypto.seal(Array(plaintext[offset..<(offset + length)]), key: key, nonce: HAPCrypto.nonce(counter: counter), aad: aad)
            counter += 1
            offset += length
        } while offset < plaintext.count
        return output
    }
}

struct FrameDecryptor: Sendable {
    let key: SymmetricKey
    private var counter: UInt64 = 0
    private var buffer: [UInt8] = []

    init(key: SymmetricKey) {
        self.key = key
    }

    // Returns plaintext of all complete frames; partial frames wait for more bytes.
    mutating func decrypt(_ bytes: [UInt8]) throws -> [UInt8] {
        buffer += bytes
        var plaintext: [UInt8] = []
        while buffer.count >= 2 {
            let length = Int(buffer[0]) | Int(buffer[1]) << 8
            guard length <= 1024 else { throw HAPCryptoError.frameTooLarge }
            guard buffer.count >= 2 + length + 16 else { break }
            let aad = Array(buffer[0..<2])
            plaintext += try HAPCrypto.open(Array(buffer[2..<(2 + length + 16)]), key: key, nonce: HAPCrypto.nonce(counter: counter), aad: aad)
            counter += 1
            buffer.removeFirst(2 + length + 16)
        }
        return plaintext
    }
}
