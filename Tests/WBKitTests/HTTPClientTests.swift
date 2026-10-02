//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import NIOCore
import NIOPosix
import Testing
@testable import WBKit

// Answers every connection with a fixed raw response, like nginx does for /api/dashboards.
private func serve(_ response: String) async throws -> (port: Int, close: @Sendable () async -> Void) {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "127.0.0.1", port: 0) { child in
            child.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
            }
        }
    let task = Task {
        try await server.executeThenClose { inbound in
            for try await connection in inbound {
                try await connection.executeThenClose { requests, outbound in
                    for try await _ in requests {
                        try await outbound.write(ByteBuffer(string: response))
                        return
                    }
                }
            }
        }
    }
    return (server.channel.localAddress!.port!, { task.cancel() })
}

@Test func readsAChunkedResponse() async throws {
    let body = #"{"dashboards":[]}"#
    let server = try await serve(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + "5\r\n\(body.prefix(5))\r\n\(String(body.count - 5, radix: 16))\r\n\(body.dropFirst(5))\r\n0\r\n\r\n"
    )
    let (status, received) = try await HTTPClient.get(host: "127.0.0.1", port: server.port, path: "/api/dashboards")
    await server.close()
    #expect(status == 200)
    #expect(String(decoding: received, as: UTF8.self) == body)
}

@Test func reportsTheStatus() async throws {
    let server = try await serve("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    let (status, received) = try await HTTPClient.get(host: "127.0.0.1", port: server.port, path: "/api/dashboards")
    await server.close()
    #expect(status == 401)
    #expect(received.isEmpty)
}
