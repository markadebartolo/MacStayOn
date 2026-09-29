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
/// frontmost focus plus bundle-wide CPU (main app + helpers + Application Support
/// workers), so background agents like Claude keep counting when not focused.
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
    /// Cumulative CPU seconds keyed by pid (main + helpers + support workers).
    private var lastCPU: [pid_t: Double] = [:]
    private var ownPID: pid_t = 0
    private var activeKeys: Set<String> = []

    /// Minimum bundle CPU seconds in a sample to count as working.
    private let cpuWorkThreshold: Double = 0.008
    /// Keep crediting after CPU drops — agents burst then wait on network/model.
    private let stickyActive: TimeInterval = 45
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

        let pathByPID = Self.processPaths()
        let parentOf = Self.parentMap(for: Array(pathByPID.keys))
        let childrenOf = Self.childrenMap(from: parentOf)

        var nextActive = Set<String>()
        var touchedPIDs = Set<pid_t>()

        for app in apps {
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier ?? "pid.\(pid)"
            let appName = app.localizedName ?? bid
            let bundlePath = app.bundleURL?.path

            let memberPIDs = Self.memberPIDs(
                mainPID: pid,
                bundlePath: bundlePath,
                appName: appName,
                bundleID: app.bundleIdentifier,
                pathByPID: pathByPID,
                childrenOf: childrenOf
            )

            var cpuDelta: Double = 0
            for member in memberPIDs {
                touchedPIDs.insert(member)
                guard let cpuNow = Self.cpuSeconds(for: member) else { continue }
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
            // Focus, real CPU across the whole app family, or sticky after a recent burst.
            let shouldCredit = isFront || cpuWorking || sticky

            if shouldCredit {
                acc.seconds += delta
                if !isFront {
                    acc.backgroundSeconds += delta
                }
                nextActive.insert(bid)
            }

            // Keep rows we have already seen this session (so Claude does not vanish).
            if acc.seconds > 0 || shouldCredit || hasWindow && cpuWorking {
                totals[bid] = acc
            }
        }

        activeKeys = nextActive
        lastCPU = lastCPU.filter { touchedPIDs.contains($0.key) }

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
            guard layer == 0 else { continue }
            if !allSpaces {
                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                guard alpha > 0.05 else { continue }
            }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
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
        // Query required buffer size first — a fixed 4096-pid cap silently drops
        // high-numbered helpers (common for Electron apps like Claude).
        let neededBytes = proc_listallpids(nil, 0)
        guard neededBytes > 0 else { return [:] }
        let count = Int(neededBytes) / MemoryLayout<pid_t>.size + 128
        var pids = [pid_t](repeating: 0, count: count)
        let bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [:] }
        let filled = Int(bytes) / MemoryLayout<pid_t>.size

        var map: [pid_t: String] = [:]
        map.reserveCapacity(filled)
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for i in 0..<filled {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard n > 0 else { continue }
            map[pid] = String(cString: pathBuf)
        }
        return map
    }

    private static func parentMap(for pids: [pid_t]) -> [pid_t: pid_t] {
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(pids.count)
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids {
            var info = proc_bsdinfo()
            let n = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
            }
            guard n == size else { continue }
            map[pid] = pid_t(info.pbi_ppid)
        }
        return map
    }

    private static func childrenMap(from parentOf: [pid_t: pid_t]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parentOf {
            children[parent, default: []].append(pid)
        }
        return children
    }

    private static func descendants(of root: pid_t, childrenOf: [pid_t: [pid_t]]) -> Set<pid_t> {
        var result: Set<pid_t> = []
        var stack = [root]
        while let current = stack.popLast() {
            for child in childrenOf[current] ?? [] {
                if result.insert(child).inserted {
                    stack.append(child)
                }
            }
        }
        return result
    }

    /// Support folders where apps (esp. Claude) park nested workers outside the .app bundle.
    private static func supportRoots(appName: String, bundleID: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var roots: [String] = []
        let candidates = [
            appName,
            bundleID,
            bundleID?.components(separatedBy: ".").last
        ].compactMap { $0 }.filter { !$0.isEmpty }

        var seen = Set<String>()
        for name in candidates {
            let path = support.appendingPathComponent(name, isDirectory: true).path
            if seen.insert(path.lowercased()).inserted {
                roots.append(path)
            }
        }
        return roots
    }

    private static func memberPIDs(
        mainPID: pid_t,
        bundlePath: String?,
        appName: String,
        bundleID: String?,
        pathByPID: [pid_t: String],
        childrenOf: [pid_t: [pid_t]]
    ) -> Set<pid_t> {
        var members: Set<pid_t> = [mainPID]

        // 1) Everything executing from inside the .app bundle (Electron Helpers, etc.).
        if let bundlePath, !bundlePath.isEmpty {
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            for (pid, path) in pathByPID {
                if path == bundlePath || path.hasPrefix(prefix) {
                    members.insert(pid)
                }
            }
        }

        // 2) Nested workers under ~/Library/Application Support/<App>/…
        //    Claude runs agent work from Application Support/Claude/claude-code/.../claude
        //    which is outside /Applications/Claude.app.
        for root in supportRoots(appName: appName, bundleID: bundleID) {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            for (pid, path) in pathByPID {
                if path.hasPrefix(prefix) {
                    members.insert(pid)
                }
            }
        }

        // 3) Full process tree under the main app pid (covers helpers we miss by path).
        members.formUnion(descendants(of: mainPID, childrenOf: childrenOf))

        // Also pull descendants of every path-matched member (support workers spawn kids).
        let pathMatched = members
        for seed in pathMatched {
            members.formUnion(descendants(of: seed, childrenOf: childrenOf))
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
