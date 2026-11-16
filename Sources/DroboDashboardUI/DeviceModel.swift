// The dashboard's device model: one poll reads every ESA page through the
// dext and publishes the parsed result. Polling is a fixed timer; the read
// is read-only and touches no volume.

import Foundation
import DroboKit
import DroboTransport

struct DeviceSnapshot {
    var firmware: ESAFirmwareInfo?
    var capacity: ESACapacityInfo?
    var status: ESAStatusInfo?
    var slots: [ESASlotInfo] = []
}

/// The read loop. All dext IO happens on a private serial queue so a slow
/// or wedged read never blocks the UI; results land on the main queue.
/// The transport opens once and is kept across polls; reopening per poll
/// trips the dext's open-close-reopen trap (MACH_SEND_INVALID_DEST).
final class DevicePoller {
    var onResult: ((Result<DeviceSnapshot, Error>) -> Void)?

    private let queue = DispatchQueue(label: "cc.jorvik.drobodashboard.poll")
    private var session: ESASession?

    func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if session == nil {
                    session = try ESASession(transport: DextTransport())
                }
                guard let session else { return }
                let snapshot = DeviceSnapshot(
                    firmware: try session.getFirmwareInfo(),
                    capacity: try session.getCapacityInfo(),
                    status: try session.getStatusInfo(),
                    slots: (try? session.getSlotInfo()) ?? []
                )
                DispatchQueue.main.async { self.onResult?(.success(snapshot)) }
            } catch {
                // Drop the session so the next poll starts clean; a wedged
                // connection must not poison every later read.
                session = nil
                DispatchQueue.main.async { self.onResult?(.failure(error)) }
            }
        }
    }
}

@MainActor
final class DeviceModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published var snapshot = DeviceSnapshot()
    @Published var state: LoadState = .loading
    @Published var lastRefresh: Date?

    private let poller = DevicePoller()
    private var timer: DispatchSourceTimer?

    /// One-shot hook for the render harness: fires after a poll settles,
    /// success or failure.
    var onSettled: (() -> Void)?

    func start() {
        guard timer == nil else { return }
        poller.onResult = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.state = .loaded
                self.lastRefresh = Date()
            case .failure(let error):
                self.state = .failed(String(describing: error))
            }
            self.onSettled?()
        }
        // A fixed cadence is fine for a status window; the reads are cheap
        // MODE SENSE sweeps and a poll skipped while one is in flight is
        // harmless. Long-term the cadence should ship as a defaults knob.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 5)
        source.setEventHandler { [weak self] in self?.poller.poll() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        poller.onResult = nil
    }

    func refresh() {
        // A loaded dashboard stays visible while the next poll runs; only a
        // first load shows the loading state.
        if snapshot.firmware == nil { state = .loading }
        poller.poll()
    }
}
