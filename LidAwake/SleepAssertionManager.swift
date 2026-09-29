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
    private static let defaultsKey = "lidStayAwakeEnabled"
    private static let savedPrevKey = "savedDisablesleepValue"
    private static let assertionName = "LidAwake: keep system awake with lid closed" as CFString

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDetail: String?
    @Published private(set) var lastError: String?

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var isActivating = false
    private var didFinishLaunchSetup = false

    private var stateDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LidAwake-\(NSUserName())", isDirectory: true)
    }

    private var prevFile: URL { stateDir.appendingPathComponent("disablesleep.prev") }
    private var sentinelFile: URL { stateDir.appendingPathComponent("restore.sentinel") }
    private var watchdogPidFile: URL { stateDir.appendingPathComponent("watchdog.pid") }
    private var enableScriptFile: URL { stateDir.appendingPathComponent("enable-watchdog.sh") }

    deinit {
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

    private static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any],
              let state = desc[kIOPSPowerSourceStateKey] as? String
        else {
            return false
        }
        return state == kIOPSACPowerValue
    }
}
