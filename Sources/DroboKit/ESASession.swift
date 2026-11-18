// Transport abstraction and the ESA session that layers the vendor protocol
// over any pass-through pipe. Two transports exist behind this protocol:
// the user-space SCSITaskDeviceInterface route (C, DDServiceC) and the
// TrustedData kext user client route (C, DDServiceC).

import Foundation

public enum SCSITransferDirection {
    case none
    case read     // target → initiator
    case write    // initiator → target
}

public protocol SCSITransport: AnyObject {
    /// Sends one CDB. Returns the realized transfer count. `data` is the
    /// caller's buffer, filled on read and consumed on write.
    func send(cdb: Data, data: inout Data, direction: SCSITransferDirection) throws -> Int
    func close()
}

/// Optional exclusive-access session control. The dext transport
/// implements it with UserSuspendServices/UserResumeServices (the vendor
/// 0xEA opcodes need it); other transports just don't conform.
public protocol SCSISessionControl: AnyObject {
    func suspendServices() throws
    func resumeServices() throws
}

/// Optional per-command verdicts: what the DEVICE said about the last
/// command. The dext (v12+) transport reports the SCSI completion status
/// and sense bytes from its result trailer.
public protocol SCSITransportDiagnostics: AnyObject {
    var lastSCSIStatus: UInt8? { get }
    var lastSense: Data? { get }
    var lastRealized: Int? { get }
}

/// Runs the vendor protocol against one device through one transport.
/// `protocolByte` is the device session byte the original shifts left 6 into
/// CDB byte 9; it stays a knob set to 0 until live data names the value.
public final class ESASession {
    public var protocolByte: UInt8
    private let transport: SCSITransport
    private var sequence: UInt8 = 0

    public init(transport: SCSITransport, protocolByte: UInt8 = 0) {
        self.transport = transport
        self.protocolByte = protocolByte
    }

    /// MODE SENSE(10) page 0x3A. Returns the raw response buffer; the page
    /// data (page tag first) sits after the 8-byte mode parameter header,
    /// since the request disables block descriptors.
    public func modeSense(subpage: UInt8, allocationLength: Int) throws -> Data {
        var buffer = Data(repeating: 0, count: allocationLength)
        let cdb = SCSICDB.modeSense10(subpage: subpage, allocationLength: allocationLength,
                                      protocolByte: protocolByte)
        let realized = try transport.send(cdb: cdb, data: &buffer, direction: .read)
        guard realized >= 8 + 2 else {
            throw DroboError.badPage("mode sense returned only \(realized) bytes")
        }
        return buffer.prefix(realized)
    }

    /// The page data as the parsers expect it: page tag first. The Drobo's
    /// vendor MODE SENSE(10) response carries the raw ESA page with NO mode
    /// parameter header: byte 0 is the page tag 0x7a, byte 1 the subpage.
    public static func pageData(ofModeSenseResponse raw: Data) -> Data {
        return raw
    }

    public func getSystemInfo() throws -> ESASystemInfo {
        let raw = try modeSense(subpage: ESASystemInfo.subpage,
                                allocationLength: ESASystemInfo.pageSize + 0x10)
        return try ESASystemInfo.parse(Self.pageData(ofModeSenseResponse: raw))
    }

    public func getCapacityInfo() throws -> ESACapacityInfo {
        let raw = try modeSense(subpage: ESACapacityInfo.subpage,
                                allocationLength: ESACapacityInfo.minimumLength + 0x10)
        return try ESACapacityInfo.parse(Self.pageData(ofModeSenseResponse: raw))
    }

    public func getStatusInfo() throws -> ESAStatusInfo {
        // Allocate for the long form; short-form devices return less.
        let raw = try modeSense(subpage: ESAStatusInfo.subpage, allocationLength: 0x28)
        return try ESAStatusInfo.parse(Self.pageData(ofModeSenseResponse: raw))
    }

