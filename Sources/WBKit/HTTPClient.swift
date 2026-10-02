//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import NIOCore
import NIOHTTP1
import NIOPosix

public enum HTTPClientError: Error, Equatable {
    case timeout
    case closedEarly
    case tooLarge
}

// A one-shot plain HTTP GET, enough for the local WB web server.
public enum HTTPClient {
    public static let maxBody = 8 * 1024 * 1024

    public static func get(host: String, port: Int, path: String, timeout: Duration = .seconds(5)) async throws -> (status: Int, body: [UInt8]) {
        try await withThrowingTaskGroup(of: (status: Int, body: [UInt8]).self) { group in
            group.addTask { try await fetch(host: host, port: port, path: path) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HTTPClientError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func fetch(host: String, port: Int, path: String) async throws -> (status: Int, body: [UInt8]) {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(5))
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path)
            head.headers.add(name: "Host", value: host)
            head.headers.add(name: "Accept", value: "application/json")
            head.headers.add(name: "Connection", value: "close")
            try await outbound.write(.head(head))
            try await outbound.write(.end(nil))

            var status = 0
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let response):
                    status = Int(response.status.code)
                case .body(var chunk):
                    guard body.count + chunk.readableBytes <= maxBody else { throw HTTPClientError.tooLarge }
                    body += chunk.readBytes(length: chunk.readableBytes) ?? []
                case .end:
                    return (status, body)
                }
            }
            throw HTTPClientError.closedEarly
        }
    }
}
