// DroboHealth: the persistent pack health check. A LaunchAgent runs this
// bundled app once per interval (StartInterval in the LaunchAgent plist);
// each run does exactly one thing: open the dext, read the pack read-only,
// decide healthy or problem, and act only on a CHANGE of verdict, because
// the point is a notification when the pack's state moves, not a nag every
// quarter hour.
//
// State lives in ~/Library/Application Support/DroboHealth/state.json so the
// transition logic survives across runs. Logs go through the gated rotating
// DDBLog (DROBO_LOG env gate). DROBO_HEALTH_NOTIFY=off disables User
// Notifications entirely (used for testing and for machines where the
// permission prompt is unwanted); the state machine and logging still run.
//
// The process is asynchronous end to end: every path ends in an explicit
// exit, and a watchdog exits after 30 seconds no matter what, so a hung
// notification callback can never leave a zombie for launchd to stack up.

import AppKit
import Foundation
import DroboKit
import DroboTransport
import UserNotifications

private let log = DDBLog(directory: FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask).first?
    .appendingPathComponent("Logs/DroboHealth", isDirectory: true),
    baseName: "health.log")

// MARK: - Persistent state

struct HealthState: Codable {
    var verdict: String = "unknown"          // "healthy" | "problem" | "unknown"
    var reason: String?
    var consecutiveFailures: Int = 0
    var lastChecked: Date?
    var lastNotified: Date?
}

enum StateStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DroboHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    static func load() -> HealthState {
        guard let data = try? Data(contentsOf: url) else { return HealthState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A stale or unreadable state file falls back to "unknown", which
        // behaves like healthy for notification purposes; measured live
        // 2026-11-17: the missing date strategy made every load fail and
        // the recovery branch was never reachable.
        return (try? decoder.decode(HealthState.self, from: data)) ?? HealthState()
    }

    static func save(_ state: HealthState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Notifications

enum Notifier {
    /// One stable identifier: a new verdict REPLACES the delivered
    /// notification instead of stacking a fresh one every run.
    static let identifier = "cc.jorvik.drobohealth.pack"

    /// Fire-and-forget authorisation request so the one-time prompt
    /// happens on a calm first run, never during an incident.
    static func requestEarly() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.info("early authorisation request failed: \(error)")
            } else {
                log.info("notification authorisation: \(granted ? "granted" : "denied")")
            }
        }
    }

    static func post(title: String, body: String, then: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted, error == nil else {
                log.info("notification authorisation denied or failed: \(String(describing: error))")
                then(false)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { addError in
                if let addError {
                    log.error("notification add failed: \(addError)")
                }
                then(addError == nil)
            }
        }
    }
}

// MARK: - One check

private var exited = false
private func finish(_ state: HealthState, notified: Bool) {
    var s = state
    if notified { s.lastNotified = Date() }
    StateStore.save(s)
    exitNow()
}

private func exitNow() {
    guard !exited else { return }
    exited = true
    exit(0)
}

func runCheck() {
    var state = StateStore.load()

    // Request authorisation on EVERY notify-enabled run, before the
    // verdict matters: the first call shows the one-time prompt, every
    // later call returns instantly granted. Without this the prompt would
    // land mid-incident, exactly when a notification must not need a
    // click first.
    if ProcessInfo.processInfo.environment["DROBO_HEALTH_NOTIFY"] != "off" {
        Notifier.requestEarly()
    }

    var snapshotVerdict: PackHealth
    var readOK = false
    do {
        let session = try ESASession(transport: DextTransport())
        let packStatus = try session.getStatusInfo()
        let slots = (try? session.getSlotInfo()) ?? []
        snapshotVerdict = PackHealth.evaluate(status: packStatus, slots: slots)
        readOK = true
        log.info("read ok: \(snapshotVerdict.isHealthy ? "healthy" : "problem: \(snapshotVerdict.reason ?? "")")")
    } catch {
        state.consecutiveFailures += 1
        log.error("read failed (consecutive \(state.consecutiveFailures)): \(String(describing: error))")
        // Two consecutive failed polls before calling it a problem: one
        // failure covers a transient while a dashboard poll or a cable
        // blip is in flight; two in a row is a pattern.
        if state.consecutiveFailures >= 2 {
            snapshotVerdict = .problem("cannot reach the disk pack (\(state.consecutiveFailures) failed polls)")
        } else {
            // Not enough evidence to change the verdict; keep the old one.
            snapshotVerdict = state.verdict == "problem"
                ? .problem(state.reason ?? "previous problem")
                : .healthy
        }
    }

    var nextState = state
    // The failure counter only resets on a genuinely successful read; a
    // "keep the old verdict" failure must keep counting toward the next one.
    nextState.consecutiveFailures = readOK ? 0 : state.consecutiveFailures
    nextState.lastChecked = Date()

    let wasHealthy = state.verdict == "healthy" || state.verdict == "unknown"
    let isHealthy = snapshotVerdict.isHealthy
    nextState.verdict = isHealthy ? "healthy" : "problem"
    nextState.reason = snapshotVerdict.reason

    let notificationsWanted = ProcessInfo.processInfo.environment["DROBO_HEALTH_NOTIFY"] != "off"

    if wasHealthy && !isHealthy {
        // Transition INTO a problem: the case the whole agent exists for.
        log.error("PROBLEM: \(snapshotVerdict.reason ?? "")")
        guard notificationsWanted else { return finish(nextState, notified: false) }
        Notifier.post(
            title: "Drobo disk pack needs attention",
            body: snapshotVerdict.reason ?? "unspecified problem"
        ) { posted in finish(nextState, notified: posted) }
    } else if !wasHealthy && isHealthy {
        // Recovery: close the loop so silence can be trusted again.
        log.info("recovered: pack healthy again")
        guard notificationsWanted else { return finish(nextState, notified: false) }
        Notifier.post(
            title: "Drobo disk pack healthy again",
            body: nextState.reason.map { "resolved: \($0)" } ?? "all checks pass"
        ) { posted in finish(nextState, notified: posted) }
    } else {
        // Steady state: healthy stays silent, an ongoing problem stays
        // delivered (its notification is still on screen) without re-post.
        finish(nextState, notified: false)
    }
}

// Watchdog: whichever path completes first wins; the other is moot.
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exitNow() }

runCheck()
dispatchMain()
