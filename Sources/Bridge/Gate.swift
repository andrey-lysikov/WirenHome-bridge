//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

// Gate cells picked by type and widget order; HAP door states: 0 open, 1 closed, 2 opening, 3 closing, 4 stopped.
struct Gate: Sendable, Hashable {
    var open: Cell?
    var close: Cell?
    var toggle: Cell?
    var opened: Cell?
    var closed: Cell?

    // Buttons: open, close; one button is an impulse input. Sensors: open, closed; a single one is "closed".
    init(buttons: [Cell], toggle: Cell?, sensors: [Cell]) {
        open = buttons.first
        close = buttons.count > 1 ? buttons[1] : nil
        self.toggle = buttons.isEmpty ? toggle : nil
        opened = sensors.count > 1 ? sensors[0] : nil
        closed = sensors.count > 1 ? sensors[1] : sensors.first
    }

    var cells: [Cell] {
        [open, close, toggle, opened, closed].compactMap { $0 }
    }

    // The bridge remembers targets only for buttons; a held relay is its own target.
    var remembersTarget: Bool { toggle == nil }

    // 0 or 1 when sensors show an end position, nil while moving or without sensors.
    func position(_ lookup: ControlLookup) -> Int? {
        func on(_ cell: Cell?) -> Bool? {
            cell.map { (Double(Source.value($0, lookup) ?? "0") ?? 0) != 0 }
        }
        if on(opened) == true { return 0 }
        if let closed = on(closed) {
            if closed { return 1 }
            return opened == nil ? 0 : nil
        }
        return nil
    }

    func target(remembered: Int?, _ lookup: ControlLookup) -> Int {
        if let toggle {
            return (Double(Source.value(toggle, lookup) ?? "0") ?? 0) != 0 ? 0 : 1
        }
        return remembered ?? position(lookup) ?? 1
    }

    func current(remembered: Int?, _ lookup: ControlLookup) -> Int {
        if let position = position(lookup) { return position }
        let target = target(remembered: remembered, lookup)
        guard opened != nil else { return target }
        // Between both end sensors: moving if we know where to, otherwise stopped half-way.
        return remembered != nil || toggle != nil ? (target == 0 ? 2 : 3) : 4
    }

    func commands(target: Int, _ lookup: ControlLookup) -> [(Cell, String)] {
        if let toggle {
            return [(toggle, target == 0 ? "1" : "0")]
        }
        guard let open else { return [] }
        // An impulse input reverses the gate, so do not press it when already there.
        guard let close else { return position(lookup) == target ? [] : [(open, "1")] }
        return [(target == 0 ? open : close, "1")]
    }
}
