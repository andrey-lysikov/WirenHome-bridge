//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public typealias Translations = [String: String]

public struct WBControlMeta: Sendable, Equatable, Decodable {
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
