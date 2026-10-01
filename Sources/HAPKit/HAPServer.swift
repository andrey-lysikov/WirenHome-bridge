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

    // Binds on all interfaces (IPv6 with IPv4 fallback) and serves until cancelled.
    public func run(port: Int = 0, onListening: @Sendable (Int) async -> Void) async throws {
        let channel = try await bind(host: "::", port: port)
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

    private func bind(host: String, port: Int) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        let initializer: @Sendable (any Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> = { child in
            child.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
            }
        }
        do {
            return try await bootstrap.bind(host: host, port: port, childChannelInitializer: initializer)
        } catch where host == "::" {
            Log.warning("IPv6 bind failed (\(error)), using IPv4 only")
            return try await bootstrap.bind(host: "0.0.0.0", port: port, childChannelInitializer: initializer)
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
            Log.debug("HomeKit connection from \(remote) ended: \(error)")
        }
    }
}
