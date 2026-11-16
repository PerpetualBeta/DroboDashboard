// ESA mode page parsers, decoded from DDService64d (ESAProtocol/*.cpp).
//
// Every page rides MODE SENSE(10) page 0x3A and carries a page tag byte 0x7A
// ('z') followed by the per-type subpage byte. Field offsets below are offsets
// into the page data, which starts at the page tag.

import Foundation

public enum ESAPage {
    public static let tag: UInt8 = 0x7A

    /// Validates the page tag and subpage, then hands the payload to `body`.
    static func guardPage(_ data: Data, expectedSubpage: UInt8, minimumLength: Int, name: String) throws {
        guard data.count >= minimumLength else {
            throw DroboError.badPage("\(name) needs \(minimumLength) bytes, got \(data.count)")
        }
        guard data[0] == tag else {
            throw DroboError.badPage("\(name) wrong page tag 0x\(String(data[0], radix: 16)), expected 0x\(String(tag, radix: 16))")
        }
        guard data[1] == expectedSubpage else {
            throw DroboError.badPage("\(name) wrong subpage 0x\(String(data[1], radix: 16)), expected 0x\(String(expectedSubpage, radix: 16))")
        }
    }

    static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(data[offset + i]) }
        return value
    }

    /// ASCII, trimmed at the first NUL.
    static func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
        let slice = data.subdata(in: offset..<min(offset + length, data.count))
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - ESASystemInfo (subpage 0x33)

/// Three big-endian u32 fields at +8, +12, +16; page size 0x18. The original
/// keeps them unnamed in traces, so they stay numbered until live data names them.
public struct ESASystemInfo: Equatable {
    public let field1: UInt32
    public let field2: UInt32
    public let field3: UInt32

    public static let subpage: UInt8 = 0x33
    public static let pageSize = 0x18

    public static func parse(_ data: Data) throws -> ESASystemInfo {
        try ESAPage.guardPage(data, expectedSubpage: subpage, minimumLength: pageSize, name: "SystemInfo")
        return ESASystemInfo(
            field1: ESAPage.be32(data, 8),
            field2: ESAPage.be32(data, 12),
            field3: ESAPage.be32(data, 16)
        )
    }
}

// MARK: - ESACapacityInfo (subpage 0x02)

/// Four big-endian u64 fields at +4, +12, +20, +28. The original parser's
/// length check is 0x1C, which does not cover the field at +28; it survived on
/// the device always returning more. Our guard covers what we read: 0x24.
public struct ESACapacityInfo: Equatable {
    public let field1: UInt64
    public let field2: UInt64
    public let field3: UInt64
    public let field4: UInt64

    public static let subpage: UInt8 = 0x02
    /// 0x1C in the original parser; raised here to cover the field at +28.
    public static let minimumLength = 0x24

    public static func parse(_ data: Data) throws -> ESACapacityInfo {
        try ESAPage.guardPage(data, expectedSubpage: subpage, minimumLength: minimumLength, name: "CapacityInfo")
        return ESACapacityInfo(
            field1: ESAPage.be64(data, 4),
            field2: ESAPage.be64(data, 12),
            field3: ESAPage.be64(data, 20),
            field4: ESAPage.be64(data, 28)
        )
    }
}

// MARK: - ESAStatusInfo (subpage 0x09)

/// Health and data-protection state. Two wire shapes exist: the short form
/// ends after the diskpack status; the long form adds relayout and
/// double-degraded counters. Field names follow the original traces.
public struct ESAStatusInfo: Equatable {
    public let status: UInt32
    public let extendedStatus: UInt32
    public let diskpackStatus: UInt32?
    public let relayoutCount: UInt32?
    public let doubleDegraded: UInt32?

    public static let subpage: UInt8 = 0x09

    public static func parse(_ data: Data) throws -> ESAStatusInfo {
        try ESAPage.guardPage(data, expectedSubpage: subpage, minimumLength: 0x10, name: "StatusInfo")
        let diskpack: UInt32? = data.count > 0x0C ? ESAPage.be32(data, 0x0C) : nil
        let relayout: UInt32? = data.count > 0x10 ? ESAPage.be32(data, 0x10) : nil
        let doubleDegraded: UInt32? = data.count > 0x14 ? ESAPage.be32(data, 0x14) : nil
        return ESAStatusInfo(
            status: ESAPage.be32(data, 4),
            extendedStatus: ESAPage.be32(data, 8),
            diskpackStatus: diskpack,
            relayoutCount: relayout,
            doubleDegraded: doubleDegraded
        )
    }

