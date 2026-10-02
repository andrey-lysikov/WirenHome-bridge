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

public actor BridgeApp {
    private let publisher: any MQTTPublisher
    private let source: any WebUIConfigSource
    private let store: StateStore
    private let page: any SettingsPageStore
    private let qr: any QRRenderer
    private let configPath: String
    private let version: String
    private var state: BridgeState
    private var registry = DeviceRegistry()
    private var config: WebUIConfig?
    private var pendingConfig: WebUIConfig?
    private var connected = false
    private var homeKit: (any HomeKitControl)?
    private var paired = false
    private var stopped = false

    // Settings page: the file content last applied, the MQTT part it started with, the schema last written.
    private var appliedSettings: Data?
    private var startupMQTT: SettingsFile.MQTT?
    private var writtenSchema: Data?
    private var qrCache: (uri: String, svg: String?)?
    // checkSettings is called by the poll and after dashboards load; one run at a time, a call meanwhile repeats it.
    private var checkingSettings = false
    private var settingsRecheck = false
    private var schemaWrite: Task<Void, Never>?

    // HomeKit side: current accessory mapping and the values last reported to controllers.
    private var bridgeAccessory = HAPAccessory(aid: 1, services: [])
    private var mapping: Mapping?
    private var cellIndex: [Cell: [HAPCharacteristicID]] = [:]
    private var knownKinds: [Cell: CellKind] = [:]
    private var lastValues: [HAPCharacteristicID: HAPValue] = [:]
    private var counters: [Cell: String] = [:]
    private var momentaryOn: Set<HAPCharacteristicID> = []
    private var blindsPosition: [Cell: Int] = [:]
    // Where a button-driven gate was sent; cleared when a sensor reports an end position.
    private var doorTargets: [Gate: Int] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    // Events from WB go out at most once per second per characteristic; the latest held value follows.
    static let eventInterval = Duration.seconds(1)
    private let clock = ContinuousClock()
    private var lastEventAt: [HAPCharacteristicID: ContinuousClock.Instant] = [:]
    private var heldEvents: [HAPCharacteristicID: HAPValue] = [:]
    private var flushScheduled = false

    public init(
        publisher: any MQTTPublisher, source: any WebUIConfigSource, store: StateStore, state: BridgeState, version: String,
        page: any SettingsPageStore, qr: any QRRenderer = QREncodeRenderer(), configPath: String = Settings.defaultConfigPath
    ) {
        self.publisher = publisher
        self.source = source
        self.store = store
        self.state = state
        self.version = version
        self.page = page
        self.qr = qr
        self.configPath = configPath
    }

    var currentState: BridgeState { state }

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

    func setPaired(_ paired: Bool) async {
        self.paired = paired
        await publishPage()
    }

    public func handle(_ event: MQTTEvent) async {
        switch event {
        case .connected:
            connected = true
            await publishPage()
        case .disconnected:
            connected = false
        case .message(let message):
            if let change = registry.apply(message) {
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
        await checkSettings()
        await publishPage()
    }

    public func stop() async {
        stopped = true
        await publishPage()
    }

    // Reads the settings file saved by the form; returns true when the MQTT settings changed and a restart is due.
    @discardableResult
    public func checkSettings() async -> Bool {
        guard !checkingSettings else {
            settingsRecheck = true
            return false
        }
        checkingSettings = true
        defer { checkingSettings = false }
        repeat {
            settingsRecheck = false
            if await applySettingsFile() {
                return true
            }
        } while settingsRecheck
        return false
    }

    private func applySettingsFile() async -> Bool {
        let data = await page.readSettings()
        guard data == nil || data != appliedSettings else { return false }
        var file = SettingsFile()
        if let data {
            guard let decoded = try? JSONDecoder().decode(SettingsFile.self, from: data) else {
                Log.warning("Cannot parse \(configPath), keeping the current settings")
                appliedSettings = data
                return false
            }
            file = decoded
        }
        if let startupMQTT, startupMQTT != file.mqtt {
            Log.info("MQTT settings changed in \(configPath), restarting")
            return true
        }
        startupMQTT = file.mqtt

        var rewrite = data == nil
        if let dashboards = file.dashboards {
            apply(dashboards)
        } else if let config {
            // A new or reset file (e.g. after a firmware reflash) gets the choices kept in state.json.
            file.dashboards = SettingsFile.dashboards(from: state, config: config)
            rewrite = true
        }
        if file.resetPairing {
            file.resetPairing = false
            rewrite = true
            await resetPairing()
        }
        if rewrite {
            let encoded = file.encoded()
            await page.writeSettings(encoded)
            appliedSettings = encoded
        } else {
            appliedSettings = data
        }
        // Until the dashboards are known the file cannot be completed, so look at it again later.
        if file.dashboards == nil {
            appliedSettings = nil
        }
        save()
        await remap()
        await publishPage()
        return false
    }

    private func apply(_ dashboards: [String: SettingsFile.Dashboard]) {
        state.dashboards = Set(dashboards.filter(\.value.enabled).keys)
        // A widget shown on several dashboards takes its role from the first one, as listed on the form.
        let owners = config.map { SettingsSchema.owners(in: $0).map(\.0.id) } ?? []
        let order = owners + dashboards.keys.sorted().filter { !owners.contains($0) }
        var roles: [String: AccessoryRole] = [:]
        for dashboard in order.reversed() {
            for (widget, code) in dashboards[dashboard]?.roles ?? [:] {
                roles[widget] = AccessoryRole(code: code)
            }
        }
        state.roles = roles.filter { $0.value != .auto }
    }

    private func resetPairing() async {
        state.pinCode = PinCode.generate()
        state.setupID = HAPSetupPayload.generateSetupID()
        Log.info("Pairing reset from the settings page, new setup code generated")
        save()
        await homeKit?.reset(setupCode: state.pinCode, setupID: state.setupID)
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

    private func publishPage() async {
        let uri = HAPSetupPayload.uri(setupCode: state.pinCode, setupID: state.setupID)
        if qrCache?.uri != uri {
            qrCache = (uri, await qr.svg(for: uri))
        }
        let info = SettingsPageInfo(
            status: status, accessories: max(0, (mapping?.accessories.count ?? 1) - 1), issues: mapping?.issues ?? [],
            version: version, pinCode: state.pinCode, setupURI: uri, qrSVG: qrCache?.svg
        )
        let schema = SettingsSchema.build(info: info, config: config, configPath: configPath)
        guard schema != writtenSchema else { return }
        writtenSchema = schema
        // Writes queue up in build order, so an older schema never lands after a newer one.
        let previous = schemaWrite
        let write = Task { [page] in
            await previous?.value
            await page.writeSchema(schema)
        }
        schemaWrite = write
        await write.value
    }

    private var status: BridgeStatus {
        if stopped { return .stopped }
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
        case .doorTarget(let gate):
            if gate.remembersTarget, let target = value.doubleValue {
                doorTargets[gate] = Int(target)
            }
            await valuesChanged(gate.cells, except: origin, writtenIDs: [id])
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
        case .doorCurrent(let gate):
            return .success(.int(gate.current(remembered: doorTargets[gate], lookup)))
        case .doorTarget(let gate):
            return .success(.int(gate.target(remembered: doorTargets[gate], lookup)))
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
            let cell = Cell(device: device, control: control)
            for gate in doorTargets.keys where [gate.opened, gate.closed].contains(cell) && gate.position(lookup) != nil {
                doorTargets[gate] = nil
            }
            await valuesChanged([cell], except: nil)
        case .meta(let device, let control), .removed(let device, let control):
            let cell = Cell(device: device, control: control)
            guard cellIndex[cell] != nil || isSelected(cell) else { return }
            let before = knownKinds[cell]
            if kind(of: cell) != before {
                await remap()
                await publishPage()
            } else {
                await valuesChanged([cell], except: nil)
            }
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
        let now = clock.now
        // Writes from HomeKit answer at once; WB changes are rate-limited.
        if origin == nil {
            for (id, value) in changes {
                if let last = lastEventAt[id], now - last < Self.eventInterval {
                    heldEvents[id] = value
                    changes[id] = nil
                }
            }
            scheduleFlush()
        }
        for id in changes.keys {
            lastEventAt[id] = now
            heldEvents[id] = nil
        }
        if !changes.isEmpty {
            await homeKit?.notify(changes, except: origin)
        }
        if let origin, !originChanges.isEmpty {
            await homeKit?.notify(originChanges, only: origin)
        }
    }

    private func scheduleFlush() {
        guard !heldEvents.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: Self.eventInterval)
            await self.flushHeldEvents()
        }
    }

    private func flushHeldEvents() async {
        flushScheduled = false
        let now = clock.now
        var due: [HAPCharacteristicID: HAPValue] = [:]
        for (id, value) in heldEvents where lastEventAt[id].map({ now - $0 >= Self.eventInterval }) ?? true {
            due[id] = value
            lastEventAt[id] = now
        }
        for id in due.keys {
            heldEvents[id] = nil
        }
        if !due.isEmpty {
            await homeKit?.notify(due, except: nil)
        }
        scheduleFlush()
    }
}
