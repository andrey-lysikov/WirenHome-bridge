//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: [UInt8]
}

public enum HTTPParseError: Error, Equatable {
    case malformed
    case tooLarge
}

// Just enough HTTP/1.1 for HAP controllers: no chunked bodies, no continuation lines.
struct HTTPParser: Sendable {
    static let maxSize = 64 * 1024
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) {
        buffer += bytes
    }

    mutating func next() throws -> HTTPRequest? {
        guard let headerEnd = Self.find([13, 10, 13, 10], in: buffer) else {
            if buffer.count > Self.maxSize { throw HTTPParseError.tooLarge }
            return nil
        }
        let head = String(decoding: buffer[0..<headerEnd], as: UTF8.self)
        // "\r\n" is a single Character in Swift.
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmed
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= Self.maxSize else { throw HTTPParseError.tooLarge }
        let bodyStart = headerEnd + 4
        guard buffer.count >= bodyStart + length else { return nil }

        let body = Array(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeFirst(bodyStart + length)
        let target = requestLine[1].split(separator: "?", maxSplits: 1)
        return HTTPRequest(
            method: String(requestLine[0]),
            path: String(target[0]),
            query: target.count == 2 ? Self.parseQuery(String(target[1])) : [:],
            headers: headers,
            body: body
        )
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            result[String(parts[0])] = parts.count == 2 ? (parts[1].percentDecoded ?? String(parts[1])) : ""
        }
        return result
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for index in 0...(bytes.count - pattern.count) where bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
            return index
        }
        return nil
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let contentType: String?
    public let body: [UInt8]

    public init(status: Int, contentType: String? = nil, body: [UInt8] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static func tlv(_ tlv: TLV8) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/pairing+tlv8", body: tlv.encoded())
    }

    static func json(_ status: Int, _ body: [UInt8]) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/hap+json", body: body)
    }

    static let noContent = HTTPResponse(status: 204)

    func serialized(protocol proto: String = "HTTP/1.1") -> [UInt8] {
        var head = "\(proto) \(status) \(Self.reason(status))\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 207: "Multi-Status"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 422: "Unprocessable Entity"
        case 470: "Connection Authorization Required"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
