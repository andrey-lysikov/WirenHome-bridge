//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto
import Foundation
import Testing
@testable import HAPKit

func bytes(hex: String) -> [UInt8] {
    BigUInt(hex: hex)!.bytes()
}

func vectorServer() -> SRPServer {
    SRPServer(username: "alice", password: "password123", salt: bytes(hex: SRPVectors.s), privateKey: bytes(hex: SRPVectors.b))
}

@Test func matchesHAPVectors() throws {
    #expect(SRPServer.k == BigUInt(hex: SRPVectors.k))
    #expect(SRPServer.x(salt: bytes(hex: SRPVectors.s), username: "alice", password: "password123") == BigUInt(hex: SRPVectors.x))

    let server = vectorServer()
    #expect(server.verifier == BigUInt(hex: SRPVectors.v))
    #expect(server.publicKey == BigUInt(hex: SRPVectors.B)!.bytes(length: 384))

    let session = try #require(server.session(clientPublicKey: BigUInt(hex: SRPVectors.A)!.bytes(length: 384)))
    #expect(session.u == BigUInt(hex: SRPVectors.u))
    #expect(session.premasterSecret == BigUInt(hex: SRPVectors.S))
    #expect(session.key == bytes(hex: SRPVectors.K))
    #expect(session.clientProof == bytes(hex: SRPVectors.M1))
}

@Test func rejectsZeroClientKey() {
    let server = vectorServer()
    #expect(server.session(clientPublicKey: [0]) == nil)
    #expect(server.session(clientPublicKey: SRPServer.N.bytes()) == nil)
}

@Test func comparesProofs() {
    #expect(SRPServer.matches([1, 2, 3], [1, 2, 3]))
    #expect(!SRPServer.matches([1, 2, 3], [1, 2, 4]))
    #expect(!SRPServer.matches([1, 2], [1, 2, 3]))
}

@Test func encryptedFramesRoundTrip() throws {
    let key = SymmetricKey(size: .bits256)
    var encryptor = FrameEncryptor(key: key)
    var decryptor = FrameDecryptor(key: key)
    let message = [UInt8]((0..<3000).map { UInt8($0 % 251) })

    let first = encryptor.encrypt(message)
    let second = encryptor.encrypt([1, 2, 3])
    #expect(first.count == 3000 + 3 * (2 + 16))

    // Delivered in odd chunks, as TCP may do.
    let stream = first + second
    var received: [UInt8] = []
    var offset = 0
    while offset < stream.count {
        let end = min(stream.count, offset + 777)
        received += try decryptor.decrypt(Array(stream[offset..<end]))
        offset = end
    }
    #expect(received == message + [1, 2, 3])
}

@Test func rejectsTamperedFrame() {
    let key = SymmetricKey(size: .bits256)
    var encryptor = FrameEncryptor(key: key)
    var decryptor = FrameDecryptor(key: key)
    var frame = encryptor.encrypt([9, 9, 9])
    frame[4] ^= 1
    #expect(throws: HAPCryptoError.self) { try decryptor.decrypt(frame) }
}
