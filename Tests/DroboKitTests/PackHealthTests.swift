import XCTest
@testable import DroboKit

final class PackHealthTests: XCTestCase {
    private func status(diskpack: UInt32? = 0, relayout: UInt32? = nil,
                        doubleDegraded: UInt32? = nil) -> ESAStatusInfo {
        ESAStatusInfo(status: 0x28000, extendedStatus: 0, diskpackStatus: diskpack,
                      relayoutCount: relayout, doubleDegraded: doubleDegraded)
    }

    private func slot(_ state: UInt8) -> ESASlotInfo {
        ESASlotInfo(state: state, capacityBytes: 1, reserved: 0,
                    model: "test", shortModel: "t")
    }

    func testMeasuredHealthyCombinations() {
        // diskpack 0 is the observed value; 1 is named healthy by the
        // original daemon. nil means the 0x10 page generation, also fine.
        XCTAssertEqual(PackHealth.evaluate(status: status(), slots: []), .healthy)
        XCTAssertEqual(PackHealth.evaluate(status: status(diskpack: 1), slots: []), .healthy)
        XCTAssertEqual(PackHealth.evaluate(status: status(diskpack: nil), slots: []), .healthy)
        XCTAssertEqual(PackHealth.evaluate(status: nil, slots: []), .healthy)
    }

    func testGoodSlotsDoNotMaskProblemsAndViceVersa() {
        XCTAssertEqual(PackHealth.evaluate(status: status(), slots: [slot(0x03), slot(0x03)]), .healthy)
        if case .problem(let reason) = PackHealth.evaluate(status: status(diskpack: 2), slots: [slot(0x03)]) {
            XCTAssertEqual(reason, "disk pack status 2")
        } else {
            XCTFail("expected a problem")
        }
    }

    func testSlotFaultNamesTheSlot() {
        if case .problem(let reason) = PackHealth.evaluate(status: status(), slots: [slot(0x03), slot(0x00)]) {
            XCTAssertEqual(reason, "bay 2 not ready (state 0x0)")
        } else {
            XCTFail("expected a problem")
        }
        if case .problem(let reason) = PackHealth.evaluate(status: status(),
                                                           slots: [slot(0x03), slot(0x03), slot(0x03),
                                                                   slot(0x03), slot(0x03), slot(0x01)]) {
            XCTAssertEqual(reason, "cache slot not ready (state 0x1)")
        } else {
            XCTFail("expected a problem")
        }
    }

    func testRelayoutAndDoubleDegradedAreProblems() {
        if case .problem(let reason) = PackHealth.evaluate(status: status(relayout: 1), slots: []) {
            XCTAssertEqual(reason, "relayout in progress (relayout 1)")
        } else {
            XCTFail("expected a problem")
        }
        if case .problem(let reason) = PackHealth.evaluate(status: status(doubleDegraded: 1), slots: []) {
            XCTAssertEqual(reason, "double degraded (doubleDegraded 1)")
        } else {
            XCTFail("expected a problem")
        }
        // Zero means idle, not active.
        XCTAssertEqual(PackHealth.evaluate(status: status(relayout: 0, doubleDegraded: 0), slots: []), .healthy)
    }

    func testFirstFaultWinsInOrder() {
        // Status problems outrank slot problems because the status page is
        // read first; the reason text must be the status one.
        if case .problem(let reason) = PackHealth.evaluate(status: status(diskpack: 5),
                                                           slots: [slot(0x00)]) {
            XCTAssertEqual(reason, "disk pack status 5")
        } else {
            XCTFail("expected a problem")
        }
    }
}
