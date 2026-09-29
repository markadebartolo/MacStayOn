import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake with the lid closed — including on battery — by:
/// 1. `pmset -a disablesleep 1` (requires admin; the reliable lid-sleep block)
/// 2. An IOKit `PreventSystemSleep` assertion (extra belt-and-suspenders)
///
/// On enable, a privileged watchdog is started (one admin dialog). It restores
/// the previous `disablesleep` value when the app asks (sentinel file) or when
/// the app process exits — so sleep is not left disabled after a clean quit.
final class SleepAssertionManager: ObservableObject {
    private static let defaultsKey = "macStayOnEnabled"
    private static let savedPrevKey = "savedDisablesleepValue"
    private static let guardEnabledKey = "macStayOnGuardEnabled"
    private static let batteryFloorKey = "macStayOnBatteryFloor"
    private static let assertionName = "MacStayOn: keep system awake with lid closed" as CFString

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDetail: String?
    @Published private(set) var lastError: String?
    @Published private(set) var guardEnabled: Bool
    @Published private(set) var batteryFloor: Int
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onACPower: Bool = false
    @Published private(set) var thermalLabel: String = "cool"

    private var guardTimer: Timer?
    private var guardTripping = false

    let analytics = SessionAnalytics()

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var isActivating = false
    private var didFinishLaunchSetup = false
    private let lidMonitor = LidMonitor()
    private var lidWasClosedWhileEnabled = false
    private var isPromptingLidOpen = false

