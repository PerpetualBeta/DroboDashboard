import XCTest
@testable import DroboKit

final class ESAPageTests: XCTestCase {
    private func page(_ subpage: UInt8, _ payload: [UInt8]) -> Data {
        var data = Data([ESAPage.tag, subpage])
        data.append(contentsOf: payload)
        return data
    }

    func testSystemInfoParse() throws {
        // Field offsets are from the page tag; the 0x18 page runs four bytes
        // past the last field, matching what the device sends.
        var data = page(0x33, [0, 0, 0, 0, 0, 0]) // +2..+7 reserved
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // +8  BE32
        data.append(contentsOf: [0x0A, 0x0B, 0x0C, 0x0D])  // +12 BE32
        data.append(contentsOf: [0x11, 0x12, 0x13, 0x14])  // +16 BE32
        data.append(contentsOf: [0, 0, 0, 0])              // +20..+23
        let info = try ESASystemInfo.parse(data)
        XCTAssertEqual(info.field1, 0x01020304)
        XCTAssertEqual(info.field2, 0x0A0B0C0D)
        XCTAssertEqual(info.field3, 0x11121314)
    }

    func testSystemInfoRejectsWrongSubpage() {
        XCTAssertThrowsError(try ESASystemInfo.parse(page(0x34, [UInt8](repeating: 0, count: 16))))
    }

    func testCapacityInfoParse() throws {
        var data = page(0x02, [])
        data.append(contentsOf: [0, 0])                     // +2..+3
        for value: UInt64 in [0x1111111111111111, 0x2222222222222222,
                              0x3333333333333333, 0x4444444444444444] {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        let info = try ESACapacityInfo.parse(data)
        XCTAssertEqual(info.field1, 0x1111111111111111)
        XCTAssertEqual(info.field2, 0x2222222222222222)
        XCTAssertEqual(info.field3, 0x3333333333333333)
        XCTAssertEqual(info.field4, 0x4444444444444444)
    }

    func testCapacityInfoRejectsShort() {
        XCTAssertThrowsError(try ESACapacityInfo.parse(page(0x02, [UInt8](repeating: 0, count: 16))))
    }

    func testStatusInfoShortForm() throws {
        var data = page(0x09, [])
        data.append(contentsOf: [0, 0])                      // +2..+3
        data.append(contentsOf: [0, 0, 0x12, 0x34])          // +4  status
        data.append(contentsOf: [0, 0, 0, 0x05])             // +8  extended
        data.append(contentsOf: [0, 0, 0, 0x01])             // +12 diskpackStatus
        let info = try ESAStatusInfo.parse(data)
        XCTAssertEqual(info.status, 0x1234)
        XCTAssertEqual(info.extendedStatus, 0x05)
        XCTAssertEqual(info.diskpackStatus, 0x01)
        XCTAssertNil(info.relayoutCount)
    }

    func testStatusInfoLongForm() throws {
        var data = page(0x09, [])
        data.append(contentsOf: [UInt8](repeating: 0, count: 2))
        data.append(contentsOf: [0, 0, 0, 0])                // +4
        data.append(contentsOf: [0, 0, 0, 0])                // +8
        data.append(contentsOf: [0, 0, 0, 0x02])             // +12 diskpackStatus
        data.append(contentsOf: [0, 0, 0, 0x09])             // +16 relayout
        data.append(contentsOf: [0, 0, 0, 0x01])             // +20 doubleDegraded
        let info = try ESAStatusInfo.parse(data)
        XCTAssertEqual(info.diskpackStatus, 0x02)
        XCTAssertEqual(info.relayoutCount, 0x09)
        XCTAssertEqual(info.doubleDegraded, 0x01)
    }

    func testStatusFlagMapping() {
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 1), 0)
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 2), 0x1000)
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 3), 0x10000000)
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 4), 0x800)
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 5), 0x20)
        XCTAssertEqual(ESAStatusInfo.statusFlag(forDiskpackStatus: 8), 0x40000)
    }

    func testFirmwareInfoParse() throws {
        var data = page(0x08, [0, 0])                        // +2..+3
        data.append(contentsOf: [0x31, 0x39])                // +4, +5 version chars
        data.append(contentsOf: [0x01, 0x00])                // +6..7 BE16
        data.append(contentsOf: [0x41, 0x42])                // +8, +9
        data.append(contentsOf: Array("Drobo, Inc.".utf8))   // +10 package string
        data.append(contentsOf: [UInt8](repeating: 0, count: 0x2A - 0x0A - 11))
        data.append(contentsOf: Array("1.4.2".utf8))         // +42 build string
        data.append(contentsOf: [UInt8](repeating: 0, count: 0x10 - 5))
        let info = try ESAFirmwareInfo.parse(data)
        XCTAssertEqual(info.versionChar1, 0x31)
        XCTAssertEqual(info.versionChar2, 0x39)
        XCTAssertEqual(info.versionWord, 0x0100)
        XCTAssertEqual(info.fieldChar1, 0x41)
        XCTAssertEqual(info.fieldChar2, 0x42)
        XCTAssertEqual(info.packageString, "Drobo, Inc.")
        XCTAssertEqual(info.buildString, "1.4.2")
    }

    func testSlotInfoParse() throws {
        var data = page(0x03, [])
        data.append(contentsOf: [0x00, 0x4C])                // +2..3 page length
        data.append(0x01)                                    // +4 slot count
        var slot = Data(repeating: 0, count: 0x44)
        slot[2] = 0x03
        var serial: UInt64 = 0x0011223344556677
        var serialBE = serial.bigEndian
        withUnsafeBytes(of: &serialBE) { slot.replaceSubrange(3..<11, with: Data($0)) }
        slot[0x13] = 0x01
        slot.replaceSubrange(0x14..<0x14 + 5, with: Data("Bay 1".utf8))
        slot.replaceSubrange(0x34..<0x34 + 3, with: Data("WDC".utf8))
        data.append(slot)
        let slots = try ESASlotInfo.parse(data)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].state, 0x03)
        XCTAssertEqual(slots[0].serial, 0x0011223344556677)
        XCTAssertEqual(slots[0].flag, 0x01)
        XCTAssertEqual(slots[0].name, "Bay 1")
        XCTAssertEqual(slots[0].shortName, "WDC")
    }

    func testSlotInfoMultiple() throws {
        var data = page(0x03, [0x00, 0x99, 0x02])
        for _ in 0..<2 { data.append(Data(repeating: 0, count: 0x44)) }
        let slots = try ESASlotInfo.parse(data)
        XCTAssertEqual(slots.count, 2)
    }

    func testESASessionReturnsRawPage() throws {
        // MEASURED on the live 5D3 (2026-11-16): the Drobo's vendor
        // MODE SENSE(10) response carries the raw ESA page with NO mode
        // parameter header. Byte 0 is the page tag 0x7a, byte 1 the subpage,
        // and pageData returns the response unchanged.
        var response = page(0x02, {
            var p: [UInt8] = [0, 0]
            p.append(contentsOf: [UInt8](repeating: 0, count: 32))
            return p
        }())
        response[0] = ESAPage.tag
        let pageData = ESASession.pageData(ofModeSenseResponse: response)
        XCTAssertEqual(pageData[0], ESAPage.tag)
        XCTAssertEqual(pageData[1], 0x02)
        let info = try ESACapacityInfo.parse(pageData)
        XCTAssertEqual(info, ESACapacityInfo(field1: 0, field2: 0, field3: 0, field4: 0))
    }
}
