//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public protocol Updater: Sendable {
    // Newest version offered by the bridge's apt source, nil when it cannot be checked.
    func availableVersion() async -> String?
    func startUpgrade() async -> Bool
}

// Checks and installs updates from the bridge's own apt repository only.
public struct AptUpdater: Updater {
    static let sourceList = "sources.list.d/wb-homekit.list"
    static let package = "wb-homekit"

    public init() {}

    // Present only when installed from the package, so source checkouts never touch apt.
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: "/etc/apt/\(sourceList)")
    }

    public func availableVersion() async -> String? {
        let update = await Subprocess.run("/usr/bin/apt-get", [
            "update", "-qq",
            "-o", "Dir::Etc::sourcelist=\(Self.sourceList)",
            "-o", "Dir::Etc::sourceparts=-",
            "-o", "APT::Get::List-Cleanup=0"
        ], environment: Self.environment)
        guard update.status == 0 else {
            Log.warning("apt-get update for wb-homekit failed: \(update.output)")
            return nil
        }
        let policy = await Subprocess.run("/usr/bin/apt-cache", ["policy", Self.package], environment: Self.environment)
        return Self.candidate(in: policy.output)
    }

    // Runs in a separate systemd unit so the upgrade survives the restart of this service.
    public func startUpgrade() async -> Bool {
        let result = await Subprocess.run("/usr/bin/systemd-run", [
            "--unit=wb-homekit-upgrade", "--collect",
            "/usr/bin/apt-get", "install", "-y", "--only-upgrade", Self.package
        ], environment: Self.environment)
        if result.status != 0 {
            Log.error("Cannot start upgrade: \(result.output)")
        }
        return result.status == 0
    }

    static let environment = ["LANG=C", "PATH=/usr/sbin:/usr/bin:/sbin:/bin"]

    static func candidate(in policy: String) -> String? {
        for line in policy.split(separator: "\n") {
            let trimmed = line.trimmed
            if trimmed.hasPrefix("Candidate:") {
                let value = trimmed.dropFirst("Candidate:".count).trimmed
                return value == "(none)" || value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

enum AppVersionOrder {
    // Versions are "major.minor"; anything else compares as older.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
