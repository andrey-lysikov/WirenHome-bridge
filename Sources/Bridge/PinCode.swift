//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

public enum PinCode {
    // HomeKit rejects trivial codes.
    static let forbidden: Set<String> = Set((0...9).map { String(repeating: String($0), count: 8) } + ["12345678", "87654321"])

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        while true {
            let digits = (0..<8).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
            if !forbidden.contains(digits) {
                return format(digits)
            }
        }
    }

    public static func isValid(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [3, 2, 3] else { return false }
        let digits = parts.joined()
        return digits.allSatisfy { $0.isASCII && $0.isNumber } && !forbidden.contains(digits)
    }

    static func format(_ digits: String) -> String {
        let d = Array(digits)
        return "\(String(d[0..<3]))-\(String(d[3..<5]))-\(String(d[5..<8]))"
    }
}
