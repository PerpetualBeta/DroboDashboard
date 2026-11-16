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
/// (cdbLength, direction, dataLength) + the 16-byte CDB; output struct =
/// the read data. v0.1 issues reads only.
public final class DextTransport: SCSITransport {
    private var connect: io_connect_t = IO_OBJECT_NULL

    public init() throws {
        // Open once and keep: a second open of the same node races the user
        // client lifecycle and dies with MACH_SEND_INVALID_DEST.
        connect = try DroboDextSupport.openDextConnection()
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

        var input = Data()
        let fields: [UInt32] = [UInt32(cdb.count), dir, UInt32(data.count)]
        fields.withUnsafeBytes { input.append(contentsOf: $0) }
        input.append(contentsOf: cdbBytes)

        var transferred = 0
        let kr = input.withUnsafeBytes { inputBytes -> kern_return_t in
            data.withUnsafeMutableBytes { dataBytes -> kern_return_t in
                var outputSize = dataBytes.count
                let result = IOConnectCallStructMethod(
                    connect, 0,
                    inputBytes.baseAddress, inputBytes.count,
                    dataBytes.baseAddress, &outputSize)
                if result == KERN_SUCCESS {
                    // The dext appends what it read; the kernel reports how
                    // much landed in the buffer.
                    transferred = outputSize
                }
                return result
            }
        }
        guard kr == KERN_SUCCESS else {
            throw DroboError.transport("SendCDB: 0x\(String(kr, radix: 16))")
        }
        data.count = transferred
        return transferred
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
enum DroboDextSupport {
    static func openDextConnection() throws -> io_connect_t {
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
