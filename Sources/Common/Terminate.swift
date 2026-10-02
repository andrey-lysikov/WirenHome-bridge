//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Ends the process; systemd (Restart=always) starts it again with the new settings.
public enum Terminate {
    public static func now(_ code: Int32) -> Never {
        exit(code)
    }
}
