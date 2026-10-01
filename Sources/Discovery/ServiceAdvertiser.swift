//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Common
import Synchronization

public enum DiscoveryError: Error, Equatable, CustomStringConvertible {
    case libraryMissing(String)
    case daemonNotRunning
    case registrationFailed(Int32)
    case notRegistered

    public var description: String {
        switch self {
        case .libraryMissing(let library):
            "mDNS library \(library) not found, install it: apt install libavahi-compat-libdnssd1"
        case .daemonNotRunning:
            "mDNS daemon is not running, start it: systemctl enable --now avahi-daemon"
        case .registrationFailed(let code):
            "mDNS registration failed with error \(code)"
        case .notRegistered:
            "mDNS service is not registered"
        }
    }
}

// DNS-SD TXT record: length-prefixed "key=value" strings.
public enum TXTRecord {
    public static func encode(_ entries: [(String, String)]) -> [UInt8] {
        var bytes: [UInt8] = []
        for (key, value) in entries {
            let entry = Array("\(key)=\(value)".utf8.prefix(255))
            bytes.append(UInt8(entry.count))
            bytes += entry
        }
        return bytes
    }
}

// dns_sd API loaded at runtime: system library on macOS, Avahi compat layer on Linux.
public final class ServiceAdvertiser: @unchecked Sendable {
    private typealias RegisterReply = @convention(c) (
        OpaquePointer?, UInt32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias RegisterFunction = @convention(c) (
        UnsafeMutablePointer<OpaquePointer?>?, UInt32, UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt16, UInt16, UnsafeRawPointer?, RegisterReply?, UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UpdateRecordFunction = @convention(c) (OpaquePointer?, OpaquePointer?, UInt32, UInt16, UnsafeRawPointer?, UInt32) -> Int32
    private typealias DeallocateFunction = @convention(c) (OpaquePointer?) -> Void

    #if os(macOS)
    public static let library = "/usr/lib/system/libsystem_dnssd.dylib"
    #else
    public static let library = "libdns_sd.so.1"
    #endif

    static let serviceNotRunning: Int32 = -65563

    private let register: RegisterFunction
    private let updateRecord: UpdateRecordFunction
    private let deallocate: DeallocateFunction
    // The DNSServiceRef as a bit pattern, so the mutex holds a Sendable value.
    private let service = Mutex<UInt?>(nil)

    // Fails early with an install hint when the library is absent.
    public init() throws {
        guard let handle = dlopen(Self.library, RTLD_NOW) else {
            throw DiscoveryError.libraryMissing(Self.library)
        }
        guard let register = dlsym(handle, "DNSServiceRegister"),
              let update = dlsym(handle, "DNSServiceUpdateRecord"),
              let deallocate = dlsym(handle, "DNSServiceRefDeallocate")
        else {
            throw DiscoveryError.libraryMissing(Self.library)
        }
        self.register = unsafeBitCast(register, to: RegisterFunction.self)
        updateRecord = unsafeBitCast(update, to: UpdateRecordFunction.self)
        self.deallocate = unsafeBitCast(deallocate, to: DeallocateFunction.self)
    }

    deinit {
        stop()
    }

    public var isRegistered: Bool {
        service.withLock { $0 != nil }
    }

    // Name conflicts are resolved by the daemon, which appends a number.
    public func register(name: String, type: String, port: Int, txt: [(String, String)]) throws {
        stop()
        var reference: OpaquePointer?
        let record = TXTRecord.encode(txt)
        let callback: RegisterReply = { _, _, error, name, _, _, _ in
            if error != 0 {
                Log.warning("mDNS registration error \(error)")
            } else if let name {
                Log.debug("mDNS registered as \(String(cString: name))")
            }
        }
        let status = record.withUnsafeBytes { txtBytes in
            register(&reference, 0, 0, name, type, nil, nil, UInt16(port).bigEndian, UInt16(record.count), txtBytes.baseAddress, callback, nil)
        }
        if status == Self.serviceNotRunning {
            throw DiscoveryError.daemonNotRunning
        }
        guard status == 0, let reference else {
            throw DiscoveryError.registrationFailed(status)
        }
        service.withLock { $0 = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(reference))) }
        Log.info("mDNS advertising \"\(name)\" \(type) on port \(port)")
    }

    public func update(txt: [(String, String)]) throws {
        let record = TXTRecord.encode(txt)
        let status: Int32 = try service.withLock { raw in
            guard let raw, let reference = OpaquePointer(bitPattern: raw) else { throw DiscoveryError.notRegistered }
            return record.withUnsafeBytes { updateRecord(reference, nil, 0, UInt16(record.count), $0.baseAddress, 0) }
        }
        guard status == 0 else {
            throw DiscoveryError.registrationFailed(status)
        }
    }

    public func stop() {
        service.withLock { raw in
            if let current = raw, let reference = OpaquePointer(bitPattern: current) {
                deallocate(reference)
            }
            raw = nil
        }
    }
}
