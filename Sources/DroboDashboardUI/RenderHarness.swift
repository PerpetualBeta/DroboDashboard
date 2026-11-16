// Off-screen render harness (the reference pattern for verifying UI work
// without popping windows or needing screen-recording permission):
//
//   DROBO_RENDER_PNG=<path> <binary>
//
// Renders one frame of the dashboard from LIVE data after the first poll
// settles, writes a PNG, and exits. A failed read renders the failure state
// the same way, so both appearances are checkable. Exit 0 on a PNG, 3 on
// timeout.

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

        model.onSettled = {
            let view = NSHostingView(rootView: ContentView(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
            view.layoutSubtreeIfNeeded()
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()

            let bounds = view.bounds
            let rep = view.bitmapImageRepForCachingDisplay(in: bounds)!
            view.cacheDisplay(in: bounds, to: rep)
            let png = rep.representation(using: .png, properties: [:])!
            try! png.write(to: URL(fileURLWithPath: path))
            exit(0)
        }

        model.start()
        app.run()
    }
}
