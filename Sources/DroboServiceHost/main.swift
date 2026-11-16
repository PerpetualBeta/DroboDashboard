// DroboServiceHost: the minimal host app that installs and activates the
// DroboDext system extension. It embeds the dext in
// Contents/Library/SystemExtensions/ and submits one activation request.
// Later this app grows into the SwiftUI Dashboard; for now it is the
// installer.
//
// Run it once with `open`. macOS prompts once in System Settings; approve
// and the driver attaches.

import Foundation
import SystemExtensions

// `open` detaches the app, so delegate output must land in a log file to be
// visible. ~/Library/Logs/DroboService/, like the daemon's own logs.
let logPath = NSHomeDirectory() + "/Library/Logs/DroboService/host-install.log"
func say(_ line: String)
{
    let stamped = "\(Date()): \(line)\n"
    let data = Data(stamped.utf8)
    try? FileManager.default.createDirectory(
        atPath: (logPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    let handle = FileHandle(forWritingAtPath: logPath)
    handle?.seekToEndOfFile()
    do {
        try handle?.write(contentsOf: data)
        try handle?.close()
    } catch {
        // A dead log handle must never take the host app down.
    }
    print(line)
}

final class InstallDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension current: OSSystemExtensionProperties,
                 withExtension incoming: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction
    {
        // Same identifier, newer bundle: replace.
        say("existing extension found; replacing")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest)
    {
        say("waiting for your approval in System Settings -> Privacy & Security")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result)
    {
        say("install finished, result \(result.rawValue)")
        if result == .completed {
            say("DroboDext is active. Try: drobo status")
            // The delegate must outlive the request: an upgrade waits for the
            // previous version to terminate "via delegate", and quitting here
            // orphans that replacement. Stay resident.
            say("staying resident as the extension delegate")
        } else {
            say("a reboot may be needed to finish activation")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error)
    {
        say("install failed: \(error)")
        exit(1)
    }
}

say("host app started; submitting activation request for cc.jorvik.drobodext")
let delegate = InstallDelegate()

// `open --args -d` submits a deactivation instead: for a clean reinstall
// when the upgrade state machine is clogged.
let argv = CommandLine.arguments
let request: OSSystemExtensionRequest
if argv.contains("-d") {
    say("deactivation requested")
    request = OSSystemExtensionRequest.deactivationRequest(
        forExtensionWithIdentifier: "cc.jorvik.drobodext",
        queue: .main)
} else {
    request = OSSystemExtensionRequest.activationRequest(
        forExtensionWithIdentifier: "cc.jorvik.drobodext",
        queue: .main)
}
request.delegate = delegate
OSSystemExtensionManager.shared.submitRequest(request)
dispatchMain()
