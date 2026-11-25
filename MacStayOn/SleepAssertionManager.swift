import AppKit
import Combine
import Darwin
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
    enum AdminResult {
        case success(String)
        case cancelled
        case failure(String)
    }

    enum CriticalAlertChoice {
        case restoreNow
        case later
    }

    /// Everything the manager touches outside its own process. The live values talk
    /// to `pmset`, the admin prompt and AppKit; the test suite swaps in fakes so the
    /// On/Off state machine can be exercised without root.
    struct Environment {
        var stateDirectory: URL
        var defaults: UserDefaults
        /// nil → read the real system-wide flag with `pmset -g`.
        var readSleepDisabled: (() -> Int?)?
        /// nil → real `do shell script … with administrator privileges`.
        var runAdminCommand: ((_ executable: String, _ arguments: [String]) -> AdminResult)?
        /// nil → real modal `NSAlert`.
        var presentCriticalAlert: (() -> CriticalAlertChoice)?
        /// Lid sensor / clamshell monitors and the python3 preflight (hardware + host specific).
        var usesHostIntegrations: Bool
        /// How long Off waits for the root watchdog before treating lid sleep as stuck.
        var watchdogRestoreTimeout: TimeInterval = 5

        static var live: Environment {
            Environment(
                stateDirectory: URL(fileURLWithPath: "/tmp/MacStayOn-\(NSUserName())", isDirectory: true),
                defaults: .standard,
                readSleepDisabled: nil,
                runAdminCommand: nil,
                presentCriticalAlert: nil,
                usesHostIntegrations: true
            )
        }
    }

    private let environment: Environment
    private var defaults: UserDefaults { environment.defaults }

    private static let defaultsKey = "macStayOnEnabled"
    private static let savedPrevKey = "savedDisablesleepValue"
    private static let guardEnabledKey = "macStayOnGuardEnabled"
    private static let batteryFloorKey = "macStayOnBatteryFloor"
    private static let darkenDisplayKey = "macStayOnDarkenDisplay"
    /// Legacy v1.2.0 key — no longer used for assertion mode (was unsafe display-sleep).
    private static let legacyKeepDisplayAwakeKey = "macStayOnKeepDisplayAwake"
    private static let systemAssertionName = "MacStayOn: keep system awake" as CFString
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
    /// Defaults said On after quit/reboot, but no live session — user must Turn On again.
    @Published private(set) var needsUserReEnable: Bool = false
    /// Off while SleepDisabled is still 1 (or unreadable with our state files).
    @Published private(set) var isSleepStuckWhileOff: Bool = false
    /// Other apps holding sleep assertions (not MacStayOn / SleepDisabled).
    @Published private(set) var foreignSleepNote: String?
    /// Black-screen cover while Stay Awake — does **not** allow display sleep.
    @Published private(set) var darkenDisplay: Bool
    /// Heat/safety ack shown inside the menu popover before admin/Touch ID.
    @Published private(set) var pendingEnableConfirm: Bool = false
    /// Lid reopened while Stay Awake was on — choose Turn Off / Keep On in the menu.
    @Published private(set) var pendingLidOpenChoice: Bool = false
    /// Duration string for the lid-open menu prompt.
    @Published private(set) var lidOpenSessionDuration: String = ""

    private var guardTimer: Timer?
    /// Serial queue for pmset/ps — never block the menu-bar main thread (hang sample MSO-7).
    private let guardQueue = DispatchQueue(label: "com.markdebartolo.MacStayOn.guard", qos: .utility)
    /// Skip timer ticks while a prior guard pass is still running (pmset can stall).
    private var isGuardEvalRunning = false
    /// SleepDisabled as last sampled by the guard (off-main). Main-thread only.
    private var lastGuardSleepDisabled: Int?
    private var guardTripping = false
    /// Prevents re-entrant admin prompts while forcing SleepDisabled back to 0.
    private var isReconcilingSleep = false
    /// Keep the process awake while Off-but-SleepDisabled so the 5s reconcile timer cannot nap away.
    private var stuckSleepActivity: NSObjectProtocol?
    /// One blocking CRITICAL alert per stuck episode (in addition to menu banner + restore button).
    private var didPresentCriticalAlertForStuckEpisode = false
    /// The exact "lid sleep is stuck" text currently shown in `lastError`, so clearing the
    /// stuck state removes only that warning and never an unrelated message (e.g. why a
    /// guard turned Stay Awake off).
    private var sleepStuckErrorText: String?
    /// Bumped on every On/Off transition. A guard snapshot sampled before a transition
    /// must not be applied after it (it would report the old SleepDisabled value).
    private var stateGeneration: UInt64 = 0
    /// Off dropped the sentinel and a background poll is waiting for the root watchdog
    /// to restore lid sleep — do not escalate to CRITICAL / admin while this is true.
    private var isAwaitingWatchdogRestore = false
    private let restoreWaitQueue = DispatchQueue(label: "com.markdebartolo.MacStayOn.restore-wait", qos: .userInitiated)
    /// Quit in progress: wait for the watchdog synchronously (the app is about to exit).
    private var isTerminating = false
    /// A second copy of the app that is about to exit — it must never touch the first
    /// copy's session (shared /tmp state, defaults, sentinel).
    private var isInertSecondaryInstance = false

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
    private var stateDir: URL { environment.stateDirectory }

    private var prevFile: URL { stateDir.appendingPathComponent("disablesleep.prev") }
    private var sentinelFile: URL { stateDir.appendingPathComponent("restore.sentinel") }
    private var sessionFile: URL { stateDir.appendingPathComponent("session.id") }
    private var watchdogPidFile: URL { stateDir.appendingPathComponent("watchdog.pid") }
    private var enableScriptFile: URL { stateDir.appendingPathComponent(PrivilegedScripts.enableScriptFileName) }
    private var watchdogPythonFile: URL { stateDir.appendingPathComponent(PrivilegedScripts.watchdogFileName) }

    init(environment: Environment = .live) {
        self.environment = environment
        let defaults = environment.defaults
        if defaults.object(forKey: Self.guardEnabledKey) == nil {
            guardEnabled = true
        } else {
            guardEnabled = defaults.bool(forKey: Self.guardEnabledKey)
        }
        let storedFloor = defaults.object(forKey: Self.batteryFloorKey) as? Int
        batteryFloor = Self.clampFloor(storedFloor ?? 20)
        // Fresh default Off. Do not migrate legacy "display may sleep" — that mode was unsafe.
        if defaults.object(forKey: Self.darkenDisplayKey) == nil {
            darkenDisplay = false
            defaults.removeObject(forKey: Self.legacyKeepDisplayAwakeKey)
        } else {
            darkenDisplay = defaults.bool(forKey: Self.darkenDisplayKey)
        }
        // Instant fallback from sysctl; marketing name/chip fill in after warmCache.
        machineLabel = HardwareProfile.readModelIdentifierForDisplay()
        startGuardMonitor()
    }

    /// Black-screen cover while Stay Awake is On. Does not allow display sleep —
    /// system + display-idle assertions stay held. Key/click turns this off.
    func setDarkenDisplay(_ enabled: Bool) {
        guard darkenDisplay != enabled else {
            if enabled, isEnabled { applyDarkenOverlay() }
            return
        }
        darkenDisplay = enabled
        defaults.set(enabled, forKey: Self.darkenDisplayKey)
        if isEnabled {
            applyDarkenOverlay()
        } else if !enabled {
            DisplayDarkenOverlay.deactivate()
        }
        refreshStatusDetail()
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
        if let stuckSleepActivity {
            ProcessInfo.processInfo.endActivity(stuckSleepActivity)
        }
    }

    /// Call once the menu bar UI is up (or from AppDelegate.didFinishLaunching).
    func applyPersistedStateIfNeeded() {
        guard !isInertSecondaryInstance else { return }
        guard !didFinishLaunchSetup else { return }
        didFinishLaunchSetup = true
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if defaults.bool(forKey: Self.defaultsKey) {
            // Do NOT auto-prompt Touch ID/admin at login/reboot. Only resume if the
            // root watchdog is still alive and SleepDisabled is already 1.
            if canResumeExistingSession() {
                resumeExistingSession()
            } else {
                defaults.set(false, forKey: Self.defaultsKey)
                needsUserReEnable = true
                lastError = "Stay Awake was on earlier. Turn On again when you’re ready (no auto admin at launch)."
                _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true)
                if readSleepDisabled() == 0 {
                    cleanupStateFiles()
                }
                refreshStatusDetail()
            }
        } else {
            // Off must mean normal lid sleep — clear any stuck SleepDisabled from a
            // prior crash / failed Turn On (e.g. pmset ran but watchdog died).
            _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true)
            if readSleepDisabled() == 0 {
                cleanupStateFiles()
            }
            refreshStatusDetail()
        }
    }

    /// Menu “Restore lid sleep now” — forces admin reconcile even inside the re-prompt window.
    func requestRestoreSleepNow() {
        // The user already asked for the restore — go straight to the admin prompt.
        didPresentCriticalAlertForStuckEpisode = true
        _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true, forceAdminPrompt: true)
        refreshStatusDetail()
    }

    private func canResumeExistingSession() -> Bool {
        readSleepDisabled() == 1 && isWatchdogProcessAlive()
    }

    /// Resume after relaunch when the root watchdog survived (no second admin).
    private func resumeExistingSession() {
        lastError = nil
        needsUserReEnable = false
        defaults.set("0", forKey: Self.savedPrevKey)
        defaults.set(true, forKey: Self.defaultsKey)
        _ = createAssertion()
        isEnabled = true
        endStuckSleepActivity()
        startSessionHelpers()
        refreshStatusDetail()
        appendEnableDebug("resumed existing session without admin")
    }

    /// Call from AppDelegate on terminate so pmset is restored even if SwiftUI
    /// quit handling is skipped.
    func prepareForTermination() {
        guard !isInertSecondaryInstance else { return }
        isTerminating = true
        if isEnabled || hasAssertion || FileManager.default.fileExists(atPath: prevFile.path) {
            deactivate(persistOff: true)
        } else {
            // Even when already Off, never quit while SleepDisabled is stuck on.
            _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true)
        }
    }

    /// Another copy of MacStayOn already owns the session and this copy is about to
    /// exit. Stop the guard and ignore termination cleanup: this copy's Off path would
    /// otherwise drop the restore sentinel and switch the *running* copy's Stay Awake off.
    func becomeInertSecondaryInstance() {
        isInertSecondaryInstance = true
        guardTimer?.invalidate()
        guardTimer = nil
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            activate()
        } else {
            pendingEnableConfirm = false
            pendingLidOpenChoice = false
            deactivate(persistOff: true)
        }
    }

    func setGuardEnabled(_ enabled: Bool) {
        guardEnabled = enabled
        defaults.set(enabled, forKey: Self.guardEnabledKey)
        scheduleEvaluateGuard()
    }

    func setBatteryFloor(_ percent: Int) {
        let clamped = Self.clampFloor(percent)
        batteryFloor = clamped
        defaults.set(clamped, forKey: Self.batteryFloorKey)
        scheduleEvaluateGuard()
    }

    static func clampFloor(_ percent: Int) -> Int {
        min(50, max(10, percent))
    }

    /// Start Stay Awake from the menu: show inline heat/safety confirm in the popover
    /// (no center-screen alert), then admin/Touch ID on confirm.
    func requestEnableFromUser() {
        if isEnabled {
            refreshStatusDetail()
            return
        }
        // Prefer clearing stuck sleep before a new Turn On.
        if isSleepStuckWhileOff {
            requestRestoreSleepNow()
            if isSleepStuckWhileOff {
                return
            }
        }
        pendingLidOpenChoice = false
        pendingEnableConfirm = true
        lastError = nil
        refreshStatusDetail()
    }

    /// User accepted heat/safety copy in the menu — run admin/pmset activate.
    func confirmEnableFromMenu() {
        guard pendingEnableConfirm, !isEnabled else { return }
        pendingEnableConfirm = false
        activate()
    }

    /// User canceled the in-menu heat/safety confirm.
    func cancelEnableFromMenu() {
        pendingEnableConfirm = false
        isEnabled = false
        lastError = nil
        defaults.set(false, forKey: Self.defaultsKey)
        refreshStatusDetail()
    }

    /// Lid-open menu choice: restore normal sleep.
    func confirmTurnOffAfterLidOpen() {
        pendingLidOpenChoice = false
        isPromptingLidOpen = false
        setEnabled(false)
    }

    /// Lid-open menu choice: leave Stay Awake on.
    func confirmKeepOnAfterLidOpen() {
        pendingLidOpenChoice = false
        isPromptingLidOpen = false
        refreshStatusDetail()
    }

    // MARK: - Activate

    private func activate() {
        if isEnabled && hasAssertion {
            refreshStatusDetail()
            return
        }
        if isActivating { return }
        isActivating = true
        // Invalidate guard snapshots sampled before and during this Turn On.
        stateGeneration &+= 1
        defer {
            stateGeneration &+= 1
            isActivating = false
        }

        lastError = nil
        sleepStuckErrorText = nil

        if environment.usesHostIntegrations, let problem = Self.missingWatchdogInterpreterProblem() {
            failActivation(message: problem, debugNote: "preflight: python3 unavailable")
            return
        }
        guard prepareStateDirectory() else {
            failActivation(
                message: "MacStayOn's working folder (\(stateDir.path)) is not a folder owned by your account — stayed Off. Remove it and Turn On again.",
                debugNote: "state dir unusable"
            )
            return
        }
        try? FileManager.default.removeItem(at: sentinelFile)

        // Unique per Turn On so a dying previous watchdog cannot undo pmset after we re-enable.
        let appProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let sessionID = "\(appProcessIdentifier)-\(UInt64(Date().timeIntervalSince1970 * 1000))-\(UInt64.random(in: 0...UInt64.max))"

        let stagedSafety: (script: URL, plist: URL)
        do {
            stagedSafety = try SleepSafetyResources.writeStagingFiles(to: stateDir)
        } catch {
            failActivation(
                message: "Could not prepare sleep-safety files — stayed Off. (\(error.localizedDescription))",
                debugNote: "staging write failed: \(error)"
            )
            return
        }

        let enableScript = PrivilegedScripts.enableScript(
            stateDirectoryPath: stateDir.path,
            appProcessIdentifier: appProcessIdentifier,
            sessionID: sessionID,
            stagedSafetyScriptPath: stagedSafety.script.path,
            stagedSafetyPlistPath: stagedSafety.plist.path
        )
        do {
            try SleepSafetyResources.writeFile(PrivilegedScripts.watchdogPython, to: watchdogPythonFile, permissions: 0o755)
            try SleepSafetyResources.writeFile(enableScript, to: enableScriptFile, permissions: 0o755)
        } catch {
            failActivation(
                message: "Could not prepare enable script — stayed Off. (\(error.localizedDescription))",
                debugNote: "enable script write failed: \(error)"
            )
            return
        }

        switch runAdmin("/bin/bash", arguments: [enableScriptFile.path]) {
        case .success:
            // Always remember restore target 0 — never persist script stdout ("watchdog_ok")
            // or a stuck SleepDisabled=1 as the value to write back later.
            defaults.set("0", forKey: Self.savedPrevKey)
            // Refuse to claim On unless sleep is actually disabled and a watchdog is up.
            // Treat unreadable pmset output as failure (never assume SleepDisabled=0).
            // Bag-safety: any failed claim must restore SleepDisabled before returning Off.
            let sleepFlag = readSleepDisabled()
            let watchdogAlive = isWatchdogProcessAlive()
            if sleepFlag != 1 || !watchdogAlive {
                let detail = "sleep=\(sleepFlag.map(String.init) ?? "?") watchdog=\(watchdogAlive ? "up" : "down")"
                failActivation(
                    message: "Stay Awake did not fully enable (\(detail)) — kept Off and restored normal lid sleep.",
                    debugNote: "post-admin reject \(detail)"
                )
                return
            }
            appendEnableDebug("post-admin accept sleep=1 watchdog=up")
            _ = createAssertion()
            isEnabled = true
            needsUserReEnable = false
            isSleepStuckWhileOff = false
            didPresentCriticalAlertForStuckEpisode = false
            defaults.set(true, forKey: Self.defaultsKey)
            endStuckSleepActivity()
            startSessionHelpers()
            refreshStatusDetail()
        case .cancelled:
            failActivation(message: "Admin authorization canceled — stayed Off.", debugNote: "admin cancelled")
        case .failure(let message):
            // Enable script should have undone pmset; failActivation still verifies —
            // bag-safety invariant.
            failActivation(message: Self.userFacingEnableFailure(message), debugNote: "admin failure \(message)")
        }
    }

    /// Every failed Turn On ends here: stay Off, say why, and make sure lid sleep is normal.
    private func failActivation(message: String, debugNote: String) {
        appendEnableDebug(debugNote)
        isEnabled = false
        defaults.set(false, forKey: Self.defaultsKey)
        _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true)
        // Only replace the message when lid sleep is fine; a stuck-sleep warning outranks it.
        if !isSleepStuckWhileOff {
            lastError = message
        }
        refreshStatusDetail()
    }

    /// The shared /tmp folder must be a real directory owned by this user and not
    /// writable by anyone else: root later executes scripts staged inside it.
    private func prepareStateDirectory() -> Bool {
        let path = stateDir.path
        func isUsable() -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            let ownedByUser = info.st_uid == getuid()
            let writableByOthers = (info.st_mode & (S_IWGRP | S_IWOTH)) != 0
            return isDirectory && ownedByUser && !writableByOthers
        }
        if isUsable() { return true }
        // Ours but too permissive: tighten it rather than discarding live state.
        chmod(path, 0o755)
        if isUsable() { return true }
        // Wrong kind / owner (or missing): replace it with a fresh private folder.
        try? FileManager.default.removeItem(atPath: path)
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            appendEnableDebug("state dir create failed: \(error)")
        }
        return isUsable()
    }

    /// The root watchdog runs on Apple's `/usr/bin/python3`, which only works once the
    /// Command Line Tools (or Xcode) are installed. Say so before asking for admin
    /// rather than failing with an unexplained watchdog error afterwards.
    private static func missingWatchdogInterpreterProblem() -> String? {
        let message = "Stay Awake needs Apple's Command Line Tools (for python3). Run “xcode-select --install” in Terminal, then Turn On again."
        guard let result = ProcessRunner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], timeout: 3) else {
            // Could not ask — do not block Turn On on an inconclusive check.
            return nil
        }
        guard result.status == 0 else { return message }
        let developerDirectory = (String(data: result.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developerDirectory.isEmpty else { return message }
        let interpreterPath = developerDirectory + "/usr/bin/python3"
        return FileManager.default.isExecutableFile(atPath: interpreterPath) ? nil : message
    }

    // MARK: - Deactivate

    private func deactivate(persistOff: Bool) {
        if isEnabled { appendEnableDebug("turn off") }
        stateGeneration &+= 1
        stopSessionHelpers(retainAnalytics: true)
        releaseAssertion()

        isEnabled = false
        if persistOff {
            defaults.set(false, forKey: Self.defaultsKey)
        }

        defaults.removeObject(forKey: Self.savedPrevKey)
        // Invariant: Off ⇒ SleepDisabled must be 0 (never leave a bag-awake Mac).
        if ensureNormalSleepWhileOff(promptAdminIfNeeded: true) {
            lastError = nil
        }
        refreshStatusDetail()
    }

    /// When MacStayOn is Off, `pmset disablesleep` / SleepDisabled must be 0.
    /// Asks the root watchdog first (no prompt), then falls back to an admin `pmset`.
    ///
    /// Returns true only when lid sleep is confirmed normal right now. A false return
    /// with `isAwaitingWatchdogRestore` set means "the watchdog is on it" — a
    /// background poll finishes the job and escalates only if the watchdog fails.
    @discardableResult
    private func ensureNormalSleepWhileOff(
        promptAdminIfNeeded: Bool,
        forceAdminPrompt: Bool = false,
        skipWatchdogWait: Bool = false
    ) -> Bool {
        guard !isInertSecondaryInstance else { return false }
        guard !isEnabled else {
            isSleepStuckWhileOff = false
            return false
        }
        let sleepFlag = readSleepDisabled()
        if sleepFlag == 0 {
            // Do not wipe state on every poll — only after we know sleep is normal
            // and there is no live watchdog still shutting down.
            if !isWatchdogProcessAlive() {
                cleanupStateFiles()
            }
            clearCriticalSleepStuckUI()
            return true
        }
        // Unreadable pmset with no Stay Awake artifacts → do not spam admin.
        if sleepFlag == nil, !hasStayAwakeStateArtifacts() {
            clearCriticalSleepStuckUI()
            return true
        }
        // 1, or nil with our state files still present — unsafe until we confirm 0.
        if isAwaitingWatchdogRestore && !forceAdminPrompt { return false }
        if isReconcilingSleep { return false }
        isReconcilingSleep = true
        defer { isReconcilingSleep = false }

        // Step 1 — the root watchdog restores sleep without any prompt. It needs a
        // moment (it polls for the sentinel, then runs pmset), so never judge it by a
        // single immediate read: that showed CRITICAL + an admin prompt on a normal Off.
        if !skipWatchdogWait {
            requestWatchdogRestore()
            if isWatchdogProcessAlive() {
                if isTerminating {
                    // Quitting: the process is about to exit, so wait right here.
                    if waitForSleepDisabledClearBlocking(timeout: environment.watchdogRestoreTimeout) {
                        cleanupStateFiles()
                        clearCriticalSleepStuckUI()
                        return true
                    }
                } else if !forceAdminPrompt {
                    beginAwaitingWatchdogRestore(promptAdminIfNeeded: promptAdminIfNeeded)
                    return false
                }
            }
        }

        // Step 2 — no watchdog, or it did not restore in time: this is the real emergency.
        if !isSleepStuckWhileOff {
            let watchdogPid = (try? String(contentsOf: watchdogPidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            appendEnableDebug(
                "off stuck: sleep=\(sleepFlag.map(String.init) ?? "?") watchdogPid=\(watchdogPid)"
                    + " alive=\(isWatchdogProcessAlive()) sentinel=\(FileManager.default.fileExists(atPath: sentinelFile.path))"
            )
        }
        isSleepStuckWhileOff = true
        beginStuckSleepActivity()
        setSleepStuckError("CRITICAL: Lid sleep is still disabled while MacStayOn is Off. Approve admin to restore sleep — otherwise the Mac can stay awake in a bag.")

        if !didPresentCriticalAlertForStuckEpisode {
            didPresentCriticalAlertForStuckEpisode = true
            switch presentCriticalSleepAlert() {
            case .restoreNow:
                if restoreDisablesleepWithAdmin() || readSleepDisabled() == 0 {
                    cleanupStateFiles()
                    clearCriticalSleepStuckUI()
                    return true
                }
                refreshStatusDetail()
                return false
            case .later:
                // Respect "Later": keep the menu banner; the user restores from there.
                refreshStatusDetail()
                return false
            }
        }

        guard promptAdminIfNeeded else {
            refreshStatusDetail()
            return false
        }

        // The alert already ran once this episode. Background passes (the 5s guard
        // timer) must not open the blocking admin dialog again on their own: re-prompting
        // every 20s froze the menu bar for hours while the user was away. The menu keeps
        // the CRITICAL banner (tap = admin restore), the root watchdog keeps getting the
        // sentinel, and the sleep-safety daemon restores a stale request on its own.
        // Only an explicit user action, or quitting, prompts again.
        guard forceAdminPrompt || isTerminating else {
            refreshStatusDetail()
            return false
        }

        // Admin script success is authoritative — a flaky follow-up pmset read must not
        // leave CRITICAL sticky after Touch ID already cleared SleepDisabled.
        if restoreDisablesleepWithAdmin() || readSleepDisabled() == 0 {
            cleanupStateFiles()
            clearCriticalSleepStuckUI()
            return true
        }

        refreshStatusDetail()
        return false
    }

    /// Off-main poll for the watchdog's restore, so the menu bar never blocks on it.
    private func beginAwaitingWatchdogRestore(promptAdminIfNeeded: Bool) {
        isAwaitingWatchdogRestore = true
        let generationAtStart = stateGeneration
        restoreWaitQueue.async { [weak self] in
            guard let self else { return }
            let cleared = self.waitForSleepDisabledClearBlocking(timeout: self.environment.watchdogRestoreTimeout)
            DispatchQueue.main.async {
                self.isAwaitingWatchdogRestore = false
                // Turned On again (or mid Turn On) while we waited — that session owns the flag.
                guard !self.isEnabled, !self.isActivating else { return }
                if cleared, generationAtStart == self.stateGeneration {
                    if !self.isWatchdogProcessAlive() {
                        self.cleanupStateFiles()
                    }
                    self.clearCriticalSleepStuckUI()
                } else {
                    // Watchdog did not deliver (or state changed underneath us): re-check
                    // from scratch and escalate to the admin restore if still stuck.
                    _ = self.ensureNormalSleepWhileOff(
                        promptAdminIfNeeded: promptAdminIfNeeded,
                        skipWatchdogWait: generationAtStart == self.stateGeneration
                    )
                }
                self.refreshStatusDetail()
            }
        }
    }

    private func setSleepStuckError(_ text: String) {
        sleepStuckErrorText = text
        lastError = text
    }

    /// Drop CRITICAL / stuck-Off UI once lid sleep is normal (or confirmed restored).
    /// Removes only the stuck-sleep warning itself — other messages (why a guard
    /// turned Stay Awake off, why Turn On failed) must stay readable.
    private func clearCriticalSleepStuckUI() {
        endStuckSleepActivity()
        isSleepStuckWhileOff = false
        didPresentCriticalAlertForStuckEpisode = false
        if let stuckText = sleepStuckErrorText, lastError == stuckText {
            lastError = nil
        }
        sleepStuckErrorText = nil
    }

    private func presentCriticalSleepAlert() -> CriticalAlertChoice {
        if let presentCriticalAlert = environment.presentCriticalAlert {
            return presentCriticalAlert()
        }
        let alert = NSAlert()
        alert.messageText = "Lid sleep is still disabled"
        alert.informativeText = """
        MacStayOn is Off, but the Mac may stay awake with the lid closed (bag risk).

        Click Restore Sleep and approve admin / Touch ID. A background safety service also tries to fix this within about a minute if Stay Awake was turned on before.
        """
        alert.alertStyle = .critical
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "Restore Sleep")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .restoreNow : .later
    }

    /// Polls SleepDisabled until it reads 0 or the timeout passes. Blocks the calling
    /// thread, so only use it off the main thread or while quitting — a busy wait on
    /// the main thread froze the menu bar (MSO-7).
    private func waitForSleepDisabledClearBlocking(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readSleepDisabled() == 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return readSleepDisabled() == 0
    }

    private func beginStuckSleepActivity() {
        guard stuckSleepActivity == nil else { return }
        // Must NOT disable idle system sleep: that kept the Mac awake in a bag while
        // Off was stuck in CRITICAL limbo. Note `.userInitiated` *includes*
        // `.idleSystemSleepDisabled` (it showed up in `pmset -g log` as a
        // PreventUserIdleSystemSleep assertion held for hours) — use the
        // AllowingIdleSystemSleep variant, which still resists App Nap.
        stuckSleepActivity = ProcessInfo.processInfo.beginActivity(
            options: Self.stuckSleepActivityOptions,
            reason: "MacStayOn restoring lid sleep — Off but SleepDisabled stuck"
        )
    }

    static let stuckSleepActivityOptions: ProcessInfo.ActivityOptions = [
        .suddenTerminationDisabled,
        .automaticTerminationDisabled,
        .userInitiatedAllowingIdleSystemSleep,
    ]

    private func endStuckSleepActivity() {
        if let stuckSleepActivity {
            ProcessInfo.processInfo.endActivity(stuckSleepActivity)
            self.stuckSleepActivity = nil
        }
    }

    /// Restores normal lid sleep via admin auth.
    /// Always writes `disablesleep 0` — never re-apply a stuck SleepDisabled=1 as "previous".
    /// Also uninstalls the sleep-safety LaunchDaemon so Off leaves no durable root leftovers.
    /// The command is passed inline: restoring must not depend on writing a script file.
    @discardableResult
    private func restoreDisablesleepWithAdmin() -> Bool {
        switch runAdmin("/bin/sh", arguments: ["-c", PrivilegedScripts.restoreCommand]) {
        case .success:
            // The command ran `pmset -a disablesleep 0` and only succeeds if that did.
            // Trust it even if a follow-up pmset -g read times out — otherwise CRITICAL
            // sticks after Touch ID.
            return true
        case .cancelled:
            setSleepStuckError("Admin canceled — sleep may still be disabled. Turn Off again to restore lid sleep.")
            return false
        case .failure(let message):
            setSleepStuckError("Could not restore lid sleep. \(message)")
            return false
        }
    }

    private func runAdmin(_ executable: String, arguments: [String]) -> AdminResult {
        if let runAdminCommand = environment.runAdminCommand {
            return runAdminCommand(executable, arguments)
        }
        return Self.runAdminCommand(executable, arguments: arguments)
    }

    /// True if the pid in `watchdog.pid` is still alive and looks like our watchdog.
    ///
    /// The watchdog runs as root after Touch ID / admin auth. A non-root
    /// `kill(pid, 0)` often returns `EPERM` for that process — that means the
    /// process **exists**, not that it is dead. Treating EPERM as dead made
    /// Turn On fail immediately after a successful fingerprint (UI stayed Off
    /// while we rolled SleepDisabled back — correct bag-safety, wrong enable).
    private func isWatchdogProcessAlive() -> Bool {
        guard let text = try? String(contentsOf: watchdogPidFile, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else { return false }

        // Clear errno so a prior failure cannot spoof EPERM.
        errno = 0
        let rc = kill(pid, 0)
        let killErrno = errno
        if rc != 0 {
            if killErrno == ESRCH {
                return false
            }
            if killErrno != EPERM {
                // Unexpected errno — fall through to ps / ready-file confirmation.
                appendEnableDebug("kill(0) pid=\(pid) rc=\(rc) errno=\(killErrno)")
            }
            // EPERM: process exists but we cannot signal it (root watchdog).
        }

        if let args = Self.processArguments(pid: pid) {
            if args.isEmpty {
                // ps ran but hid args; existence already indicated by kill/EPERM.
                return readyFileMatches(pid: pid) || rc == 0 || killErrno == EPERM
            }
            return args.contains("watchdog.py") || args.contains("MacStayOn")
        }

        // ps unavailable — accept only with matching ready stamp (written by root watchdog).
        return readyFileMatches(pid: pid)
    }

    private func readyFileMatches(pid: Int32) -> Bool {
        let readyFile = stateDir.appendingPathComponent("watchdog.ready")
        guard let text = try? String(contentsOf: readyFile, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == String(pid)
    }

    private static func processArguments(pid: Int32) -> String? {
        guard let result = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "args="],
            timeout: 2
        ), result.status == 0 else {
            return nil
        }
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendEnableDebug(_ message: String) {
        let url = stateDir.appendingPathComponent("enable.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    private func cleanupStateFiles() {
        let logFile = stateDir.appendingPathComponent("watchdog.log")
        let readyFile = stateDir.appendingPathComponent("watchdog.ready")
        let notRootFile = stateDir.appendingPathComponent("watchdog.notroot")
        let stagedSafety = stateDir.appendingPathComponent(SleepSafetyResources.scriptName)
        let stagedPlist = stateDir.appendingPathComponent(SleepSafetyResources.plistName)
        for url in [
            sentinelFile, prevFile, sessionFile, watchdogPidFile,
            enableScriptFile, watchdogPythonFile, logFile, readyFile, notRootFile,
            stagedSafety, stagedPlist,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True when /tmp state suggests we left (or are leaving) a Stay Awake session.
    private func hasStayAwakeStateArtifacts() -> Bool {
        let readyFile = stateDir.appendingPathComponent("watchdog.ready")
        let candidates = [prevFile, sessionFile, watchdogPidFile, sentinelFile, readyFile]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Session helpers (analytics + lid)

    private func startSessionHelpers() {
        lidWasClosedWhileEnabled = false
        isPromptingLidOpen = false
        lastLidAngle = nil
        didFlashForCurrentClose = false
        analytics.start()
        guard environment.usesHostIntegrations else { return }
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
        DisplayDarkenOverlay.deactivate()
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
                self?.pendingLidOpenChoice = false
                return
            }
            // In-menu choice — no center-screen alert. Open the popover via status item click.
            self.lidOpenSessionDuration = SessionAnalytics.formatDuration(self.analytics.elapsed)
            self.pendingLidOpenChoice = true
            self.isPromptingLidOpen = false
            self.refreshStatusDetail()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func requestWatchdogRestore() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sentinelFile.path, contents: Data(), attributes: nil)
    }

    // MARK: - Assertion

    /// Holds system + display-idle assertions for the whole Stay Awake session.
    /// Darken mode uses a black overlay only — never drops display-sleep prevention.
    @discardableResult
    private func createAssertion() -> Bool {
        ensureAssertionsHeld()
        applyDarkenOverlay()
        return hasAssertion
    }

    /// Sync black overlay with `darkenDisplay` while Stay Awake is On.
    private func applyDarkenOverlay() {
        guard isEnabled else {
            DisplayDarkenOverlay.deactivate()
            return
        }
        if darkenDisplay {
            ScreenFlashAlert.cancel()
            DisplayDarkenOverlay.activate { [weak self] in
                // Key/click — restore display and clear the preference.
                self?.setDarkenDisplay(false)
            }
        } else {
            DisplayDarkenOverlay.deactivate()
            declareUserActivityToWakeDisplay()
        }
    }

    /// Create any missing assertions. Always hold display-idle while Stay Awake is On.
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

    private func declareUserActivityToWakeDisplay() {
        var activityID: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "MacStayOn: wake display" as CFString,
            kIOPMUserActiveLocal,
            &activityID
        )
    }

    private func releaseAssertion() {
        DisplayDarkenOverlay.deactivate()
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
        // Check often enough that a stuck SleepDisabled while Off cannot linger in a bag.
        // Work runs on guardQueue: a hung `pmset` must not rainbow-wheel the menu bar.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.scheduleEvaluateGuard()
        }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
        scheduleEvaluateGuard()
    }

    private func scheduleEvaluateGuard() {
        guard !isInertSecondaryInstance else { return }
        // Always called on the main thread (timer / setters), so this read is safe.
        let generationAtSchedule = stateGeneration
        guardQueue.async { [weak self] in
            guard let self else { return }
            if self.isGuardEvalRunning { return }
            self.isGuardEvalRunning = true
            defer { self.isGuardEvalRunning = false }

            // Shell-outs stay off the main thread and are hard-capped (see ProcessRunner).
            let snapshot = Self.powerSnapshot()
            let thermal = ProcessInfo.processInfo.thermalState
            let sleepDisabled = self.readSleepDisabled()
            let watchdogAlive = self.isWatchdogProcessAlive()
            let foreignNote = Self.foreignSleepHoldersNote()

            DispatchQueue.main.async {
                self.applyGuardEvaluation(
                    snapshot: snapshot,
                    thermal: thermal,
                    sleepDisabled: sleepDisabled,
                    watchdogAlive: watchdogAlive,
                    foreignNote: foreignNote,
                    generation: generationAtSchedule
                )
            }
        }
    }

    /// While Stay Awake is on, turn it off if the battery is at or below the floor
    /// (on battery only) or the Mac reports serious/critical thermal pressure.
    /// While Off, force SleepDisabled back to 0 if it ever sticks.
    /// Main-thread only — Process I/O already finished on `guardQueue`.
    func applyGuardEvaluation(
        snapshot: PowerSnapshot,
        thermal: ProcessInfo.ThermalState,
        sleepDisabled: Int?,
        watchdogAlive: Bool,
        foreignNote: String?,
        generation: UInt64? = nil
    ) {
        guard !isInertSecondaryInstance else { return }
        onACPower = snapshot.onAC
        batteryPercent = snapshot.percent
        lastGuardSleepDisabled = sleepDisabled
        switch thermal {
        case .critical: thermalLabel = "critical heat"
        case .serious: thermalLabel = "serious heat"
        case .fair: thermalLabel = "warm"
        default: thermalLabel = "cool"
        }
        foreignSleepNote = foreignNote

        // Sampled before an On/Off transition that has since happened: its SleepDisabled
        // and watchdog values describe the previous state. Acting on them could snap a
        // fresh Stay Awake session Off, or raise CRITICAL on a normal Off. Resample.
        if let generation, generation != stateGeneration {
            if !isActivating { scheduleEvaluateGuard() }
            return
        }

        // While enabled (lid open or closed), keep screensaver/display assertions alive.
        if isEnabled {
            ensureAssertionsHeld()
            // Watchdog died while On → SleepDisabled can stick after quit. Force Off + restore.
            // Also trip when pmset is unreadable and the watchdog is gone (fail closed).
            if !watchdogAlive, sleepDisabled != 0 {
                tripGuard("Turned off — sleep watchdog stopped. Normal lid sleep was restored for safety.")
                return
            }
            // On but SleepDisabled cleared externally → UI was lying; snap to Off.
            // Only when we positively read 0 (nil means unknown — do not snap).
            if sleepDisabled == 0 {
                stateGeneration &+= 1
                isEnabled = false
                defaults.set(false, forKey: Self.defaultsKey)
                releaseAssertion()
                stopSessionHelpers(retainAnalytics: true)
                lastError = "Stay Awake stopped — system sleep was re-enabled outside MacStayOn."
                refreshStatusDetail()
                return
            }
        } else if !isActivating {
            // Off must obey the user setting: never leave system sleep disabled.
            // Use the guardQueue snapshot — do not re-call pmset on the main thread
            // (MSO-7 freeze) or leave CRITICAL sticky after SleepDisabled is already 0.
            if sleepDisabled == 0 {
                if !watchdogAlive {
                    cleanupStateFiles()
                }
                clearCriticalSleepStuckUI()
            } else if sleepDisabled == 1 || (sleepDisabled == nil && hasStayAwakeStateArtifacts()) {
                // Snapshot already proved stuck — reconcile on main so admin/alerts stay
                // AppKit-safe. The watchdog wait itself runs off the main thread.
                _ = ensureNormalSleepWhileOff(promptAdminIfNeeded: true)
            } else {
                // Unreadable pmset, no Stay Awake artifacts — not a bag emergency.
                clearCriticalSleepStuckUI()
            }
            refreshStatusDetail()
            return
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
        // Drop sentinel immediately so a closed-lid auto-Off restores via watchdog
        // without waiting on UI / a second admin prompt.
        requestWatchdogRestore()
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

        let power = onACPower ? "AC power" : "on battery"
        // Last value sampled off the main thread by the guard. Never shell out to pmset
        // here: this runs on every state change, on the main thread (menu-bar stalls).
        let disablesleep = lastGuardSleepDisabled

        if isEnabled {
            let flag: String
            if let disablesleep {
                flag = "SleepDisabled=\(disablesleep)"
            } else {
                flag = "SleepDisabled=?"
            }
            let display = "display/screensaver \(displayAssertionID != 0 ? "held" : "off")"
            let dark = darkenDisplay ? " · black screen" : ""
            statusDetail = "\(flag) · system \(systemAssertionID != 0 ? "on" : "off") · \(display)\(dark) · \(power)"
        } else if isAwaitingWatchdogRestore {
            statusDetail = "Restoring normal lid sleep… · \(power)"
        } else if isSleepStuckWhileOff || disablesleep == 1 || (disablesleep == nil && hasStayAwakeStateArtifacts()) {
            statusDetail = "CRITICAL: Off but lid sleep still disabled — approve admin to restore (bag risk)"
        } else if disablesleep == nil {
            statusDetail = "Could not verify lid sleep · \(power)"
        } else {
            statusDetail = "Normal sleep · \(power)"
        }
    }

    /// Reads system-wide sleep-disabled flag. On current macOS, `pmset -g`
    /// reports this as `SleepDisabled` under "System-wide power settings", not
    /// as `disablesleep` in the "Currently in use" block.
    /// Returns nil when pmset fails or the key is missing — callers must not
    /// treat that as “sleep is normal” (bag-safety).
    private func readSleepDisabled() -> Int? {
        if let readSleepDisabled = environment.readSleepDisabled {
            return readSleepDisabled()
        }
        if let v = Self.readSleepDisabledFromPmset(arguments: ["-g"]) { return v }
        // Fallback shapes used on some macOS builds / power profiles.
        if let v = Self.readSleepDisabledFromPmset(arguments: ["-g", "custom"]) { return v }
        if let v = Self.readSleepDisabledFromPmset(arguments: ["-g", "live"]) { return v }
        return nil
    }

    private static func readSleepDisabledFromPmset(arguments: [String]) -> Int? {
        guard let result = ProcessRunner.run(
            executable: "/usr/bin/pmset",
            arguments: arguments,
            timeout: 2
        ), result.status == 0 else {
            return nil
        }
        return parseSleepDisabled(pmsetOutput: String(data: result.stdout, encoding: .utf8) ?? "")
    }

    static func parseSleepDisabled(pmsetOutput: String) -> Int? {
        for line in pmsetOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let key = parts[0].lowercased()
            if key == "disablesleep" || key == "sleepdisabled", let v = Int(parts[1]) {
                return v
            }
        }
        return nil
    }

    /// Surface non-MacStayOn assertions so “Off but still awake” isn’t blamed on us.
    /// Safe off the main thread (timed `pmset`).
    private static func foreignSleepHoldersNote() -> String? {
        guard let result = ProcessRunner.run(
            executable: "/usr/bin/pmset",
            arguments: ["-g", "assertions"],
            timeout: 2
        ), result.status == 0 else {
            return nil
        }
        return foreignSleepHoldersNote(
            assertionsOutput: String(data: result.stdout, encoding: .utf8) ?? "",
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func foreignSleepHoldersNote(assertionsOutput: String, ownProcessIdentifier: Int32) -> String? {
        var holders: [String] = []
        for line in assertionsOutput.split(separator: "\n") {
            let s = String(line)
            let interesting = s.contains("PreventSystemSleep")
                || s.contains("NoIdleSleepAssertion")
                || s.contains("PreventUserIdleSystemSleep")
            guard interesting else { continue }
            if s.contains("MacStayOn") { continue }
            // pid 707(Claude): ...
            if let pidRange = s.range(of: #"pid (\d+)"#, options: .regularExpression) {
                let pidToken = String(s[pidRange]).replacingOccurrences(of: "pid ", with: "")
                if let pid = Int32(pidToken), pid == ownProcessIdentifier { continue }
            }
            if s.contains("powerd") || s.contains("WindowServer") || s.contains("lidopen") {
                continue
            }
            // Extract process name in parentheses when present.
            if let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")"), open < close {
                let name = String(s[s.index(after: open)..<close])
                if !name.isEmpty, !holders.contains(name) {
                    holders.append(name)
                }
            }
        }
        if holders.isEmpty { return nil }
        let listed = holders.prefix(3).joined(separator: ", ")
        return "Also preventing idle sleep (not MacStayOn): \(listed)"
    }

    // MARK: - Admin command

    /// Map raw admin/watchdog failures to short menu copy (no internal tokens).
    static func userFacingEnableFailure(_ message: String) -> String {
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

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleStringLiteral(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    struct PowerSnapshot {
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
}
