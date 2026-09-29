import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import UserNotifications

struct AppUsageRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let detail: String?
    let duration: TimeInterval
    let wasBackgroundWork: Bool
    let isActiveNow: Bool
    /// False once the app process has quit; the duration is frozen.
    let isRunning: Bool
    /// Recent clock-time spans, newest last. Example: "2:14–2:41 working".
    let timeline: [String]
}

/// Tracks how long MacStayOn has been On and which apps were doing work.
///
/// Detection uses (in order of reliability for Electron/agent apps like Claude):
/// 1. Live workers under `~/Library/Application Support/<App>/` (agent sessions)
/// 2. `ps` CPU % across the app family (works for sandboxed helpers; rusage often does not)
/// 3. Frontmost focus + sticky window after recent activity
final class SessionAnalytics: ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var topApps: [AppUsageRow] = []
    @Published private(set) var hasSummary = false

    private struct Span {
        var phase: String
        var start: Date
        var end: Date
    }

    private struct Acc {
        var name: String
        var detail: String?
        var seconds: TimeInterval
        var backgroundSeconds: TimeInterval
        var lastActiveAt: Date?
        var spans: [Span] = []

        mutating func note(phase: String, at now: Date, started: Date? = nil) {
            if var last = spans.last, last.phase == phase {
                last.end = now
                spans[spans.count - 1] = last
                return
            }
            if !spans.isEmpty {
                spans[spans.count - 1].end = now
            }
            spans.append(Span(phase: phase, start: started ?? now, end: now))
            if spans.count > 8 {
                spans.removeFirst(spans.count - 8)
            }
        }

        func timelineLines(now: Date) -> [String] {
            spans.suffix(3).map { span in
                let end = span.end
                let endLabel = abs(now.timeIntervalSince(end)) < 2 ? "now" : SessionAnalytics.clock(end)
                return "\(SessionAnalytics.clock(span.start))–\(endLabel) \(span.phase)"
            }
        }
    }

    private var sessionStartedAt: Date?
    private var totals: [String: Acc] = [:]
    private var tick: Timer?
    private var lastSampleAt: Date?
    private var ownPID: pid_t = 0
    private var activeKeys: Set<String> = []
    private var runningKeys: Set<String> = []
    /// When CPU went quiet and the app was not frontmost. Cleared when work resumes.
    private var quietSince: [String: Date] = [:]
    private var stallNotified: Set<String> = []

    /// Combined `ps` %CPU across the app family to count as working.
    private let cpuPercentThreshold: Double = 1.0
    private let stickyActive: TimeInterval = 60
    /// Quiet this long (not frontmost, low CPU) before a stall notification.
    private let stallNotifyAfter: TimeInterval = 120
    private let maxRows = 12

    func start() {
        tearDownObservers()
        ownPID = ProcessInfo.processInfo.processIdentifier
        sessionStartedAt = Date()
        lastSampleAt = Date()
        activeKeys = []
        runningKeys = []
        quietSince = [:]
        stallNotified = []
        elapsed = 0
        totals = [:]
        topApps = []
        hasSummary = false
        isLive = true
        Self.requestNotificationPermission()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
        sample()
    }

    func stopAndRetainSummary() {
        sample(final: true)
        tearDownObservers()
        if let sessionStartedAt {
            elapsed = Date().timeIntervalSince(sessionStartedAt)
        }
        activeKeys = []
        runningKeys = []
        quietSince = [:]
        stallNotified = []
        publishApps()
        isLive = false
        hasSummary = elapsed > 0 || !topApps.isEmpty
        sessionStartedAt = nil
        lastSampleAt = nil
    }

    func clear() {
        tearDownObservers()
        sessionStartedAt = nil
        lastSampleAt = nil
        activeKeys = []
        runningKeys = []
        quietSince = [:]
        stallNotified = []
        totals = [:]
        topApps = []
        elapsed = 0
        isLive = false
        hasSummary = false
    }

    private static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postStallNotification(appName: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) stalled"
        content.body = "Stopped working at \(clock(date)). It may be waiting on you."
        content.sound = .default
        let id = "stall-\(appName)-\(Int(date.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

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
        let cpuPercent = Self.cpuPercentByPID()

        var nextActive = Set<String>()
        var nextRunning = Set<String>()

        for app in apps {
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier ?? "pid.\(pid)"
            let appName = app.localizedName ?? bid
            nextRunning.insert(bid)
            let bundlePath = app.bundleURL?.path
            let roots = Self.supportRoots(appName: appName, bundleID: app.bundleIdentifier)

            let memberPIDs = Self.memberPIDs(
                mainPID: pid,
                bundlePath: bundlePath,
                supportRoots: roots,
                pathByPID: pathByPID,
                childrenOf: childrenOf
            )

            var familyCPU = 0.0
            for member in memberPIDs {
                familyCPU += cpuPercent[member] ?? 0
            }

            // Nested agent CLIs (Claude Code under Application Support) — alive ⇒ working,
            // even when waiting on the network with near-zero CPU.
            let supportWorkerCount = memberPIDs.filter { member in
                guard let path = pathByPID[member] else { return false }
                return roots.contains { root in
                    let prefix = root.hasSuffix("/") ? root : root + "/"
                    return path.hasPrefix(prefix)
                }
            }.count

            let isFront = pid == frontPID
            let hasWindow = pidsWithWindows.contains(pid)
                || memberPIDs.contains(where: { pidsWithWindows.contains($0) })
            let cpuWorking = familyCPU >= cpuPercentThreshold
            let agentsAlive = supportWorkerCount > 0

            var acc = totals[bid] ?? Acc(
                name: appName,
                detail: nil,
                seconds: 0,
                backgroundSeconds: 0,
                lastActiveAt: nil
            )
            acc.name = appName

            let titles = Self.preferredTitles(
                windowTitlesByPID[pid] ?? memberPIDs.flatMap { windowTitlesByPID[$0] ?? [] },
                appName: appName
            )
            if let best = titles.first {
                acc.detail = best
            } else if agentsAlive {
                acc.detail = supportWorkerCount == 1
                    ? "1 agent session"
                    : "\(supportWorkerCount) agent sessions"
            }

            if cpuWorking || isFront || agentsAlive {
                acc.lastActiveAt = now
            }

            let sticky = acc.lastActiveAt.map { now.timeIntervalSince($0) <= stickyActive } ?? false
            let shouldCredit = isFront || cpuWorking || agentsAlive || sticky

            let cpuQuiet = !cpuWorking && !isFront
            if cpuQuiet {
                if quietSince[bid] == nil {
                    quietSince[bid] = now
                }
            } else {
                quietSince[bid] = nil
                stallNotified.remove(bid)
            }
            let quietFor = quietSince[bid].map { now.timeIntervalSince($0) } ?? 0
            let stalled = acc.seconds > 0 && cpuQuiet && quietFor >= stallNotifyAfter

            if stalled {
                let stalledAt = quietSince[bid] ?? now
                acc.note(phase: "stalled", at: now, started: stalledAt)
                totals[bid] = acc
                if stallNotified.insert(bid).inserted {
                    Self.postStallNotification(appName: acc.name, at: stalledAt)
                }
            } else if shouldCredit {
                acc.seconds += delta
                if !isFront {
                    acc.backgroundSeconds += delta
                }
                acc.note(phase: "working", at: now)
                nextActive.insert(bid)
                totals[bid] = acc
            } else if acc.seconds > 0 {
                acc.note(phase: "stalled", at: now)
                totals[bid] = acc
            } else if hasWindow {
                totals[bid] = acc
            }
        }

        let sampleNow = now
        for key in Array(totals.keys) {
            guard var acc = totals[key], acc.seconds > 0, !nextRunning.contains(key) else { continue }
            acc.note(phase: "stopped", at: sampleNow)
            totals[key] = acc
            quietSince[key] = nil
            stallNotified.remove(key)
        }

        activeKeys = nextActive
        runningKeys = nextRunning
        // Apps that quit stay in `totals` with a frozen duration — they are not removed.
        publishApps()
    }

    private func publishApps() {
        topApps = totals
            .filter { $0.value.seconds > 0 }
            .map { key, acc in
                let running = isLive && runningKeys.contains(key)
                return AppUsageRow(
                    key: key,
                    name: acc.name,
                    detail: acc.detail,
                    duration: acc.seconds,
                    wasBackgroundWork: acc.backgroundSeconds > acc.seconds * 0.5,
                    isActiveNow: isLive && activeKeys.contains(key),
                    isRunning: running,
                    timeline: acc.timelineLines(now: Date())
                )
            }
            .sorted {
                if $0.isActiveNow != $1.isActiveNow { return $0.isActiveNow && !$1.isActiveNow }
                if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
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

    /// `ps` %CPU — reliable for sandboxed Electron helpers where `proc_pid_rusage` fails.
    private static func cpuPercentByPID() -> [pid_t: Double] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,pcpu="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return [:]
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var map: [pid_t: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1])
            else { continue }
            map[pid, default: 0] += cpu
        }
        return map
    }

    private static func processPaths() -> [pid_t: String] {
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
        // Claude Desktop also uses this exact folder name.
        if appName.localizedCaseInsensitiveContains("claude")
            || (bundleID?.localizedCaseInsensitiveContains("anthropic") ?? false)
        {
            let claude = support.appendingPathComponent("Claude", isDirectory: true).path
            if seen.insert(claude.lowercased()).inserted {
                roots.append(claude)
            }
        }
        return roots
    }

    private static func memberPIDs(
        mainPID: pid_t,
        bundlePath: String?,
        supportRoots: [String],
        pathByPID: [pid_t: String],
        childrenOf: [pid_t: [pid_t]]
    ) -> Set<pid_t> {
        var members: Set<pid_t> = [mainPID]

        if let bundlePath, !bundlePath.isEmpty {
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            for (pid, path) in pathByPID {
                if path == bundlePath || path.hasPrefix(prefix) {
                    members.insert(pid)
                }
            }
        }

        for root in supportRoots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            for (pid, path) in pathByPID {
                if path.hasPrefix(prefix) {
                    members.insert(pid)
                }
            }
        }

        let seeds = members
        for seed in seeds {
            members.formUnion(descendants(of: seed, childrenOf: childrenOf))
        }

        return members
    }
}
