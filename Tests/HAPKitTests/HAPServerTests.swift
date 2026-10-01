//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import HAPKit

// Client end of a TCP connection that speaks HTTP, optionally inside HAP session encryption.
final class TCPClient: @unchecked Sendable {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private var buffered: [UInt8] = []
    private var encryptor: FrameEncryptor?
    private var decryptor: FrameDecryptor?

    init(inbound: NIOAsyncChannelInboundStream<ByteBuffer>, outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        iterator = inbound.makeAsyncIterator()
        self.outbound = outbound
    }

    func secure(_ keys: SessionKeys) {
        encryptor = FrameEncryptor(key: keys.controllerToAccessory)
        decryptor = FrameDecryptor(key: keys.accessoryToController)
    }

    func request(_ method: String, _ path: String, _ body: [UInt8]) async throws -> (status: Int, body: [UInt8]) {
        var bytes = Array("\(method) \(path) HTTP/1.1\r\nHost: test\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        if encryptor != nil {
            bytes = encryptor!.encrypt(bytes)
        }
        try await outbound.write(ByteBuffer(bytes: bytes))
        return try await response()
    }

    func response() async throws -> (status: Int, body: [UInt8]) {
        while true {
            if let end = find(Array("\r\n\r\n".utf8)) {
                let head = String(decoding: buffered[0..<end], as: UTF8.self)
                let status = Int(head.split(separator: " ")[1]) ?? 0
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffered.count >= end + 4 + length {
                    let body = Array(buffered[(end + 4)..<(end + 4 + length)])
                    buffered.removeFirst(end + 4 + length)
                    return (status, body)
                }
            }
            guard let chunk = try await iterator.next() else { throw TestFailure(description: "connection closed") }
            var bytes = Array(chunk.readableBytesView)
            if decryptor != nil {
                bytes = try decryptor!.decrypt(bytes)
            }
            buffered += bytes
        }
    }

    private func find(_ pattern: [UInt8]) -> Int? {
        guard buffered.count >= pattern.count else { return nil }
        return (0...(buffered.count - pattern.count)).first { buffered[$0..<($0 + pattern.count)].elementsEqual(pattern) }
    }
}

func withClient<T: Sendable>(port: Int, _ body: @Sendable (TCPClient) async throws -> T) async throws -> T {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    return try await channel.executeThenClose { inbound, outbound in
        try await body(TCPClient(inbound: inbound, outbound: outbound))
    }
}

@Test func pairsAndTalksOverEncryptedTCP() async throws {
    let accessory = try Accessory()
    let server = HAPServer(controller: accessory.controller)
    let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
    let serverTask = Task {
        try await server.run(port: 0) { portContinuation.yield($0) }
    }
    defer { serverTask.cancel() }
    var ports = portStream.makeAsyncIterator()
    let port = try #require(await ports.next())

    let iPhone = try await withClient(port: port) { client in
        var controller = TestController()
        let refused = try await controller.pairSetup(code: "031-45-154") { try await client.request($0, $1, $2) }
        #expect(refused == nil)
        return controller
    }

    try await withClient(port: port) { client in
        let keys = try await iPhone.pairVerify { try await client.request($0, $1, $2) }
        client.secure(keys)
        let accessories = try await client.request("GET", "/accessories", [])
        #expect(accessories.status == 200)
        #expect(String(decoding: accessories.body, as: UTF8.self).contains(#""aid":1"#))

        let write = try await client.request("PUT", "/characteristics", Array(#"{"characteristics":[{"aid":1,"iid":11,"value":true,"ev":true}]}"#.utf8))
        #expect(write.status == 204)
        #expect(await accessory.accessories.on)

        await accessory.controller.notify([HAPCharacteristicID(aid: 1, iid: 11): .bool(false)])
        let event = try await client.response()
        #expect(event.status == 200)
        #expect(String(decoding: event.body, as: UTF8.self).contains(#""value":false"#))
    }
}
