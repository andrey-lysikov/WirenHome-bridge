//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Runs a program with posix_spawn and collects stdout and stderr together.
public enum Subprocess {
    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let output: String
    }

    public static func run(_ executable: String, _ arguments: [String], environment: [String] = []) async -> Result {
        await Task.detached { runBlocking(executable, arguments, environment: environment) }.value
    }

    static func runBlocking(_ executable: String, _ arguments: [String], environment: [String]) -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return Result(status: -1, output: "pipe failed: errno \(errno)") }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid = pid_t()
        let spawned = posix_spawn(&pid, executable, &actions, nil, argv, envp)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return Result(status: -1, output: "cannot start \(executable): error \(spawned)")
        }

        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, $0.count) }
            if count > 0 {
                output += buffer[0..<count]
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fds[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // WIFEXITED/WEXITSTATUS are macros, so they are spelled out here.
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : -1
        return Result(status: code, output: String(decoding: output, as: UTF8.self))
    }
}
