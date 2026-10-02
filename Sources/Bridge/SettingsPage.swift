//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HAPKit
import WBKit

public enum BridgeStatus: Int, CaseIterable, Sendable {
    case loading, waitingForPairing, running, stopped

    var title: Translations {
        switch self {
        case .loading: ["ru": "Загрузка", "en": "Loading"]
        case .waitingForPairing: ["ru": "Ожидание сопряжения", "en": "Waiting for pairing"]
        case .running: ["ru": "Работает", "en": "Running"]
        case .stopped: ["ru": "Остановлен", "en": "Stopped"]
        }
    }
}

// /etc/wirenhome-bridge.conf as the confed form reads and writes it.
struct SettingsFile: Equatable, Codable {
    struct MQTT: Equatable, Codable {
        var host = "localhost"
        var port = 1883
        var username = ""
        var password = ""

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? host
            port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? port
            username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
            password = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? ""
        }
    }

    struct Dashboard: Equatable, Codable {
        var enabled = false
        var roles: [String: Int] = [:]

        init(enabled: Bool = false, roles: [String: Int] = [:]) {
            self.enabled = enabled
            self.roles = roles
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            roles = (try? c.decodeIfPresent([String: Int].self, forKey: .roles)) ?? [:]
        }
    }

    var mqtt = MQTT()
    // nil until the bridge has written its choices once (older installs kept them in state.json only).
    var dashboards: [String: Dashboard]?
    var resetPairing = false

    // The form's sections: "pairing", one "panel_<id>" per dashboard, "advanced" with the broker.
    static let panelPrefix = "panel_"

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct Pairing: Codable {
        var reset = false

        init(reset: Bool = false) {
            self.reset = reset
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reset = (try? c.decodeIfPresent(Bool.self, forKey: .reset)) ?? false
        }
    }

    struct Advanced: Codable {
        var mqtt: MQTT?
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let pairing = try? c.decodeIfPresent(Pairing.self, forKey: Key("pairing"))
        resetPairing = pairing?.reset ?? false
        let advanced = try? c.decodeIfPresent(Advanced.self, forKey: Key("advanced"))
        mqtt = advanced?.mqtt ?? MQTT()
        var panels: [String: Dashboard] = [:]
        for key in c.allKeys where key.stringValue.hasPrefix(Self.panelPrefix) {
            panels[String(key.stringValue.dropFirst(Self.panelPrefix.count))] = (try? c.decode(Dashboard.self, forKey: key)) ?? Dashboard()
        }
        // The pairing section is always written by the bridge, so it marks a file that already has the choices.
        dashboards = pairing == nil && panels.isEmpty ? nil : panels
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(Pairing(reset: resetPairing), forKey: Key("pairing"))
        for (id, dashboard) in dashboards ?? [:] {
            try c.encode(dashboard, forKey: Key(Self.panelPrefix + id))
        }
        try c.encode(Advanced(mqtt: mqtt), forKey: Key("advanced"))
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    // Each widget's role lives under the first dashboard that shows it, as on the form.
    static func dashboards(from state: BridgeState, config: WebUIConfig) -> [String: Dashboard] {
        var result: [String: Dashboard] = [:]
        for (dashboard, widgets) in SettingsSchema.owners(in: config) {
            var roles: [String: Int] = [:]
            for widget in widgets where state.role(of: widget.id) != .auto {
                roles[widget.id] = state.role(of: widget.id).code
            }
            result[dashboard.id] = Dashboard(enabled: state.dashboards.contains(dashboard.id), roles: roles)
        }
        return result
    }
}

// Everything the form shows besides the settings themselves.
struct SettingsPageInfo: Equatable {
    var status: BridgeStatus
    var accessories: Int
    var issues: [WidgetIssue]
    var version: String
    var pinCode: String
    var setupURI: String
    var qrSVG: String?
}

// The confed schema of the bridge: rebuilt on every change, confed picks the file up by itself.
enum SettingsSchema {
    static let roles = AccessoryRole.allCases.sorted { $0.code < $1.code }

    // Dashboards of the form with the widgets listed under each; a widget appears under its first dashboard.
    static func owners(in config: WebUIConfig) -> [(WebUIConfig.Dashboard, [WebUIConfig.Widget])] {
        var seen = Set<String>()
        return DashboardSelection.dashboards(in: config).map { dashboard in
            let widgets = DashboardSelection.widgets(in: config, selected: [dashboard.id]).filter { seen.insert($0.id).inserted }
            return (dashboard, widgets)
        }
    }

