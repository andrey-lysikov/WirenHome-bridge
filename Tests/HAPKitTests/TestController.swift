//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto
import Foundation
import Testing
@testable import HAPKit

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

// Plays the iPhone side of HAP pairing against an accessory.
struct TestController: Sendable {
    typealias Exchange = @Sendable (_ method: String, _ path: String, _ body: [UInt8]) async throws -> (status: Int, body: [UInt8])

    let identifier = "TEST-CONTROLLER-\(UUID().uuidString.prefix(8))"
    let signingKey = Curve25519.Signing.PrivateKey()
    var accessoryKey: Curve25519.Signing.PublicKey?
    var accessoryID: String?

    // Runs M1-M6 and returns the TLV error code if the accessory refused.
    mutating func pairSetup(code: String, exchange: Exchange) async throws -> UInt8? {
        let m2 = try await tlv(exchange("POST", "/pair-setup", TLV8([(.state, [1]), (.method, [0])]).encoded()))
        if let error = m2.byte(.error) { return error }
        guard let salt = m2[.salt], let serverKey = m2[.publicKey] else { throw TestFailure(description: "M2 incomplete") }

        let N = SRPServer.N
        let a = BigUInt(bytes: (0..<32).map { _ in UInt8.random(in: 0...255) })
        let clientKey = SRPServer.g.power(a, modulus: N).bytes(length: 384)
        let x = SRPServer.x(salt: salt, username: "Pair-Setup", password: code)
        let u = BigUInt(bytes: SRPServer.hash(clientKey, serverKey))
        let kv = (SRPServer.k * SRPServer.g.power(x, modulus: N)) % N
        let base = (BigUInt(bytes: serverKey) + N - kv) % N
        let premaster = base.power(a + u * x, modulus: N)
        let sessionKey = SRPServer.hash(premaster.bytes(length: 384))
        let xored = zip(SRPServer.hash(N.bytes()), SRPServer.hash(SRPServer.g.bytes())).map { $0 ^ $1 }
        let proof = SRPServer.hash(xored, SRPServer.hash(Array("Pair-Setup".utf8)), salt, clientKey, serverKey, sessionKey)

        let m4 = try await tlv(exchange("POST", "/pair-setup", TLV8([(.state, [3]), (.publicKey, clientKey), (.proof, proof)]).encoded()))
        if let error = m4.byte(.error) { return error }
        guard m4[.proof] == SRPServer.hash(clientKey, proof, sessionKey) else { throw TestFailure(description: "bad server proof") }

        let encryptKey = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let controllerX = HAPController.raw(HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info"))
        let ltpk = Array(signingKey.publicKey.rawRepresentation)
        let signature = try signingKey.signature(for: controllerX + Array(identifier.utf8) + ltpk)
        let sub = TLV8([(.identifier, Array(identifier.utf8)), (.publicKey, ltpk), (.signature, Array(signature))])
        let m5 = TLV8([(.state, [5]), (.encryptedData, HAPCrypto.seal(sub.encoded(), key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg05")))])

        let m6 = try await tlv(exchange("POST", "/pair-setup", m5.encoded()))
        if let error = m6.byte(.error) { return error }
        let reply = try TLV8(decoding: HAPCrypto.open(m6[.encryptedData] ?? [], key: encryptKey, nonce: HAPCrypto.nonce("PS-Msg06")))
        guard let rawID = reply[.identifier], let rawKey = reply[.publicKey], let accessorySignature = reply[.signature] else {
            throw TestFailure(description: "M6 incomplete")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        let accessoryX = HAPController.raw(HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info"))
        guard key.isValidSignature(accessorySignature, for: accessoryX + rawID + rawKey) else {
            throw TestFailure(description: "bad accessory signature")
        }
        accessoryKey = key
        accessoryID = String(decoding: rawID, as: UTF8.self)
        return nil
    }

    // Runs M1-M4 and returns the session keys both sides derive.
    func pairVerify(exchange: Exchange) async throws -> SessionKeys {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ownKey = Array(ephemeral.publicKey.rawRepresentation)
        let m2 = try await tlv(exchange("POST", "/pair-verify", TLV8([(.state, [1]), (.publicKey, ownKey)]).encoded()))
        guard let accessoryEphemeral = m2[.publicKey], let encrypted = m2[.encryptedData], let accessoryKey else {
            throw TestFailure(description: "verify M2 incomplete")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: accessoryEphemeral)).withUnsafeBytes { Array($0) }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = try TLV8(decoding: HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PV-Msg02")))
        guard let rawID = sub[.identifier], let signature = sub[.signature],
              accessoryKey.isValidSignature(signature, for: accessoryEphemeral + rawID + ownKey)
        else {
            throw TestFailure(description: "bad accessory verify signature")
        }

        let ownSignature = try signingKey.signature(for: ownKey + Array(identifier.utf8) + accessoryEphemeral)
        let m3sub = TLV8([(.identifier, Array(identifier.utf8)), (.signature, Array(ownSignature))])
        let m3 = TLV8([(.state, [3]), (.encryptedData, HAPCrypto.seal(m3sub.encoded(), key: key, nonce: HAPCrypto.nonce("PV-Msg03")))])
        let m4 = try await tlv(exchange("POST", "/pair-verify", m3.encoded()))
        guard m4.byte(.state) == 4, m4.byte(.error) == nil else { throw TestFailure(description: "verify refused") }
        return SessionKeys(sharedSecret: shared)
    }

    private func tlv(_ response: (status: Int, body: [UInt8])) throws -> TLV8 {
        guard response.status == 200 else { throw TestFailure(description: "HTTP \(response.status)") }
        return try TLV8(decoding: response.body)
    }
}

actor RecordingSink: HAPConnectionSink {
    private(set) var sent: [String] = []
    private(set) var isClosed = false

    func send(_ plaintext: [UInt8]) async {
        sent.append(String(decoding: plaintext, as: UTF8.self))
    }

    func close() async {
        isClosed = true
    }
}

final class MemoryStorage: HAPStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: HAPIdentity?

    func load() throws -> HAPIdentity? {
        lock.withLock { identity }
    }

    func save(_ identity: HAPIdentity) throws {
        lock.withLock { self.identity = identity }
    }
}

actor TestAccessories: HAPAccessoryDelegate {
    var on = false
    private(set) var writes: [(HAPCharacteristicID, HAPValue)] = []
    private(set) var identified = 0

    func accessories() async -> [HAPAccessory] {
        [
            HAPAccessory(aid: 1, services: [
                HAPService(iid: 1, type: HAPType.Service.accessoryInformation, characteristics: [
                    HAPCharacteristic(iid: 2, type: HAPType.Characteristic.identify, format: .bool, permissions: .write),
                    HAPCharacteristic(iid: 3, type: HAPType.Characteristic.name, format: .string, permissions: .read, value: .string("Test"))
                ]),
                HAPService(iid: 10, type: HAPType.Service.switch, characteristics: [
                    HAPCharacteristic(iid: 11, type: HAPType.Characteristic.on, format: .bool, permissions: .readWriteEvents, value: .bool(on))
                ])
            ])
        ]
    }

    func read(_ id: HAPCharacteristicID) async -> Result<HAPValue, HAPStatus> {
        switch (id.aid, id.iid) {
        case (1, 3): .success(.string("Test"))
        case (1, 11): .success(.bool(on))
        default: .failure(.notFound)
        }
    }

    func write(_ id: HAPCharacteristicID, value: HAPValue, origin: HAPConnectionID) async -> HAPStatus {
        writes.append((id, value))
        if id.iid == 11, let flag = value.boolValue {
            on = flag
        }
        return .success
    }

    func identify() async {
        identified += 1
    }
}