    /// The flag bits the original daemon ORs into the status word, per
    /// ESASCSISession::getStatusInfo. diskpackStatus 1 means healthy.
    public static func statusFlag(forDiskpackStatus diskpackStatus: UInt32) -> UInt32 {
        switch diskpackStatus {
        case 2: return 0x1000
        case 3: return 0x10000000
        case 4: return 0x800
        case 5, 6, 7: return 0x20
        case 8: return 0x40000
        default: return 0
        }
    }
}

// MARK: - ESAFirmwareInfo (subpage 0x08)

/// Firmware identity. Version fields are raw; the two ASCII strings are the
/// package and build strings at +10 and +42. A trailing blob exists for
/// longer protocol versions and is skipped in v0.1.
public struct ESAFirmwareInfo: Equatable {
    public let versionChar1: UInt8
    public let versionChar2: UInt8
    public let versionWord: UInt16
    public let fieldChar1: UInt8
    public let fieldChar2: UInt8
    public let packageString: String
    public let buildString: String?

    public static let subpage: UInt8 = 0x08

    public static func parse(_ data: Data) throws -> ESAFirmwareInfo {
        try ESAPage.guardPage(data, expectedSubpage: subpage, minimumLength: 0x2A, name: "FirmwareInfo")
        let versionWord = UInt16(data[6]) << 8 | UInt16(data[7])
        let build: String? = data.count >= 0x3A ? ESAPage.ascii(data, 0x2A, 0x10) : nil
        return ESAFirmwareInfo(
            versionChar1: data[4],
            versionChar2: data[5],
            versionWord: versionWord,
            fieldChar1: data[8],
            fieldChar2: data[9],
            packageString: ESAPage.ascii(data, 0x0A, 0x20),
            buildString: build
        )
    }
}

// MARK: - ESASlotInfo (subpage 0x03)

/// Drive bay state. The page holds a count byte at +4 followed by count
/// fixed-size slot structs starting at +5.
/// Slot page (subpage 0x03), MEASURED on the live 5D3 2026-11-16.
///
/// Page: 6-byte header [tag 0x7a, subpage, BE16 length, count, reserved],
/// then `count` records of 0x48 bytes. On the 5D3 the count is 6: the five
/// drive bays plus the internal SSD cache slot. The length field (0x1b1)
/// counts from offset 5 to the page end.
///
/// Record layout (offsets relative to the record):
///   0x00  marker 0x46
///   0x01  slot index (0..5)
///   0x02  BE64 capacity in bytes (4000787030016 = exactly a 4TB drive)
///   0x0A  BE64 reserved (zeros on every slot observed)
///   0x12  state byte (0x03 = present and good)
///   0x13  model string, 32 bytes, space-padded
///   0x33  short model, 16 bytes, space-padded, right-aligned
///   0x43  5 bytes tail (R0 carries 0x01 in the first byte; unfitted)
public struct ESASlotInfo: Equatable {
    public let state: UInt8
    public let capacityBytes: UInt64
    public let reserved: UInt64
    public let model: String
    public let shortModel: String

    public static let subpage: UInt8 = 0x03
    public static let headerSize = 0x06
    public static let recordSize = 0x48

    public static func parse(_ data: Data) throws -> [ESASlotInfo] {
        try ESAPage.guardPage(data, expectedSubpage: subpage, minimumLength: headerSize, name: "SlotInfo")
        let count = Int(data[4])
        var slots: [ESASlotInfo] = []
        slots.reserveCapacity(count)
        var offset = headerSize
        for _ in 0..<count {
            guard offset + recordSize <= data.count else { break }
            let s = data.subdata(in: offset..<offset + recordSize)
            slots.append(ESASlotInfo(
                state: s[0x12],
                capacityBytes: ESAPage.be64(s, 0x02),
                reserved: ESAPage.be64(s, 0x0A),
                model: ESAPage.ascii(s, 0x13, 0x20).trimmingCharacters(in: .whitespaces),
                shortModel: ESAPage.ascii(s, 0x33, 0x10).trimmingCharacters(in: .whitespaces)
            ))
            offset += recordSize
        }
        return slots
    }
}
