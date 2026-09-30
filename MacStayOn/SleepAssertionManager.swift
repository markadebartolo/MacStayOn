import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake with the lid closed — including on battery — by:
/// 1. `pmset -a disablesleep 1` (requires admin; the reliable lid-sleep block)
/// 2. IOKit assertions: system sleep + display idle (blocks screensaver)
/// 3. `ProcessInfo` activity so App Nap / idle display sleep stay off
///
/// On enable, a privileged watchdog is started (one admin dialog). It restores
/// the previous `disablesleep` value when the app asks (sentinel file) or when
/// the app process exits — so sleep is not left disabled after a clean quit.
final class SleepAssertionManager: ObservableObject {
    private static let defaultsKey = "macStayOnEnabled"
    private static let savedPrevKey = "savedDisablesleepValue"
    private static let guardEnabledKey = "macStayOnGuardEnabled"
    private static let batteryFloorKey = "macStayOnBatteryFloor"
    private static let systemAssertionName = "MacStayOn: keep system awake with lid closed" as CFString
    private static let displayAssertionName = "MacStayOn: keep display awake (no screensaver)" as CFString

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDetail: String?
    @Published private(set) var lastError: String?
    @Published private(set) var guardEnabled: Bool
    @Published private(set) var batteryFloor: Int
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onACPower: Bool = false
    @Published private(set) var thermalLabel: String = "cool"
    /// e.g. "MacBook Pro · M5 Max" — shown next to AC/battery in the menu.
    @Published private(set) var machineLabel: String = ""

    private var guardTimer: Timer?
    private var guardTripping = false

    let analytics = SessionAnalytics()

    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var processActivity: NSObjectProtocol?
    private var isActivating = false
    private var didFinishLaunchSetup = false
    private let lidMonitor = LidMonitor()
    private let lidAngleMonitor = LidAngleMonitor()
    private var lidWasClosedWhileEnabled = false
    private var isPromptingLidOpen = false

    /// Last sampled lid angle (degrees). Nil until the sensor reports.
    private var lastLidAngle: Int?
    /// After flashing once for a close gesture, wait until the lid opens again.
    private var didFlashForCurrentClose = false

    /// Sensor degrees at/below which we warn (higher = earlier while closing).
    private static let lidWarnAngleDegrees = 85
    /// Must reopen past this before another warn can fire (hysteresis).
    private static let lidWarnResetAngleDegrees = 100

    /// Stable path (not NSTemporaryDirectory) so On/Off and the root watchdog
    /// always share the same sentinel/pid files for the login session.
    private var stateDir: URL {
        URL(fileURLWithPath: "/tmp/MacStayOn-\(NSUserName())", isDirectory: true)
    }

