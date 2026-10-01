//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import HAPKit

// Deterministic xorshift so failures are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

func randomBig(limbs: Int, using generator: inout SeededGenerator) -> BigUInt {
    BigUInt(limbs: (0..<limbs).map { _ in
        // Bias towards edge values that stress Algorithm D.
        switch generator.next() % 6 {
        case 0: 0
        case 1: UInt32.max
        case 2: 0x8000_0000
        default: UInt32(truncatingIfNeeded: generator.next())
        }
    })
}

@Test func convertsBytes() {
    let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
    #expect(BigUInt(bytes: bytes).limbs == [0x0203_0405, 0x01])
    #expect(BigUInt(bytes: bytes).bytes() == bytes)
    #expect(BigUInt(bytes: [0, 0, 7]).bytes() == [7])
    #expect(BigUInt(bytes: [7]).bytes(length: 3) == [0, 0, 7])
    #expect(BigUInt.zero.bytes() == [])
}

@Test func arithmeticOnSmallNumbers() {
    let a = BigUInt(0xFFFF_FFFF_FFFF)
    let b = BigUInt(0x1_0000)
    #expect(a + b == BigUInt(0x1_0000_0000_FFFF))
    #expect(a - b == BigUInt(0xFFFF_FFFE_FFFF))
    #expect(BigUInt(0xFFFF_FFFF) * BigUInt(0xFFFF_FFFF) == BigUInt(0xFFFF_FFFE_0000_0001))
    #expect(BigUInt(1000) % BigUInt(7) == BigUInt(6))
    #expect(BigUInt(3).power(BigUInt(200), modulus: BigUInt(1_000_000_007)) == BigUInt(136_318_165))
}

@Test func divisionReconstructsDividend() {
    var generator = SeededGenerator(state: 0x5EED_1234_ABCD_0001)
    for _ in 0..<2000 {
        let divisor = randomBig(limbs: Int(generator.next() % 12) + 1, using: &generator)
        guard !divisor.isZero else { continue }
        let dividend = randomBig(limbs: Int(generator.next() % 24) + 1, using: &generator)
        let (q, r) = dividend.quotientAndRemainder(dividingBy: divisor)
        #expect(r < divisor)
        #expect(q * divisor + r == dividend)
    }
}

@Test func multiplicationDistributes() {
    var generator = SeededGenerator(state: 42)
    for _ in 0..<300 {
        let a = randomBig(limbs: 10, using: &generator)
        let b = randomBig(limbs: 7, using: &generator)
        let c = randomBig(limbs: 5, using: &generator)
        #expect(a * (b + c) == a * b + a * c)
    }
}
