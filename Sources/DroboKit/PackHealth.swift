// The pack-health verdict, shared by the dashboard pill and the health
// agent so both answer from one rule set. Every threshold here is a
// measured value: diskpack 0 observed healthy on this firmware, 1 named
// healthy by the original daemon's statusFlag mapping, slot state 0x03
// observed on all six good slots. Anything else is a problem stated with
// its raw value, never an invented label.

import Foundation

public enum PackHealth: Equatable {
    case healthy
    case problem(String)

    public static func evaluate(status: ESAStatusInfo?, slots: [ESASlotInfo]) -> PackHealth {
        if let status {
            if let relayout = status.relayoutCount, relayout != 0 {
                return .problem("relayout in progress (relayout \(relayout))")
            }
            if let doubleDegraded = status.doubleDegraded, doubleDegraded != 0 {
                return .problem("double degraded (doubleDegraded \(doubleDegraded))")
            }
            if let diskpack = status.diskpackStatus, diskpack != 0, diskpack != 1 {
                return .problem("disk pack status \(diskpack)")
            }
        }
        for (index, slot) in slots.enumerated() where slot.state != 0x03 {
            let label = (slots.count == 6 && index == 5) ? "cache slot" : "bay \(index + 1)"
            return .problem("\(label) not ready (state 0x\(String(slot.state, radix: 16)))")
        }
        return .healthy
    }

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var reason: String? {
        if case .problem(let text) = self { return text }
        return nil
    }
}
