//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Dashboards and widgets of the WB web UI (GET /api/dashboards, stored in /etc/wb-webui.conf).
public struct WebUIConfig: Sendable, Equatable, Decodable {
    public struct Dashboard: Sendable, Equatable, Decodable {
        public let id: String
        public let name: String
        public let widgets: [String]

        public init(id: String, name: String, widgets: [String]) {
            self.id = id
            self.name = name
            self.widgets = widgets
        }

        enum CodingKeys: String, CodingKey {
            case id, name, widgets
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            // A flat list, or columns of widgets in newer web UIs; repeats are dropped as the UI does.
            let flat = (try? c.decodeIfPresent([String].self, forKey: .widgets))
                ?? (try? c.decodeIfPresent([[String]].self, forKey: .widgets))?.flatMap { $0 } ?? []
            var seen = Set<String>()
            widgets = flat.filter { seen.insert($0).inserted }
        }
    }

    public struct Widget: Sendable, Equatable, Decodable {
        public let id: String
        public let name: String
        public let description: String
        public let cells: [Cell]

        public init(id: String, name: String, description: String = "", cells: [Cell]) {
            self.id = id
            self.name = name
            self.description = description
            self.cells = cells
        }

        enum CodingKeys: String, CodingKey {
            case id, name, description, cells
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
            cells = (try? c.decodeIfPresent([Cell].self, forKey: .cells)) ?? []
        }
    }

    public struct Cell: Sendable, Equatable, Decodable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case id, name
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        }

        // Cell id is "device/control".
        public var device: String { String(id.split(separator: "/", maxSplits: 1).first ?? "") }
        public var control: String {
            let parts = id.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : ""
        }
    }

    public let dashboards: [Dashboard]
    public let widgets: [Widget]

    public init(dashboards: [Dashboard], widgets: [Widget]) {
        self.dashboards = dashboards
        self.widgets = widgets
    }

    enum CodingKeys: String, CodingKey {
        case dashboards, widgets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dashboards = (try? c.decodeIfPresent([Dashboard].self, forKey: .dashboards)) ?? []
        widgets = (try? c.decodeIfPresent([Widget].self, forKey: .widgets)) ?? []
    }

    public func widget(_ id: String) -> Widget? {
        widgets.first { $0.id == id }
    }
}

public protocol WebUIConfigSource: Sendable {
    func load() async throws -> WebUIConfig
}

// Asks the web UI backend first; reads the file when HTTP fails, e.g. once a login is required.
public actor WebUIDashboardsSource: WebUIConfigSource {
    public typealias Fetch = @Sendable () async throws -> (status: Int, body: [UInt8])
    private let fetch: Fetch
    private let file: String
    private var usingFile = false

    public init(host: String, port: Int = 80, file: String = "/etc/wb-webui.conf") {
        self.init(file: file) { try await HTTPClient.get(host: host, port: port, path: "/api/dashboards") }
    }

    init(file: String, fetch: @escaping Fetch) {
        self.file = file
        self.fetch = fetch
    }

    public func load() async throws -> WebUIConfig {
        do {
            let config = try await loadHTTP()
            if usingFile {
                usingFile = false
                Log.info("Dashboards are read from the web UI API again")
            }
            return config
        } catch {
            guard FileManager.default.fileExists(atPath: file) else { throw error }
            let config = try Self.decode(Data(contentsOf: URL(fileURLWithPath: file)))
            if !usingFile {
                usingFile = true
                Log.warning("Web UI API unavailable (\(error)), reading dashboards from \(file)")
            }
            return config
        }
    }

    private func loadHTTP() async throws -> WebUIConfig {
        let (status, body) = try await fetch()
        guard status == 200 else { throw WebUISourceError.status(status) }
        return try Self.decode(Data(body))
    }

    // Requires the dashboards list, so an error object never reads as "no dashboards".
    static func decode(_ data: Data) throws -> WebUIConfig {
        _ = try JSONDecoder().decode(Shape.self, from: data)
        return try JSONDecoder().decode(WebUIConfig.self, from: data)
    }

    private struct Shape: Decodable {
        let dashboards: [Anything]
    }

    private struct Anything: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

public enum WebUISourceError: Error, Equatable {
    case status(Int)
}
