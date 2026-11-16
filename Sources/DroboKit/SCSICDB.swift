// Vendor CDB builders, decoded from DDService64d (ESASystemOperationRequest.cpp,
// ModeSenseSCSIRequest.cpp, ModeSelectSCSIRequest.cpp).
//
// All builders produce 10-byte CDBs; byte 9 carries the device protocol byte
// shifted left 6 (a knob: 0 until live data names the value).

import Foundation

public enum SCSICDB {
    /// MODE SENSE(10). The 5D3 keeps its management data in vendor page 0x3A;
    /// the device echoes page tag 0x7A in the reply.
    public static func modeSense10(
        page: UInt8 = 0x3A,
        subpage: UInt8,
        allocationLength: Int,
        protocolByte: UInt8 = 0
    ) -> Data {
        var cdb = Data(repeating: 0, count: 10)
        cdb[0] = 0x5A
        cdb[1] = 0x08                 // DBD set, page control 0
        cdb[2] = page
        cdb[3] = subpage
        cdb[7] = UInt8((allocationLength >> 8) & 0xFF)
        cdb[8] = UInt8(allocationLength & 0xFF)
        cdb[9] = protocolByte << 6
        return cdb
    }

    /// MODE SELECT(10), the write side of the vendor pages.
    public static func modeSelect10(
        savePages: Bool = false,
        pageFormat: Bool = true,
        page: UInt8 = 0x3A,
        subpage: UInt8,
        parameterListLength: Int,
        protocolByte: UInt8 = 0
    ) -> Data {
        var cdb = Data(repeating: 0, count: 10)
        cdb[0] = 0x55
        cdb[1] = (savePages ? 0x10 : 0) | (pageFormat ? 0x08 : 0)
        cdb[2] = page
        cdb[3] = subpage
        cdb[7] = UInt8((parameterListLength >> 8) & 0xFF)
        cdb[8] = UInt8(parameterListLength & 0xFF)
        cdb[9] = protocolByte << 6
        return cdb
    }

    /// Vendor system operation. Read variants carry 0x80 in byte 2; the
    /// sequence byte increments per command on the original daemon.
    public static func systemOperation(
        op: UInt8,
        sequence: UInt8,
        read: Bool,
        transferLength: Int,
        protocolByte: UInt8 = 0
    ) -> Data {
        var cdb = Data(repeating: 0, count: 10)
        cdb[0] = 0xEA
        cdb[1] = 0x10
        cdb[2] = read ? 0x80 : 0x00
        cdb[3] = op
        cdb[4] = sequence
        cdb[6] = 0x21
        cdb[7] = UInt8((transferLength >> 8) & 0xFF)
        cdb[8] = UInt8(transferLength & 0xFF)
        cdb[9] = protocolByte << 6
        return cdb
    }
}
