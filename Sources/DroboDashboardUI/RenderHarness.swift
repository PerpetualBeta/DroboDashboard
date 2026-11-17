// Off-screen render harness (the reference pattern for verifying UI work
// without popping windows or needing screen-recording permission):
//
//   DROBO_RENDER_PNG=<path> <binary>
//
// Renders one frame of the dashboard from LIVE data after the first poll
// settles, writes a PNG, and exits. A failed read renders the failure state
// the same way, so both appearances are checkable. Exit 0 on a PNG, 3 on
// timeout.
//
//   DROBO_RENDER_FAKE=problem <binary>
//
// Renders immediately from synthetic data with a faulted cache slot, so
// the problem pill and its reason text can be verified without a real
// fault. DROBO_RENDER_FAKE=diskpack renders a diskpack status 4 (the
// original Dashboard's "mismatched disks") to check the label path.
// (Implies no live poll; live renders stay the default when unset.)

import AppKit
import SwiftUI
import DroboKit

enum RenderHarness {
    @MainActor
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["DROBO_RENDER_PNG"] else { return }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = DeviceModel()
        let timeout = DispatchWorkItem { exit(3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)

        if let fake = ProcessInfo.processInfo.environment["DROBO_RENDER_FAKE"] {
            // Synthetic frame, rendered without touching the pack. Only
            // shapes the UI can actually show; measured values only, the
            // same shape a real fault produces.
            let badSlot = ESASlotInfo(state: 0x01, capacityBytes: 4_000_000_000_000,
                                      reserved: 0, model: "ST4000DM004", shortModel: "ST4000")
            var snapshot = DeviceSnapshot()
            snapshot.slots = (0..<6).map { i in
                let state = (fake == "problem" && i == 5) ? UInt8(0x01) : UInt8(0x03)
                return ESASlotInfo(state: state, capacityBytes: 4_000_000_000_000,
                                   reserved: 0, model: "ST4000DM004", shortModel: "ST4000")
            }
            if fake == "diskpack" {
                // Diskpack code 4 = the original Dashboard's "mismatched
                // disks" (flag 0x800), so the label path renders.
                snapshot.status = ESAStatusInfo(status: 0x28000, extendedStatus: 0,
                                                diskpackStatus: 4, relayoutCount: nil,
                                                doubleDegraded: nil)
            }
            model.snapshot = snapshot
            model.state = .loaded
            model.lastRefresh = Date()
            renderNow(model)
            return
        }

        model.onSettled = { renderNow(model) }

        model.start()
        app.run()
    }

    @MainActor
    private static func renderNow(_ model: DeviceModel) -> Never {
        let view = NSHostingView(rootView: ContentView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()

        let bounds = view.bounds
        let rep = view.bitmapImageRepForCachingDisplay(in: bounds)!
        view.cacheDisplay(in: bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROBO_RENDER_PNG"]!))
        exit(0)
    }
}
