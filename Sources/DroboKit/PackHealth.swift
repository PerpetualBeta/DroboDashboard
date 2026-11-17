// The pack-health verdict, shared by the dashboard pill and the health
// agent so both answer from one rule set. Every threshold here is a
// measured value: diskpack 0 observed healthy on this firmware, 1 named
// healthy by the original daemon's statusFlag mapping, slot state 0x03
// observed on all six good slots. Anything else is a problem stated with
// its raw value, never an invented label.
//
// The labels for diskpack codes 2 to 8 are NOT invented: they come from
// the original Dashboard 3.6.1. REA decompile of ActionTextPresenter::
// SetDeviceAction in "Drobo Dashboard" (2026-11-17) maps each flag bit
// the daemon's ESASCSISession::getStatusInfo ORs in for a given code to
// a kStatusString_* resource key, and strings_en.xml carries the text.
// The full original sentences are long (warning paragraphs); these are
// shortened labels, always shown with the raw code so nothing is hidden.

import Foundation

public enum PackHealth: Equatable {
    case healthy
    case problem(String)

    /// The original Dashboard's meaning for each diskpack status code,
    /// shortened from its kStatusString_* text. 5, 6 and 7 share the
    /// multiple-drives-removed meaning (one flag bit 0x20 for all three).
    /// A code outside the original's switch returns nil and renders raw.
    public static func label(forDiskpackStatus code: UInt32) -> String? {
        switch code {
        case 2: return "pack incompatible with firmware"
        case 3: return "unknown pack state"
        case 4: return "mismatched disks (mixing packs)"
        case 5, 6, 7: return "multiple drives removed"
        case 8: return "1st-generation Drobo pack"
        default: return nil
        }
    }

    public static func evaluate(status: ESAStatusInfo?, slots: [ESASlotInfo]) -> PackHealth {
        if let status {
            if let relayout = status.relayoutCount, relayout != 0 {
                return .problem("relayout in progress (relayout \(relayout))")
            }
            if let doubleDegraded = status.doubleDegraded, doubleDegraded != 0 {
                return .problem("double degraded (doubleDegraded \(doubleDegraded))")
            }
            if let diskpack = status.diskpackStatus, diskpack != 0, diskpack != 1 {
                let text = label(forDiskpackStatus: diskpack)
                    .map { "disk pack status \(diskpack): \($0)" }
                    ?? "disk pack status \(diskpack)"
                return .problem(text)
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
