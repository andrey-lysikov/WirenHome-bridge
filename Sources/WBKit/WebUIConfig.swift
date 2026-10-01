//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

// Dashboards and widgets from /etc/wb-webui.conf.
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
            widgets = (try? c.decodeIfPresent([String].self, forKey: .widgets)) ?? []
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

// Reads the config through wb-mqtt-confed, which works both locally and over the network.
public struct ConfedWebUISource: WebUIConfigSource {
    private let rpc: RPCClient

    public init(rpc: RPCClient) {
        self.rpc = rpc
    }

    public func load() async throws -> WebUIConfig {
        try await rpc.call("confed/Editor/Load", params: ["path": "/etc/wb-webui.conf"], as: LoadResult.self).content
    }

    private struct LoadResult: Decodable {
        let content: WebUIConfig
    }
}
