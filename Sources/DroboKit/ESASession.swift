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

    /// Closes the underlying transport.
    public func close() {
        transport.close()
    }
}
