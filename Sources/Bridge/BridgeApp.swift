//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Common
import HAPKit
import WBKit

public actor BridgeApp {
    private let publisher: any MQTTPublisher
    private let source: any WebUIConfigSource
    private let store: StateStore
    private let version: String
    private var state: BridgeState
    private var registry = DeviceRegistry()
    private var config: WebUIConfig?
    private var pendingConfig: WebUIConfig?
    private var connected = false
    private var published: [String: VirtualControl] = [:]
    private var staleRemoved = false
    private var homeKit: (any HomeKitControl)?
    private var paired = false
    private var updater: (any Updater)?
    private var update: PluginModel.UpdateInfo?
    private var upgrading = false

    // HomeKit side: current accessory mapping and the values last reported to controllers.
    private var bridgeAccessory = HAPAccessory(aid: 1, services: [])
    private var mapping: Mapping?
    private var cellIndex: [Cell: [HAPCharacteristicID]] = [:]
    private var knownKinds: [Cell: CellKind] = [:]
    private var lastValues: [HAPCharacteristicID: HAPValue] = [:]
    private var counters: [Cell: String] = [:]
    private var momentaryOn: Set<HAPCharacteristicID> = []
    private var blindsPosition: [Cell: Int] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    public init(publisher: any MQTTPublisher, source: any WebUIConfigSource, store: StateStore, state: BridgeState, version: String) {
        self.publisher = publisher
        self.source = source
        self.store = store
        self.state = state
        self.version = version
    }

    public var currentState: BridgeState { state }

    func attach(_ homeKit: any HomeKitControl, paired: Bool, bridge: HAPAccessory) {
        self.homeKit = homeKit
        self.paired = paired
        bridgeAccessory = bridge
    }

    // Returns once the first accessory mapping exists, so HomeKit never sees an empty bridge by mistake.
    func waitUntilReady() async {
        guard mapping == nil else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    func attach(updater: any Updater) {
        self.updater = updater
        update = PluginModel.UpdateInfo()
    }

    func checkForUpdates() async {
        guard let updater else { return }
        let available = await updater.availableVersion()
        update = PluginModel.UpdateInfo(available: available)
        if let available, AppVersionOrder.isNewer(available, than: version) {
            Log.info("Update available: \(available)")
        }
        await sync()
    }

    func setPaired(_ paired: Bool) async {
        self.paired = paired
        await sync()
    }

    public func handle(_ event: MQTTEvent) async {
        switch event {
        case .connected:
            connected = true
            published = [:]
            staleRemoved = false
            await publisher.publish(PluginModel.device.metaMessage())
            await sync()
        case .disconnected:
            connected = false
        case .message(let message):
            // Retained commands are leftovers, not user actions.
            if case .controlCommand(let device, let control) = WBTopic(message.topic), device == PluginModel.device.id {
                if !message.retain {
                    await command(control, message.payload)
                }
            } else if let change = registry.apply(message) {
                await registryChanged(change)
            }
        }
    }

    // Applies a dashboards change only once two polls in a row agree, so edits settle first.
    public func refreshDashboards() async {
        guard connected else { return }
        let fetched: WebUIConfig
        do {
            fetched = try await source.load()
        } catch {
            Log.warning("Cannot load dashboards: \(error)")
            return
        }
        if fetched == config {
            pendingConfig = nil
            return
        }
        guard config == nil || fetched == pendingConfig else {
            pendingConfig = fetched
            Log.info("Dashboards changed, waiting for edits to settle")
            return
        }
        pendingConfig = nil
        config = fetched
        prune(for: fetched)
        Log.info("Dashboards loaded: \(fetched.dashboards.count) dashboards, \(fetched.widgets.count) widgets")
        await remap()
        await sync()
    }

    public func stop() async {
        await publisher.publish(PluginModel.stoppedMessage)
    }

    private func command(_ control: String, _ payload: String) async {
        let id = PluginModel.ID.self
        switch control {
        case id.update:
            guard let updater, let available = update?.available, AppVersionOrder.isNewer(available, than: version) else {
                Log.info("Update requested, but no newer version is known")
                break
            }
            Log.info("Updating to \(available) from the web UI")
            upgrading = await updater.startUpgrade()
        case id.resetPairing:
            state.pinCode = PinCode.generate()
            Log.info("Pairing reset from the web UI, new setup code generated")
            save()
            await homeKit?.reset(setupCode: state.pinCode)
        case _ where control.hasPrefix(id.dashboardPrefix) && (payload == "0" || payload == "1"):
            let dashboard = String(control.dropFirst(id.dashboardPrefix.count))
            if payload == "1" {
                state.dashboards.insert(dashboard)
            } else {
                state.dashboards.remove(dashboard)
            }
        case _ where control.hasPrefix(id.rolePrefix):
            let widget = String(control.dropFirst(id.rolePrefix.count))
            if let role = Int(payload).flatMap(AccessoryRole.init(code:)) {
                state.roles[widget] = role == .auto ? nil : role
            }
        default:
            break
        }
        save()
        if control.hasPrefix(id.dashboardPrefix) || control.hasPrefix(id.rolePrefix) {
            await remap()
        }
        // Echo the accepted value, otherwise the UI rolls the control back.
        published.removeValue(forKey: control)
        await sync()
    }

    // Forget dashboards and roles that no longer exist in the web UI config.
    private func prune(for config: WebUIConfig) {
        let dashboards = Set(config.dashboards.map(\.id))
        let widgets = Set(config.widgets.map(\.id))
        var next = state
        next.dashboards = state.dashboards.intersection(dashboards)
        next.roles = state.roles.filter { widgets.contains($0.key) }
        if next != state {
            state = next
            save()
        }
    }

    private func sync() async {
        guard connected else { return }
        let device = PluginModel.device
        let desired = PluginModel.controls(
            state: state, config: config, status: status, accessories: max(0, (mapping?.accessories.count ?? 1) - 1),
            issues: mapping?.issues ?? [], version: version, update: update
        )
        let desiredIDs = Set(desired.map(\.id))

        for control in desired where published[control.id] != control {
            await publisher.publish(device.messages(for: control))
        }
        var removed = Set(published.keys).subtracting(desiredIDs)
        // Controls left from a previous run are known only once the dashboards are loaded.
        if config != nil, !staleRemoved {
            staleRemoved = true
            let leftovers = registry.device(device.id).map { Set($0.controls.keys) } ?? []
            removed.formUnion(leftovers.subtracting(desiredIDs))
        }
        for control in removed.sorted() {
            await publisher.publish(device.removalMessages(control))
        }
        published = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
    }

    private var status: PluginModel.Status {
        if upgrading { return .updating }
        guard config != nil else { return .loading }
        return paired ? .running : .waitingForPairing
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            Log.error("Cannot save state to \(store.directory.path): \(error)")
        }
    }

    // MARK: HomeKit

    func hapAccessories() -> [HAPAccessory] {
        guard let mapping else { return [bridgeAccessory] }
        return mapping.accessories.map { accessory in
            var filled = accessory
            for (serviceIndex, service) in accessory.services.enumerated() {
                for (index, characteristic) in service.characteristics.enumerated() where characteristic.permissions.contains(.read) {
                    let id = HAPCharacteristicID(aid: accessory.aid, iid: characteristic.iid)
                    if mapping.sources[id] != nil, case .success(let value) = read(id) {
                        filled.services[serviceIndex].characteristics[index].value = value
                    }
                }
            }
            return filled
        }
    }

    func hapRead(_ id: HAPCharacteristicID) -> Result<HAPValue, HAPStatus> {
        if mapping?.sources[id] != nil {
            return read(id)
        }
        let accessories = mapping?.accessories ?? [bridgeAccessory]
        guard let characteristic = accessories.first(where: { $0.aid == id.aid })?.characteristic(id.iid) else {
            return .failure(.notFound)
        }
        guard characteristic.permissions.contains(.read), let value = characteristic.value else {
            return .failure(.writeOnly)
        }
        return .success(value)
    }

    func hapWrite(_ id: HAPCharacteristicID, value: HAPValue, origin: HAPConnectionID) async -> HAPStatus {
        // Identify on any accessory is accepted and only logged.
        if id.iid == 2 {
            Log.info("HomeKit identify for accessory \(id.aid)")
            return .success
        }
        guard let source = mapping?.sources[id] else { return .notFound }
        // Renames made in the Home app are kept by the bridge.
        if case .configuredName = source {
            guard let name = value.stringValue else { return .invalidValue }
            state.configuredNames[Self.key(id)] = name
            save()
            lastValues[id] = value
            await homeKit?.notify([id: value], except: origin)
            return .success
        }
        let commands: [(Cell, String)]
        switch source.commands(for: value, lookup) {
        case .success(let result): commands = result
        case .failure(let status): return status
        }
        for (cell, payload) in commands {
            await publisher.publish(MQTTMessage(topic: WBTopic.controlCommand(device: cell.device, control: cell.control).path, payload: payload, retain: false))
            // Optimistic: assume WB applies the command; its echo will correct us if not.
            registry.apply(MQTTMessage(topic: WBTopic.controlValue(device: cell.device, control: cell.control).path, payload: payload))
        }
        switch source {
        case .momentary:
            momentaryOn.insert(id)
            lastValues[id] = .bool(true)
            Task {
                try? await Task.sleep(for: .seconds(1))
                await self.releaseMomentary(id)
            }
        case .blinds(let up, _):
            if let target = value.doubleValue {
                blindsPosition[up] = target >= 50 ? 100 : 0
            }
            await valuesChanged([up], except: origin, writtenIDs: [id])
            return .success
        default:
            break
        }
        await valuesChanged(commands.map(\.0), except: origin, writtenIDs: [id])
        return .success
    }

    private func releaseMomentary(_ id: HAPCharacteristicID) async {
        momentaryOn.remove(id)
        lastValues[id] = .bool(false)
        await homeKit?.notify([id: .bool(false)], except: nil)
    }

    private func read(_ id: HAPCharacteristicID) -> Result<HAPValue, HAPStatus> {
        guard let source = mapping?.sources[id] else { return .failure(.notFound) }
        switch source {
        case .momentary:
            return .success(.bool(momentaryOn.contains(id)))
        case .blinds(let up, _):
            return .success(.int(blindsPosition[up] ?? 100))
        case .configuredName(let name):
            return .success(.string(state.configuredNames[Self.key(id)] ?? name))
        default:
            return source.read(lookup)
        }
    }

    static func key(_ id: HAPCharacteristicID) -> String {
        "\(id.aid).\(id.iid)"
    }

    private var lookup: ControlLookup {
        let registry = registry
        return { registry.control(device: $0.device, control: $0.control) }
    }

    private func kind(of cell: Cell) -> CellKind? {
        if let control = registry.control(device: cell.device, control: cell.control), control.meta.type != nil {
            let kind = CellKind.classify(control)
            knownKinds[cell] = kind
            return kind
        }
        // A control that vanished keeps its last kind, so the accessory is not deleted from Home.
        return knownKinds[cell]
    }

    private func remap() async {
        guard let config else { return }
        let widgets = DashboardSelection.widgets(in: config, selected: state.dashboards)
        var kinds: [Cell: CellKind] = [:]
        for widget in widgets {
            for item in widget.cells {
                let cell = Cell(device: item.device, control: item.control)
                kinds[cell] = kind(of: cell)
            }
        }
        var mapper = AccessoryMapper(ids: state.ids, version: version) { kinds[$0] }
        mapper.map(widgets: widgets, roles: state.roles, bridge: bridgeAccessory)

        if mapper.ids != state.ids {
            state.ids = mapper.ids
            save()
        }
        let next = mapper.mapping
        // Compared with the saved value, so a new structure after restart also bumps c#.
        let fingerprint = next.fingerprint
        let changed = fingerprint != state.structure
        if changed {
            state.structure = fingerprint
            save()
        }
        let first = mapping == nil
        mapping = next
        cellIndex = [:]
        for (id, source) in next.sources {
            for cell in source.cells {
                cellIndex[cell, default: []].append(id)
            }
        }
        lastValues = [:]
        for id in next.sources.keys {
            if case .success(let value) = read(id) {
                lastValues[id] = value
            }
        }
        for cell in cellIndex.keys {
            counters[cell] = registry.control(device: cell.device, control: cell.control)?.value
        }
        for item in next.issues {
            Log.warning("\(item.widget.map { "Widget \($0): " } ?? "")\(item.issue.title["en"] ?? "")")
        }
        if changed {
            Log.info("HomeKit accessories changed: \(next.accessories.count - 1) accessories")
            await homeKit?.accessoriesChanged()
        }
        if first {
            Log.info("HomeKit accessories ready: \(next.accessories.count - 1) accessories")
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func registryChanged(_ change: WBChange) async {
        switch change {
        case .value(let device, let control, _):
            await valuesChanged([Cell(device: device, control: control)], except: nil)
        case .meta(let device, let control), .removed(let device, let control):
            let cell = Cell(device: device, control: control)
            guard cellIndex[cell] != nil || isSelected(cell) else { return }
            let before = knownKinds[cell]
            if kind(of: cell) != before {
                await remap()
                await sync()
            } else {
                await valuesChanged([cell], except: nil)
            }
        case .device:
            break
        }
    }

    private func isSelected(_ cell: Cell) -> Bool {
        guard let config else { return false }
        return DashboardSelection.widgets(in: config, selected: state.dashboards).contains { widget in
            widget.cells.contains { $0.id == cell.id }
        }
    }

    // Recomputes affected characteristics and sends events for those that really changed.
    private func valuesChanged(_ cells: [Cell], except origin: HAPConnectionID?, writtenIDs: Set<HAPCharacteristicID> = []) async {
        var changes: [HAPCharacteristicID: HAPValue] = [:]
        var originChanges: [HAPCharacteristicID: HAPValue] = [:]
        for cell in Set(cells) {
            let newCounter = registry.control(device: cell.device, control: cell.control)?.value
            let counterMoved = counters[cell] != nil && newCounter != nil && counters[cell] != newCounter
            counters[cell] = newCounter
            for id in cellIndex[cell] ?? [] {
                guard let source = mapping?.sources[id] else { continue }
                if case .buttonEvent(_, let event) = source {
                    if counterMoved {
                        changes[id] = .int(event)
                    }
                    continue
                }
                guard case .success(let value) = read(id), lastValues[id] != value else { continue }
                lastValues[id] = value
                // The writer already knows the value it wrote; other characteristics it affected still go to it.
                changes[id] = value
                if !writtenIDs.contains(id) {
                    originChanges[id] = value
                }
            }
        }
        guard !changes.isEmpty else { return }
        await homeKit?.notify(changes, except: origin)
        if let origin, !originChanges.isEmpty {
            await homeKit?.notify(originChanges, only: origin)
        }
    }
}
