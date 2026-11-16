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
    // Dext server processes are on-demand spawns; an upgrade waits for the
    // old one to exit and it never does on its own. Killing them is safe:
    // the live one respawns when the device re-matches.
    let pids = runCapture("/usr/bin/pgrep", ["DroboDext"])
        .split(separator: "\n")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    if pids.isEmpty {
        print("no DroboDext server processes to kill")
    } else {
        print("killing wedged DroboDext server\(pids.count == 1 ? "" : "s"): \(pids.map(String.init).joined(separator: " "))")
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        kill.arguments = ["kill"] + pids.map(String.init)
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

func parseArgs(_ argv: [String]) -> (command: String, options: [String: String]) {
    var options: [String: String] = [:]
    var positional: [String] = []
    var index = 0
    while index < argv.count {
        let arg = argv[index]
        if arg == "--eject" {
            options["eject"] = "true"
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

let argv = Array(CommandLine.arguments.dropFirst())
var (command, options) = parseArgs(argv)

do {
    switch command {
    case "list":
        commandList()
    case "probe":
        try probe(args: &options)
    case "status":
        try status(args: &options)
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