    static func build(info: SettingsPageInfo, config: WebUIConfig?, configPath: String) -> Data {
        var en: [String: String] = [:]
        var ru: [String: String] = [
            "Apple HomeKit bridge": "Мост Apple HomeKit",
            "Pairing": "Сопряжение",
            "Reset pairing": "Сбросить сопряжение",
            "Publish to Apple Home": "Публиковать в Apple Home",
            "Widget roles": "Роли виджетов",
            "Advanced": "Дополнительно",
            "MQTT broker": "MQTT-брокер",
            "Host": "Адрес",
            "Port": "Порт",
            "Username": "Пользователь",
            "Password": "Пароль"
        ]
        for role in roles {
            ru[role.title["en"] ?? ""] = role.title["ru"]
        }

        let html = infoHTML(info)
        en["pairing-info"] = html["en"]
        ru["pairing-info"] = html["ru"]
        en["reset-description"] = "Tick and press Save: every paired iPhone is forgotten, a new code and QR code appear"
        ru["reset-description"] = "Отметьте и нажмите «Сохранить»: все сопряжённые iPhone будут забыты, появятся новый код и QR-код"
        en["username-description"] = "Leave empty when the broker does not require authentication"
        ru["username-description"] = "Оставьте пустым, если брокер не требует авторизации"

        var properties: [String: JSON] = [
            "pairing": [
                "type": "object", "title": "Pairing", "description": "pairing-info", "propertyOrder": 1, "options": plain,
                "properties": [
                    "reset": [
                        "type": "boolean", "format": "checkbox", "title": "Reset pairing", "description": "reset-description",
                        "default": false, "propertyOrder": 1
                    ]
                ]
            ],
            "advanced": [
                "type": "object", "title": "Advanced", "propertyOrder": 100_000, "options": plain,
                "properties": [
                    "mqtt": [
                        "type": "object", "title": "MQTT broker", "propertyOrder": 1, "options": plain,
                        "properties": [
                            "host": ["type": "string", "title": "Host", "default": "localhost", "propertyOrder": 1],
                            "port": ["type": "integer", "title": "Port", "default": 1883, "minimum": 1, "maximum": 65535, "propertyOrder": 2],
                            "username": ["type": "string", "title": "Username", "description": "username-description", "default": "", "propertyOrder": 3],
                            "password": ["type": "string", "title": "Password", "format": "password", "default": "", "propertyOrder": 4]
                        ]
                    ]
                ]
            ]
        ]

        // Each dashboard is a section of its own, in the web UI order, between pairing and advanced.
        for (index, (dashboard, widgets)) in (config.map(owners) ?? []).enumerated() {
            var roleFields: [String: JSON] = [:]
            for (order, widget) in widgets.enumerated() {
                var field: [String: JSON] = [
                    "type": "integer",
                    "title": .string(widget.name),
                    "enum": .array(roles.map { .int($0.code) }),
                    "default": .int(AccessoryRole.auto.code),
                    "propertyOrder": .int(order + 1),
                    "options": ["enum_titles": .array(roles.map { .string($0.title["en"] ?? "") })]
                ]
                let issues = info.issues.filter { $0.widget == widget.id }.map(\.issue)
                if !issues.isEmpty {
                    let key = "warning-\(widget.id)"
                    field["description"] = .string(key)
                    en[key] = "⚠ " + issues.map { escaped($0.title["en"] ?? "") }.joined(separator: "; ")
                    ru[key] = "⚠ " + issues.map { escaped($0.title["ru"] ?? "") }.joined(separator: "; ")
                }
                roleFields[widget.id] = .object(field)
            }
            var fields: [String: JSON] = [
                "enabled": ["type": "boolean", "format": "checkbox", "title": "Publish to Apple Home", "default": false, "propertyOrder": 1]
            ]
            if !roleFields.isEmpty {
                fields["roles"] = ["type": "object", "title": "Widget roles", "propertyOrder": 2, "options": plain, "properties": .object(roleFields)]
            }
            properties[SettingsFile.panelPrefix + dashboard.id] = [
                "type": "object", "title": .string(dashboard.name), "propertyOrder": .int(index + 10),
                "options": plain, "properties": .object(fields)
            ]
        }

        // "categories" shows the sections as a list on the left, the chosen one on the right (like the DALI page).
        let schema: JSON = requiringAll([
            "$schema": "http://json-schema.org/draft-04/schema#",
            "type": "object",
            "title": "Apple HomeKit bridge",
            "format": "categories",
            "configFile": ["path": .string(configPath), "validate": false],
            "options": plain,
            "properties": .object(properties),
            "translations": ["en": .object(en.mapValues { .string($0) }), "ru": .object(ru.mapValues { .string($0) })]
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(schema)) ?? Data()
    }

    // json-editor drops optional fields missing from the file, so every field is marked required to stay visible.
    static func requiringAll(_ value: JSON) -> JSON {
        guard case .object(var object) = value else { return value }
        if case .object(let properties)? = object["properties"] {
            object["properties"] = .object(properties.mapValues(requiringAll))
            object["required"] = .array(properties.keys.sorted().map { .string($0) })
        }
        return .object(object)
    }

    private static let plain: JSON = ["disable_collapse": true, "disable_edit_json": true, "disable_properties": true]

    // The form sanitizes descriptions with DOMPurify, so plain HTML and inline SVG are shown as is.
    static func infoHTML(_ info: SettingsPageInfo) -> Translations {
        var result: Translations = [:]
        for language in ["ru", "en"] {
            let ru = language == "ru"
            var parts = [
                "<p><b>\(ru ? "Статус" : "Status"):</b> \(info.status.title[language] ?? "")"
                    + " · <b>\(ru ? "Аксессуаров" : "Accessories"):</b> \(info.accessories)"
                    + " · <b>\(ru ? "Предупреждений" : "Warnings"):</b> \(info.issues.count)"
                    + " · <b>\(ru ? "Версия приложения" : "App version"):</b> \(escaped(info.version))</p>",
                "<p><b>\(ru ? "Код сопряжения HomeKit" : "HomeKit setup code"):</b> <b>\(escaped(info.pinCode))</b></p>"
            ]
            if let svg = info.qrSVG {
                parts.append("<div>\(svg)</div>")
            }
            parts.append(ru
                ? "<p>Отсканируйте QR-код камерой iPhone или в приложении «Дом» нажмите «+» → «Добавить аксессуар» и введите код. Код для iPhone: <code>\(escaped(info.setupURI))</code></p>"
                : "<p>Scan the QR code with the iPhone camera, or in the Home app tap + → Add Accessory and enter the code. Setup link: <code>\(escaped(info.setupURI))</code></p>")
            let general = info.issues.filter { $0.widget == nil }.map { escaped($0.issue.title[language] ?? "") }
            if !general.isEmpty {
                parts.append("<p>⚠ \(general.joined(separator: "; "))</p>")
            }
            // Must not lead the HTML: DOMPurify drops a <style> that the parser would hoist into <head>.
            parts.append(roleRowStyle)
            result[language] = parts.joined()
        }
        return result
    }

    // One line per widget role: name on the left, the role list on the right, warnings below.
    static let roleRowStyle = """
        <style>
        [data-schemapath*=".roles."] .form-group { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 16px; margin-bottom: 6px; }
        [data-schemapath*=".roles."] .form-group > label { flex: 1 1 auto; margin: 0; }
        [data-schemapath*=".roles."] .form-group > select { flex: 0 0 260px; width: 260px; max-width: 100%; }
        [data-schemapath*=".roles."] .help-block { flex-basis: 100%; margin: 0; }
        </style>
        """

    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}

// A JSON value for building schemas with literals.
enum JSON: Encodable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSON])
    case object([String: JSON])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

