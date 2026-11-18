// drobo: management CLI for the 5D3 and friends. This is the live verification
// tool for the rebuild; every device command goes through an explicit
// transport open, and the eject that exclusive access requires is opt-in.
//
//   drobo list                 registry-only enumeration, no device access
//   drobo probe --disk disk15  read-only sweep of every ESA page
//   drobo status --disk disk15 parsed health, capacity, firmware, bays

import Foundation
import DroboKit
import DroboTransport
import DDServiceC

func hexDump(_ data: Data, limit: Int = 0x40) -> String {
    let bytes = data.prefix(limit)
    var lines: [String] = []
    for offset in stride(from: 0, to: bytes.count, by: 16) {
        let chunk = bytes.subdata(in: offset..<min(offset + 16, bytes.count))
        let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        lines.append(String(format: "  %04x  %@", offset, hex))
    }
    return lines.joined(separator: "\n")
}

func openTransport(args: [String: String]) throws -> SCSITransport {
    let kind = DDTransportKind(rawValue: args["transport"] ?? "") ?? .dext
    return try makeTransport(kind: kind, bsdName: args["disk"])
}

func maybeEject(args: inout [String: String]) {
    guard args["eject"] == "true" else { return }
    guard let disk = args["disk"], !disk.isEmpty else {
        print("--eject needs --disk <bsd name>")
        exit(2)
    }
    print("Ejecting \(disk) so exclusive access is possible...")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    task.arguments = ["eject", disk]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        print("diskutil failed to start: \(error)")
        exit(1)
    }
    guard task.terminationStatus == 0 else {
        print("diskutil eject \(disk) failed with status \(task.terminationStatus)")
        print("Close anything holding files open on the volume, then retry.")
        exit(1)
    }
    // A whole-device eject destroys the BSD name; the session that follows
    // opens the Drobo peripheral nub by vendor match instead.
    args["disk"] = nil
}

func printUnlockHint() {
    print("""
    Done with the session. To bring Jupiter back:
      diskutil coreStorage list        (find the logical volume UUID)
      diskutil coreStorage unlockLV <uuid>
    """)
}

func commandList() {
    let count = ddus_count_drobo_nubs()
    guard count >= 0 else {
        print("enumeration failed: \(String(cString: dd_last_error()))")
        exit(1)
    }
    print("Drobo peripheral nubs found: \(count)")
    if count == 0 {
        print("Check the enclosure is connected and powered, then run again.")
    }
}

// MARK: - Heal: clear wedged driver servers after a dext upgrade

