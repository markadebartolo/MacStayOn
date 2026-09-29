import AppKit
import Combine
import Foundation

struct AppUsageRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let duration: TimeInterval
}

/// Tracks how long MacStayOn has been On and which apps were frontmost (local only).
final class SessionAnalytics: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var topApps: [AppUsageRow] = []
    @Published private(set) var hasSummary = false

    private var sessionStartedAt: Date?
    private var totals: [String: (name: String, seconds: TimeInterval)] = [:]
    private var currentBundleID: String?
    private var currentName: String?
    private var currentStartedAt: Date?
    private var tick: Timer?
    private var activateObserver: NSObjectProtocol?

    func start() {
        tearDownObservers()
        sessionStartedAt = Date()
        elapsed = 0
        totals = [:]
        topApps = []
        hasSummary = false
        isLive = true
        beginFrontmost(NSWorkspace.shared.frontmostApplication)

        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.beginFrontmost(app)
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPublished()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
        refreshPublished()
    }

    /// Stop tracking but keep last session stats visible in the popover.
    func stopAndRetainSummary() {
        sealCurrent()
        tearDownObservers()
        if let sessionStartedAt {
            elapsed = Date().timeIntervalSince(sessionStartedAt)
        }
        publishApps(from: totals)
        isLive = false
        hasSummary = elapsed > 0 || !topApps.isEmpty
        sessionStartedAt = nil
        currentBundleID = nil
        currentName = nil
        currentStartedAt = nil
    }

    func clear() {
        tearDownObservers()
        sessionStartedAt = nil
        totals = [:]
        topApps = []
        elapsed = 0
        isLive = false
        hasSummary = false
        currentBundleID = nil
        currentName = nil
        currentStartedAt = nil
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    private func tearDownObservers() {
        if let activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activateObserver)
            self.activateObserver = nil
        }
        tick?.invalidate()
        tick = nil
    }

    private func beginFrontmost(_ app: NSRunningApplication?) {
        sealCurrent()
        guard let app else { return }
        let bid = app.bundleIdentifier ?? "unknown.\(app.processIdentifier)"
        let name = app.localizedName ?? bid
        currentBundleID = bid
        currentName = name
        currentStartedAt = Date()
        refreshPublished()
    }

    private func sealCurrent() {
        guard let bid = currentBundleID,
              let name = currentName,
              let started = currentStartedAt
        else { return }
        let delta = Date().timeIntervalSince(started)
        var entry = totals[bid] ?? (name: name, seconds: 0)
        entry.seconds += max(0, delta)
        entry.name = name
        totals[bid] = entry
        currentStartedAt = Date()
    }

    private func refreshPublished() {
        if let sessionStartedAt {
            elapsed = Date().timeIntervalSince(sessionStartedAt)
        }
        var snapshot = totals
        if let bid = currentBundleID,
           let name = currentName,
           let started = currentStartedAt
        {
            var entry = snapshot[bid] ?? (name: name, seconds: 0)
            entry.seconds += max(0, Date().timeIntervalSince(started))
            entry.name = name
            snapshot[bid] = entry
        }
        publishApps(from: snapshot)
    }

    private func publishApps(from snapshot: [String: (name: String, seconds: TimeInterval)]) {
        topApps = snapshot
            .map { AppUsageRow(bundleID: $0.key, name: $0.value.name, duration: $0.value.seconds) }
            .sorted { $0.duration > $1.duration }
            .prefix(5)
            .map { $0 }
    }
}