// Where the form lives: the generated schema for confed and the settings file it edits.
public protocol SettingsPageStore: Sendable {
    func writeSchema(_ data: Data) async
    func readSettings() async -> Data?
    func writeSettings(_ data: Data) async
}

public struct FileSettingsPage: SettingsPageStore {
    // confed watches this directory and lists every schema found there.
    public static var defaultSchemaPath: String {
        #if os(macOS)
        Settings.defaultDataDirectory + "/wirenhome-bridge.schema.json"
        #else
        "/var/lib/wb-mqtt-confed/schemas/wirenhome-bridge.schema.json"
        #endif
    }

    let schemaPath: String
    let settingsPath: String

    public init(schemaPath: String = FileSettingsPage.defaultSchemaPath, settingsPath: String) {
        self.schemaPath = schemaPath
        self.settingsPath = settingsPath
    }

    public func writeSchema(_ data: Data) async {
        write(data, to: schemaPath, permissions: 0o644)
    }

    public func readSettings() async -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: settingsPath))
    }

    // The settings hold the MQTT password, so only root may read them.
    public func writeSettings(_ data: Data) async {
        write(data, to: settingsPath, permissions: 0o600)
    }

    private func write(_ data: Data, to path: String, permissions: Int) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        } catch {
            Log.error("Cannot write \(path): \(error)")
        }
    }
}

public protocol QRRenderer: Sendable {
    func svg(for text: String) async -> String?
}

// qrencode from the package dependencies; without it the form shows the code and the link only.
public struct QREncodeRenderer: QRRenderer {
    let executable: String

    public init(executable: String = "/usr/bin/qrencode") {
        self.executable = executable
    }

    public func svg(for text: String) async -> String? {
        guard FileManager.default.fileExists(atPath: executable) else { return nil }
        let result = await Subprocess.run(executable, ["-t", "SVG", "-s", "6", "-m", "2", "-o", "-", text])
        guard result.status == 0, let start = result.output.firstRange(of: "<svg") else {
            Log.warning("qrencode failed: \(result.output)")
            return nil
        }
        return String(result.output[start.lowerBound...]).trimmed
    }
}
