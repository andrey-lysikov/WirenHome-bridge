//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Log {
    public enum Level: Int, Sendable {
        case debug, info, warning, error
    }

    // Debug output is enabled with WIRENHOME_BRIDGE_DEBUG=1.
    static let minimum: Level = getenv("WIRENHOME_BRIDGE_DEBUG").map { String(cString: $0) } == "1" ? .debug : .info

    public static func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public static func warning(_ message: @autoclosure () -> String) { write(.warning, message) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message) }

    // Stderr is unbuffered, so journald gets lines immediately.
    private static func write(_ level: Level, _ message: () -> String) {
        guard level.rawValue >= minimum.rawValue else { return }
        let tag = ["debug", "info", "warning", "error"][level.rawValue]
        var line = "[\(tag)] \(message())\n"
        line.withUTF8 { bytes in
            _ = systemWrite(2, bytes.baseAddress, bytes.count)
        }
    }
}

#if canImport(Glibc)
private let systemWrite = Glibc.write
#else
private let systemWrite = Darwin.write
#endif
