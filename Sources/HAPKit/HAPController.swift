//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Transport side of one controller connection.
public protocol HAPConnectionSink: Sendable {
    func send(_ plaintext: [UInt8]) async
    func close() async
}

public struct HAPResult: Sendable {
    public let response: HTTPResponse
    let sessionKeys: SessionKeys?
    let closeAfterResponse: Bool

    init(_ response: HTTPResponse, sessionKeys: SessionKeys? = nil, closeAfterResponse: Bool = false) {
        self.response = response
        self.sessionKeys = sessionKeys
        self.closeAfterResponse = closeAfterResponse
    }
}

// HAP protocol logic without networking: pairing, accessories, characteristics, events.
public actor HAPController {
    private struct PairSetupState {
        var srp: SRPServer
        var sessionKey: [UInt8]?
    }

    private struct PairVerifyState {
        let accessoryPublicKey: [UInt8]
        let controllerPublicKey: [UInt8]
        let sharedSecret: [UInt8]
        let key: SymmetricKey
    }

    private struct Connection {
        let sink: any HAPConnectionSink
        var controller: String?
        var pairVerify: PairVerifyState?
        var subscriptions: Set<HAPCharacteristicID> = []
    }

    public static let maxFailedAttempts = 100

    private let storage: any HAPStorage
    private let delegate: any HAPAccessoryDelegate
    private var identity: HAPIdentity
    private var setupCode: String
    private var connections: [HAPConnectionID: Connection] = [:]
    private var nextConnection = 1
    private var pairSetup: (owner: HAPConnectionID, state: PairSetupState)?
    private var failedAttempts = 0
    private var onPairingChange: (@Sendable (Bool) async -> Void)?

    public init(storage: any HAPStorage, delegate: any HAPAccessoryDelegate, setupCode: String) throws {
        self.storage = storage
        self.delegate = delegate
        self.setupCode = setupCode
        if let stored = try storage.load() {
            identity = stored
        } else {
            identity = HAPIdentity.generate()
            try storage.save(identity)
        }
    }

    public var deviceID: String { identity.deviceID }
    public var isPaired: Bool { identity.isPaired }
    public var configNumber: UInt32 { identity.configNumber }

    public func setPairingChangeHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
        onPairingChange = handler
    }

    // MARK: Connections

    public func open(_ sink: any HAPConnectionSink) -> HAPConnectionID {
        let id = HAPConnectionID(value: nextConnection)
        nextConnection += 1
        connections[id] = Connection(sink: sink)
        return id
    }

    public func closed(_ id: HAPConnectionID) {
        connections.removeValue(forKey: id)
        if pairSetup?.owner == id {
            pairSetup = nil
        }
    }

    public func closeAll() async {
        for connection in connections.values {
            await connection.sink.close()
        }
    }

    // Drops all pairings, e.g. from the "reset pairing" button.
    public func reset(setupCode: String) async {
        self.setupCode = setupCode
        pairSetup = nil
        failedAttempts = 0
        identity.pairings = []
        persist()
        await closeAll()
        await onPairingChange?(false)
    }

    // Call when the accessory database changes, so controllers refetch it.
    public func accessoriesChanged() {
        identity.bumpConfigNumber()
        persist()
    }

    // MARK: Requests

    public func handle(_ request: HTTPRequest, from id: HAPConnectionID) async -> HAPResult {
        let result = await route(request, from: id)
        let who = connections[id]?.controller.map { String($0.prefix(8)) } ?? "unverified"
        Log.debug("HAP #\(id.value) \(who) \(request.method) \(request.path)\(request.query.isEmpty ? "" : "?" + request.query.map { "\($0)=\($1)" }.joined(separator: "&")) -> \(result.response.status)")
        return result
    }

    private func route(_ request: HTTPRequest, from id: HAPConnectionID) async -> HAPResult {
        let verified = connections[id]?.controller != nil
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            return HAPResult(.tlv(await pairSetup(request.body, from: id)))
        case ("POST", "/pair-verify"):
            return pairVerify(request.body, from: id)
        case ("POST", "/identify"):
            if identity.isPaired {
                return HAPResult(.json(400, Self.statusJSON(.insufficientPrivileges)))
            }
            await delegate.identify()
            return HAPResult(.noContent)
        case _ where !verified:
            return HAPResult(.json(470, Self.statusJSON(.insufficientAuthorization)))
        case ("POST", "/pairings"):
            return await pairings(request.body, from: id)
        case ("GET", "/accessories"):
            return HAPResult(.json(200, Self.encode(AccessoryList(accessories: await delegate.accessories()))))
        case ("GET", "/characteristics"):
            return HAPResult(await readCharacteristics(request.query))
        case ("PUT", "/characteristics"):
            return HAPResult(await writeCharacteristics(request.body, from: id))
        case ("PUT", "/prepare"):
            return HAPResult(.json(200, Self.statusJSON(.success)))
        default:
            return HAPResult(HTTPResponse(status: 404))
        }
    }

    // MARK: Pair Setup (M1-M6)

    private func pairSetup(_ body: [UInt8], from id: HAPConnectionID) async -> TLV8 {
        guard let tlv = try? TLV8(decoding: body), let step = tlv.byte(.state) else {
            return Self.error(.unknown, state: 2)
        }
        switch step {
        case 1:
            if identity.isPaired {
                return Self.error(.unavailable, state: 2)
            }
            if failedAttempts >= Self.maxFailedAttempts {
                return Self.error(.maxTries, state: 2)
            }
            if let owner = pairSetup?.owner, owner != id, connections[owner] != nil {
                return Self.error(.busy, state: 2)
            }
            let srp = SRPServer(username: "Pair-Setup", password: setupCode)
            pairSetup = (id, PairSetupState(srp: srp))
            return TLV8([(.state, [2]), (.publicKey, srp.publicKey), (.salt, srp.salt)])

        case 3:
            guard let setup = pairSetup, setup.owner == id, let a = tlv[.publicKey], let proof = tlv[.proof],
                  let session = setup.state.srp.session(clientPublicKey: a),
                  SRPServer.matches(session.clientProof, proof)
            else {
                failedAttempts += 1
                pairSetup = nil
                Log.warning("HomeKit pairing attempt with a wrong setup code")
                return Self.error(.authentication, state: 4)
            }
            pairSetup?.state.sessionKey = session.key
            return TLV8([(.state, [4]), (.proof, session.serverProof)])

        case 5:
            guard let setup = pairSetup, setup.owner == id, let sessionKey = setup.state.sessionKey,
                  let encrypted = tlv[.encryptedData]
            else {
                return Self.error(.unknown, state: 6)
            }
            pairSetup = nil
            let key = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            guard let plaintext = try? HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PS-Msg05")),
                  let sub = try? TLV8(decoding: plaintext),
                  let controllerID = sub[.identifier], let controllerKey = sub[.publicKey], let signature = sub[.signature],
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: controllerKey)
            else {
                return Self.error(.authentication, state: 6)
            }
            let controllerX = Self.raw(HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info"))
            guard publicKey.isValidSignature(signature, for: controllerX + controllerID + controllerKey) else {
                return Self.error(.authentication, state: 6)
            }

            let identifier = String(decoding: controllerID, as: UTF8.self)
            identity.pairings.removeAll { $0.identifier == identifier }
            identity.pairings.append(HAPPairing(identifier: identifier, publicKey: Data(controllerKey), isAdmin: true))
            persist()
            Log.info("HomeKit paired with controller \(identifier)")

            guard let signingKey = try? identity.signingKey else { return Self.error(.unknown, state: 6) }
            let accessoryX = Self.raw(HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info"))
            let accessoryID = Array(identity.deviceID.utf8)
            let accessoryKey = Array(signingKey.publicKey.rawRepresentation)
            guard let accessorySignature = try? signingKey.signature(for: accessoryX + accessoryID + accessoryKey) else {
                return Self.error(.unknown, state: 6)
            }
            let reply = TLV8([(.identifier, accessoryID), (.publicKey, accessoryKey), (.signature, Array(accessorySignature))])
            let sealed = HAPCrypto.seal(reply.encoded(), key: key, nonce: HAPCrypto.nonce("PS-Msg06"))
            await onPairingChange?(true)
            return TLV8([(.state, [6]), (.encryptedData, sealed)])

        default:
            return Self.error(.unknown, state: step &+ 1)
        }
    }

    // MARK: Pair Verify (M1-M4)

    private func pairVerify(_ body: [UInt8], from id: HAPConnectionID) -> HAPResult {
        guard let tlv = try? TLV8(decoding: body), let step = tlv.byte(.state), connections[id] != nil else {
            return HAPResult(.tlv(Self.error(.unknown, state: 2)))
        }
        switch step {
        case 1:
            guard let controllerKey = tlv[.publicKey],
                  let controllerPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerKey),
                  let signingKey = try? identity.signingKey
            else {
                return HAPResult(.tlv(Self.error(.unknown, state: 2)))
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: controllerPublic) else {
                return HAPResult(.tlv(Self.error(.unknown, state: 2)))
            }
            let sharedSecret = shared.withUnsafeBytes { Array($0) }
            let accessoryKey = Array(ephemeral.publicKey.rawRepresentation)
            let accessoryID = Array(identity.deviceID.utf8)
            guard let signature = try? signingKey.signature(for: accessoryKey + accessoryID + controllerKey) else {
                return HAPResult(.tlv(Self.error(.unknown, state: 2)))
            }
            let key = HAPCrypto.hkdf(sharedSecret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let sub = TLV8([(.identifier, accessoryID), (.signature, Array(signature))])
            let sealed = HAPCrypto.seal(sub.encoded(), key: key, nonce: HAPCrypto.nonce("PV-Msg02"))
            connections[id]?.pairVerify = PairVerifyState(
                accessoryPublicKey: accessoryKey, controllerPublicKey: controllerKey, sharedSecret: sharedSecret, key: key
            )
            return HAPResult(.tlv(TLV8([(.state, [2]), (.publicKey, accessoryKey), (.encryptedData, sealed)])))

        case 3:
            guard let verify = connections[id]?.pairVerify else {
                return HAPResult(.tlv(Self.error(.authentication, state: 4)))
            }
            connections[id]?.pairVerify = nil
            guard let encrypted = tlv[.encryptedData],
                  let plaintext = try? HAPCrypto.open(encrypted, key: verify.key, nonce: HAPCrypto.nonce("PV-Msg03")),
                  let sub = try? TLV8(decoding: plaintext),
                  let controllerID = sub[.identifier], let signature = sub[.signature]
            else {
                return HAPResult(.tlv(Self.error(.authentication, state: 4)))
            }
            let identifier = String(decoding: controllerID, as: UTF8.self)
            guard let pairing = identity.pairings.first(where: { $0.identifier == identifier }) else {
                Log.warning("HomeKit verify refused: unknown controller \(identifier)")
                return HAPResult(.tlv(Self.error(.authentication, state: 4)))
            }
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
                  publicKey.isValidSignature(signature, for: verify.controllerPublicKey + controllerID + verify.accessoryPublicKey)
            else {
                Log.warning("HomeKit verify refused: bad signature from \(identifier)")
                return HAPResult(.tlv(Self.error(.authentication, state: 4)))
            }
            connections[id]?.controller = identifier
            return HAPResult(.tlv(TLV8([(.state, [4])])), sessionKeys: SessionKeys(sharedSecret: verify.sharedSecret))

        default:
            return HAPResult(.tlv(Self.error(.unknown, state: step &+ 1)))
        }
    }

    // MARK: Pairings (add, remove, list)

    private func pairings(_ body: [UInt8], from id: HAPConnectionID) async -> HAPResult {
        guard let tlv = try? TLV8(decoding: body), let method = tlv.byte(.method) else {
            return HAPResult(.tlv(Self.error(.unknown, state: 2)))
        }
        guard let controller = connections[id]?.controller,
              identity.pairings.first(where: { $0.identifier == controller })?.isAdmin == true
        else {
            return HAPResult(.tlv(Self.error(.authentication, state: 2)))
        }

        switch method {
        case 3:
            guard let rawID = tlv[.identifier], let key = tlv[.publicKey], let permissions = tlv.byte(.permissions) else {
                return HAPResult(.tlv(Self.error(.unknown, state: 2)))
            }
            let identifier = String(decoding: rawID, as: UTF8.self)
            if let index = identity.pairings.firstIndex(where: { $0.identifier == identifier }) {
                guard identity.pairings[index].publicKey == Data(key) else {
                    return HAPResult(.tlv(Self.error(.unknown, state: 2)))
                }
                identity.pairings[index].isAdmin = permissions == 1
            } else {
                identity.pairings.append(HAPPairing(identifier: identifier, publicKey: Data(key), isAdmin: permissions == 1))
            }
            persist()
            Log.info("HomeKit added controller \(identifier)\(permissions == 1 ? " (admin)" : "")")
            return HAPResult(.tlv(TLV8([(.state, [2])])))

        case 4:
            guard let rawID = tlv[.identifier] else {
                return HAPResult(.tlv(Self.error(.unknown, state: 2)))
            }
            let identifier = String(decoding: rawID, as: UTF8.self)
            Log.info("HomeKit removed controller \(identifier)")
            identity.pairings.removeAll { $0.identifier == identifier }
            // Without an admin nobody could manage the accessory, so it becomes unpaired.
            if !identity.pairings.contains(where: \.isAdmin) {
                identity.pairings = []
            }
            persist()
            let remaining = Set(identity.pairings.map(\.identifier))
            for (other, connection) in connections where other != id {
                if let owner = connection.controller, !remaining.contains(owner) {
                    await connection.sink.close()
                }
            }
            if !identity.isPaired {
                await onPairingChange?(false)
            }
            return HAPResult(.tlv(TLV8([(.state, [2])])), closeAfterResponse: !remaining.contains(controller))

        case 5:
            let records = identity.pairings.map {
                TLV8([(.identifier, Array($0.identifier.utf8)), (.publicKey, Array($0.publicKey)), (.permissions, [$0.isAdmin ? 1 : 0])])
            }
            var list = TLV8([(.state, [2])])
            for item in TLV8.joined(records).items {
                list.append(TLVType(rawValue: item.type) ?? .separator, item.value)
            }
            return HAPResult(.tlv(list))

        default:
            return HAPResult(.tlv(Self.error(.unknown, state: 2)))
        }
    }

    // MARK: Characteristics

    private func readCharacteristics(_ query: [String: String]) async -> HTTPResponse {
        guard let ids = query["id"].map(Self.parseIDs), !ids.isEmpty else {
            return .json(400, Self.statusJSON(.invalidValue))
        }
        var results: [CharacteristicResult] = []
        var failed = false
        for id in ids {
            switch await delegate.read(id) {
            case .success(let value):
                results.append(CharacteristicResult(aid: id.aid, iid: id.iid, value: value, status: nil))
            case .failure(let status):
                failed = true
                results.append(CharacteristicResult(aid: id.aid, iid: id.iid, value: nil, status: status.rawValue))
            }
        }
        // With any failure every entry carries a status.
        if failed {
            results = results.map { CharacteristicResult(aid: $0.aid, iid: $0.iid, value: $0.value, status: $0.status ?? 0) }
            return .json(207, Self.encode(CharacteristicList(characteristics: results)))
        }
        return .json(200, Self.encode(CharacteristicList(characteristics: results)))
    }

    private func writeCharacteristics(_ body: [UInt8], from connection: HAPConnectionID) async -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(WriteRequest.self, from: Data(body)) else {
            return .json(400, Self.statusJSON(.invalidValue))
        }
        let accessories = await delegate.accessories()
        var statuses: [CharacteristicResult] = []
        for item in request.characteristics {
            let id = HAPCharacteristicID(aid: item.aid, iid: item.iid)
            var status = HAPStatus.success
            if let characteristic = accessories.first(where: { $0.aid == item.aid })?.characteristic(item.iid) {
                if let events = item.ev {
                    if characteristic.permissions.contains(.events) {
                        if events {
                            connections[connection]?.subscriptions.insert(id)
                        } else {
                            connections[connection]?.subscriptions.remove(id)
                        }
                    } else {
                        status = .notificationNotSupported
                    }
                }
                if status == .success, let value = item.value {
                    status = characteristic.permissions.contains(.write)
                        ? await delegate.write(id, value: value, origin: connection)
                        : .readOnly
                }
            } else {
                status = .notFound
            }
            statuses.append(CharacteristicResult(aid: item.aid, iid: item.iid, value: nil, status: status.rawValue))
        }
        if statuses.allSatisfy({ $0.status == 0 }) {
            return .noContent
        }
        return .json(207, Self.encode(CharacteristicList(characteristics: statuses)))
    }

    // Sends an EVENT to every subscribed controller except the one that caused the change.
    public func notify(_ changes: [HAPCharacteristicID: HAPValue], except origin: HAPConnectionID? = nil) async {
        await notify(changes) { $0 != origin }
    }

    public func notify(_ changes: [HAPCharacteristicID: HAPValue], only target: HAPConnectionID) async {
        await notify(changes) { $0 == target }
    }

    private func notify(_ changes: [HAPCharacteristicID: HAPValue], to include: (HAPConnectionID) -> Bool) async {
        for (id, connection) in connections where include(id) && connection.controller != nil {
            let relevant = changes.filter { connection.subscriptions.contains($0.key) }.sorted { $0.key < $1.key }
            guard !relevant.isEmpty else { continue }
            let list = CharacteristicList(characteristics: relevant.map { CharacteristicResult(aid: $0.key.aid, iid: $0.key.iid, value: $0.value, status: nil) })
            await connection.sink.send(HTTPResponse.json(200, Self.encode(list)).serialized(protocol: "EVENT/1.0"))
        }
    }

    // MARK: Helpers

    private func persist() {
        do {
            try storage.save(identity)
        } catch {
            Log.error("Cannot save HomeKit identity: \(error)")
        }
    }

    static func parseIDs(_ value: String) -> [HAPCharacteristicID] {
        value.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: ".")
            guard parts.count == 2, let aid = Int(parts[0]), let iid = Int(parts[1]) else { return nil }
            return HAPCharacteristicID(aid: aid, iid: iid)
        }
    }

    static func error(_ error: TLVError, state: UInt8) -> TLV8 {
        TLV8([(.state, [state]), (.error, [error.rawValue])])
    }

    static func raw(_ key: SymmetricKey) -> [UInt8] {
        key.withUnsafeBytes { Array($0) }
    }

    static func statusJSON(_ status: HAPStatus) -> [UInt8] {
        Array("{\"status\":\(status.rawValue)}".utf8)
    }

    static func encode<T: Encodable>(_ value: T) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? Array(encoder.encode(value))) ?? []
    }

    private struct AccessoryList: Encodable {
        let accessories: [HAPAccessory]
    }

    struct CharacteristicResult: Codable {
        let aid: Int
        let iid: Int
        let value: HAPValue?
        let status: Int?
    }

    struct CharacteristicList: Codable {
        let characteristics: [CharacteristicResult]
    }

    private struct WriteRequest: Decodable {
        struct Item: Decodable {
            let aid: Int
            let iid: Int
            let value: HAPValue?
            let ev: Bool?
        }

        let characteristics: [Item]
    }
}
