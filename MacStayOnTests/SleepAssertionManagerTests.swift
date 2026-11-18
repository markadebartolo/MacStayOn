import Combine
import XCTest

/// Stands in for the parts of macOS the manager needs root for: the SleepDisabled
/// flag, the admin prompt, and the root watchdog. The flag lives in a file so the
/// fake watchdog (a separate process, like the real one) can clear it.
private final class FakeSystem {
    enum EnableBehavior {
        case succeed
        case cancel
        case fail(String)
        /// Admin approved and the script "succeeded", but SleepDisabled never became 1.
        case succeedWithoutSettingFlag
    }

    enum RestoreBehavior {
        case succeed
        case cancel
        case fail(String)
    }

    let sandbox: TestSandbox
    var enableBehavior: EnableBehavior = .succeed
    var restoreBehavior: RestoreBehavior = .succeed
    /// How long the fake watchdog takes to clear the flag after the sentinel appears.
    var watchdogRestoreDelay: TimeInterval = 0.6
    /// false → the watchdog sees the sentinel but never restores (hung / broken).
    var watchdogRestores = true
    var criticalAlertChoice: SleepAssertionManager.CriticalAlertChoice = .restoreNow

    private(set) var enableCallCount = 0
    private(set) var restoreCallCount = 0
    private(set) var criticalAlertCount = 0
    private(set) var lastEnableScriptPath: String?
    private(set) var watchdogProcess: Process?

    init() {
        sandbox = TestSandbox(name: "manager")
        setSleepDisabled(0)
        // Named watchdog.py so `ps` shows the marker the app looks for.
        sandbox.write("""
        state="$1"; flag="$2"; delay="$3"; restores="$4"
        while [ ! -e "$state/restore.sentinel" ]; do sleep 0.05; done
        sleep "$delay"
        if [ "$restores" = "yes" ]; then
          printf 0 > "$flag"
          rm -f "$state/restore.sentinel" "$state/disablesleep.prev" "$state/watchdog.pid" "$state/watchdog.ready"
          exit 0
        fi
        while :; do sleep 1; done
        """, to: "fake/watchdog.py", permissions: 0o755)
    }

    var stateDirectoryURL: URL { sandbox.url("state") }
    private var flagPath: String { sandbox.path("pmset.state") }

    var sleepDisabled: Int? {
        guard let text = try? String(contentsOfFile: flagPath, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func setSleepDisabled(_ value: Int) {
        try! Data(String(value).utf8).write(to: URL(fileURLWithPath: flagPath))
    }

    func makeUnreadable() {
        try? FileManager.default.removeItem(atPath: flagPath)
    }

    func makeDefaults() -> UserDefaults {
        let suiteName = "MacStayOnTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func makeEnvironment(defaults: UserDefaults? = nil, watchdogRestoreTimeout: TimeInterval = 4) -> SleepAssertionManager.Environment {
        SleepAssertionManager.Environment(
            stateDirectory: stateDirectoryURL,
            defaults: defaults ?? makeDefaults(),
            readSleepDisabled: { self.sleepDisabled },
            runAdminCommand: { executable, arguments in
                self.handleAdminCommand(executable: executable, arguments: arguments)
            },
            presentCriticalAlert: {
                self.criticalAlertCount += 1
                return self.criticalAlertChoice
            },
            usesHostIntegrations: false,
            watchdogRestoreTimeout: watchdogRestoreTimeout
        )
    }

    private func handleAdminCommand(executable: String, arguments: [String]) -> SleepAssertionManager.AdminResult {
        if executable == "/bin/bash" {
            enableCallCount += 1
            lastEnableScriptPath = arguments.first
            switch enableBehavior {
            case .cancel:
                return .cancelled
            case .fail(let message):
                return .failure(message)
            case .succeedWithoutSettingFlag:
                return .success("watchdog_ok")
            case .succeed:
                setSleepDisabled(1)
                startWatchdog()
                return .success("watchdog_ok")
            }
        }
        // Restore: `/bin/sh -c <restoreCommand>`
        restoreCallCount += 1
        precondition(arguments.last?.contains("disablesleep 0") == true, "unexpected admin command: \(arguments)")
        switch restoreBehavior {
        case .cancel:
            return .cancelled
        case .fail(let message):
            return .failure(message)
        case .succeed:
            setSleepDisabled(0)
            return .success("")
        }
    }

    func startWatchdog() {
        killWatchdog()
        let process = spawnDetached("/bin/bash", [
            sandbox.path("fake/watchdog.py"),
            stateDirectoryURL.path,
            flagPath,
            String(watchdogRestoreDelay),
            watchdogRestores ? "yes" : "no",
        ])
        watchdogProcess = process
        try? FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        let pidText = String(process.processIdentifier)
        try! Data(pidText.utf8).write(to: stateDirectoryURL.appendingPathComponent("watchdog.pid"))
        try! Data(pidText.utf8).write(to: stateDirectoryURL.appendingPathComponent("watchdog.ready"))
        try! Data("0".utf8).write(to: stateDirectoryURL.appendingPathComponent("disablesleep.prev"))
    }

    func killWatchdog() {
        guard let process = watchdogProcess else { return }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        watchdogProcess = nil
    }

    func stateFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: stateDirectoryURL.appendingPathComponent(name).path)
    }

