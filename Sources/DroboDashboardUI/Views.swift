// The Dashboard window: device header, protected-capacity gauge, one card
// per slot (five bays plus the SSD cache), and a details footer. Values the
// protocol has not pinned are shown raw rather than labelled with guesses.

import SwiftUI
import DroboKit

struct ContentView: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            CapacityGauge(capacity: model.snapshot.capacity)
            SlotGrid(slots: model.snapshot.slots)
            footer
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drobo 5D3")
                    .font(.title2.weight(.semibold))
                Text("DAS pack, dual-disk protection")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HealthPill(status: model.snapshot.status,
                       slots: model.snapshot.slots)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let firmware = model.snapshot.firmware {
                Text("Firmware \(firmware.packageString) \(firmware.buildString ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let when = model.lastRefresh {
                Text(when, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch model.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help(message)
            default:
                EmptyView()
            }
            Button("Refresh") { model.refresh() }
        }
    }
}

/// Green when the shared PackHealth evaluator passes; yellow with the
/// reason otherwise. The SAME rule set the health agent notifies on, so
/// the window and the agent cannot disagree.
private struct HealthPill: View {
    let status: ESAStatusInfo?
    let slots: [ESASlotInfo]

    var body: some View {
        let verdict = PackHealth.evaluate(status: status, slots: slots)
        let healthy = verdict.isHealthy
        HStack(spacing: 5) {
            Circle()
                .fill(healthy ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
            Text(healthy ? "Protected" : (verdict.reason ?? "Attention"))
                .lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(healthy ? Color.green.opacity(0.12) : Color.yellow.opacity(0.15)))
        .help(verdict.reason ?? "")
    }
}

private struct CapacityGauge: View {
    let capacity: ESACapacityInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = capacity {
                let fraction = c.totalProtectedBytes > 0
                    ? Double(c.usedBytes) / Double(c.totalProtectedBytes) : 0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(Color(nsColor: NSColor(red: 0, green: 0.25, blue: 0.5, alpha: 1)))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 14)
                HStack {
                    Text("\(Self.tb(c.freeBytes)) TB free")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Self.tb(c.usedBytes)) TB of \(Self.tb(c.totalProtectedBytes)) TB used")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 14)
                Text("Capacity unavailable").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static func tb(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_000_000_000_000)
    }
}

private struct SlotGrid: View {
    let slots: [ESASlotInfo]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                SlotCard(index: index, count: slots.count, slot: slot)
            }
        }
    }
}

private struct SlotCard: View {
    let index: Int
    let count: Int
    let slot: ESASlotInfo

    private var label: String {
        (count == 6 && index == 5) ? "Cache" : "Bay \(index + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(slot.state == 0x03 ? Color.green : Color.yellow)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(CapacityGauge.tb(slot.capacityBytes) ) TB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(slot.model.isEmpty ? "Empty" : slot.model)
                .font(.caption)
                .foregroundStyle(slot.model.isEmpty ? Color.secondary : .primary)
                .lineLimit(1)
            if slot.state != 0x03 {
                Text("state 0x\(String(slot.state, radix: 16))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
