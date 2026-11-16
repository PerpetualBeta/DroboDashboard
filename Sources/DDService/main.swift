// DDService: the daemon half of the like-for-like rebuild. It listens on
// 127.0.0.1:4502, validates the 16-byte TMSessionHeader handshake, and routes
// text commands (opcode 0x02/0x03 sessions) to the device layer. This mirrors
// SkyPCManager::Listen and CmdAdapter::RecvAndProcessCommand in the original.
//
// Device access is on demand: the transport opens for the first command that
// needs it and closes right after, because the user-space transport holds
// exclusive access and the device must be ejected while the session is open.
//
//   DDService [--disk disk15] [--transport userspace|kext]

import Foundation
import DroboKit
import DroboTransport
import DDServiceC

// MARK: - Device access

final class DeviceAccess {
    private let diskName: String?
    private let transportKind: DDTransportKind
    private let log: DDBLog
    private let lock = NSLock()
    private var esa: ESASession?

    init(diskName: String?, transportKind: DDTransportKind, log: DDBLog) {
        self.diskName = diskName
        self.transportKind = transportKind
        self.log = log
    }

    func withSession<T>(_ body: (ESASession) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if esa == nil {
            let transport = try makeTransport(kind: transportKind, bsdName: diskName)
            log.info("device transport open (\(transportKind.rawValue))")
            esa = ESASession(transport: transport)
        }
        do {
            return try body(esa!)
        } catch {
            esa?.close()
            esa = nil
            log.error("device session error: \(error); transport closed")
            throw error
        }
    }
}

// MARK: - Command router

/// Text command routing in the spirit of ServiceCmdRouter::RouteCommand.
/// v0.1 answers the read-only survey commands; everything else answers
/// like the original does for unknown commands, with a diagnostic.
final class Router {
    let access: DeviceAccess
    let log: DDBLog

    init(access: DeviceAccess, log: DDBLog) {
        self.access = access
        self.log = log
    }

    func route(_ command: String) -> String {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        log.debug("route \(name)")
        switch name {
        case "eCmdGetDevices":
            return read { _ in String(ddus_count_drobo_nubs()) }
        case "eCmdGetSysInfo":
            return read { try $0.getSystemInfo() }
        case "eCmdGetCapacity":
            return read { try $0.getCapacityInfo() }
        case "eCmdGetFirmware":
            return read { try $0.getFirmwareInfo() }
        case "eCmdGetStatus":
            return read { try $0.getStatusInfo() }
        case "eCmdGetSlotInfo":
            return read { try $0.getSlotInfo() }
        case "eCmdDoPoll":
            return "ok"
        case "eCmdEmpty":
            return "ok"
        default:
            log.info("unrouted command \(name)")
            return "error unknown command \(name)"
        }
    }

    private func read(_ body: @escaping (ESASession) throws -> Any) -> String {
        do {
            let value = try access.withSession(body)
            return "ok \(value)"
        } catch {
            return "error \(error)"
        }
    }
}

// MARK: - Socket server

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data()
    data.reserveCapacity(count)
    var buffer = [UInt8](repeating: 0, count: count)
    while data.count < count {
        let want = count - data.count
        let n = recv(fd, &buffer, want, 0)
        if n <= 0 { return nil }
        data.append(contentsOf: buffer[0..<n])
    }
    return data
}

func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
        let n = bytes.withUnsafeBufferPointer { buf -> Int in
            send(fd, buf.baseAddress! + offset, bytes.count - offset, 0)
        }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

func handleConnection(fd: Int32, router: Router, log: DDBLog) {
    defer { close(fd) }
    guard let headerData = readExactly(fd, 16) else { return }
    guard let header = try? TMSessionHeader.decode(headerData) else {
        log.info("bad session header, dropping connection")
        return
    }
    log.debug("session opcode \(header.primaryOpcode)/\(header.secondaryOpcode) length \(header.dataLength)")

    switch header.primaryOpcode {
    case TMOpcode.tmCommand, TMOpcode.tmCmd:
        break
    default:
        log.info("opcode \(header.primaryOpcode) not supported in v0.1, closing")
        return
    }

    var payload = Data()
    if header.dataLength > 0 {
        guard header.dataLength <= TMSessionHeader.maxPayloadLength,
              let body = readExactly(fd, Int(header.dataLength)) else { return }
        payload = body
    }
    let command = String(decoding: payload, as: UTF8.self)
    let response = router.route(command)
    let responseBytes = Data(response.utf8)
    let reply = TMSessionHeader(primaryOpcode: TMOpcode.tmCmd,
                                dataLength: UInt32(responseBytes.count)).encoded() + responseBytes
    _ = sendAll(fd, reply)
}

let log = DDBLog()
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let port: UInt16 = 4502
let diskName = option("--disk")
let transportKind = DDTransportKind(rawValue: option("--transport") ?? "") ?? .dext

log.info("DDService starting on 127.0.0.1:\(port), transport \(transportKind.rawValue), disk \(diskName ?? "-")")

let router = Router(access: DeviceAccess(diskName: diskName, transportKind: transportKind, log: log),
                    log: log)

let listenFd = socket(AF_INET, SOCK_STREAM, 0)
var reuse: Int32 = 1
setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(listenFd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0, listen(listenFd, 8) == 0 else {
    log.error("cannot listen on 127.0.0.1:\(port), another DDService may be running")
    print("DDService: cannot listen on 127.0.0.1:\(port)")
    exit(1)
}

print("DDService listening on 127.0.0.1:\(port)")
log.info("listening")

while true {
    var clientAddress = sockaddr()
    var length = socklen_t(MemoryLayout<sockaddr>.size)
    let fd = accept(listenFd, &clientAddress, &length)
    if fd < 0 { continue }
    DispatchQueue.global(qos: .utility).async {
        handleConnection(fd: fd, router: router, log: log)
    }
}
