import AppKit
import DroboKit

// Harness mode first: render one frame to a PNG and exit. Normal app
// launch when the variable is absent.
if ProcessInfo.processInfo.environment["DROBO_RENDER_PNG"] != nil {
    MainActor.assumeIsolated { RenderHarness.runIfRequested() }
} else {
    DroboDashboardApp.main()
}