    func tearDown() {
        killWatchdog()
        sandbox.remove()
    }
}

final class SleepAssertionManagerTests: XCTestCase {
    private var system: FakeSystem!
    private var managers: [SleepAssertionManager] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Every value `isSleepStuckWhileOff` published — the CRITICAL banner must not even flash.
    private var stuckBannerWasShown = false

    override func setUp() {
        super.setUp()
        system = FakeSystem()
        stuckBannerWasShown = false
    }

    override func tearDown() {
        for manager in managers {
            manager.prepareForTermination()
        }
        managers.removeAll()
        cancellables.removeAll()
        system.tearDown()
        system = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeManager(
        defaults: UserDefaults? = nil,
        watchdogRestoreTimeout: TimeInterval = 4
    ) -> SleepAssertionManager {
        let manager = SleepAssertionManager(
            environment: system.makeEnvironment(defaults: defaults, watchdogRestoreTimeout: watchdogRestoreTimeout)
        )
        manager.$isSleepStuckWhileOff
            .sink { [weak self] isStuck in
                if isStuck { self?.stuckBannerWasShown = true }
            }
            .store(in: &cancellables)
        managers.append(manager)
        return manager
    }

    private func turnOn(_ manager: SleepAssertionManager) {
        manager.requestEnableFromUser()
        XCTAssertTrue(manager.pendingEnableConfirm, "Turn On must ask for the heat/safety confirmation first")
        manager.confirmEnableFromMenu()
    }

    private func makeEnabledManager(watchdogRestoreTimeout: TimeInterval = 4) -> SleepAssertionManager {
        let manager = makeManager(watchdogRestoreTimeout: watchdogRestoreTimeout)
        turnOn(manager)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(system.sleepDisabled, 1)
        return manager
    }

    private func guardEvaluation(
        _ manager: SleepAssertionManager,
        onAC: Bool = true,
        batteryPercent: Int? = 80,
        thermal: ProcessInfo.ThermalState = .nominal,
        sleepDisabled: Int?,
        watchdogAlive: Bool,
        generation: UInt64? = nil
    ) {
        manager.applyGuardEvaluation(
            snapshot: SleepAssertionManager.PowerSnapshot(onAC: onAC, percent: batteryPercent),
            thermal: thermal,
            sleepDisabled: sleepDisabled,
            watchdogAlive: watchdogAlive,
            foreignNote: nil,
            generation: generation
        )
    }

    // MARK: - Turn On

    func testTurnOnEnablesStayAwake() throws {
        let defaults = system.makeDefaults()
        let manager = makeManager(defaults: defaults)

        turnOn(manager)

        XCTAssertTrue(manager.isEnabled)
        XCTAssertFalse(manager.pendingEnableConfirm)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(system.sleepDisabled, 1)
        XCTAssertEqual(system.enableCallCount, 1)
        XCTAssertTrue(defaults.bool(forKey: "macStayOnEnabled"))
        XCTAssertTrue(manager.analytics.isLive)

        // The script handed to the admin prompt exists, is executable and is valid bash.
        let scriptPath = try XCTUnwrap(system.lastEnableScriptPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath))
        XCTAssertEqual(runTool("/bin/bash", ["-n", scriptPath]).status, 0)
        XCTAssertTrue(system.stateFileExists("watchdog.py"))
        XCTAssertTrue(system.stateFileExists("sleep-safety.sh"))
        XCTAssertTrue(system.stateFileExists("sleep-safety.plist"))
    }