    private var stateDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStayOn-\(NSUserName())", isDirectory: true)
    }

    private var prevFile: URL { stateDir.appendingPathComponent("disablesleep.prev") }
    private var sentinelFile: URL { stateDir.appendingPathComponent("restore.sentinel") }
    private var watchdogPidFile: URL { stateDir.appendingPathComponent("watchdog.pid") }
    private var enableScriptFile: URL { stateDir.appendingPathComponent("enable-watchdog.sh") }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.guardEnabledKey) == nil {
            guardEnabled = true
        } else {
            guardEnabled = defaults.bool(forKey: Self.guardEnabledKey)
        }
        let storedFloor = defaults.object(forKey: Self.batteryFloorKey) as? Int
        batteryFloor = Self.clampFloor(storedFloor ?? 20)
        startGuardMonitor()
    }

    deinit {
        guardTimer?.invalidate()
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
        }
    }

    /// Call once the menu bar UI is up (or from AppDelegate.didFinishLaunching).
    func applyPersistedStateIfNeeded() {
        guard !didFinishLaunchSetup else { return }
        didFinishLaunchSetup = true
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if UserDefaults.standard.bool(forKey: Self.defaultsKey) {
            setEnabled(true)
        } else {
            refreshStatusDetail()
        }
    }

    /// Call from AppDelegate on terminate so pmset is restored even if SwiftUI
    /// quit handling is skipped.
    func prepareForTermination() {
        if isEnabled || hasAssertion || FileManager.default.fileExists(atPath: prevFile.path) {
            deactivate(persistOff: true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            activate()
        } else {
            deactivate(persistOff: true)
        }
    }

    func setGuardEnabled(_ enabled: Bool) {
        guardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.guardEnabledKey)
        evaluateGuard()
    }

    func setBatteryFloor(_ percent: Int) {
        let clamped = Self.clampFloor(percent)
        batteryFloor = clamped
        UserDefaults.standard.set(clamped, forKey: Self.batteryFloorKey)
        evaluateGuard()
    }

    private static func clampFloor(_ percent: Int) -> Int {
        min(50, max(10, percent))
    }

    /// Interactive Turn On from the menu: heat warning first, then admin/pmset flow.
    /// Cancel leaves the feature Off. Not used when turning Off.
    func requestEnableFromUser() {
        if isEnabled {
            refreshStatusDetail()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Keep Mac awake with lid closed?"
        alert.informativeText = """
        MacStayOn will prevent sleep when you close the lid so agents and other work can keep running.

        A closed Mac can overheat in a confined space. Do not put it in a bag, under a blanket, or in another enclosed space while this is on.
        """
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            activate()
        } else {
            isEnabled = false
            lastError = nil
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            refreshStatusDetail()
        }
    }

    // MARK: - Activate

    private func activate() {
        if isEnabled && hasAssertion {
            refreshStatusDetail()
            return
        }
        if isActivating { return }
        isActivating = true
        defer { isActivating = false }

        lastError = nil
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: sentinelFile)

        let pid = ProcessInfo.processInfo.processIdentifier
        let prevPath = prevFile.path
        let sentinelPath = sentinelFile.path
        let watchdogPidPath = watchdogPidFile.path
        let statePath = stateDir.path

        let script = """
        #!/bin/bash
        set -euo pipefail
        mkdir -p '\(Self.sq(statePath))'
        PREV=$(pmset -g | awk '/disablesleep/ { print $2; exit }' || true)
        if [ -z "${PREV}" ]; then PREV=0; fi
        printf '%s' "${PREV}" > '\(Self.sq(prevPath))'
        chmod 644 '\(Self.sq(prevPath))'
        pmset -a disablesleep 1
        if [ -f '\(Self.sq(watchdogPidPath))' ]; then
          OLD=$(cat '\(Self.sq(watchdogPidPath))' 2>/dev/null || true)
          if [ -n "${OLD}" ]; then kill "${OLD}" 2>/dev/null || true; fi
        fi
        nohup /bin/bash -c '
          PREV_FILE="\(Self.dq(prevPath))"
          SENTINEL="\(Self.dq(sentinelPath))"
          WATCHDOG_PID_FILE="\(Self.dq(watchdogPidPath))"
          APP_PID=\(pid)
          PREV=$(cat "$PREV_FILE" 2>/dev/null || echo 0)
          while kill -0 "$APP_PID" 2>/dev/null; do
            if [ -f "$SENTINEL" ]; then
              break
            fi
            sleep 1
          done
          pmset -a disablesleep "${PREV:-0}"
          rm -f "$SENTINEL" "$PREV_FILE" "$WATCHDOG_PID_FILE"
        ' >/dev/null 2>&1 &
        echo $! > '\(Self.sq(watchdogPidPath))'
        chmod 644 '\(Self.sq(watchdogPidPath))'
        printf '%s\\n' "${PREV}"
        """

        do {
            try script.write(to: enableScriptFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: enableScriptFile.path
            )
        } catch {
            isEnabled = false
            lastError = "Could not prepare enable script — stayed Off."
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            refreshStatusDetail()
            return
        }

        switch Self.runAdminCommand("/bin/bash", arguments: [enableScriptFile.path]) {
        case .success(let prev):
            let trimmed = prev.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: Self.savedPrevKey)
            }
            _ = createAssertion()
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            startSessionHelpers()
            refreshStatusDetail()
        case .cancelled:
            isEnabled = false
            lastError = "Admin authorization canceled — stayed Off."
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            refreshStatusDetail()
        case .failure(let message):
            isEnabled = false
            lastError = "Admin authorization failed — stayed Off. \(message)"
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            refreshStatusDetail()
        }
    }

    // MARK: - Deactivate

    private func deactivate(persistOff: Bool) {
        stopSessionHelpers(retainAnalytics: true)
        requestWatchdogRestore()
        releaseAssertion()

        isEnabled = false
        if persistOff {
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if currentDisablesleep() == 0 { break }
            Thread.sleep(forTimeInterval: 0.15)
        }

        // Last-resort restore if watchdog did not clear it (may prompt).
        if currentDisablesleep() != 0 {
            let prev = UserDefaults.standard.string(forKey: Self.savedPrevKey) ?? "0"
            let safePrev = prev.allSatisfy(\.isNumber) ? prev : "0"
            _ = Self.runAdminCommand("/usr/bin/pmset", arguments: ["-a", "disablesleep", safePrev])
        }

        UserDefaults.standard.removeObject(forKey: Self.savedPrevKey)
        lastError = nil
        refreshStatusDetail()
    }

    // MARK: - Session helpers (analytics + lid)

    private func startSessionHelpers() {
        lidWasClosedWhileEnabled = false
        isPromptingLidOpen = false
        analytics.start()
        lidMonitor.onClamshellChange = { [weak self] closed in
            self?.handleClamshellChange(closed: closed)
        }
        lidMonitor.start()
    }

    private func stopSessionHelpers(retainAnalytics: Bool) {
        lidMonitor.stop()
        lidMonitor.onClamshellChange = nil
        if retainAnalytics {
            analytics.stopAndRetainSummary()
        } else {
            analytics.clear()
        }
        lidWasClosedWhileEnabled = false
    }

    private func handleClamshellChange(closed: Bool) {
        guard isEnabled else { return }
        if closed {
            lidWasClosedWhileEnabled = true
            return
        }
        guard lidWasClosedWhileEnabled, !isPromptingLidOpen else { return }
        lidWasClosedWhileEnabled = false
        isPromptingLidOpen = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isEnabled else {
                self?.isPromptingLidOpen = false
                return
            }
            self.promptTurnOffAfterLidOpen()
            self.isPromptingLidOpen = false
        }
    }

    private func promptTurnOffAfterLidOpen() {
        let elapsed = SessionAnalytics.formatDuration(analytics.elapsed)

        let alert = NSAlert()
        alert.messageText = "Lid opened — turn MacStayOn off?"
        alert.informativeText = """
        Stay Awake was on for \(elapsed) while the lid was closed.

        Turn it off to restore normal lid sleep, or keep it on for another closed-lid session.
        """
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "laptopcomputer.and.arrow.down", accessibilityDescription: nil)
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Keep On")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            setEnabled(false)
        }
    }

    private func requestWatchdogRestore() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sentinelFile.path, contents: Data(), attributes: nil)
    }

    // MARK: - Assertion

    @discardableResult
    private func createAssertion() -> Bool {
        if hasAssertion { return true }
        var newID: IOPMAssertionID = 0
        let type = kIOPMAssertionTypePreventSystemSleep as CFString
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
            hasAssertion = true
            return true
        }
        return false
    }

    private func releaseAssertion() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            hasAssertion = false
        }
    }

    // MARK: - Status

    private func startGuardMonitor() {
        guardTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.evaluateGuard()
        }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
        evaluateGuard()
    }

    /// While Stay Awake is on, turn it off if the battery is at or below the floor
    /// (on battery only) or the Mac reports serious/critical thermal pressure.
    private func evaluateGuard() {
        let snapshot = Self.powerSnapshot()
        onACPower = snapshot.onAC
        batteryPercent = snapshot.percent
        let thermal = ProcessInfo.processInfo.thermalState
        switch thermal {
        case .critical: thermalLabel = "critical heat"
        case .serious: thermalLabel = "serious heat"
        case .fair: thermalLabel = "warm"
        default: thermalLabel = "cool"
        }

        guard isEnabled, guardEnabled, !guardTripping else { return }

        if thermal == .serious || thermal == .critical {
            tripGuard("Turned off — Mac reported \(thermalLabel). Unplug it from a confined space before turning Stay Awake back on.")
            return
        }
        if !snapshot.onAC, let percent = snapshot.percent, percent <= batteryFloor {
            tripGuard("Turned off — battery at \(percent)% (floor \(batteryFloor)%).")
        }
    }

    private func tripGuard(_ message: String) {
        guard isEnabled else { return }
        guardTripping = true
        setEnabled(false)
        lastError = message
        statusDetail = message
        guardTripping = false
    }

    private func refreshStatusDetail() {
        if let lastError {
            statusDetail = lastError
            return
        }

        let onAC = Self.isOnACPower()
        let power = onAC ? "AC power" : "on battery"
        let disablesleep = currentDisablesleep()

        if isEnabled {
            statusDetail = "disablesleep=\(disablesleep) · assertion \(hasAssertion ? "on" : "off") · \(power)"
        } else {
            statusDetail = "Normal lid sleep · \(power)"
        }
    }

    private func currentDisablesleep() -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, parts[0] == "disablesleep", let v = Int(parts[1]) {
                    return v
                }
            }
        } catch {}
        return 0
    }

    // MARK: - Admin command

    private enum AdminResult {
        case success(String)
        case cancelled
        case failure(String)
    }

    private static func runAdminCommand(_ executable: String, arguments: [String]) -> AdminResult {
        let joined = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let appleSource = "do shell script \(appleStringLiteral(joined)) with administrator privileges"

        var error: NSDictionary?
        guard let script = NSAppleScript(source: appleSource) else {
            return .failure("Could not build authorization script.")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {
                return .cancelled
            }
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error (\(code))"
            return .failure(msg)
        }
        return .success(result.stringValue ?? "")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleStringLiteral(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func sq(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func dq(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private struct PowerSnapshot {
        var onAC: Bool
        var percent: Int?
    }

    private static func powerSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any]
        else {
            return PowerSnapshot(onAC: false, percent: nil)
        }
        let state = desc[kIOPSPowerSourceStateKey] as? String
        let onAC = state == kIOPSACPowerValue
        let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue
        let maxCap = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.intValue
        let percent: Int?
        if let current, let maxCap, maxCap > 0 {
            percent = Int((Double(current) / Double(maxCap) * 100).rounded())
        } else {
            percent = current
        }
        return PowerSnapshot(onAC: onAC, percent: percent)
    }

    private static func isOnACPower() -> Bool {
        powerSnapshot().onAC
    }
}
