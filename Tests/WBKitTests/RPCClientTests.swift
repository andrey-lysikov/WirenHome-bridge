//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WBKit

actor RecordingPublisher: MQTTPublisher {
    private(set) var messages: [MQTTMessage] = []

    func publish(_ message: MQTTMessage) async {
        messages.append(message)
    }

    func waitForMessage() async -> MQTTMessage {
        while messages.isEmpty {
            await Task.yield()
        }
        return messages[0]
    }
}

@Test func sendsRequestAndDecodesReply() async throws {
    let publisher = RecordingPublisher()
    let rpc = RPCClient(publisher: publisher, clientID: "tester")
    async let content = ConfedWebUISource(rpc: rpc).load()

    let request = await publisher.waitForMessage()
    #expect(request.topic == "/rpc/v1/confed/Editor/Load/tester")
    #expect(request.retain == false)
    #expect(request.payload == #"{"id":1,"params":{"path":"/etc/wb-webui.conf"}}"#)

    let reply = #"{"id":1,"result":{"configPath":"/etc/wb-webui.conf","content":{"dashboards":[{"id":"d1","name":"Home","widgets":["w1"]}],"widgets":[]}}}"#
    #expect(await rpc.handle(MQTTMessage(topic: "/rpc/v1/confed/Editor/Load/tester/reply", payload: reply)))
    #expect(try await content.dashboards == [WebUIConfig.Dashboard(id: "d1", name: "Home", widgets: ["w1"])])
}

@Test func reportsRemoteError() async throws {
    let publisher = RecordingPublisher()
    let rpc = RPCClient(publisher: publisher, clientID: "tester")
    let result = Task { try await rpc.call("confed/Editor/Load", params: ["path": "/nope"], as: String.self) }

    _ = await publisher.waitForMessage()
    await rpc.handle(MQTTMessage(topic: "/rpc/v1/confed/Editor/Load/tester/reply", payload: #"{"id":1,"error":{"message":"not found","code":-1}}"#))
    await #expect(throws: RPCError.remote("not found")) { try await result.value }
}

@Test func timesOut() async throws {
    let rpc = RPCClient(publisher: RecordingPublisher(), clientID: "tester")
    await #expect(throws: RPCError.timeout) {
        try await rpc.call("confed/Editor/Load", params: ["path": "/x"], as: String.self, timeout: .milliseconds(50))
    }
}

@Test func ignoresForeignReplies() async {
    let rpc = RPCClient(publisher: RecordingPublisher(), clientID: "tester")
    #expect(await rpc.handle(MQTTMessage(topic: "/rpc/v1/confed/Editor/Load/other/reply", payload: "{}")) == false)
    #expect(await rpc.handle(MQTTMessage(topic: "/devices/x/meta", payload: "{}")) == false)
}
