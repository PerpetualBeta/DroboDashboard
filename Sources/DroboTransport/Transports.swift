// Swift wrappers around the two C transports. Both conform to the DroboKit
// SCSITransport protocol so the ESASession needs no knowledge of which pipe
// it is running over.

import Foundation
import DroboKit
import DDServiceC

public enum DDTransportKind: String {
    case userspace
    case kext
    case dext
}

/// User-space pass-through over SCSITaskDeviceInterface. Needs exclusive
/// access, so the whole device must be ejected first. After that eject the
/// BSD name no longer exists, so `bsdName` is optional: nil opens the first
/// Drobo peripheral nub by vendor match, as does a failed BSD-name open.
public final class UserSpaceTransport: SCSITransport {
    private var session: OpaquePointer?

    public init(bsdName: String?) throws {
        var raw: OpaquePointer?
        if let bsdName, !bsdName.isEmpty, ddus_open_bsd_name(bsdName, &raw) == 0 {
            session = raw
            return
        }
        guard ddus_open_first_drobo_nub(&raw) == 0, let viaNub = raw else {
            throw DroboError.transport(String(cString: dd_last_error()))
        }
        session = viaNub
    }

    public func send(cdb: Data, data: inout Data, direction: SCSITransferDirection) throws -> Int {
        guard let current = session else {
            throw DroboError.transport("transport is closed")
        }
        let dir: Int32
        switch direction {
        case .read: dir = DD_DIR_IN
        case .write: dir = DD_DIR_OUT
        case .none: dir = DD_DIR_NONE
        }
        var transferred: UInt32 = 0
        var sense = [UInt8](repeating: 0, count: 18)
        var senseLen: UInt32 = 0
        let bufferLength = data.count
        let cdbBytes = [UInt8](cdb)
        let rc = cdbBytes.withUnsafeBufferPointer { cdbPointer -> Int32 in
            data.withUnsafeMutableBytes { buffer -> Int32 in
                ddus_send(current,
                          cdbPointer.baseAddress,
                          Int32(cdbBytes.count),
                          buffer.bindMemory(to: UInt8.self).baseAddress,
                          UInt32(bufferLength),
                          dir,
                          &transferred,
                          &sense, &senseLen)
            }
        }
        guard rc == 0 else {
            throw DroboError.transport(String(cString: dd_last_error()))
        }
        return Int(transferred)
    }

    public func close() {
        if let current = session { ddus_close(current) }
        session = nil
    }
}

/// TrustedData kext user client pass-through. Secondary transport; needs the
/// kext loaded and the reduced-security policy change.
public final class KextTransport: SCSITransport {
    private var session: OpaquePointer?

    public init() throws {
        var raw: OpaquePointer?
        var bsdName = [CChar](repeating: 0, count: 64)
        guard ddk_open(&raw, &bsdName, 64) == 0, let opened = raw else {
            throw DroboError.transport(String(cString: dd_last_error()))
        }
        session = opened
    }
    public func send(cdb: Data, data: inout Data, direction: SCSITransferDirection) throws -> Int {
        guard let current = session else {
            throw DroboError.transport("transport is closed")
        }
        let dir: Int32
        switch direction {
        case .read: dir = DD_DIR_IN
        case .write: dir = DD_DIR_OUT
        case .none: dir = DD_DIR_NONE
        }
        var transferred: UInt32 = 0
        let bufferLength = data.count
        let cdbBytes = [UInt8](cdb)
        let rc = cdbBytes.withUnsafeBufferPointer { cdbPointer -> Int32 in
            data.withUnsafeMutableBytes { buffer -> Int32 in
                ddk_send(current,
                         cdbPointer.baseAddress,
                         Int32(cdbBytes.count),
                         buffer.bindMemory(to: UInt8.self).baseAddress,
                         UInt32(bufferLength),
                         dir,
                         &transferred)
            }
        }
        guard rc == 0 else {
            throw DroboError.transport(String(cString: dd_last_error()))
        }
        return Int(transferred)
    }

