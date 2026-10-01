//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

// Minimal unsigned big integer for SRP: little-endian 32-bit limbs, no trailing zero limbs.
struct BigUInt: Sendable, Equatable, Comparable {
    private(set) var limbs: [UInt32]

    static let zero = BigUInt(limbs: [])

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    // Big-endian bytes, as used on the wire.
    init(bytes: some Collection<UInt8>) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << (8 * (index % 4))
        }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var chars = Array(digits)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    // Minimal big-endian bytes, or left-padded with zeros to `length`.
    func bytes(length: Int? = nil) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            for shift in stride(from: 24, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: limb >> UInt32(shift)))
            }
        }
        let firstNonZero = result.firstIndex { $0 != 0 } ?? result.count
        result.removeFirst(firstNonZero)
        if let length, result.count < length {
            result.insert(contentsOf: [UInt8](repeating: 0, count: length - result.count), at: 0)
        }
        return result
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let sum = UInt64(index < lhs.limbs.count ? lhs.limbs[index] : 0) + UInt64(index < rhs.limbs.count ? rhs.limbs[index] : 0) + carry
            result[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        result[count] = UInt32(carry)
        return BigUInt(limbs: result)
    }

    // Requires lhs >= rhs.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var result = lhs.limbs
        var borrow: Int64 = 0
        for index in 0..<result.count {
            let difference = Int64(result[index]) - Int64(index < rhs.limbs.count ? rhs.limbs[index] : 0) - borrow
            result[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return .zero }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        lhs.limbs.withUnsafeBufferPointer { a in
            rhs.limbs.withUnsafeBufferPointer { b in
                result.withUnsafeMutableBufferPointer { r in
                    for i in 0..<a.count {
                        var carry: UInt64 = 0
                        let ai = UInt64(a[i])
                        for j in 0..<b.count {
                            let t = ai * UInt64(b[j]) + UInt64(r[i + j]) + carry
                            r[i + j] = UInt32(truncatingIfNeeded: t)
                            carry = t >> 32
                        }
                        r[i + b.count] = UInt32(carry)
                    }
                }
            }
        }
        return BigUInt(limbs: result)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    // Knuth, TAOCP vol. 2, 4.3.1 Algorithm D (as in Hacker's Delight divmnu).
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt division by zero")
        if self < divisor {
            return (.zero, self)
        }
        if divisor.limbs.count == 1 {
            return shortDivision(by: divisor.limbs[0])
        }

        let n = divisor.limbs.count
        let m = limbs.count
        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        let vn = Self.shiftedLeft(divisor.limbs, by: shift, extraLimb: false)
        var un = Self.shiftedLeft(limbs, by: shift, extraLimb: true)
        var quotient = [UInt32](repeating: 0, count: m - n + 1)
        let base: UInt64 = 1 << 32

        un.withUnsafeMutableBufferPointer { u in
            vn.withUnsafeBufferPointer { v in
                for j in stride(from: m - n, through: 0, by: -1) {
                    let numerator = UInt64(u[j + n]) << 32 | UInt64(u[j + n - 1])
                    var qhat = numerator / UInt64(v[n - 1])
                    var rhat = numerator % UInt64(v[n - 1])
                    while qhat >= base || qhat * UInt64(v[n - 2]) > (rhat << 32 | UInt64(u[j + n - 2])) {
                        qhat -= 1
                        rhat += UInt64(v[n - 1])
                        if rhat >= base { break }
                    }

                    var borrow: Int64 = 0
                    for i in 0..<n {
                        let product = qhat * UInt64(v[i])
                        let t = Int64(u[i + j]) - borrow - Int64(product & 0xFFFF_FFFF)
                        u[i + j] = UInt32(truncatingIfNeeded: t)
                        borrow = Int64(product >> 32) - (t >> 32)
                    }
                    let t = Int64(u[j + n]) - borrow
                    u[j + n] = UInt32(truncatingIfNeeded: t)

                    if t < 0 {
                        // qhat was one too large: add the divisor back.
                        qhat -= 1
                        var carry: UInt64 = 0
                        for i in 0..<n {
                            let sum = UInt64(u[i + j]) + UInt64(v[i]) + carry
                            u[i + j] = UInt32(truncatingIfNeeded: sum)
                            carry = sum >> 32
                        }
                        u[j + n] = u[j + n] &+ UInt32(truncatingIfNeeded: carry)
                    }
                    quotient[j] = UInt32(truncatingIfNeeded: qhat)
                }
            }
        }

        var remainder = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            remainder[i] = shift == 0 ? un[i] : (un[i] >> UInt32(shift)) | (un[i + 1] << UInt32(32 - shift))
        }
        return (BigUInt(limbs: quotient), BigUInt(limbs: remainder))
    }

    private func shortDivision(by divisor: UInt32) -> (quotient: BigUInt, remainder: BigUInt) {
        var quotient = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for index in stride(from: limbs.count - 1, through: 0, by: -1) {
            let current = remainder << 32 | UInt64(limbs[index])
            quotient[index] = UInt32(current / UInt64(divisor))
            remainder = current % UInt64(divisor)
        }
        return (BigUInt(limbs: quotient), BigUInt(remainder))
    }

    private static func shiftedLeft(_ limbs: [UInt32], by shift: Int, extraLimb: Bool) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: limbs.count + (extraLimb ? 1 : 0))
        for index in 0..<limbs.count {
            result[index] |= limbs[index] << UInt32(shift)
            if shift > 0, index + 1 < result.count {
                result[index + 1] = limbs[index] >> UInt32(32 - shift)
            }
        }
        return result
    }

    // Left-to-right binary exponentiation.
    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1) % modulus
        let base = self % modulus
        for limb in exponent.limbs.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = (result * result) % modulus
                if limb >> UInt32(bit) & 1 == 1 {
                    result = (result * base) % modulus
                }
            }
        }
        return result
    }
}
