//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
import WBKit
@testable import Bridge

let sampleConfig = WebUIConfig(
    dashboards: [
        .init(id: "kitchen", name: "Кухня", widgets: ["light", "sensor", "ghost"]),
        .init(id: "hall", name: "Холл", widgets: ["sensor", "unnamed", "door"]),
        .init(id: "blank", name: " ", widgets: ["door"])
    ],
    widgets: [
        .init(id: "light", name: "Свет", cells: [.init(id: "wb-mdm3_223/K1", name: "Люстра")]),
        .init(id: "sensor", name: "Мультидатчик", cells: [.init(id: "wb-msw-v4_147/Temperature", name: "Температура")]),
        .init(id: "unnamed", name: "", cells: []),
        .init(id: "door", name: "Дверь", cells: [])
    ]
)

@Test func skipsUnnamedDashboards() {
    #expect(DashboardSelection.dashboards(in: sampleConfig).map(\.id) == ["kitchen", "hall"])
}

@Test func collectsWidgetsOnceInOrder() {
    let widgets = DashboardSelection.widgets(in: sampleConfig, selected: ["hall", "kitchen"])
    #expect(widgets.map(\.id) == ["light", "sensor", "door"])
}

@Test func ignoresUnselectedAndUnnamedDashboards() {
    #expect(DashboardSelection.widgets(in: sampleConfig, selected: ["blank"]).isEmpty)
    #expect(DashboardSelection.widgets(in: sampleConfig, selected: []).isEmpty)
}
