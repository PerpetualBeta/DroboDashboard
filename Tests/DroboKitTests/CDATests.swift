import XCTest
@testable import DroboKit

final class CDATests: XCTestCase {
    func testModeSense10() {
        let cdb = [UInt8](SCSICDB.modeSense10(subpage: 0x33, allocationLength: 0x30))
        XCTAssertEqual(cdb, [0x5A, 0x08, 0x3A, 0x33, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00])
    }

    func testModeSense10LongAllocation() {
        let cdb = [UInt8](SCSICDB.modeSense10(subpage: 0x03, allocationLength: 0x104, protocolByte: 2))
        XCTAssertEqual(cdb, [0x5A, 0x08, 0x3A, 0x03, 0x00, 0x00, 0x00, 0x01, 0x04, 0x80])
    }

    func testModeSelect10() {
        let cdb = [UInt8](SCSICDB.modeSelect10(subpage: 0x09, parameterListLength: 0x40))
        XCTAssertEqual(cdb, [0x55, 0x08, 0x3A, 0x09, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00])
    }

    func testSystemOperationRead() {
        let cdb = [UInt8](SCSICDB.systemOperation(op: 0x0A, sequence: 5, read: true,
                                                  transferLength: 0x1234, protocolByte: 2))
        XCTAssertEqual(cdb, [0xEA, 0x10, 0x80, 0x0A, 0x05, 0x00, 0x21, 0x12, 0x34, 0x80])
    }

    func testSystemOperationWrite() {
        let cdb = [UInt8](SCSICDB.systemOperation(op: 0x0B, sequence: 0, read: false,
                                                  transferLength: 0x18))
        XCTAssertEqual(cdb, [0xEA, 0x10, 0x00, 0x0B, 0x00, 0x00, 0x21, 0x00, 0x18, 0x00])
    }

    /// The identify blink: op 0x06, write, one byte. Matches the measured
    /// original: identifyESA -> sendSystemOperation(6) -> ctor(type 1,
    /// read false, transferLength 1, protocolByte<<6).
    func testIdentifyCDB() {
        let cdb = [UInt8](SCSICDB.systemOperation(op: 0x06, sequence: 1, read: false,
                                                  transferLength: 1, protocolByte: 0))
        XCTAssertEqual(cdb, [0xEA, 0x10, 0x00, 0x06, 0x01, 0x00, 0x21, 0x00, 0x01, 0x00])
    }

    /// The session's identify() must send exactly the measured CDB with an
    /// incrementing sequence byte and a single zero payload byte.
    func testSessionIdentifySendsMeasuredCDB() throws {
        final class CaptureTransport: SCSITransport {
            var cdbBytes: [UInt8] = []
            var payload: [UInt8] = []
            var direction: SCSITransferDirection?
            func send(cdb: Data, data: inout Data, direction: SCSITransferDirection) throws -> Int {
                cdbBytes = [UInt8](cdb)
                payload = [UInt8](data)
                self.direction = direction
                return data.count
            }
            func close() {}
        }
        let transport = CaptureTransport()
        let session = ESASession(transport: transport)
        try session.identify()
        XCTAssertEqual(transport.cdbBytes, [0xEA, 0x10, 0x00, 0x06, 0x01, 0x00, 0x21, 0x00, 0x01, 0x00])
        XCTAssertEqual(transport.payload, [0x00])
        XCTAssertEqual(transport.direction, .write)
        try session.identify()
        XCTAssertEqual(transport.cdbBytes[4], 2, "sequence increments per command")
    }
}
