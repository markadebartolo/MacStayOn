import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

struct AppUsageRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let duration: TimeInterval
    /// True when this row was credited mainly for background CPU / windows, not focus.
    let wasBackgroundWork: Bool
}

/// Tracks how long MacStayOn has been On and which apps were doing work —
/// frontmost focus, on-screen windows, and background CPU (local only).
final class SessionAnalytics: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var topApps: [AppUsageRow] = []
    @Published private(set) var hasSummary = false

    private struct Acc {
        var name: String
        var seconds: TimeInterval
        var backgroundSeconds: TimeInterval
    }

    private var sessionStartedAt: Date?
    private var totals: [String: Acc] = [:]
    private var tick: Timer?
    private var lastSampleAt: Date?
    private var lastCPU: [pid_t: Double] = [:]
    private var ownPID: pid_t = 0

    /// Minimum CPU seconds consumed in a sample window to count as "working".
    private let cpuWorkThreshold: Double = 0.04
    private let maxRows = 6

    func start() {
        tearDownObservers()
        ownPID = ProcessInfo.processInfo.processIdentifier
        sessionStartedAt = Date()
        lastSampleAt = Date()
        lastCPU = [:]
        elapsed = 0
        totals = [:]
        topApps = []
        hasSummary = false
        isLive = true

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
        sample()
    }

    /// Stop tracking but keep last session stats visible in the popover.
    func stopAndRetainSummary() {
        sample(final: true)
        tearDownObservers()
        if let sessionStartedAt {
            elapsed = Date().timeIntervalSince(sessionStartedAt)
        }
        publishApps()
        isLive = false
        hasSummary = elapsed > 0 || !topApps.isEmpty
        sessionStartedAt = nil
        lastSampleAt = nil
        lastCPU = [:]
    }

    func clear() {
        tearDownObservers()
        sessionStartedAt = nil
        lastSampleAt = nil
        lastCPU = [:]
        totals = [:]
        topApps = []
        elapsed = 0
        isLive = false
        hasSummary = false
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
        tick?.invalidate()
        tick = nil
    }

    private func sample(final: Bool = false) {
        let now = Date()
        if let sessionStartedAt {
            elapsed = now.timeIntervalSince(sessionStartedAt)
        }

        let previous = lastSampleAt ?? now
        let delta = max(0, now.timeIntervalSince(previous))
        lastSampleAt = now
        guard delta > 0 || final else {
            publishApps()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID = frontmost?.processIdentifier
        let appsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
                .map { ($0.processIdentifier, $0) }
        )

        let windows = Self.onScreenWindows()
        var windowTitlesByPID: [pid_t: [String]] = [:]
        var pidsWithWindows = Set<pid_t>()
        for win in windows {
            pidsWithWindows.insert(win.pid)
            guard let title = win.title, !title.isEmpty else { continue }
            windowTitlesByPID[win.pid, default: []].append(title)
        }

        var credited = Set<String>()

        for (pid, app) in appsByPID {
            let cpuNow = Self.cpuSeconds(for: pid)
            let cpuPrev = lastCPU[pid]
            if let cpuNow {
                lastCPU[pid] = cpuNow
            }

            let cpuDelta: Double = {
                guard let cpuNow, let cpuPrev else { return 0 }
                return max(0, cpuNow - cpuPrev)
            }()

            let isFront = pid == frontPID
            let hasWindow = pidsWithWindows.contains(pid)
            let isWorking = cpuDelta >= cpuWorkThreshold
            // Credit: focused, or on-screen and burning CPU (agent behind another window).
            guard isFront || (hasWindow && isWorking) || (isWorking && cpuDelta >= cpuWorkThreshold * 2) else {
                continue
            }

            let bid = app.bundleIdentifier ?? "pid.\(pid)"
            let appName = app.localizedName ?? bid
            let titles = Self.preferredTitles(windowTitlesByPID[pid] ?? [], appName: appName)

            if titles.isEmpty {
                credit(
                    key: bid,
                    name: appName,
                    seconds: delta,
                    background: !isFront,
                    into: &credited
                )
            } else {
                // Split the sample across distinct working windows of the same app.
                let share = delta / Double(titles.count)
                for title in titles {
                    credit(
                        key: "\(bid)|\(title)",
                        name: "\(appName) — \(title)",
                        seconds: share,
                        background: !isFront,
                        into: &credited
                    )
                }
            }
        }

        // Drop stale CPU samples for exited processes.
        let livePIDs = Set(appsByPID.keys)
        lastCPU = lastCPU.filter { livePIDs.contains($0.key) }

        publishApps()
    }

    private func credit(
        key: String,
        name: String,
        seconds: TimeInterval,
        background: Bool,
        into credited: inout Set<String>
    ) {
        guard seconds > 0, !credited.contains(key) else { return }
        credited.insert(key)
        var acc = totals[key] ?? Acc(name: name, seconds: 0, backgroundSeconds: 0)
        acc.name = name
        acc.seconds += seconds
        if background {
            acc.backgroundSeconds += seconds
        }
        totals[key] = acc
    }

    private func publishApps() {
        topApps = totals
            .map { key, acc in
                AppUsageRow(
                    key: key,
                    name: acc.name,
                    duration: acc.seconds,
                    wasBackgroundWork: acc.backgroundSeconds > acc.seconds * 0.5
                )
            }
            .sorted { $0.duration > $1.duration }
            .prefix(maxRows)
            .map { $0 }
    }

    // MARK: - Window / CPU helpers

    private struct WinInfo {
        let pid: pid_t
        let title: String?
    }

    private static func onScreenWindows() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [WinInfo] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            // Normal app windows sit on layer 0.
            guard layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }
            let title = info[kCGWindowName as String] as? String
            result.append(WinInfo(pid: pid_t(pidNum.int32Value), title: title))
        }
        return result
    }

    /// Prefer informative window titles; drop generic / empty / app-name-only duplicates.
    private static func preferredTitles(_ titles: [String], appName: String) -> [String] {
        let appLower = appName.lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for raw in titles {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if lower == appLower { continue }
            // Skip tiny chrome titles.
            if t.count < 2 { continue }
            if seen.contains(lower) { continue }
            seen.insert(lower)
            out.append(t)
            if out.count >= 3 { break }
        }
        return out
    }

    private static func cpuSeconds(for pid: pid_t) -> Double? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard status == 0 else { return nil }
        // ri_user_time / ri_system_time are nanoseconds on modern macOS.
        let nanos = Double(info.ri_user_time) + Double(info.ri_system_time)
        return nanos / 1_000_000_000.0
    }
}