    func testCancelingTheConfirmationNeverAsksForAdmin() {
        let manager = makeManager()
        manager.requestEnableFromUser()
        manager.cancelEnableFromMenu()

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.pendingEnableConfirm)
        XCTAssertEqual(system.enableCallCount, 0)
    }

    func testAdminCancelStaysOffWithAClearMessage() {
        system.enableBehavior = .cancel
        let manager = makeManager()

        turnOn(manager)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.lastError, "Admin authorization canceled — stayed Off.")
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertEqual(system.criticalAlertCount, 0)
    }

    func testWatchdogFailureIsReportedInPlainWords() {
        system.enableBehavior = .fail("watchdog_failed")
        let manager = makeManager()

        turnOn(manager)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(
            manager.lastError,
            "Couldn't start the sleep watchdog after admin approval — stayed Off. Try Turn On again."
        )
    }

    func testTurnOnIsRejectedWhenSleepWasNotActuallyDisabled() {
        system.enableBehavior = .succeedWithoutSettingFlag
        let manager = makeManager()

        turnOn(manager)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(system.sleepDisabled, 0)
        let message = manager.lastError ?? ""
        XCTAssertTrue(message.contains("did not fully enable"), message)

        // The explanation must survive the next routine guard pass.
        guardEvaluation(manager, sleepDisabled: 0, watchdogAlive: false)
        XCTAssertEqual(manager.lastError, message)
    }

    func testTurnOnRecoversWhenTheStateFolderPathIsAFile() {
        try? FileManager.default.removeItem(at: system.stateDirectoryURL)
        try! Data("not a folder".utf8).write(to: system.stateDirectoryURL)
        let manager = makeManager()

        turnOn(manager)

        XCTAssertTrue(manager.isEnabled, manager.lastError ?? "")
    }

    func testTurnOnTightensAStateFolderOthersCouldWriteTo() throws {
        try FileManager.default.createDirectory(at: system.stateDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: system.stateDirectoryURL.path)
        let manager = makeManager()

        turnOn(manager)

        XCTAssertTrue(manager.isEnabled)
        let attributes = try FileManager.default.attributesOfItem(atPath: system.stateDirectoryURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o022, 0, "root runs scripts from this folder — nobody else may write to it")
    }

    func testTurnOnReplacesStaleLeftoverScripts() throws {
        // Leftovers from an earlier session that the app cannot overwrite in place.
        try FileManager.default.createDirectory(at: system.stateDirectoryURL, withIntermediateDirectories: true)
        for name in ["sleep-safety.sh", "sleep-safety.plist", "watchdog.py", "enable-watchdog.sh"] {
            let fileURL = system.stateDirectoryURL.appendingPathComponent(name)
            try Data("stale".utf8).write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        }
        let manager = makeManager()

        turnOn(manager)

        XCTAssertTrue(manager.isEnabled, manager.lastError ?? "")
        let staged = try String(contentsOf: system.stateDirectoryURL.appendingPathComponent("sleep-safety.sh"), encoding: .utf8)
        XCTAssertEqual(staged, SleepSafetyResources.script)
    }

    // MARK: - Turn Off

    /// The regression this suite exists for: a normal Off must hand the restore to the
    /// watchdog and wait for it — no CRITICAL banner, no alert, no second admin prompt —
    /// even though the watchdog needs longer than one immediate read.
    func testTurnOffRestoresSleepThroughWatchdogWithoutAnyWarning() {
        let manager = makeEnabledManager()

        manager.setEnabled(false)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(manager.lastError)
        waitUntil("lid sleep restored") { self.system.sleepDisabled == 0 }
        waitUntil("state files cleaned up") { !self.system.stateFileExists("watchdog.pid") && !self.system.stateFileExists("session.id") && !self.system.stateFileExists("watchdog.py") }
        spinMainRunLoop(for: 0.5)

        XCTAssertFalse(stuckBannerWasShown, "CRITICAL banner appeared during a normal Off")
        XCTAssertEqual(system.criticalAlertCount, 0)
        XCTAssertEqual(system.restoreCallCount, 0, "a normal Off must not need a second admin prompt")
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertFalse(manager.analytics.isLive)
    }

    func testGuardTicksDuringANormalOffDoNotEscalate() {
        system.watchdogRestoreDelay = 1.2
        let manager = makeEnabledManager()

        manager.setEnabled(false)
        // What the 5-second guard would report while the watchdog is still working.
        guardEvaluation(manager, sleepDisabled: 1, watchdogAlive: true)
        guardEvaluation(manager, sleepDisabled: 1, watchdogAlive: true)

        waitUntil("lid sleep restored") { self.system.sleepDisabled == 0 }
        spinMainRunLoop(for: 0.5)
        XCTAssertFalse(stuckBannerWasShown)
        XCTAssertEqual(system.criticalAlertCount, 0)
        XCTAssertEqual(system.restoreCallCount, 0)
    }

    func testOffEscalatesToAdminRestoreWhenWatchdogNeverRestores() {
        system.watchdogRestores = false
        let manager = makeEnabledManager(watchdogRestoreTimeout: 1)

        manager.setEnabled(false)
        XCTAssertEqual(system.criticalAlertCount, 0, "must give the watchdog its chance first")

        waitUntil("admin restore") { self.system.restoreCallCount == 1 }
        XCTAssertEqual(system.criticalAlertCount, 1)
        waitUntil("stuck state cleared") { !manager.isSleepStuckWhileOff && manager.lastError == nil }
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertEqual(system.restoreCallCount, 1, "one prompt is enough once the restore succeeded")
    }

    func testOffWithDeadWatchdogRestoresWithAdminImmediately() {
        let manager = makeEnabledManager()
        system.killWatchdog()

        manager.setEnabled(false)

        XCTAssertEqual(system.criticalAlertCount, 1)
        XCTAssertEqual(system.restoreCallCount, 1)
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertNil(manager.lastError)
    }

    func testChoosingLaterOnTheAlertDoesNotImmediatelyPromptForAdmin() {
        system.criticalAlertChoice = .later
        let manager = makeEnabledManager()
        system.killWatchdog()

        manager.setEnabled(false)

        XCTAssertEqual(system.criticalAlertCount, 1)
        XCTAssertEqual(system.restoreCallCount, 0, "\"Later\" was ignored — admin prompt fired anyway")
        XCTAssertTrue(manager.isSleepStuckWhileOff, "the menu must keep warning while lid sleep is disabled")
        XCTAssertTrue(manager.lastError?.contains("CRITICAL") == true)

        // A guard pass inside the quiet period keeps the banner but does not nag.
        guardEvaluation(manager, sleepDisabled: 1, watchdogAlive: false)
        XCTAssertEqual(system.criticalAlertCount, 1)
        XCTAssertEqual(system.restoreCallCount, 0)

        // The menu's "Restore lid sleep now" goes straight to the admin restore.
        manager.requestRestoreSleepNow()
        XCTAssertEqual(system.criticalAlertCount, 1)
        XCTAssertEqual(system.restoreCallCount, 1)
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertNil(manager.lastError)
    }

    func testCanceledAdminRestoreKeepsTheWarningUp() {
        system.restoreBehavior = .cancel
        let manager = makeEnabledManager()
        system.killWatchdog()

        manager.setEnabled(false)

        XCTAssertEqual(system.sleepDisabled, 1)
        XCTAssertTrue(manager.isSleepStuckWhileOff)
        XCTAssertTrue(manager.lastError?.contains("Admin canceled") == true, manager.lastError ?? "nil")

        // Once the flag clears by any route, the warning goes away on the next guard pass.
        system.setSleepDisabled(0)
        guardEvaluation(manager, sleepDisabled: 0, watchdogAlive: false)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertNil(manager.lastError)
    }

    func testTurningOnAgainRightAfterOffStaysOn() {
        system.watchdogRestoreDelay = 1.0
        let manager = makeEnabledManager(watchdogRestoreTimeout: 1)

        manager.setEnabled(false)
        turnOn(manager) // the fake admin replaces the old watchdog, as the real script does

        XCTAssertTrue(manager.isEnabled)
        spinMainRunLoop(for: 2.5) // let the Off's background wait time out and report
        XCTAssertTrue(manager.isEnabled, "the earlier Off's follow-up switched the new session off")
        XCTAssertEqual(system.sleepDisabled, 1)
        XCTAssertEqual(system.restoreCallCount, 0)
        XCTAssertEqual(system.criticalAlertCount, 0)
    }

    // MARK: - Quit

    func testQuitWhileOnRestoresSleepBeforeReturning() {
        let manager = makeEnabledManager()

        manager.prepareForTermination()

        XCTAssertEqual(system.sleepDisabled, 0, "the app must not exit while lid sleep is still disabled")
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(system.criticalAlertCount, 0)
        XCTAssertEqual(system.restoreCallCount, 0)
    }

    func testQuitWhileOffWithStuckSleepRestoresWithAdmin() {
        let manager = makeManager()
        system.setSleepDisabled(1)
        try? FileManager.default.createDirectory(at: system.stateDirectoryURL, withIntermediateDirectories: true)

        manager.prepareForTermination()

        XCTAssertEqual(system.restoreCallCount, 1)
        XCTAssertEqual(system.sleepDisabled, 0)
    }

    /// A second copy of the app exits straight away. Its cleanup used to drop the
    /// restore sentinel and switch the running copy's Stay Awake off.
    func testSecondCopyOfTheAppDoesNotDisturbTheRunningSession() {
        let primary = makeEnabledManager()
        let secondary = makeManager()

        secondary.becomeInertSecondaryInstance()
        secondary.applyPersistedStateIfNeeded()
        secondary.prepareForTermination()
        guardEvaluation(secondary, sleepDisabled: 1, watchdogAlive: true)
        spinMainRunLoop(for: 1.5)

        XCTAssertFalse(system.stateFileExists("restore.sentinel"))
        XCTAssertEqual(system.sleepDisabled, 1)
        XCTAssertTrue(primary.isEnabled)
        XCTAssertEqual(system.restoreCallCount, 0)
    }

    // MARK: - Launch

    func testLaunchResumesALiveSessionWithoutAdmin() {
        let defaults = system.makeDefaults()
        defaults.set(true, forKey: "macStayOnEnabled")
        system.setSleepDisabled(1)
        system.startWatchdog()
        let manager = makeManager(defaults: defaults)

        manager.applyPersistedStateIfNeeded()

        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(system.enableCallCount, 0)
        XCTAssertNil(manager.lastError)
    }

    func testLaunchAfterRebootStaysOffAndNeverPromptsOnItsOwn() {
        let defaults = system.makeDefaults()
        defaults.set(true, forKey: "macStayOnEnabled")
        let manager = makeManager(defaults: defaults)

        manager.applyPersistedStateIfNeeded()

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.needsUserReEnable)
        XCTAssertFalse(defaults.bool(forKey: "macStayOnEnabled"))
        XCTAssertEqual(system.enableCallCount, 0)
        XCTAssertEqual(system.restoreCallCount, 0)
        XCTAssertNotNil(manager.lastError, "the user should be told why Stay Awake is Off again")
    }

    func testLaunchWhileOffClearsStuckSleepLeftByACrash() {
        system.setSleepDisabled(1)
        try? FileManager.default.createDirectory(at: system.stateDirectoryURL, withIntermediateDirectories: true)
        try! Data("0".utf8).write(to: system.stateDirectoryURL.appendingPathComponent("disablesleep.prev"))
        let manager = makeManager()

        manager.applyPersistedStateIfNeeded()

        XCTAssertEqual(system.criticalAlertCount, 1)
        XCTAssertEqual(system.restoreCallCount, 1)
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertFalse(system.stateFileExists("disablesleep.prev"))
    }

    func testUnreadablePmsetWithNoSessionLeftoversIsNotAnEmergency() {
        system.makeUnreadable()
        let manager = makeManager()

        manager.applyPersistedStateIfNeeded()
        guardEvaluation(manager, sleepDisabled: nil, watchdogAlive: false)

        XCTAssertFalse(manager.isSleepStuckWhileOff)
        XCTAssertEqual(system.criticalAlertCount, 0)
        XCTAssertEqual(system.restoreCallCount, 0)
    }

    // MARK: - Guard (battery / heat / watchdog)

    func testSeriousHeatTurnsStayAwakeOffAndKeepsTheReasonVisible() {
        let manager = makeEnabledManager()

        guardEvaluation(manager, thermal: .serious, sleepDisabled: 1, watchdogAlive: true)

        XCTAssertFalse(manager.isEnabled)
        let message = manager.lastError ?? ""
        XCTAssertTrue(message.contains("serious heat"), message)

        waitUntil("lid sleep restored") { self.system.sleepDisabled == 0 }
        spinMainRunLoop(for: 0.5)
        guardEvaluation(manager, sleepDisabled: 0, watchdogAlive: false)
        XCTAssertEqual(manager.lastError, message, "the reason for the automatic Off vanished")
        XCTAssertEqual(system.restoreCallCount, 0)
    }

    func testLowBatteryOnBatteryPowerTurnsStayAwakeOff() {
        let manager = makeEnabledManager()
        manager.setBatteryFloor(20)

        guardEvaluation(manager, onAC: false, batteryPercent: 20, sleepDisabled: 1, watchdogAlive: true)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.lastError?.contains("battery at 20%") == true, manager.lastError ?? "nil")
        waitUntil("lid sleep restored") { self.system.sleepDisabled == 0 }
    }

    func testLowBatteryIsIgnoredOnACPowerAndAboveTheFloor() {
        let manager = makeEnabledManager()
        manager.setBatteryFloor(20)

        guardEvaluation(manager, onAC: true, batteryPercent: 5, sleepDisabled: 1, watchdogAlive: true)
        guardEvaluation(manager, onAC: false, batteryPercent: 21, sleepDisabled: 1, watchdogAlive: true)

        XCTAssertTrue(manager.isEnabled)
    }

    func testGuardSwitchDisablesBatteryAndHeatCutoffs() {
        let manager = makeEnabledManager()
        manager.setGuardEnabled(false)

        guardEvaluation(manager, onAC: false, batteryPercent: 5, thermal: .critical, sleepDisabled: 1, watchdogAlive: true)

        XCTAssertTrue(manager.isEnabled)
    }

    func testBatteryFloorIsClampedToASaneRange() {
        let manager = makeManager()
        manager.setBatteryFloor(1)
        XCTAssertEqual(manager.batteryFloor, 10)
        manager.setBatteryFloor(99)
        XCTAssertEqual(manager.batteryFloor, 50)
    }

    func testWatchdogDyingWhileOnForcesOffAndRestoresSleep() {
        let manager = makeEnabledManager()
        system.killWatchdog()

        guardEvaluation(manager, sleepDisabled: 1, watchdogAlive: false)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(system.sleepDisabled, 0)
        XCTAssertEqual(system.restoreCallCount, 1)
        XCTAssertTrue(manager.lastError?.contains("watchdog stopped") == true, manager.lastError ?? "nil")
    }

    func testSleepReEnabledOutsideTheAppSnapsToOff() {
        let manager = makeEnabledManager()
        system.setSleepDisabled(0)

        guardEvaluation(manager, sleepDisabled: 0, watchdogAlive: true)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.lastError?.contains("re-enabled outside MacStayOn") == true)
    }

    /// A guard reading taken *before* Turn On says "SleepDisabled=0". Applied after
    /// Turn On it used to look like "sleep was re-enabled outside the app" and
    /// switched the brand-new session off.
    func testGuardReadingFromBeforeTurnOnIsIgnored() {
        let manager = makeEnabledManager()

        guardEvaluation(manager, sleepDisabled: 0, watchdogAlive: false, generation: 0)

        XCTAssertTrue(manager.isEnabled)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(system.sleepDisabled, 1)
    }

    func testUnreadablePmsetWhileOnDoesNotSnapOff() {
        let manager = makeEnabledManager()

        guardEvaluation(manager, sleepDisabled: nil, watchdogAlive: true)

        XCTAssertTrue(manager.isEnabled)
    }
}
