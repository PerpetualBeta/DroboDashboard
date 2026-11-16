import XCTest
@testable import DroboKit

final class DDBLogTests: XCTestCase {
    func testOffByDefaultWritesNothing() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drobo-log-tests-\(UUID().uuidString)")
        let log = DDBLog(directory: directory, baseName: "gated.log")
        log.info("should not appear")
        let path = directory.appendingPathComponent("gated.log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testRotationKeepsHistory() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drobo-log-tests-\(UUID().uuidString)")
        let log = DDBLog(directory: directory, baseName: "rotate.log", maxBytes: 200, keep: 2)
        log.level = .info
        for i in 0..<40 { log.info("line \(i) padding padding padding padding") }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("rotate.log").path))
        XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("rotate.log.1").path))
        XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("rotate.log.2").path))
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("rotate.log.3").path))
        try? FileManager.default.removeItem(at: directory)
    }
}
