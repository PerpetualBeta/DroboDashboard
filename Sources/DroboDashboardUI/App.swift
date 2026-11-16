// DroboDashboard: the native replacement for the retired Drobo Dashboard.
// A read-only window on the pool: capacity, slots, health.

import SwiftUI

struct DroboDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = DeviceModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
                .onDisappear { model.stop() }
        }
        .windowResizability(.contentSize)
    }
}

/// Keeps the app alive without a window when the display count changes and
/// stops the poll timer on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
    }
}
