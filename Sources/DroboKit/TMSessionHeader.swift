// TMSessionHeader: the 16-byte frame that opens every session between the
// Dashboard UI and DDService64d, decoded from DDService64d (TMSessionHeader.cpp).
//
// Wire layout, big-endian length field:
//   bytes 0-7   magic "DRIDDSVC"
//   byte  8     primary opcode
//   byte  9     secondary opcode (DDClientProxy uses the pair 0x01/0x08)
//   bytes 10-11 spare, zero
//   bytes 12-15 payload length, big-endian

import Foundation

public enum TMOpcode {
    /// UI ⇄ daemon command proxy (primary 0x01, secondary 0x08).
    public static let clientProxy: (primary: UInt8, secondary: UInt8) = (0x01, 0x08)
    /// TMCommand connection: structured command stream.
    public static let tmCommand: UInt8 = 0x02
    /// TMCmd connection: plain text command stream.
    public static let tmCmd: UInt8 = 0x03
}

public struct TMSessionHeader: Equatable {
    public static let magic = Data("DRIDDSVC".utf8)
    /// Largest payload we will read from a peer. The original read at most
    /// 0xFFF per recv into an accumulating buffer, so this cap is generous.
    public static let maxPayloadLength = 1 << 20

    public var primaryOpcode: UInt8
    public var secondaryOpcode: UInt8
    public var dataLength: UInt32

    public init(primaryOpcode: UInt8, secondaryOpcode: UInt8 = 0, dataLength: UInt32 = 0) {
        self.primaryOpcode = primaryOpcode
        self.secondaryOpcode = secondaryOpcode
        self.dataLength = dataLength
    }

    /// 16 wire bytes.
    public func encoded() -> Data {
        var out = Data(capacity: 16)
        out.append(Self.magic)
        out.append(primaryOpcode)
        out.append(secondaryOpcode)
        out.append(0)
        out.append(0)
        var be = dataLength.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        return out
    }

    /// Decodes and validates a 16-byte header.
    public static func decode(_ data: Data) throws -> TMSessionHeader {
        guard data.count == 16 else {
            throw DroboError.badFrame("header must be 16 bytes, got \(data.count)")
        }
        guard data.prefix(8) == magic else {
            throw DroboError.badFrame("bad session magic")
        }
        var be: UInt32 = 0
        withUnsafeMutableBytes(of: &be) { dst in
            data.subdata(in: 12..<16).copyBytes(to: dst)
        }
        return TMSessionHeader(
            primaryOpcode: data[8],
            secondaryOpcode: data[9],
            dataLength: UInt32(bigEndian: be)
        )
    }
}

public enum DroboError: Error, CustomStringConvertible {
    case badFrame(String)
    case badPage(String)
    case transport(String)
    case deviceNotFound(String)

    public var description: String {
        switch self {
        case .badFrame(let m): return "bad frame: \(m)"
        case .badPage(let m): return "bad ESA page: \(m)"
        case .transport(let m): return "transport: \(m)"
        case .deviceNotFound(let m): return "device not found: \(m)"
        }
    }
}