    public func getFirmwareInfo() throws -> ESAFirmwareInfo {
        let raw = try modeSense(subpage: ESAFirmwareInfo.subpage, allocationLength: 0x4A)
        return try ESAFirmwareInfo.parse(Self.pageData(ofModeSenseResponse: raw))
    }

    public func getSlotInfo() throws -> [ESASlotInfo] {
        // Allocation covers the measured page: 8-byte header + 6 x 0x48-byte
        // records (5 bays + the SSD cache slot on the 5D3) = 0x1b1.
        let raw = try modeSense(subpage: ESASlotInfo.subpage, allocationLength: 0x230)
        return try ESASlotInfo.parse(Self.pageData(ofModeSenseResponse: raw))
    }

    /// The next per-session sequence byte. The original daemon increments
    /// under a lock before every system operation; a single-threaded CLI
    /// only needs atomicity against itself.
    private func nextSequence() -> UInt8 {
        sequence &+= 1
        return sequence
    }

    /// One vendor system operation with the device's verdict, for the
    /// identify flow's probe battery: op 0x06 write is the blink;
    /// op 0x0A read is the original's telemetry read. ANY device response
    /// (GOOD or CHECK CONDITION with sense) proves the framework
    /// DELIVERED the task; status 5 (DeliveryFailure) with empty sense
    /// means the transport refused it before the bus.
    public func sendSystemOperation(op: UInt8, read: Bool,
                                    transferLength: Int) throws -> (status: UInt8?, realized: Int?) {
        var data = Data(repeating: 0, count: transferLength)
        let cdb = SCSICDB.systemOperation(op: op, sequence: nextSequence(), read: read,
                                          transferLength: transferLength, protocolByte: protocolByte)
        let realized = try transport.send(cdb: cdb, data: &data, direction: read ? .read : .write)
        if let diag = transport as? SCSITransportDiagnostics {
            return (diag.lastSCSIStatus, diag.lastRealized)
        }
        return (nil, realized)
    }

    /// The original's identifyESA: the blink. MEASURED from DDService64d
    /// (mining record, commit 101b02d): identifyESA =
    /// sendSystemOperation(6) = ctor(REQUEST_TYPE 1, op 6, seq = ++seq,
    /// read = false, transferLength 1, ONE ZERO BYTE, protocolByte 0).
    /// A 4-byte BE-duration shape was tried live on 2026-11-17 and the
    /// device never got it: DeliveryFailure (task status 5), realized 4,
    /// no sense — a BOT phase mismatch, because the firmware expects the
    /// 1-byte shape it was built for. The blink duration is the device's
    /// business; nobody tells it how long.
    ///
    /// The verdict that matters is the DEVICE's SCSI status from the dext
    /// trailer, not write bookkeeping: GOOD means the op reached it.
    @discardableResult
    public func identify() throws -> Int {
        var payload = Data([0x00])
        let cdb = SCSICDB.systemOperation(op: 0x06, sequence: nextSequence(),
                                          read: false, transferLength: payload.count,
                                          protocolByte: protocolByte)
        let realized = try transport.send(cdb: cdb, data: &payload, direction: .write)

        if let diag = transport as? SCSITransportDiagnostics, let status = diag.lastSCSIStatus {
            guard status == 0 else {
                let sense = [UInt8](diag.lastSense ?? Data())
                let key = sense.count > 2 ? Int(sense[2] & 0x0F) : -1
                let asc = sense.count > 12 ? Int(sense[12]) : -1
                let ascq = sense.count > 13 ? Int(sense[13]) : -1
                throw DroboError.transport(
                    "device rejected identify: SCSI status \(status), sense key \(key), " +
                    "ASC 0x\(String(asc, radix: 16)), ASCQ 0x\(String(ascq, radix: 16))")
            }
            return realized
        }
        // Pre-v12 transport with no device verdict: fall back to the
        // realized count.
        guard realized == payload.count else {
            throw DroboError.transport("identify wrote \(realized) bytes, expected \(payload.count)")
        }
        return realized
    }

    /// Closes the underlying transport.
    public func close() {
        transport.close()
    }
}
