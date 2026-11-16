// Gated debug logging with rotation. The level comes from the DROBO_LOG
// environment variable (off | error | info | debug); nothing is written
// while the gate is off. Logs go to ~/Library/Logs/DroboService/, never /tmp,
// and rotate at a size cap with a small kept-history window.

import Foundation

public enum DDBLogLevel: String {
    case off, error, info, debug

    var rank: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .info: return 2
        case .debug: return 3
        }
    }
}

public final class DDBLog {
    public static let shared = DDBLog()

    /// The gate: off unless DROBO_LOG selects a level. Assign directly to
    /// turn logging on in code (tests do this).
    public var level: DDBLogLevel
    private let directory: URL
    private let baseName: String
    private let maxBytes: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "cc.jorvik.ddservice.log")
    private var wroteThisSession = false

    public init(directory: URL? = nil, baseName: String = "ddservice.log",
                maxBytes: Int = 1_000_000, keep: Int = 3) {
        level = DDBLogLevel(rawValue: ProcessInfo.processInfo.environment["DROBO_LOG"] ?? "") ?? .off
        let logs = directory
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                .map { $0.appendingPathComponent("Logs/DroboService", isDirectory: true) }
        self.directory = logs ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.baseName = baseName
        self.maxBytes = maxBytes
        self.keep = keep
    }

    public func debug(_ message: String) { write(message, level: .debug) }
    public func info(_ message: String) { write(message, level: .info) }
    public func error(_ message: String) { write(message, level: .error) }

    private func write(_ message: String, level: DDBLogLevel) {
        guard level.rank <= self.level.rank else { return }
        let line = "\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) [\(level.rawValue.uppercased())] \(message)\n"
        queue.sync { self.append(line) }
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        do {
            if !wroteThisSession {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                wroteThisSession = true
            }
            let path = directory.appendingPathComponent(baseName)
            if let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? Int), size >= maxBytes {
                rotate()
            }
            if !fm.fileExists(atPath: path.path) {
                fm.createFile(atPath: path.path, contents: Data())
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never take the daemon down.
        }
    }

    private func rotate() {
        let fm = FileManager.default
        let last = directory.appendingPathComponent("\(baseName).\(keep)")
        try? fm.removeItem(at: last)
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("\(baseName).\(i)")
            let to = directory.appendingPathComponent("\(baseName).\(i + 1)")
            try? fm.moveItem(at: from, to: to)
        }
        let base = directory.appendingPathComponent(baseName)
        try? fm.moveItem(at: base, to: directory.appendingPathComponent("\(baseName).1"))
    }
}
