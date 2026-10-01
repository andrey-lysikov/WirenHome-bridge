//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import HAPKit

struct Accessory {
    let storage = MemoryStorage()
    let accessories = TestAccessories()
    let controller: HAPController

    init(code: String = "031-45-154") throws {
        controller = try HAPController(storage: storage, delegate: accessories, setupCode: code)
    }

    func connect() async -> (HAPConnectionID, RecordingSink) {
        let sink = RecordingSink()
        return (await controller.open(sink), sink)
    }

    func exchange(_ id: HAPConnectionID) -> TestController.Exchange {
        { method, path, body in
            let parts = path.split(separator: "?", maxSplits: 1)
            let request = HTTPRequest(
                method: method, path: String(parts[0]),
                query: parts.count == 2 ? HTTPParser.parseQuery(String(parts[1])) : [:],
                headers: [:], body: body
            )
            let result = await controller.handle(request, from: id)
            return (result.response.status, result.response.body)
        }
    }
}

@Test func pairsVerifiesAndServesAccessories() async throws {
    let accessory = try Accessory()
    let (id, _) = await accessory.connect()
    var iPhone = TestController()

    #expect(try await iPhone.pairSetup(code: "031-45-154", exchange: accessory.exchange(id)) == nil)
    #expect(await accessory.controller.isPaired)
    #expect(iPhone.accessoryID == (await accessory.controller.deviceID))
    #expect(try accessory.storage.load()?.pairings.first?.isAdmin == true)

    let (session, _) = await accessory.connect()
    let unauthorized = try await accessory.exchange(session)("GET", "/accessories", [])
    #expect(unauthorized.status == 470)

    _ = try await iPhone.pairVerify(exchange: accessory.exchange(session))
    let list = try await accessory.exchange(session)("GET", "/accessories", [])
    #expect(list.status == 200)
    let json = String(decoding: list.body, as: UTF8.self)
    #expect(json.contains(#""type":"49""#))
    #expect(json.contains(#""perms":["pw"]"#))
    #expect(!json.contains(#""iid":2,"type":"14","format":"bool","perms":["pw"],"value""#))
}

@Test func rejectsWrongSetupCodeAndRepeatedPairing() async throws {
    let accessory = try Accessory()
    let (id, _) = await accessory.connect()
    var intruder = TestController()
    #expect(try await intruder.pairSetup(code: "999-99-998", exchange: accessory.exchange(id)) == TLVError.authentication.rawValue)
    #expect(await !accessory.controller.isPaired)

    var owner = TestController()
    #expect(try await owner.pairSetup(code: "031-45-154", exchange: accessory.exchange(id)) == nil)
    var second = TestController()
    #expect(try await second.pairSetup(code: "031-45-154", exchange: accessory.exchange(id)) == TLVError.unavailable.rawValue)
}

@Test func unknownControllerCannotVerify() async throws {
    let accessory = try Accessory()
    let (id, _) = await accessory.connect()
    var owner = TestController()
    _ = try await owner.pairSetup(code: "031-45-154", exchange: accessory.exchange(id))

    var stranger = TestController()
    stranger.accessoryKey = owner.accessoryKey
    await #expect(throws: TestFailure.self) { try await stranger.pairVerify(exchange: accessory.exchange(id)) }
}

