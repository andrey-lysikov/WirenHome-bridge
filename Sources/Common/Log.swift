//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Log {
    public enum Level: Int, Sendable {
        case debug, info, warning, error
    }

    // Debug output is enabled with WB_HOMEKIT_DEBUG=1.
    static let minimum: Level = ProcessInfo.processInfo.environment["WB_HOMEKIT_DEBUG"] == "1" ? .debug : .info

    public static func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public static func warning(_ message: @autoclosure () -> String) { write(.warning, message) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message) }

    // Stderr is unbuffered, so journald gets lines immediately.
    private static func write(_ level: Level, _ message: () -> String) {
        guard level.rawValue >= minimum.rawValue else { return }
        let tag = ["debug", "info", "warning", "error"][level.rawValue]
        FileHandle.standardError.write(Data("[\(tag)] \(message())\n".utf8))
    }
}
