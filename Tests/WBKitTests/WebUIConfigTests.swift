//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WBKit

// Trimmed /etc/wb-webui.conf from a WB 8.5 controller.
let sampleWebUI = #"""
{"defaultDashboardId":"dashboard1","dashboards":[{"id":"dashboard1","name":"Demo Dashboard","widgets":["widget5","widget13"],"isSvg":false,"options":{}},{"id":"svg1","name":"Plan","isSvg":true}],
"widgets":[{"id":"widget5","name":"Информация о системе","description":"","compact":false,"cells":[{"id":"system/HW Revision","name":"Версия контроллера","type":"text"}]},
{"id":"widget13","name":"Мультидатчик 3","description":"","compact":false,"cells":[{"id":"wb-msw-v4_147/Temperature","name":"Температура","type":"value","extra":{}},{"id":"wb-msw-v4_147/CO2","name":"Уровень CO₂","type":"concentration","extra":{}}]}]}
"""#

@Test func decodesDashboardsAndWidgets() throws {
    let config = try JSONDecoder().decode(WebUIConfig.self, from: Data(sampleWebUI.utf8))
    #expect(config.dashboards.map(\.id) == ["dashboard1", "svg1"])
    #expect(config.dashboards[1].widgets.isEmpty)

    let widget = try #require(config.widget("widget13"))
    #expect(widget.name == "Мультидатчик 3")
    #expect(widget.cells.map(\.name) == ["Температура", "Уровень CO₂"])
    #expect(widget.cells[0].device == "wb-msw-v4_147")
    #expect(widget.cells[0].control == "Temperature")
}

@Test func splitsCellIDOnFirstSlashOnly() {
    let cell = WebUIConfig.Cell(id: "dev/control", name: "x")
    #expect(cell.device == "dev")
    #expect(cell.control == "control")
    #expect(WebUIConfig.Cell(id: "broken", name: "x").control == "")
}

@Test func flattensWidgetColumns() throws {
    let json = #"{"dashboards":[{"id":"d","name":"Дом","widgets":[["w1","w2"],["w3","w1"]]}],"widgets":[]}"#
    let config = try JSONDecoder().decode(WebUIConfig.self, from: Data(json.utf8))
    #expect(config.dashboards[0].widgets == ["w1", "w2", "w3"])
}

@Test func prefersTheAPIAndFallsBackToTheFile() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("webui-\(UUID().uuidString).conf")
    try Data(sampleWebUI.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let api = #"{"dashboards":[{"id":"api","name":"API","widgets":[]}],"widgets":[]}"#
    let replies = Replies([(200, api), (401, "<html>login</html>"), (200, #"{"error":"busy"}"#), (200, api)])

    let source = WebUIDashboardsSource(file: file.path) { await replies.next() }
    #expect(try await source.load().dashboards.map(\.id) == ["api"])
    // A login page and an error object both fall back to the file instead of "no dashboards".
    #expect(try await source.load().dashboards.map(\.id) == ["dashboard1", "svg1"])
    #expect(try await source.load().dashboards.map(\.id) == ["dashboard1", "svg1"])
    #expect(try await source.load().dashboards.map(\.id) == ["api"])
}

@Test func reportsTheAPIErrorWithoutAFile() async {
    let source = WebUIDashboardsSource(file: "/nonexistent/wb-webui.conf") { (403, []) }
    await #expect(throws: WebUISourceError.status(403)) { try await source.load() }
}

actor Replies {
    private var queue: [(Int, String)]

    init(_ queue: [(Int, String)]) {
        self.queue = queue
    }

    func next() -> (status: Int, body: [UInt8]) {
        let (status, body) = queue.removeFirst()
        return (status, Array(body.utf8))
    }
}
