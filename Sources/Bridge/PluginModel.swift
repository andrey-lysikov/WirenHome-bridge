//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import WBKit

// Controls of the wb-homekit device in the WB web UI.
enum PluginModel {
    static let device = VirtualDevice(
        id: "wb-homekit",
        meta: WBDeviceMeta(driver: "wb-homekit", title: ["ru": "Мост Apple HomeKit", "en": "Apple HomeKit bridge"])
    )

    enum ID {
        static let status = "status"
        static let pinCode = "pincode"
        static let resetPairing = "reset_pairing"
        static let version = "version"
        static let warnings = "warnings"
        static let accessories = "accessories"
        static let dashboardPrefix = "dashboard_"
        static let rolePrefix = "role_"
    }

    // Shown through enum titles, so the WB UI picks the language of each browser.
    // Codes are retained in MQTT; 3 was "updating" and stays unused.
    enum Status: Int, CaseIterable {
        case loading = 0, waitingForPairing = 1, running = 2, stopped = 4

        var title: Translations {
            switch self {
            case .loading: ["ru": "Загрузка", "en": "Loading"]
            case .waitingForPairing: ["ru": "Ожидание сопряжения", "en": "Waiting for pairing"]
            case .running: ["ru": "Работает", "en": "Running"]
            case .stopped: ["ru": "Остановлен", "en": "Stopped"]
            }
        }
    }

    // Retained last will, so the UI shows a crashed bridge as stopped.
    static var stoppedMessage: MQTTMessage {
        device.valueMessage(ID.status, String(Status.stopped.rawValue))
    }

    // "Base ⚠ problem; problem" in every language present in the base title.
    static func title(_ base: Translations, issues: [MappingIssue]) -> Translations {
        guard !issues.isEmpty else { return base }
        return base.reduce(into: Translations()) { result, item in
            result[item.key] = item.value + " ⚠ " + issues.map { $0.title[item.key] ?? $0.title["en"] ?? "" }.joined(separator: "; ")
        }
    }

    static func controls(
        state: BridgeState, config: WebUIConfig?, status: Status, accessories: Int = 0, issues: [WidgetIssue] = [],
        version: String
    ) -> [VirtualControl] {
        let statuses = Dictionary(uniqueKeysWithValues: Status.allCases.map { (String($0.rawValue), $0.title) })
        let general = issues.filter { $0.widget == nil }.map(\.issue)
        var controls = [
            VirtualControl(
                id: ID.status,
                meta: WBControlMeta(type: "value", readonly: true, order: 1, title: ["ru": "Статус работы", "en": "Status"], enumTitles: statuses),
                value: String(status.rawValue)
            ),
            VirtualControl(
                id: ID.accessories,
                meta: WBControlMeta(type: "value", readonly: true, order: 3, title: ["ru": "Аксессуаров HomeKit", "en": "HomeKit accessories"]),
                value: String(accessories)
            ),
            VirtualControl(
                id: ID.pinCode,
                meta: WBControlMeta(type: "text", readonly: true, order: 2, title: ["ru": "Код сопряжения HomeKit", "en": "HomeKit setup code"]),
                value: state.pinCode
            ),
            VirtualControl(
                id: ID.resetPairing,
                meta: WBControlMeta(type: "pushbutton", readonly: false, order: 4, title: ["ru": "Сбросить сопряжение", "en": "Reset pairing"]),
                value: nil
            ),
            VirtualControl(
                id: ID.version,
                meta: WBControlMeta(type: "text", readonly: true, order: 5, title: ["ru": "Версия", "en": "Version"]),
                value: version
            ),
            // Details sit in the titles of the affected widgets' role controls.
            VirtualControl(
                id: ID.warnings,
                meta: WBControlMeta(type: "value", readonly: true, order: 6, title: title(["ru": "Предупреждения", "en": "Warnings"], issues: general)),
                value: String(issues.count)
            )
        ]
        guard let config else { return controls }

        // Each dashboard switch is followed by the roles of its widgets, so the device page reads as groups.
        let roles = Dictionary(uniqueKeysWithValues: AccessoryRole.allCases.map { (String($0.code), $0.title) })
        var order = 100
        var listed = Set<String>()
        for dashboard in DashboardSelection.dashboards(in: config) {
            let selected = state.dashboards.contains(dashboard.id)
            controls.append(VirtualControl(
                id: ID.dashboardPrefix + dashboard.id,
                meta: WBControlMeta(
                    type: "switch", readonly: false, order: order,
                    title: ["ru": "Панель «\(dashboard.name)»", "en": "Dashboard “\(dashboard.name)”"]
                ),
                value: selected ? "1" : "0"
            ))
            order += 1
            guard selected else { continue }
            // A widget shared by several dashboards is listed under the first one only.
            for widget in DashboardSelection.widgets(in: config, selected: [dashboard.id]) where !listed.contains(widget.id) {
                listed.insert(widget.id)
                controls.append(VirtualControl(
                    id: ID.rolePrefix + widget.id,
                    meta: WBControlMeta(
                        type: "value", readonly: false, order: order,
                        title: title(
                            ["ru": "\(dashboard.name) → \(widget.name)", "en": "\(dashboard.name) → \(widget.name)"],
                            issues: issues.filter { $0.widget == widget.id }.map(\.issue)
                        ),
                        enumTitles: roles
                    ),
                    value: String(state.role(of: widget.id).code)
                ))
                order += 1
            }
        }
        return controls
    }
}