    private var prevFile: URL { stateDir.appendingPathComponent("disablesleep.prev") }
    private var sentinelFile: URL { stateDir.appendingPathComponent("restore.sentinel") }
    private var watchdogPidFile: URL { stateDir.appendingPathComponent("watchdog.pid") }
    private var enableScriptFile: URL { stateDir.appendingPathComponent("enable-watchdog.sh") }
    private var watchdogPythonFile: URL { stateDir.appendingPathComponent("watchdog.py") }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.guardEnabledKey) == nil {
            guardEnabled = true
        } else {
            guardEnabled = defaults.bool(forKey: Self.guardEnabledKey)
        }
        let storedFloor = defaults.object(forKey: Self.batteryFloorKey) as? Int
        batteryFloor = Self.clampFloor(storedFloor ?? 20)
        // Instant fallback from sysctl; marketing name/chip fill in after warmCache.
        machineLabel = HardwareProfile.readModelIdentifierForDisplay()
        startGuardMonitor()
    }

    func refreshMachineLabel() {
        let label = HardwareProfile.current.menuLabel
        if !label.isEmpty {
            machineLabel = label
        }
    }

    deinit {
        guardTimer?.invalidate()
        releaseAssertion()
    }

    /// Call once the menu bar UI is up (or from AppDelegate.didFinishLaunching).
    func applyPersistedStateIfNeeded() {
        guard !didFinishLaunchSetup else { return }
        didFinishLaunchSetup = true
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if UserDefaults.standard.bool(forKey: Self.defaultsKey) {
            setEnabled(true)
        } else {
            // Prior sessions could leave SleepDisabled=1 if the privileged
            // watchdog died before restore. Clear it so "Off" means normal lid sleep.
            if currentDisablesleep() != 0 {
                restoreDisablesleepWithAdmin(preferringSavedPrev: true)
            }
            cleanupStateFiles()
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
        alert.messageText = HardwareProfile.isMacBookAir
            ? "Keep MacBook Air awake with lid closed?"
            : "Keep Mac awake with lid closed?"
        alert.informativeText = HardwareProfile.enableHeatWarningBody
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
        let watchdogPidPath = watchdogPidFile.path
        let statePath = stateDir.path
        let watchdogPyPath = watchdogPythonFile.path

        // Root watchdog survives the auth dialog (setsid + ignore SIGHUP) and
        // restores disablesleep=0 when Off drops a sentinel — no second password.
        // Always restore to 0 (never re-apply a stuck SleepDisabled=1 as "prev").
        //
        // Do NOT launch with `nohup` under AppleScript `with administrator privileges`
        // (Touch ID or password). On modern macOS, nohup fails with
        // "can't detach from console: No such process" and the child exits
        // immediately — Turn On then reports watchdog_failed even after approval.
        let watchdogPython = """
        #!/usr/bin/env python3
        import errno, os, signal, subprocess, sys, time

        state = sys.argv[1]
        app_pid = int(sys.argv[2])
        sentinel = os.path.join(state, "restore.sentinel")
        prev = os.path.join(state, "disablesleep.prev")
        pid_file = os.path.join(state, "watchdog.pid")
        ready_file = os.path.join(state, "watchdog.ready")
        log_path = os.path.join(state, "watchdog.log")

        def log(msg):
            try:
                with open(log_path, "a") as f:
                    f.write(msg + "\\n")
            except OSError:
                pass

        def pid_alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False
            except PermissionError:
                return True
            except OSError as e:
                if e.errno == errno.ESRCH:
                    return False
                if e.errno == errno.EPERM:
                    return True
                return False

        try:
            os.setsid()
        except OSError:
            pass
        # Survive AppleScript's admin shell exit (SIGHUP). Keep SIGTERM so
        # a later Turn On can replace a stale watchdog.
        signal.signal(signal.SIGHUP, signal.SIG_IGN)

        # Detach stdio so the privileged parent shell can exit cleanly.
        try:
            devnull = open(os.devnull, "r+")
            os.dup2(devnull.fileno(), 0)
            os.dup2(devnull.fileno(), 1)
            os.dup2(devnull.fileno(), 2)
        except OSError:
            pass

        log("watchdog start app=%s euid=%s" % (app_pid, os.geteuid()))
        try:
            with open(ready_file, "w") as f:
                f.write(str(os.getpid()))
        except OSError:
            pass

        while True:
            alive = pid_alive(app_pid)
            if (not alive) or os.path.exists(sentinel):
                log("restore sleep app_alive=%s sentinel=%s euid=%s" % (
                    alive, os.path.exists(sentinel), os.geteuid()))
                break
            time.sleep(0.5)

        rc = subprocess.call(["/usr/bin/pmset", "-a", "disablesleep", "0"])
        log("pmset restore rc=%s" % rc)
        for p in (sentinel, prev, pid_file, ready_file):
            try:
                os.remove(p)
            except OSError:
                pass
        log("watchdog done")
        """

        let readyPath = stateDir.appendingPathComponent("watchdog.ready").path
        let script = """
        #!/bin/bash
        set -euo pipefail
        mkdir -p '\(Self.sq(statePath))'
        rm -f '\(Self.sq(readyPath))'
        printf '0' > '\(Self.sq(prevPath))'
        chmod 644 '\(Self.sq(prevPath))'
        /usr/bin/pmset -a disablesleep 1
        if [ -f '\(Self.sq(watchdogPidPath))' ]; then
          OLD=$(cat '\(Self.sq(watchdogPidPath))' 2>/dev/null || true)
          if [ -n "${OLD}" ]; then
            kill "${OLD}" 2>/dev/null || true
            sleep 0.2
            kill -9 "${OLD}" 2>/dev/null || true
          fi
        fi
        # Background + redirects only — never nohup (breaks under AppleScript admin).
        /usr/bin/python3 '\(Self.sq(watchdogPyPath))' '\(Self.sq(statePath))' '\(pid)' \
          </dev/null >/dev/null 2>&1 &
        WPID=$!
        echo "${WPID}" > '\(Self.sq(watchdogPidPath))'
        chmod 644 '\(Self.sq(watchdogPidPath))'
        disown "${WPID}" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          if [ -f '\(Self.sq(readyPath))' ] && kill -0 "${WPID}" 2>/dev/null; then
            echo "watchdog_ok"
            exit 0
          fi
          sleep 0.1
        done
        if kill -0 "${WPID}" 2>/dev/null; then
          echo "watchdog_ok"
          exit 0
        fi
        echo "watchdog_failed" >&2
        exit 1
        """
        do {
            try watchdogPython.write(to: watchdogPythonFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: watchdogPythonFile.path
            )
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
            lastError = Self.userFacingEnableFailure(message)
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            refreshStatusDetail()
        }
    }

    // MARK: - Deactivate

    private func deactivate(persistOff: Bool) {
        stopSessionHelpers(retainAnalytics: true)
        releaseAssertion()

        isEnabled = false
        if persistOff {
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        }

        // Prefer the root watchdog started at Turn On (no password). Only fall
        // back to an admin prompt if sleep is still disabled after a short wait.
        requestWatchdogRestore()

        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if currentDisablesleep() == 0 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if currentDisablesleep() != 0 {
            // Last resort — watchdog missing or lost privileges.
            _ = restoreDisablesleepWithAdmin(preferringSavedPrev: true)
        }

        UserDefaults.standard.removeObject(forKey: Self.savedPrevKey)
        if currentDisablesleep() == 0 {
            cleanupStateFiles()
            lastError = nil
        }
        refreshStatusDetail()
    }

    /// Restores `pmset disablesleep` / system-wide SleepDisabled via admin auth.
    @discardableResult
    private func restoreDisablesleepWithAdmin(preferringSavedPrev: Bool) -> Bool {
        let prev: String
        if preferringSavedPrev,
           let saved = UserDefaults.standard.string(forKey: Self.savedPrevKey),
           saved.allSatisfy(\.isNumber) {
            prev = saved
        } else if let disk = try? String(contentsOf: prevFile, encoding: .utf8),
                  disk.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy(\.isNumber) {
            prev = disk.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prev = "0"
        }

        switch Self.runAdminCommand("/usr/bin/pmset", arguments: ["-a", "disablesleep", prev]) {
        case .success:
            return currentDisablesleep() == 0 || Int(prev) == currentDisablesleep()
        case .cancelled:
            lastError = "Admin canceled — sleep may still be disabled. Turn Off again to restore lid sleep."
            return false
        case .failure(let message):
            lastError = "Could not restore lid sleep. \(message)"
            return false
        }
    }

    private func cleanupStateFiles() {
        let logFile = stateDir.appendingPathComponent("watchdog.log")
        let readyFile = stateDir.appendingPathComponent("watchdog.ready")
        for url in [sentinelFile, prevFile, watchdogPidFile, enableScriptFile, watchdogPythonFile, logFile, readyFile] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Session helpers (analytics + lid)

    private func startSessionHelpers() {
        lidWasClosedWhileEnabled = false
        isPromptingLidOpen = false
        lastLidAngle = nil
        didFlashForCurrentClose = false
        analytics.start()
        lidMonitor.onClamshellChange = { [weak self] closed in
            self?.handleClamshellChange(closed: closed)
        }
        lidMonitor.start()
        startLidAngleWatch()
    }

    private func stopSessionHelpers(retainAnalytics: Bool) {
        lidMonitor.stop()
        lidMonitor.onClamshellChange = nil
        stopLidAngleWatch()
        ScreenFlashAlert.cancel()
        if retainAnalytics {
            analytics.stopAndRetainSummary()
        } else {
            analytics.clear()
        }
        lidWasClosedWhileEnabled = false
        lastLidAngle = nil
        didFlashForCurrentClose = false
    }

    private func startLidAngleWatch() {
        lidAngleMonitor.onAngleChange = { [weak self] degrees in
            self?.handleLidAngle(degrees)
        }
        lidAngleMonitor.start()
    }

    private func stopLidAngleWatch() {
        lidAngleMonitor.onAngleChange = nil
        lidAngleMonitor.stop()
    }

    private func handleLidAngle(_ degrees: Int) {
        guard isEnabled else { return }
        let previous = lastLidAngle
        lastLidAngle = degrees

        // Re-opened past the warn angle — stop blinking; another close can warn again.
        if degrees > Self.lidWarnAngleDegrees {
            ScreenFlashAlert.cancel()
            didFlashForCurrentClose = false
        }

        // Crossing down through the warn angle (must have been open above it first).
        let crossedDown = previous != nil
            && previous! > Self.lidWarnAngleDegrees
            && degrees <= Self.lidWarnAngleDegrees
        guard crossedDown else { return }
        guard !lidWasClosedWhileEnabled else { return }
        guard !didFlashForCurrentClose else { return }

        didFlashForCurrentClose = true
        // File log helps verify crossing without relying on the screen alone.
        let line = "WARN cross prev=\(previous.map(String.init) ?? "nil") now=\(degrees)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/macstayon-lid.log")
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
        ScreenFlashAlert.flashStayAwakeWarning()
    }

    private func handleClamshellChange(closed: Bool) {
        guard isEnabled else { return }
        if closed {
            lidWasClosedWhileEnabled = true
            // Closing warning is only while the lid is in motion — stop once shut.
            ScreenFlashAlert.cancel()
            return
        }
        guard lidWasClosedWhileEnabled, !isPromptingLidOpen else { return }
        lidWasClosedWhileEnabled = false
        isPromptingLidOpen = true
        // Latch also clears via angle hysteresis when past reset angle.
        didFlashForCurrentClose = false

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

    /// Holds system + display-idle assertions for the whole Stay Awake session
    /// (lid open or closed). Display idle is what keeps the screensaver off.
    @discardableResult
    private func createAssertion() -> Bool {
        ensureAssertionsHeld()
        return hasAssertion
    }

    /// Create any missing assertions. Safe to call periodically while enabled.
    private func ensureAssertionsHeld() {
        if systemAssertionID == 0 {
            var systemID: IOPMAssertionID = 0
            let systemResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.systemAssertionName,
                &systemID
            )
            if systemResult == kIOReturnSuccess {
                systemAssertionID = systemID
            }
        }

        // Screensaver / display dim are driven by user-idle display sleep.
        // This must stay on whenever Stay Awake is enabled — including lid open.
        if displayAssertionID == 0 {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.displayAssertionName,
                &displayID
            )
            if displayResult == kIOReturnSuccess {
                displayAssertionID = displayID
            }
        }

        // Also block idle system sleep (some policies check this separately).
        // Reuse display slot naming via a third assertion id if we add one later;
        // ProcessInfo covers App Nap / idle display for the process.
        if processActivity == nil {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .idleDisplaySleepDisabled,
                    .idleSystemSleepDisabled,
                    .suddenTerminationDisabled,
                    .automaticTerminationDisabled,
                    .userInitiated,
                ],
                reason: "MacStayOn stay awake — no screensaver"
            )
        }

        hasAssertion = systemAssertionID != 0 && displayAssertionID != 0
    }

    private func releaseAssertion() {
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        hasAssertion = false
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

        // While enabled (lid open or closed), keep screensaver/display assertions alive.
        if isEnabled {
            ensureAssertionsHeld()
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
            statusDetail = "SleepDisabled=\(disablesleep) · system \(systemAssertionID != 0 ? "on" : "off") · display/screensaver \(displayAssertionID != 0 ? "on" : "off") · \(power)"
        } else if disablesleep != 0 {
            statusDetail = "Sleep still disabled (SleepDisabled=\(disablesleep)) — turn Off again to restore"
        } else {
            statusDetail = "Normal lid sleep · \(power)"
        }
    }

    /// Reads system-wide sleep-disabled flag. On current macOS, `pmset -g`
    /// reports this as `SleepDisabled` under "System-wide power settings", not
    /// as `disablesleep` in the "Currently in use" block.
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
                guard parts.count >= 2 else { continue }
                let key = parts[0].lowercased()
                if key == "disablesleep" || key == "sleepdisabled", let v = Int(parts[1]) {
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

    /// Map raw admin/watchdog failures to short menu copy (no internal tokens).
    private static func userFacingEnableFailure(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("watchdog_failed") {
            return "Couldn't start the sleep watchdog after admin approval — stayed Off. Try Turn On again."
        }
        if lowered.contains("not authorized") || lowered.contains("authorization") {
            return "Admin authorization failed — stayed Off."
        }
        // Prefer a clean prefix; keep a short hint only when it helps.
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Admin authorization failed — stayed Off."
        }
        if trimmed.count <= 80, !trimmed.contains("\n") {
            return "Couldn't enable Stay Awake — stayed Off. \(trimmed)"
        }
        return "Couldn't enable Stay Awake after admin approval — stayed Off."
    }

    private static func runAdminCommand(_ executable: String, arguments: [String]) -> AdminResult {
        let joined = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        // Prompt text is shown on the Security Agent dialog. Touch ID itself requires a
        // Team-ID-signed app (see scripts/build.sh) — ad-hoc builds are often password-only.
        let prompt = "MacStayOn needs admin to change lid-sleep settings. Use Touch ID if offered, or enter your password."
        let appleSource = "do shell script \(appleStringLiteral(joined)) with administrator privileges with prompt \(appleStringLiteral(prompt))"

        // Frontmost + Team-ID-signed builds get Touch ID on this dialog; ad-hoc often password-only.
        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.sync {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

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
