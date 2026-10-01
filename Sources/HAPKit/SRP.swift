//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Crypto

// SRP-6a server for HAP Pair-Setup: RFC 5054 3072-bit group, g = 5, SHA-512.
// Padding follows fast-srp-hap: B and S padded to N, g unpadded in M1, A used as received.
struct SRPServer: Sendable {
    static let N = BigUInt(hex: """
        FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1 29024E08 8A67CC74
        020BBEA6 3B139B22 514A0879 8E3404DD EF9519B3 CD3A431B 302B0A6D F25F1437
        4FE1356D 6D51C245 E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
        EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D C2007CB8 A163BF05
        98DA4836 1C55D39A 69163FA8 FD24CF5F 83655D23 DCA3AD96 1C62F356 208552BB
        9ED52907 7096966D 670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
        E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9 DE2BCBF6 95581718
        3995497C EA956AE5 15D22618 98FA0510 15728E5A 8AAAC42D AD33170D 04507A33
        A85521AB DF1CBA64 ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
        ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B F12FFA06 D98A0864
        D8760273 3EC86A64 521F2B18 177B200C BBE11757 7A615D6C 770988C0 BAD946E2
        08E24FA0 74E5AB31 43DB5BFC E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF
        """)!
    static let g = BigUInt(5)
    static let length = 384

    static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA512()
        for part in parts {
            hasher.update(data: part)
        }
        return Array(hasher.finalize())
    }

    static var k: BigUInt {
        BigUInt(bytes: hash(N.bytes(), g.bytes(length: length)))
    }

    static func x(salt: [UInt8], username: String, password: String) -> BigUInt {
        BigUInt(bytes: hash(salt, hash(Array("\(username):\(password)".utf8))))
    }

    let username: String
    let salt: [UInt8]
    let verifier: BigUInt
    private let privateKey: BigUInt
    let publicKey: [UInt8]

    init(username: String, password: String, salt: [UInt8], privateKey: [UInt8]) {
        self.username = username
        self.salt = salt
        verifier = Self.g.power(Self.x(salt: salt, username: username, password: password), modulus: Self.N)
        self.privateKey = BigUInt(bytes: privateKey)
        let b = (Self.k * verifier + Self.g.power(self.privateKey, modulus: Self.N)) % Self.N
        publicKey = b.bytes(length: Self.length)
    }

    init(username: String, password: String) {
        var generator = SystemRandomNumberGenerator()
        let random = { (count: Int) in (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) } }
        self.init(username: username, password: password, salt: random(16), privateKey: random(32))
    }

    struct Session: Sendable, Equatable {
        let u: BigUInt
        let premasterSecret: BigUInt
        let key: [UInt8]
        let clientProof: [UInt8]
        let serverProof: [UInt8]
    }

    // Derives the session for a client public key; nil if A is invalid.
    func session(clientPublicKey a: [UInt8]) -> Session? {
        let clientKey = BigUInt(bytes: a)
        guard !(clientKey % Self.N).isZero else { return nil }
        let u = BigUInt(bytes: Self.hash(clientKey.bytes(length: Self.length), publicKey))
        guard !u.isZero else { return nil }
        let base = (clientKey * verifier.power(u, modulus: Self.N)) % Self.N
        let premaster = base.power(privateKey, modulus: Self.N)
        let key = Self.hash(premaster.bytes(length: Self.length))

        let hashN = Self.hash(Self.N.bytes())
        let hashG = Self.hash(Self.g.bytes())
        let xored = zip(hashN, hashG).map { $0 ^ $1 }
        let clientProof = Self.hash(xored, Self.hash(Array(username.utf8)), salt, a, publicKey, key)
        let serverProof = Self.hash(a, clientProof, key)
        return Session(u: u, premasterSecret: premaster, key: key, clientProof: clientProof, serverProof: serverProof)
    }

    // Constant-time comparison of the client proof.
    static func matches(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