    public func close() {
        if let current = session { ddk_close(current) }
        session = nil
    }
}

/// DriverKit transport: talks to the DroboDext user client. This is the
/// route that works on macOS 27, where both user-space pass-through paths
/// are measured dead. Needs the dext installed and user-approved once.
///
/// Protocol with the dext: IOServiceOpen type 0, then
/// IOConnectCallStructMethod selector 0. Input struct = three u32s
/// (cdbLength, direction, dataLength) + the 16-byte CDB (+ inline payload
/// on a write); output struct = the read data + the result trailer.
public final class DextTransport: SCSITransport, SCSISessionControl, SCSITransportDiagnostics {
    private var connect: io_connect_t = IO_OBJECT_NULL
    public private(set) var lastSCSIStatus: UInt8?
    public private(set) var lastSense: Data?
    public private(set) var lastRealized: Int?

    public init() throws {
        // Open once and keep: a second open of the same node races the user
        // client lifecycle and dies with MACH_SEND_INVALID_DEST.
        connect = try DroboDextSupport.openDextConnection()
    }

    /// UserSuspendServices: the dext's built-in exclusive-access session
    /// for the vendor 0xEA opcodes. The volume must be unmounted first.
    public func suspendServices() throws {
        let kr = IOConnectCallScalarMethod(connect, 1, nil, 0, nil, nil)
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("SuspendServices: 0x\(String(kr, radix: 16))")
        }
    }

    /// UserResumeServices: releases the exclusive session and lets the
    /// storage stack mount again.
    public func resumeServices() throws {
        let kr = IOConnectCallScalarMethod(connect, 2, nil, 0, nil, nil)
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("ResumeServices: 0x\(String(kr, radix: 16))")
        }
    }

    public func send(cdb: Data, data: inout Data, direction: SCSITransferDirection) throws -> Int {
        let dir: UInt32
        switch direction {
        case .read: dir = 2      // target to initiator
        case .write: dir = 1     // initiator to target
        case .none: dir = 0
        }
        var cdbBytes = [UInt8](cdb)
        precondition(cdbBytes.count <= 16, "CDB longer than 16 bytes")
        cdbBytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - cdbBytes.count))

        // Input struct = three u32s + 16-byte CDB (+ inline payload on a
        // write). IOConnectCallStructMethod caps the input at 4 KiB; the
        // vendor ops here are small writes, and MODE SELECT pages will
        // stay far below.
        let headerSize = 3 * MemoryLayout<UInt32>.size
        var input = Data()
        let fields: [UInt32] = [UInt32(cdb.count), dir, UInt32(data.count)]
        fields.withUnsafeBytes { input.append(contentsOf: $0) }
        input.append(contentsOf: cdbBytes)
        if direction == .write {
            precondition(data.count <= 4096 - headerSize - 16, "write payload too large for struct method")
            input.append(contentsOf: data)
        }

        // The dext v12 always appends a result trailer (magic, status,
        // realized, sense), so the output buffer carries the data AND the
        // trailer. One fresh buffer for every direction keeps the sizes
        // honest.
        let trailerLength = 4 + 4 + 4 + 1 + 22
        var output = Data(count: data.count + trailerLength)
        var transferred = 0
        let kr = input.withUnsafeBytes { inputBytes -> kern_return_t in
            output.withUnsafeMutableBytes { outputBytes -> kern_return_t in
                var outputSize = outputBytes.count
                let result = IOConnectCallStructMethod(
                    connect, 0,
                    inputBytes.baseAddress, inputBytes.count,
                    outputBytes.baseAddress, &outputSize)
                if result == KERN_SUCCESS {
                    transferred = outputSize
                }
                return result
            }
        }
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("SendCDB: 0x\(String(kr, radix: 16))")
        }

        // The trailer is identified by its magic ('DD12' at the tail
        // boundary), never by size arithmetic: a pre-v12 dext's whole
        // output is data, whatever its size.
        if ProcessInfo.processInfo.environment["DROBO_DUMP"] != nil {
            print("send: dir \(dir) cdb \(cdb.map { String(format: "%02x", $0) }.joined())")
            print("send: transferred \(transferred) output[\(output.count)]: \(output.prefix(transferred).map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        let trailerStart = transferred - trailerLength
        let hasTrailer = transferred >= trailerLength && Self.trailerMagic(
            at: trailerStart, in: output)
        guard hasTrailer else {
            // Pre-v12 dext: no trailer, the whole output is data.
            data = output
            return transferred
        }
        output = output.subdata(in: 0..<transferred)

        // Parse the trailer: u32 magic, u32 status, u32 realized, u8
        // senseLen, sense.
        let trailer = [UInt8](output.suffix(trailerLength))
        lastSCSIStatus = trailer[4]
        lastRealized = Int(trailer[8]) | (Int(trailer[9]) << 8)
            | (Int(trailer[10]) << 16) | (Int(trailer[11]) << 24)
        let senseLength = min(Int(trailer[12]), 22)
        lastSense = Data(trailer[13..<(13 + senseLength)])

        let dataCount = transferred - trailerLength
        if direction == .read {
            data = dataCount > 0 ? Data(output.prefix(dataCount)) : Data()
        }
        return direction == .read ? dataCount : (lastRealized ?? 0)
    }

    /// True when the u32 at `offset` is the 'DD12' trailer magic. The dext
    /// memcpy's the u32, so the bytes are little-endian on the wire.
    private static func trailerMagic(at offset: Int, in data: Data) -> Bool {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return bytes == [0x32, 0x31, 0x44, 0x44]
    }

    public func close() {
        if connect != IO_OBJECT_NULL { IOServiceClose(connect) }
        connect = IO_OBJECT_NULL
    }
}

