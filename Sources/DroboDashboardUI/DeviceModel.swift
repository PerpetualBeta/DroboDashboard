// The dashboard's device model: one poll reads every ESA page through the
// dext and publishes the parsed result. Polling runs on a timer whose
// cadence is a live defaults knob; the read is read-only and touches no
// volume.

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
    /// The cadence the timer is currently scheduled at, so a defaults change
    /// is detected by comparison at each fire.
    private var scheduledInterval: Double?

    /// One-shot hook for the render harness: fires after a poll settles,
    /// success or failure.
    var onSettled: (() -> Void)?

    /// The poll cadence knob. Live: read from the standard defaults every
    /// timer fire, so
    ///
    ///     defaults write cc.jorvik.drobodashboard pollInterval -float 2
    ///
    /// takes effect within one poll cycle, no relaunch. Clamped to a sane
    /// range so a fat-fingered value cannot spin the driver or stall the
    /// window. Registered so a read always answers.
    static let pollIntervalKey = "pollInterval"

    static func currentPollInterval() -> Double {
        min(60, max(0.5, UserDefaults.standard.double(forKey: pollIntervalKey)))
    }

    func start() {
        guard timer == nil else { return }
        UserDefaults.standard.register(defaults: [Self.pollIntervalKey: 5.0])
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
        // The reads are cheap MODE SENSE sweeps and a poll skipped while one
        // is in flight is harmless. The interval is re-read at every fire so
        // the knob is live without a relaunch.
        let source = DispatchSource.makeTimerSource(queue: .main)
        scheduledInterval = Self.currentPollInterval()
        source.schedule(deadline: .now(), repeating: scheduledInterval!)
        source.setEventHandler { [weak self] in
            self?.poller.poll()
            guard let self else { return }
            let interval = Self.currentPollInterval()
            if interval != self.scheduledInterval {
                self.scheduledInterval = interval
                self.timer?.schedule(deadline: .now() + interval, repeating: interval)
            }
        }
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
