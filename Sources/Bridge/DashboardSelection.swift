//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import WBKit

public enum DashboardSelection {
    // Dashboards the user can pick: named and with an id usable as an MQTT topic level.
    public static func dashboards(in config: WebUIConfig) -> [WebUIConfig.Dashboard] {
        config.dashboards.filter { isUsable($0.id, $0.name) }
    }

    // Widgets of the selected dashboards in display order, each once, unnamed ones skipped.
    public static func widgets(in config: WebUIConfig, selected: Set<String>) -> [WebUIConfig.Widget] {
        var seen = Set<String>()
        var result: [WebUIConfig.Widget] = []
        for dashboard in dashboards(in: config) where selected.contains(dashboard.id) {
            for id in dashboard.widgets where !seen.contains(id) {
                guard let widget = config.widget(id), isUsable(widget.id, widget.name) else { continue }
                seen.insert(id)
                result.append(widget)
            }
        }
        return result
    }

    static func isUsable(_ id: String, _ name: String) -> Bool {
        WBTopic.isValidName(id) && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
