//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public typealias Translations = [String: String]

public struct WBControlMeta: Sendable, Equatable, Codable {
    public var type: String?
    public var readonly: Bool?
    public var units: String?
    public var min: Double?
    public var max: Double?
    public var precision: Double?
    public var order: Int?
    public var title: Translations?
    public var enumTitles: [String: Translations]?
    public var error: String?

    public init(
        type: String? = nil, readonly: Bool? = nil, units: String? = nil, min: Double? = nil, max: Double? = nil,
        precision: Double? = nil, order: Int? = nil, title: Translations? = nil, enumTitles: [String: Translations]? = nil,
        error: String? = nil
    ) {
        self.type = type
        self.readonly = readonly
        self.units = units
        self.min = min
        self.max = max
        self.precision = precision
        self.order = order
        self.title = title
        self.enumTitles = enumTitles
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case type, readonly, units, min, max, precision, order, title, error
        case enumTitles = "enum"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        readonly = c.lenientBool(.readonly)
        units = try? c.decodeIfPresent(String.self, forKey: .units)
        min = c.lenientDouble(.min)
        max = c.lenientDouble(.max)
        precision = c.lenientDouble(.precision)
        order = c.lenientDouble(.order).map { Int($0) }
        title = c.translations(.title)
        enumTitles = try? c.decodeIfPresent([String: Translations].self, forKey: .enumTitles)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    // Older drivers publish each field as its own topic: meta/type, meta/readonly, ...
    public init(legacy fields: [String: String]) {
        type = fields["type"]
        readonly = fields["readonly"].map { $0 == "1" || $0 == "true" }
        units = fields["units"]
        min = fields["min"].flatMap(Double.init)
        max = fields["max"].flatMap(Double.init)
        precision = fields["precision"].flatMap(Double.init)
        order = fields["order"].flatMap(Int.init)
        title = fields["name"].map { ["en": $0] }
        error = fields["error"]
    }

    public static func decode(_ payload: String) -> WBControlMeta? {
        try? JSONDecoder().decode(WBControlMeta.self, from: Data(payload.utf8))
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}

public struct WBDeviceMeta: Sendable, Equatable, Codable {
    public var driver: String?
    public var title: Translations?

    public init(driver: String? = nil, title: Translations? = nil) {
        self.driver = driver
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case driver, title
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driver = try? c.decodeIfPresent(String.self, forKey: .driver)
        title = c.translations(.title)
    }

    public static func decode(_ payload: String) -> WBDeviceMeta? {
        try? JSONDecoder().decode(WBDeviceMeta.self, from: Data(payload.utf8))
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}

extension KeyedDecodingContainer {
    // Drivers differ: booleans may come as true/false, 1/0 or "1"/"0".
    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value == "1" || value == "true" }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    // A title is either {"ru": ..., "en": ...} or a plain string.
    func translations(_ key: Key) -> Translations? {
        if let value = try? decodeIfPresent(Translations.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return ["en": value] }
        return nil
    }
}