func runCapture(_ path: String, _ arguments: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

func dextStateLines() -> [String] {
    runCapture("/usr/bin/systemextensionsctl", ["list"])
        .split(separator: "\n")
        .filter { $0.contains("drobodext") }
        .map(String.init)
}

func commandHeal() {
    // A wedge is an OLD server surviving an upgrade: the DK upgrade waits
    // for the previous server to exit and it never does on its own. But the
    // healthy provider of the ACTIVE dext also runs as a server process, so
    // existence is not evidence of wedging. The rule is time: kill only
    // servers that started BEFORE the active dext bundle was installed. A
    // server younger than the install is the current provider; killing it
    // is pointless at best. MEASURED 2026-11-16: heal flagged a healthy
    // provider (started 20:50, bundle installed 19:45) and nearly sudo-
    // killed it; the password prompt was the only thing that stopped that.
    let bundleDates = (try? FileManager.default
        .contentsOfDirectory(atPath: "/Library/SystemExtensions"))?
        .compactMap { entry -> Date? in
            let dext = "/Library/SystemExtensions/\(entry)/cc.jorvik.drobodext.dext"
            return try? FileManager.default.attributesOfItem(atPath: dext)[.modificationDate] as? Date
        }
        .sorted()
    let activeInstall = bundleDates?.last

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

    var wedged: [Int] = []
    var healthy: [Int] = []
    for line in runCapture("/usr/bin/pgrep", ["DroboDext"]).split(separator: "\n") {
        guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
        // Trim newlines too: ps ends its line with one, and DateFormatter
        // refuses to parse a string with trailing garbage.
        let started = formatter.date(from: runCapture("/bin/ps", ["-o", "lstart=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines))
        if let activeInstall, let started, started >= activeInstall {
            healthy.append(pid)
        } else {
            wedged.append(pid)
        }
    }

    if !healthy.isEmpty {
        print("server\(healthy.count == 1 ? "" : "s") \(healthy.map(String.init).joined(separator: " ")) started after the active dext install: current, left running")
    }
    if wedged.isEmpty {
        if healthy.isEmpty { print("no DroboDext server processes running") }
    } else {
        print("killing wedged DroboDext server\(wedged.count == 1 ? "" : "s"): \(wedged.map(String.init).joined(separator: " "))")
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        kill.arguments = ["kill"] + wedged.map(String.init)
        kill.standardError = FileHandle.nullDevice
        do {
            try kill.run()
            kill.waitUntilExit()
        } catch {
            print("could not run sudo: \(error)")
            exit(1)
        }
        if kill.terminationStatus != 0 {
            print("the kill needs your password; run this command from your own Terminal")
            exit(1)
        }
    }

    // Wait for the version state machine to settle: no "terminating" line.
    for attempt in 0..<10 {
        let lines = dextStateLines()
        let terminating = lines.filter { $0.contains("terminating") }
        if terminating.isEmpty {
            print(lines.isEmpty ? "no dext registered yet" : "clean state: \(lines.joined(separator: " | "))")
            print("now unplug the cable, five seconds, plug it back in, then run: drobo status")
            return
        }
        if attempt == 0 {
            print("waiting for the old version to finish terminating...")
        }
        Thread.sleep(forTimeInterval: 1)
    }
    print("the upgrade is still stuck in termination; replug the cable and run: drobo status")
}

func probe(args: inout [String: String]) throws {
    maybeEject(args: &args)
    let transport = try openTransport(args: args)
    defer { transport.close() }
    let session = ESASession(transport: transport)
    print("Transport open. Sending read-only MODE SENSE sweeps (page 0x3A).")

    let subpages: [(UInt8, String, Int)] = [
        (ESASystemInfo.subpage, "system", ESASystemInfo.pageSize),
        (ESACapacityInfo.subpage, "capacity", ESACapacityInfo.minimumLength),
        (ESAFirmwareInfo.subpage, "firmware", 0x3A),
        (ESAStatusInfo.subpage, "status", 0x18),
        (ESASlotInfo.subpage, "slots", 0x220)
    ]
    for (subpage, name, size) in subpages {
        print("\n== \(name) (subpage 0x\(String(subpage, radix: 16))) ==")
        do {
            let raw = try session.modeSense(subpage: subpage, allocationLength: size + 0x10)
            print(hexDump(raw, limit: min(size + 0x10, 0x200)))
            let pageData = ESASession.pageData(ofModeSenseResponse: raw)
            switch subpage {
            case ESASystemInfo.subpage:
                print("parsed: \(try ESASystemInfo.parse(pageData))")
            case ESACapacityInfo.subpage:
                print("parsed: \(try ESACapacityInfo.parse(pageData))")
            case ESAFirmwareInfo.subpage:
                print("parsed: \(try ESAFirmwareInfo.parse(pageData))")
            case ESAStatusInfo.subpage:
                print("parsed: \(try ESAStatusInfo.parse(pageData))")
            case ESASlotInfo.subpage:
                print("parsed: \(try ESASlotInfo.parse(pageData))")
            default: break
            }
        } catch {
            print("failed: \(error)")
        }
    }
    printUnlockHint()
}

func status(args: inout [String: String]) throws {
    maybeEject(args: &args)
    let transport = try openTransport(args: args)
    defer { transport.close() }
    let session = ESASession(transport: transport)

    do {
        let fw = try session.getFirmwareInfo()
        print("firmware : \(fw.packageString) \(fw.buildString ?? "-") (v\(fw.versionChar1)\(fw.versionChar2), word 0x\(String(fw.versionWord, radix: 16)))")
    } catch { print("firmware : failed: \(error)") }
    do {
        let capacity = try session.getCapacityInfo()
        let tb: (UInt64) -> String = { String(format: "%.2f", Double($0) / 1_000_000_000_000) }
        print("capacity : free \(tb(capacity.freeBytes)) TB used \(tb(capacity.usedBytes)) TB total \(tb(capacity.totalProtectedBytes)) TB protected, \(tb(capacity.totalUnprotectedBytes)) TB unprotected")
    } catch { print("capacity : failed: \(error)") }
    do {
        let state = try session.getStatusInfo()
        print("status   : 0x\(String(state.status, radix: 16)) diskpack \(state.diskpackStatus.map(String.init) ?? "-") relayout \(state.relayoutCount.map(String.init) ?? "-") doubleDegraded \(state.doubleDegraded.map(String.init) ?? "-")")
    } catch { print("status   : failed: \(error)") }
    do {
        let slots = try session.getSlotInfo()
        for (index, slot) in slots.enumerated() {
            let terabytes = Double(slot.capacityBytes) / 1_000_000_000_000
            let label = (slots.count == 6 && index == 5) ? "cache" : "bay \(index + 1)  "
            print("slot \(index + 1) [\(label)]: state 0x\(String(slot.state, radix: 16)) \(slot.capacityBytes) bytes (\(String(format: "%.2f", terabytes)) TB) \(slot.model)")
        }
    } catch { print("slots     : failed: \(error)") }
    printUnlockHint()
}

// The CoreStorage LV UUID whose physical store sits on this disk, so
// the data volume (only) can be remounted after a dance. nil for a
// plain (non-CoreStorage) pack: the fallback then mounts the whole
// disk, which also mounts Boot OS X — noted when it happens.
func coreStorageLVUUID(disk: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["cs", "list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var groupHasDisk = false
    for line in text.split(separator: "\n") {
        if line.contains("Logical Volume Group") { groupHasDisk = false }
        if !groupHasDisk, line.contains("Physical Volume") {
            // The PV's own "Disk:" line follows; keep the group open.
            groupHasDisk = true
        }
        if groupHasDisk, line.contains("Disk:"), !line.contains(disk) {
            // This group's physical store is on a different disk.
            groupHasDisk = false
        }
        if groupHasDisk, line.contains("Family") { continue }
        if groupHasDisk, let r = line.range(of: "Logical Volume [0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                                            options: .regularExpression) {
            return String(line[r]).replacingOccurrences(of: "Logical Volume ", with: "")
        }
    }
    return nil
}

// After a dext restart or resume, the framework re-creates the media
// tree asynchronously (measured: a few seconds) and the CoreStorage LV
// does NOT auto-mount (measured): mount it by UUID. The CS stack itself
// also needs a few seconds to reassemble — MEASURED: `diskutil cs list`
// can briefly show a locked LV with no UUID, so retry before falling
// back to mountDisk (which mounts everything on the disk).
func remountDisk(_ disk: String) {
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: "/dev/\(disk)") { break }
        Thread.sleep(forTimeInterval: 1)
    }
    for attempt in 0..<4 {
        if let lv = coreStorageLVUUID(disk: disk) {
            let mount = Process()
            mount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            mount.arguments = ["mount", lv]
            mount.standardOutput = FileHandle.standardOutput
            try? mount.run()
            mount.waitUntilExit()
            if mount.terminationStatus == 0 { return }
        } else if attempt > 0 {
            print("(CoreStorage LV not resolvable yet, attempt \(attempt + 1))")
        }
        Thread.sleep(forTimeInterval: 3)
    }
    print("(no CoreStorage LV on \(disk): mounting the whole disk, which may")
    print("mount partitions like Boot OS X as well)")
    let mount = Process()
    mount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    mount.arguments = ["mountDisk", disk]
    mount.standardOutput = FileHandle.standardOutput
    try? mount.run()
    mount.waitUntilExit()
}

func parseArgs(_ argv: [String]) -> (command: String, options: [String: String]) {
    var options: [String: String] = [:]
    var positional: [String] = []
    var index = 0
    while index < argv.count {
        let arg = argv[index]
        if arg == "--eject" {
            options["eject"] = "true"
        } else if arg == "--confirm" {
            options["confirm"] = "true"
        } else if arg == "--suspend-test" {
            options["suspend-test"] = "true"
        } else if arg == "--disk", index + 1 < argv.count {
            index += 1
            options["disk"] = argv[index]
        } else if arg == "--transport", index + 1 < argv.count {
            index += 1
            options["transport"] = argv[index]
        } else {
            positional.append(arg)
        }
        index += 1
    }
    return (positional.first ?? "help", options)
}

/// The software replug: brings the newest ACTIVATED dext version onto the
/// device without touching the cable. Sequence (all measured 2026-11-17):
/// eject cleanly (the volume must never be dirty when the device goes
/// away — that is what "Disk not ejected properly" was punishing), relaunch
/// the host app so it submits the activation request for the version in
/// the bundle, then power-cycle the Drobo's USB port (uhubctl): the old
/// dext's device disappears, its teardown completes the upgrade, and the
/// new dext claims the LUN at the fresh attach. The cycle needs root, so
/// this command runs from his Terminal.
func commandDextRestart(args: inout [String: String]) throws {
    guard let disk = args["disk"] else {
        print("dext-restart needs --disk <the pack's disk, e.g. disk8> to eject cleanly first")
        return
    }
    let hub = args["hub"] ?? "34-1"
    let port = args["port"] ?? "1"

    // The disk may ALREADY be gone (measured: the USB probe personality's
    // co-claim broke the kernel block path and the BSD disk vanished).
    // Nothing to eject then — a missing disk cannot be dirty — and the
    // cycle is exactly what brings it back.
    if !FileManager.default.fileExists(atPath: "/dev/\(disk)") {
        print("\(disk) is already gone; nothing to eject — the cycle will bring it back")
    } else {
        let eject = Process()
        eject.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        eject.arguments = ["eject", disk]
        eject.standardOutput = FileHandle.standardOutput
        try? eject.run()
        eject.waitUntilExit()
        guard eject.terminationStatus == 0 else {
            print("eject of \(disk) failed; stopping (nothing touched)")
            return
        }
    }

    // The relaunch submits the activation request for whatever version
    // sits in /Applications/DroboService.app. MEASURED: the host stays
    // resident as the extension delegate, and `open` merely focuses the
    // running instance — a fresh request needs a fresh process, so quit
    // it FIRST. No approval prompt for a same-team upgrade; the
    // first-ever approval is the exception.
    let quitHost = Process()
    quitHost.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    quitHost.arguments = ["-f", "DroboServiceHost"]
    quitHost.standardError = FileHandle.nullDevice
    try? quitHost.run()
    quitHost.waitUntilExit()
    Thread.sleep(forTimeInterval: 2)

    let host = Process()
    host.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    host.arguments = ["/Applications/DroboService.app"]
    try? host.run()

    // WAIT FOR THE ACTIVATION before cycling. MEASURED: activation takes
    // longer than the old 3 s sleep, and a cycle that lands before the
    // new version's personalities are registered hands the attach to the
    // kernel driver by default (the device re-matched with NONE of our
    // personalities). Poll until the target version reads
    // [activated enabled]; 60 s budget. A first-ever install stops here
    // for the System Settings approval instead.
    let appPlist = URL(fileURLWithPath:
        "/Applications/DroboService.app/Contents/Library/SystemExtensions/" +
        "cc.jorvik.drobodext.dext/Contents/Info.plist")
    var targetVersion = ""
    if let data = try? Data(contentsOf: appPlist),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
       let dict = plist as? [String: Any],
       let ver = dict["CFBundleVersion"] as? String {
        targetVersion = "0.1.0/\(ver)"
    }
    var activated = false
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 1)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        check.arguments = ["list"]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        if text.contains("awaiting user authorization") {
            print("activation is waiting for your approval in System Settings;")
            print("approve it, then run dext-restart again")
            remountDisk(disk)
            return
        }
        if !targetVersion.isEmpty,
           text.contains("(\(targetVersion))"),
           text.contains("[activated enabled]") {
            activated = true
            break
        }
    }
    guard activated else {
        print("the new version did not reach [activated enabled] in 60 s;")
        print("check: systemextensionsctl list")
        remountDisk(disk)
        return
    }
    print("activated (\(targetVersion))")

    let cycle = Process()
    cycle.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/uhubctl")
    cycle.arguments = ["-a", "cycle", "-p", port, "-l", hub, "-d", "3"]
    cycle.standardOutput = FileHandle.standardOutput
    cycle.standardError = FileHandle.standardOutput
    do {
        try cycle.run()
        cycle.waitUntilExit()
    } catch {
        print("could not run uhubctl: \(error)")
        exit(1)
    }
    if cycle.terminationStatus != 0 {
        print("the port cycle needs your password (sudo); run this command from your own Terminal")
        exit(1)
    }

    // The device re-enumerates; the dext re-attaches; the media returns.
    remountDisk(disk)
    print("done. Verify the version and the pack:")
    print("  systemextensionsctl list | grep drobo")
    print("  drobo status")
}

/// v20: the blink over the dext's OWN USB BOT pipes (selector 3 on the
/// probe's user client). Apple's SCSI stack never sees this CDB, so its
/// vendor-opcode refusal cannot touch the path. Ejects first, settles, then
/// sends the mined identify and reads the device's CSW verdict.
func commandBlink(args: inout [String: String]) throws {
    let confirm = args["confirm"] == "true"
    print("drobo blink — the mined identify (0xEA op 0x06, one zero byte) over the dext's OWN USB BOT pipes")
    print("Apple's SCSI stack never sees this CDB; the vendor-opcode refusal cannot touch it.")
    guard confirm else {
        print("dry run: add --confirm to send (ejects the pack first)")
        return
    }
    guard let disk = args["disk"] else {
        print("blink needs --disk <the pack's disk, e.g. disk8>")
        return
    }
    if FileManager.default.fileExists(atPath: "/dev/\(disk)") {
        let eject = Process()
        eject.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        eject.arguments = ["eject", disk]
        eject.standardOutput = FileHandle.standardOutput
        try? eject.run()
        eject.waitUntilExit()
        guard eject.terminationStatus == 0 else {
            print("eject of \(disk) failed; stopping (nothing sent)")
            return
        }
        print("Disk \(disk) ejected")
    } else {
        print("\(disk) is already gone; nothing to eject")
    }
    // Let the kernel's attach probes settle before raw traffic touches the wire.
    Thread.sleep(forTimeInterval: 3)

    let connect = try DroboDextSupport.openUSBProbeConnection()
    defer { IOServiceClose(connect) }
    var seq: UInt32 = 1
    var out = [UInt32](repeating: 0, count: 3)
    var outCount = MemoryLayout<UInt32>.stride * 3
    let kr = out.withUnsafeMutableBytes { outPtr in
        IOConnectCallStructMethod(connect, 3, &seq, MemoryLayout<UInt32>.stride,
                                  outPtr.baseAddress, &outCount)
    }
    guard kr == KERN_SUCCESS else {
        print("blink call failed: 0x\(String(kr, radix: 16))")
        remountDisk(disk)
        return
    }
    let pipeKr = out[0], csw = out[1], residue = out[2]
    print("pipe kr 0x\(String(pipeKr, radix: 16)), CSW status \(csw), residue \(residue)")
    if pipeKr != 0 {
        print("the pipe IO failed before the device answered (kr 0x\(String(pipeKr, radix: 16)))")
    } else if csw == 0 {
        print("DEVICE SAID GOOD — watch the drive lights!")
    } else if csw == 0xFFFFFFFF {
        print("no valid CSW came back")
    } else {
        print("device CSW status \(csw) (1 = command failed, 2 = phase error)")
    }
    remountDisk(disk)
}

let argv = Array(CommandLine.arguments.dropFirst())
var (command, options) = parseArgs(argv)

/// The first write to the pack: the original's identify (blink the lights).
/// Vendor 0xEA op 0x06, a 1-byte zero write, measured from
/// ESASCSISession::identifyESA → sendSystemOperation in DDService64d.
/// Dry run by default; --confirm actually sends. Needs the exclusive
/// session (dext suspend/resume); the device must be EJECTED, not just
/// unmounted (measured: unmounted media still yields kIOReturnBusy).
/// --suspend-test exercises the suspend/resume dance WITHOUT the vendor
/// write, to isolate a kIOReturnBusy diagnosis from the write itself.
func commandIdentify(args: inout [String: String]) throws {
    let confirm = args["confirm"] == "true"
    let suspendTest = args["suspend-test"] == "true"
    let transportKind = args["transport"] ?? "dext"
    if suspendTest {
        print("drobo identify --suspend-test: suspend/resume only, NO vendor command sent")
    } else {
        print("drobo identify — vendor 0xEA system op 0x06 (identify: blink the drive lights)")
        print("write plan: eject device -> suspend (exclusive session) ->")
        print("  CDB ea 10 00 06 NN 00 21 00 01 00 + one zero byte (the mined original")
        print("  shape; a 4-byte duration variant phase-errors: DeliveryFailure) ->")
        print("  hold 32 s -> resume (media + volume return)")
        print("sequence byte NN increments per command, as the original daemon does.")
    }

    let transport = try openTransport(args: args)
    defer { transport.close() }
    guard transportKind == "dext" else {
        print("only the dext transport has the exclusive session today; re-run with --transport dext")
        return
    }
    let session = ESASession(transport: transport)

    if !suspendTest {
        // Pre-read so the confirm decision rests on live data, not hope.
        guard let packState = try? session.getStatusInfo(), let slots = try? session.getSlotInfo() else {
            print("could not read the pack over \(transportKind) transport; nothing sent")
            return
        }
        print("pack: diskpack \(packState.diskpackStatus.map(String.init) ?? "-"), \(slots.count) slots" +
              (slots.allSatisfy({ $0.state == 0x03 }) ? ", all ready" : ", SOMETHING NOT READY — stop and ask first"))
        let verdict = PackHealth.evaluate(status: packState, slots: slots)
        if !verdict.isHealthy {
            print("pack reports: \(verdict.reason ?? "?")")
            print("refusing to blink a pack that already has a problem; resolve that first")
            return
        }
    }

    guard confirm || suspendTest else {
        print("DRY RUN: nothing sent. Re-run with --confirm to send the blink.")
        return
    }

    // MEASURED 2026-11-17: unmount is NOT enough — with the pack's
    // CoreStorage volume active the framework still reports kIOReturnBusy
    // even with no other client polling. The device must be EJECTED (the
    // media tree released); UserResumeServices brings it back and the
    // system re-creates the media within seconds (verified: disk8
    // reappeared, Jupiter remounts, reads work).
    var ejected = false
    var ejectedDisk: String?
    if let disk = args["disk"] {
        let eject = Process()
        eject.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        eject.arguments = ["eject", disk]
        eject.standardOutput = FileHandle.standardOutput
        try? eject.run()
        eject.waitUntilExit()
        guard eject.terminationStatus == 0 else {
            print("eject of \(disk) failed; stopping before any write")
            return
        }
        ejectedDisk = disk
        ejected = true
    } else {
        print("NOTE: no --disk given; the device must be EJECTED (not just")
        print("unmounted) for the suspend to succeed. Pass --disk disk8.")
    }

    guard let control = transport as? SCSISessionControl else {
        print("this transport has no exclusive-session control; stopping")
        return
    }

    // The framework pauses ALL sources' messages to the drive; something
    // still holding the device (mounted volume, an in-flight CDB from a
    // poller) surfaces as kIOReturnBusy. A busy system gets a few tries
    // before we give up and restore the volume.
    var suspended = false
    for attempt in 1...4 {
        do {
            try control.suspendServices()
            suspended = true
            break
        } catch {
            print("suspend attempt \(attempt) failed: \(error)")
            if attempt < 4 { Thread.sleep(forTimeInterval: 2) }
        }
    }
    guard suspended else {
        print("suspend never succeeded: something still held the device.")
        print("Quit DroboDashboard (it polls the same dext) and retry; the")
        print("volume was NOT restored to a mount — run: diskutil mountDisk \(args["disk"] ?? "diskN")")
        return
    }
    print("suspended (exclusive session held)")

    if suspendTest {
        Thread.sleep(forTimeInterval: 2)
        do { try control.resumeServices() } catch { print("resume FAILED: \(error)") }
        print("resumed.")
        if ejected { remountDisk(ejectedDisk!) }
        return
    }

    // PROBE BATTERY (reads only, zero risk): each verdict localizes where
    // the write failure lives. ANY device response (GOOD or CHECK
    // CONDITION with sense) = the framework DELIVERED the task into the
    // held session; status 5 with empty sense = the transport refused it.
    // 1: the same standard MODE SENSE read that works outside the session.
    // 2: the original's vendor 0xEA telemetry READ (DataIn).
    do {
        _ = try session.getStatusInfo()
        if let diag = transport as? SCSITransportDiagnostics {
            print("probe 1: standard MODE SENSE inside session: status \(diag.lastSCSIStatus.map(String.init) ?? "n/a")")
        }
    } catch {
        print("probe 1: standard MODE SENSE inside session: THREW \(error)")
    }
    do {
        let (status, realized) = try session.sendSystemOperation(op: 0x0A, read: true, transferLength: 0x28)
        print("probe 2: vendor 0xEA read inside session: status \(status.map(String.init) ?? "n/a"), realized \(realized.map(String.init) ?? "n/a")")
    } catch {
        print("probe 2: vendor 0xEA read inside session: THREW \(error)")
    }

    print("sending identify (blink)...")
    do {
        try session.identify()
        if let diag = transport as? SCSITransportDiagnostics, let status = diag.lastSCSIStatus {
            let sense = diag.lastSense ?? Data()
            let senseBytes = [UInt8](sense)
            let key = senseBytes.count > 2 ? Int(senseBytes[2] & 0x0F) : -1
            let asc = senseBytes.count > 12 ? Int(senseBytes[12]) : -1
            let ascq = senseBytes.count > 13 ? Int(senseBytes[13]) : -1
            print("device said SCSI status \(status)" +
                  (status == 0 ? " (GOOD)" : " (NOT good: sense key \(key), ASC 0x\(String(asc, radix: 16)), ASCQ 0x\(String(ascq, radix: 16)))"))
        }
        print("sent. blinking (session held)...")
        Thread.sleep(forTimeInterval: 32)
    } catch {
        print("identify FAILED: \(error) — resuming to restore the pack")
        try? control.resumeServices()
        if ejected { remountDisk(ejectedDisk!) }
        return
    }
    print("resuming services...")
    try control.resumeServices()
    if ejected { remountDisk(ejectedDisk!) }
    print("done. Verify the pack afterwards: drobo status")
    printUnlockHint()
}

do {
    switch command {
    case "list":
        commandList()
    case "probe":
        try probe(args: &options)
    case "status":
        try status(args: &options)
    case "identify":
        try commandIdentify(args: &options)
    case "blink":
        try commandBlink(args: &options)
    case "dext-restart":
        try commandDextRestart(args: &options)
    case "heal":
        commandHeal()
    case "matchdebug":
        // Diagnostic: enumerate candidate classes and dump the properties
        // that a matching dictionary would see.
        for className in ["IOUserSCSIPeripheralDeviceType00", "IOUserService"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = IO_OBJECT_NULL
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            var count = 0
            var shown = 0
            var candidate = IOIteratorNext(iterator)
            while candidate != IO_OBJECT_NULL {
                count += 1
                if shown < 6 {
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(candidate, &entryID)
                    var userClass = "none"; var bundleID = "none"; var serverName = "none"
                    if let value = IORegistryEntrySearchCFProperty(candidate, kIOServicePlane, "IOUserClass" as CFString, nil, 0) {
                        userClass = (value as? String) ?? "nonstring"
                    }
                    if let value = IORegistryEntrySearchCFProperty(candidate, kIOServicePlane, "CFBundleIdentifier" as CFString, nil, 0) {
                        bundleID = (value as? String) ?? "nonstring"
                    }
                    if let value = IORegistryEntrySearchCFProperty(candidate, kIOServicePlane, "IOUserServerName" as CFString, nil, 0) {
                        serverName = (value as? String) ?? "nonstring"
                    }
                    FileHandle.standardError.write(Data("drobo: \(className) entryID \(entryID) IOUserClass=\(userClass) bundle=\(bundleID) server=\(serverName)\n".utf8))
                    shown += 1
                }
                IOObjectRelease(candidate)
                candidate = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
            FileHandle.standardError.write(Data("drobo: \(className) total \(count) candidates\n".utf8))
        }
    default:
        print("""
    usage: drobo <command> [options]

    commands:
      list                      registry-only enumeration (no device access)
      probe  --disk disk15      read-only sweep of every ESA page
      status --disk disk15      parsed health, capacity, firmware, bays
      heal                      kill wedged dext servers after an upgrade

    options:
      --disk <bsd name>         device, e.g. disk15
      --eject                   eject the device first so exclusive access works
      --transport dext|userspace|kext   default dext

    The dext transport is the only one that works on macOS 27. The userspace
    transport needs the whole device ejected, not just the volume unmounted,
    and only works on older stacks that publish the SCSI task user client.
    After a dext or kext session, no CoreStorage unlock is needed; after a
    userspace session, unlock the CoreStorage volume again.
    """)
    }
} catch {
    FileHandle.standardError.write(Data("drobo: \(error)\n".utf8))
    exit(1)
}
