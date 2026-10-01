//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import NIOCore
import NIOPosix

// Writes to one TCP connection, encrypting once the session is verified.
actor NIOConnectionSink: HAPConnectionSink {
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private var encryptor: FrameEncryptor?

    init(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        self.outbound = outbound
    }

    func send(_ plaintext: [UInt8]) async {
        let bytes = encryptor.map { _ in encryptor!.encrypt(plaintext) } ?? plaintext
        try? await outbound.write(ByteBuffer(bytes: bytes))
    }

    func enableEncryption(_ keys: SessionKeys) {
        encryptor = FrameEncryptor(key: keys.accessoryToController)
    }

    func close() {
        outbound.finish()
    }
}

public final class HAPServer: Sendable {
    public let controller: HAPController

    public init(controller: HAPController) {
        self.controller = controller
    }

    // IPv4 only for now; controllers reach the bridge over IPv4 in home networks.
    public func run(port: Int = 0, onListening: @Sendable (Int) async -> Void) async throws {
        let channel = try await bind(port: port)
        let actualPort = channel.channel.localAddress?.port ?? port
        Log.info("HomeKit server listening on port \(actualPort)")
        await onListening(actualPort)

        try await withThrowingDiscardingTaskGroup { group in
            try await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    group.addTask {
                        await self.serve(connection)
                    }
                }
            }
        }
    }

    private func bind(port: Int) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .bind(host: "0.0.0.0", port: port) { child in
                child.eventLoop.makeCompletedFuture {
                    Log.debug("HomeKit accepted \(child.remoteAddress?.description ?? "unknown")")
                    do {
                        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
                    } catch {
                        Log.warning("HomeKit connection setup failed: \(error)")
                        throw error
                    }
                }
            }
    }

    private func serve(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        let remote = connection.channel.remoteAddress?.description ?? "unknown"
        do {
            try await connection.executeThenClose { inbound, outbound in
                let sink = NIOConnectionSink(outbound: outbound)
                let id = await controller.open(sink)
                Log.debug("HomeKit connection from \(remote)")
                defer {
                    Task { await self.controller.closed(id) }
                }
                var parser = HTTPParser()
                var decryptor: FrameDecryptor?
                for try await buffer in inbound {
                    var bytes = Array(buffer.readableBytesView)
                    if decryptor != nil {
                        bytes = try decryptor!.decrypt(bytes)
                    }
                    parser.append(bytes)
                    while let request = try parser.next() {
                        let result = await controller.handle(request, from: id)
                        await sink.send(result.response.serialized())
                        if let keys = result.sessionKeys {
                            await sink.enableEncryption(keys)
                            decryptor = FrameDecryptor(key: keys.controllerToAccessory)
                        }
                        if result.closeAfterResponse {
                            await sink.close()
                            return
                        }
                    }
                }
            }
        } catch {
            // Controllers drop idle sessions all the time, so only unexpected errors are warnings.
            if error is HAPCryptoError || error is HTTPParseError {
                Log.warning("HomeKit connection from \(remote) dropped: \(error)")
            } else {
                Log.debug("HomeKit connection from \(remote) ended: \(error)")
            }
        }
    }
}
