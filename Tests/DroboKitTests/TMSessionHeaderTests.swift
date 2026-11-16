import XCTest
@testable import DroboKit

final class TMSessionHeaderTests: XCTestCase {
    func testEncodeMatchesWireFormat() {
        let header = TMSessionHeader(primaryOpcode: TMOpcode.tmCmd, dataLength: 5)
        let bytes = header.encoded()
        XCTAssertEqual([UInt8](bytes),
                       [0x44, 0x52, 0x49, 0x44, 0x44, 0x53, 0x56, 0x43,  // DRIDDSVC
                        0x03, 0x00, 0x00, 0x00,                          // opcode pair
                        0x00, 0x00, 0x00, 0x05])                         // BE length
    }

    func testClientProxyPair() {
        let header = TMSessionHeader(primaryOpcode: TMOpcode.clientProxy.primary,
                                     secondaryOpcode: TMOpcode.clientProxy.secondary)
        let bytes = [UInt8](header.encoded())
        XCTAssertEqual(bytes[8], 0x01)
        XCTAssertEqual(bytes[9], 0x08)
    }

    func testDecodeRoundTrip() throws {
        let header = TMSessionHeader(primaryOpcode: 0x02, secondaryOpcode: 0x09, dataLength: 0x1234)
        let decoded = try TMSessionHeader.decode(header.encoded())
        XCTAssertEqual(decoded, header)
    }

    func testDecodeRejectsBadMagic() {
        var data = Data(repeating: 0, count: 16)
        data.replaceSubrange(0..<8, with: Data("XXXXXXXX".utf8))
        XCTAssertThrowsError(try TMSessionHeader.decode(data))
    }

    func testDecodeRejectsWrongSize() {
        XCTAssertThrowsError(try TMSessionHeader.decode(Data(repeating: 0, count: 15)))
    }
}