@Test func readsWritesAndSendsEvents() async throws {
    let accessory = try Accessory()
    var iPhone = TestController()
    let (setup, _) = await accessory.connect()
    _ = try await iPhone.pairSetup(code: "031-45-154", exchange: accessory.exchange(setup))

    let (first, firstSink) = await accessory.connect()
    let (second, secondSink) = await accessory.connect()
    _ = try await iPhone.pairVerify(exchange: accessory.exchange(first))
    _ = try await iPhone.pairVerify(exchange: accessory.exchange(second))

    let subscribe = Array(#"{"characteristics":[{"aid":1,"iid":11,"ev":true}]}"#.utf8)
    #expect(try await accessory.exchange(first)("PUT", "/characteristics", subscribe).status == 204)
    #expect(try await accessory.exchange(second)("PUT", "/characteristics", subscribe).status == 204)

    let write = Array(#"{"characteristics":[{"aid":1,"iid":11,"value":1}]}"#.utf8)
    #expect(try await accessory.exchange(first)("PUT", "/characteristics", write).status == 204)
    #expect(await accessory.accessories.on)

    await accessory.controller.notify([HAPCharacteristicID(aid: 1, iid: 11): .bool(true)], except: first)
    #expect(await firstSink.sent.isEmpty)
    let event = try #require(await secondSink.sent.first)
    #expect(event.hasPrefix("EVENT/1.0 200 OK\r\n"))
    #expect(event.hasSuffix(#"{"characteristics":[{"aid":1,"iid":11,"value":true}]}"#))

    let read = try await accessory.exchange(first)("GET", "/characteristics?id=1.11,1.3", [])
    #expect(read.status == 200)
    #expect(String(decoding: read.body, as: UTF8.self) == #"{"characteristics":[{"aid":1,"iid":11,"value":true},{"aid":1,"iid":3,"value":"Test"}]}"#)

    let partial = try await accessory.exchange(first)("GET", "/characteristics?id=1.11,9.9", [])
    #expect(partial.status == 207)
    #expect(String(decoding: partial.body, as: UTF8.self).contains(#"{"aid":9,"iid":9,"status":-70409}"#))

    let readOnly = Array(#"{"characteristics":[{"aid":1,"iid":3,"value":"x"}]}"#.utf8)
    let refused = try await accessory.exchange(first)("PUT", "/characteristics", readOnly)
    #expect(refused.status == 207)
    #expect(String(decoding: refused.body, as: UTF8.self).contains("-70404"))
}

@Test func managesPairings() async throws {
    let accessory = try Accessory()
    var iPhone = TestController()
    let (setup, _) = await accessory.connect()
    _ = try await iPhone.pairSetup(code: "031-45-154", exchange: accessory.exchange(setup))
    let (admin, _) = await accessory.connect()
    _ = try await iPhone.pairVerify(exchange: accessory.exchange(admin))

    let guest = TestController()
    let add = TLV8([(.state, [1]), (.method, [3]), (.identifier, Array(guest.identifier.utf8)),
                    (.publicKey, Array(guest.signingKey.publicKey.rawRepresentation)), (.permissions, [0])])
    #expect(try await accessory.exchange(admin)("POST", "/pairings", add.encoded()).body == [0x06, 0x01, 0x02])

    let listed = try TLV8(decoding: try await accessory.exchange(admin)("POST", "/pairings", TLV8([(.state, [1]), (.method, [5])]).encoded()).body)
    #expect(listed.split().compactMap { $0[.identifier] }.count == 2)

    // Removing the only admin unpairs the accessory and closes the session.
    let remove = TLV8([(.state, [1]), (.method, [4]), (.identifier, Array(iPhone.identifier.utf8))])
    let result = await accessory.controller.handle(
        HTTPRequest(method: "POST", path: "/pairings", query: [:], headers: [:], body: remove.encoded()), from: admin
    )
    #expect(result.closeAfterResponse)
    #expect(await !accessory.controller.isPaired)
}

@Test func identifiesOnlyWhenUnpaired() async throws {
    let accessory = try Accessory()
    let (id, _) = await accessory.connect()
    #expect(try await accessory.exchange(id)("POST", "/identify", []).status == 204)
    #expect(await accessory.accessories.identified == 1)

    var iPhone = TestController()
    _ = try await iPhone.pairSetup(code: "031-45-154", exchange: accessory.exchange(id))
    #expect(try await accessory.exchange(id)("POST", "/identify", []).status == 400)
}

@Test func resetDropsPairingsAndUsesNewCode() async throws {
    let accessory = try Accessory()
    let (id, sink) = await accessory.connect()
    var iPhone = TestController()
    _ = try await iPhone.pairSetup(code: "031-45-154", exchange: accessory.exchange(id))

    await accessory.controller.reset(setupCode: "264-81-937")
    #expect(await !accessory.controller.isPaired)
    #expect(await sink.isClosed)

    let (fresh, _) = await accessory.connect()
    var again = TestController()
    #expect(try await again.pairSetup(code: "264-81-937", exchange: accessory.exchange(fresh)) == nil)
}
