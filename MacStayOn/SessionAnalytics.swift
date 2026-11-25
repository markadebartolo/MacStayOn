import Combine
import Foundation

/// How long the current (or last) Stay Awake session has run.
///
/// This used to also attribute work to apps by scanning every process with `ps`
/// and walking `~/Library/Application Support` once a second for the whole
/// session — about 2% of a CPU core with the lid closed, for a list few people
/// opened. Only the session clock remains; it does no I/O.
final class SessionAnalytics: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var hasSummary = false

    private var sessionStartedAt: Date?
    private var tick: Timer?

    func start() {
        tick?.invalidate()
        sessionStartedAt = Date()
        elapsed = 0
        hasSummary = false
        isLive = true

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        // Display-only clock: let the system coalesce it.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    func stopAndRetainSummary() {
        tick?.invalidate()
        tick = nil
        updateElapsed()
        isLive = false
        hasSummary = elapsed > 0
        sessionStartedAt = nil
    }

    func clear() {
        tick?.invalidate()
        tick = nil
        sessionStartedAt = nil
        elapsed = 0
        isLive = false
        hasSummary = false
    }

    private func updateElapsed() {
        guard let sessionStartedAt else { return }
        elapsed = Date().timeIntervalSince(sessionStartedAt)
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
}
