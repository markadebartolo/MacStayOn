import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

struct AppUsageRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let detail: String?
    let duration: TimeInterval
    /// Mostly credited while not frontmost.
    let wasBackgroundWork: Bool
    /// True if this app is still considered working in the current sample window.
    let isActiveNow: Bool
}

/// Tracks how long MacStayOn has been On and which apps were doing work —
/// frontmost focus plus bundle-wide CPU (main app + helpers), so background
/// agents like Claude keep counting when their window is not focused.
final class SessionAnalytics: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var topApps: [AppUsageRow] = []
    @Published private(set) var hasSummary = false

    private struct Acc {
        var name: String
        var detail: String?
        var seconds: TimeInterval
        var backgroundSeconds: TimeInterval
        var lastActiveAt: Date?
    }

    private var sessionStartedAt: Date?
    private var totals: [String: Acc] = [:]
    private var tick: Timer?
    private var lastSampleAt: Date?
    /// Cumulative CPU seconds keyed by pid (main + helpers).
    private var lastCPU: [pid_t: Double] = [:]
    private var ownPID: pid_t = 0
    private var activeKeys: Set<String> = []

    /// Minimum bundle CPU seconds in a sample to count as working.
    private let cpuWorkThreshold: Double = 0.015
    /// Keep crediting after CPU drops — agents burst then wait on network/model.
    private let stickyActive: TimeInterval = 30
    private let maxRows = 6

    func start() {
        tearDownObservers()
        ownPID = ProcessInfo.processInfo.processIdentifier
        sessionStartedAt = Date()
        lastSampleAt = Date()
        lastCPU = [:]
        activeKeys = []
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
        activeKeys = []
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
        activeKeys = []
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
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }

        // Include every Space/Desktop — OnScreenOnly misses apps on other Mission Control desktops.
        let windows = Self.appWindows(allSpaces: true)
        var windowTitlesByPID: [pid_t: [String]] = [:]
        var pidsWithWindows = Set<pid_t>()
        for win in windows {
            pidsWithWindows.insert(win.pid)
            guard let title = win.title, !title.isEmpty else { continue }
            windowTitlesByPID[win.pid, default: []].append(title)
        }

        // Map every live pid → path once, then attribute helpers to app bundles.
        let pathByPID = Self.processPaths()
        var cpuByPID: [pid_t: Double] = [:]
        for pid in pathByPID.keys {
            if let cpu = Self.cpuSeconds(for: pid) {
                cpuByPID[pid] = cpu
            }
        }

        var nextActive = Set<String>()

        for app in apps {
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier ?? "pid.\(pid)"
            let appName = app.localizedName ?? bid
            let bundlePath = app.bundleURL?.path

            let memberPIDs = Self.memberPIDs(
                mainPID: pid,
                bundlePath: bundlePath,
                pathByPID: pathByPID
            )

            var cpuDelta: Double = 0
            for member in memberPIDs {
                guard let cpuNow = cpuByPID[member] else { continue }
                if let cpuPrev = lastCPU[member] {
                    cpuDelta += max(0, cpuNow - cpuPrev)
                }
                lastCPU[member] = cpuNow
            }

            let isFront = pid == frontPID
            let hasWindow = pidsWithWindows.contains(pid)
                || memberPIDs.contains(where: { pidsWithWindows.contains($0) })
            let cpuWorking = cpuDelta >= cpuWorkThreshold

            var acc = totals[bid] ?? Acc(
                name: appName,
                detail: nil,
                seconds: 0,
                backgroundSeconds: 0,
                lastActiveAt: nil
            )
            acc.name = appName

            // Prefer a recent window title for display only — never as the identity key.
            // (macOS often blanks titles for unfocused apps; keying on them made Claude
            // "appear" on focus and "stop" when leaving.)
            let titles = Self.preferredTitles(
                windowTitlesByPID[pid] ?? memberPIDs.flatMap { windowTitlesByPID[$0] ?? [] },
                appName: appName
            )
            if let best = titles.first {
                acc.detail = best
            }

            if cpuWorking || isFront {
                acc.lastActiveAt = now
            }

            let sticky = acc.lastActiveAt.map { now.timeIntervalSince($0) <= stickyActive } ?? false
            // Windows on other Desktops still count via allSpaces listing.
            // No-window path covers headless helpers / fully minimized apps.
            let shouldCredit = isFront
                || (hasWindow && (cpuWorking || sticky))
                || (!hasWindow && (cpuWorking || sticky))

            if shouldCredit {
                acc.seconds += delta
                if !isFront {
                    acc.backgroundSeconds += delta
                }
                nextActive.insert(bid)
            }

            // Keep rows we have already seen this session (so Claude does not vanish).
            if acc.seconds > 0 || shouldCredit {
                totals[bid] = acc
            }
        }

        activeKeys = nextActive

        // Prune CPU cache for dead pids.
        let live = Set(pathByPID.keys)
        lastCPU = lastCPU.filter { live.contains($0.key) }

        publishApps()
    }

    private func publishApps() {
        topApps = totals
            .map { key, acc in
                AppUsageRow(
                    key: key,
                    name: acc.name,
                    detail: acc.detail,
                    duration: acc.seconds,
                    wasBackgroundWork: acc.backgroundSeconds > acc.seconds * 0.5,
                    isActiveNow: isLive && activeKeys.contains(key)
                )
            }
            .sorted {
                if $0.isActiveNow != $1.isActiveNow { return $0.isActiveNow && !$1.isActiveNow }
                return $0.duration > $1.duration
            }
            .prefix(maxRows)
            .map { $0 }
    }

    // MARK: - Process / window helpers

    private struct WinInfo {
        let pid: pid_t
        let title: String?
    }

    private static func appWindows(allSpaces: Bool) -> [WinInfo] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if allSpaces {
            options.insert(.optionAll)
        } else {
            options.insert(.optionOnScreenOnly)
        }
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WinInfo] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            // Normal app windows sit on layer 0 (including other Spaces).
            guard layer == 0 else { continue }
            // On other Desktops alpha can be reported as 0 — don't require visibility.
            if !allSpaces {
                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                guard alpha > 0.05 else { continue }
            }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            // Skip zero-size chrome / tooltip stubs.
            guard width >= 40, height >= 40 else { continue }
            let title = info[kCGWindowName as String] as? String
            result.append(WinInfo(pid: pid_t(pidNum.int32Value), title: title))
        }
        return result
    }

    private static func preferredTitles(_ titles: [String], appName: String) -> [String] {
        let appLower = appName.lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for raw in titles {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { continue }
            let lower = t.lowercased()
            if lower == appLower { continue }
            if seen.contains(lower) { continue }
            seen.insert(lower)
            out.append(t)
            if out.count >= 3 { break }
        }
        return out
    }

    private static func processPaths() -> [pid_t: String] {
        var capacity: Int32 = 4096
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        var bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, capacity * Int32(MemoryLayout<pid_t>.size))
        }
        if bytes <= 0 {
            capacity = 16384
            pids = [pid_t](repeating: 0, count: Int(capacity))
            bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
                proc_listallpids(buf.baseAddress, capacity * Int32(MemoryLayout<pid_t>.size))
            }
        }
        guard bytes > 0 else { return [:] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        var map: [pid_t: String] = [:]
        map.reserveCapacity(count)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN (typically 4096).
            var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard n > 0 else { continue }
            map[pid] = String(cString: pathBuf)
        }
        return map
    }

    private static func memberPIDs(
        mainPID: pid_t,
        bundlePath: String?,
        pathByPID: [pid_t: String]
    ) -> Set<pid_t> {
        var members: Set<pid_t> = [mainPID]
        guard let bundlePath, !bundlePath.isEmpty else { return members }
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        for (pid, path) in pathByPID {
            if path == bundlePath || path.hasPrefix(prefix) {
                members.insert(pid)
            }
        }
        return members
    }

    private static func cpuSeconds(for pid: pid_t) -> Double? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard status == 0 else { return nil }
        let nanos = Double(info.ri_user_time) + Double(info.ri_system_time)
        return nanos / 1_000_000_000.0
    }
}
