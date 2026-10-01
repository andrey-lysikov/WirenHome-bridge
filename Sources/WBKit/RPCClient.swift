//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum RPCError: Error, Equatable {
    case timeout
    case disconnected
    case remote(String)
    case badReply
}

// WB MQTT RPC: request to /rpc/v1/<service>/<group>/<method>/<client>, reply on .../reply.
public actor RPCClient {
    private let publisher: any MQTTPublisher
    private let clientID: String
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]

    public init(publisher: any MQTTPublisher, clientID: String) {
        self.publisher = publisher
        self.clientID = clientID
    }

    public static func replyFilter(for clientID: String) -> String {
        "/rpc/v1/+/+/+/\(clientID)/reply"
    }

    public func call<P: Encodable & Sendable, R: Decodable>(
        _ method: String, params: P, as type: R.Type, timeout: Duration = .seconds(5)
    ) async throws -> R {
        let reply = try await send(method, params: params, timeout: timeout)
        guard let result = try? JSONDecoder().decode(Reply<R>.self, from: reply).result else {
            throw RPCError.badReply
        }
        return result
    }

    // Resolves with the whole reply payload; errors are already turned into RPCError.
    private func send<P: Encodable & Sendable>(_ method: String, params: P, timeout: Duration) async throws -> Data {
        let id = nextID
        nextID += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = try encoder.encode(Request(id: id, params: params))
        let message = MQTTMessage(topic: "/rpc/v1/\(method)/\(clientID)", payload: String(decoding: request, as: UTF8.self), retain: false)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                await publisher.publish(message)
                try? await Task.sleep(for: timeout)
                self.resolve(id, with: .failure(RPCError.timeout))
            }
        }
    }

    // Returns true when the message was an RPC reply addressed to this client.
    @discardableResult
    public func handle(_ message: MQTTMessage) -> Bool {
        guard message.topic.hasPrefix("/rpc/v1/"), message.topic.hasSuffix("/\(clientID)/reply") else { return false }
        let data = Data(message.payload.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return true }
        if let error = envelope.error {
            resolve(envelope.id, with: .failure(RPCError.remote(error.message ?? "code \(error.code ?? 0)")))
        } else {
            resolve(envelope.id, with: .success(data))
        }
        return true
    }

    public func failAll() {
        for id in Array(pending.keys) {
            resolve(id, with: .failure(RPCError.disconnected))
        }
    }

    private func resolve(_ id: Int, with result: Result<Data, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private struct Request<P: Encodable>: Encodable {
        let id: Int
        let params: P
    }

    private struct Envelope: Decodable {
        struct RemoteError: Decodable {
            let message: String?
            let code: Int?
        }

        let id: Int
        let error: RemoteError?
    }

    private struct Reply<R: Decodable>: Decodable {
        let result: R
    }
}