/// Finds the dext's IOUserService in the registry. The dext's personality
/// carries cc_jorvik_drobodext_match so we never open another product's
/// Opens the dext's device service: the DroboDextDriver node on the LUN
/// (kernel class IOUserSCSIPeripheralDeviceType00, published by the dext's
/// RegisterService). Returns the live connection, opened once and kept: a
/// second open of the same node races the user client lifecycle and dies
/// with MACH_SEND_INVALID_DEST. Stale services from earlier dext versions
/// may also match, so candidates are tried until one opens.
public enum DroboDextSupport {
    public static func openDextConnection() throws -> io_connect_t {
        // The open target is the dext's DEVICE SERVICE in the registry: the
        // DroboDextDriver node on the LUN (kernel class
        // IOUserSCSIPeripheralDeviceType00). "IOUserService" nubs are the
        // per-server plumbing, not the client entry point.
        guard let matching = IOServiceMatching("IOUserSCSIPeripheralDeviceType00") else {
            throw DroboError.transport("IOServiceMatching(IOUserSCSIPeripheralDeviceType00) returned NULL")
        }
        let dict = matching as NSMutableDictionary
        // Unknown keys in a matching dictionary are IGNORED; property matching
        // must go through IOPropertyMatch. Our node carries IOUserClass =
        // DroboDextDriver; Apple's own Type00 instances do not.
        dict["IOPropertyMatch"] = ["IOUserClass": "DroboDextDriver"]
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("IOServiceGetMatchingServices: 0x\(String(kr, radix: 16))")
        }
        defer { IOObjectRelease(iterator) }
        var opensFailed = 0
        var lastOpenError: kern_return_t = KERN_SUCCESS
        var candidate = IOIteratorNext(iterator)
        while candidate != IO_OBJECT_NULL {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(candidate, &entryID)
            var connectOut: io_connect_t = IO_OBJECT_NULL
            let openKr = IOServiceOpen(candidate, mach_task_self_, 0, &connectOut)
            IOObjectRelease(candidate)
            if openKr == KERN_SUCCESS, connectOut != IO_OBJECT_NULL {
                return connectOut
            }
            opensFailed += 1
            lastOpenError = openKr
            FileHandle.standardError.write(Data("drobo: server entryID \(entryID) failed 0x\(String(openKr, radix: 16))\n".utf8))
            candidate = IOIteratorNext(iterator)
        }
        if opensFailed > 0 {
            throw DroboError.transport("all \(opensFailed) DroboDext servers refused IOServiceOpen; last 0x\(String(lastOpenError, radix: 16))")
        }
        throw DroboError.transport("DroboDext is not installed or not approved yet")
    }

    /// v20: open the user client on the USB PROBE node (the interface),
    /// not the LUN. The probe's raw-BOT blink rides selector 3 here; the
    /// SCSI survey path may not own the LUN while the probe co-claims the
    /// interface, so the probe node is its own reliable entry point.
    public static func openUSBProbeConnection() throws -> io_connect_t {
        // The probe device node (class IOUserService, named DroboUSBProbe)
        // is NOT in the IOUserService matching set — those are per-server
        // plumbing nubs. Reach it through the registry tree: find the Drobo
        // USB device by vendor/product, then walk down to the probe node.
        guard let devMatching = IOServiceMatching("IOUSBHostDevice") else {
            throw DroboError.transport("IOServiceMatching(IOUSBHostDevice) returned NULL")
        }
        var devIter: io_iterator_t = IO_OBJECT_NULL
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, devMatching, &devIter)
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("IOServiceGetMatchingServices(device): 0x\(String(kr, radix: 16))")
        }
        var device: io_registry_entry_t = IO_OBJECT_NULL
        var dev = IOIteratorNext(devIter)
        while dev != IO_OBJECT_NULL {
            let vid = IORegistryEntryCreateCFProperty(dev, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            let pid = IORegistryEntryCreateCFProperty(dev, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            if vid == 6585 && pid == 13619 {
                device = dev
                break
            }
            IOObjectRelease(dev)
            dev = IOIteratorNext(devIter)
        }
        IOObjectRelease(devIter)
        guard device != IO_OBJECT_NULL else {
            throw DroboError.transport("the Drobo USB device is not on the bus")
        }
        let probe = findChild(named: "DroboUSBProbe", under: device, depth: 0)
        IOObjectRelease(device)
        guard probe != IO_OBJECT_NULL else {
            throw DroboError.transport("the USB probe is not matched yet — run dext-restart so the personality attaches")
        }
        var connectOut: io_connect_t = IO_OBJECT_NULL
        let openKr = IOServiceOpen(probe, mach_task_self_, 0, &connectOut)
        IOObjectRelease(probe)
        guard openKr == KERN_SUCCESS, connectOut != IO_OBJECT_NULL else {
            throw DroboError.transport("probe IOServiceOpen refused: 0x\(String(openKr, radix: 16))")
        }
        return connectOut
    }

    /// Depth-first search of the IOService plane for a node with the given
    /// registry entry name. Returns a RETAINED entry (caller releases) or 0.
    private static func findChild(named target: String, under entry: io_registry_entry_t, depth: Int) -> io_registry_entry_t {
        if depth > 5 { return IO_OBJECT_NULL }
        var nameBuffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuffer)
        if String(cString: nameBuffer) == target {
            IOObjectRetain(entry)
            return entry
        }
        var childIter: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        var child = IOIteratorNext(childIter)
        while child != IO_OBJECT_NULL {
            let found = findChild(named: target, under: child, depth: depth + 1)
            if found != IO_OBJECT_NULL {
                IOObjectRelease(child)
                IOObjectRelease(childIter)
                return found
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIter)
        }
        IOObjectRelease(childIter)
        return IO_OBJECT_NULL
    }
}

/// Opens the configured transport kind. For `.userspace` a nil/empty
/// `bsdName` opens the first Drobo nub, which is the post-eject path.
public func makeTransport(kind: DDTransportKind, bsdName: String?) throws -> SCSITransport {
    switch kind {
    case .userspace:
        return try UserSpaceTransport(bsdName: bsdName)
    case .kext:
        return try KextTransport()
    case .dext:
        return try DextTransport()
    }
}
