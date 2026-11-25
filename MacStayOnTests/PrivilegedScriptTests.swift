import XCTest

/// Runs the *shipping* root scripts (watchdog, Turn On script, restore command,
/// LaunchDaemon safety script) without root: the only changes are text
/// substitutions that point `pmset`, `launchctl` and `/Library` at a sandbox.
final class PrivilegedScriptTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var spawnedProcesses: [Process] = []

    override func setUp() {
        super.setUp()
        sandbox = TestSandbox(name: "scripts")
        sandbox.makeDirectory("state")
        sandbox.makeDirectory("tmp")
        sandbox.makeDirectory("Library/LaunchDaemons")
        sandbox.write("0", to: "pmset.state")

        // Fake pmset: `-g` prints the flag like the real tool; `-a disablesleep N` stores N.
        sandbox.write("""
        #!/bin/bash
        STATE_FILE='\(sandbox.path("pmset.state"))'
        echo "pmset $*" >> '\(sandbox.path("calls.log"))'
        if [ -f '\(sandbox.path("pmset.fail"))' ] && [ "$1" = "-a" ]; then
          exit 1
        fi
        if [ "$1" = "-g" ]; then
          echo "System-wide power settings:"
          printf ' SleepDisabled\\t\\t%s\\n' "$(cat "$STATE_FILE")"
          echo "Currently in use:"
          echo " standby              1"
          exit 0
        fi
        if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
          printf '%s' "$3" > "$STATE_FILE"
          exit 0
        fi
        exit 0
        """, to: "bin/pmset", permissions: 0o755)

        // Fake launchctl: records the call. With the marker file present, `bootout`
        // kills its caller — exactly what launchd does to a job that boots itself out.
        sandbox.write("""
        #!/bin/bash
        echo "launchctl $*" >> '\(sandbox.path("calls.log"))'
        if [ "$1" = "bootout" ] && [ -f '\(sandbox.path("bootout.kills.caller"))' ]; then
          kill -9 "$PPID"
        fi
        exit 0
        """, to: "bin/launchctl", permissions: 0o755)
    }

    override func tearDown() {
        for process in spawnedProcesses where process.isRunning {
            process.terminate()
        }
        spawnedProcesses.removeAll()
        if let pidText = sandbox.read("state/watchdog.pid"),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            kill(pid, SIGKILL)
        }
        sandbox.remove()
        sandbox = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Points a shipping script at the sandbox instead of the real system.
    private func sandboxed(_ scriptText: String) -> String {
        scriptText
            .replacingOccurrences(of: "$(pmset -g", with: "$('\(sandbox.path("bin/pmset"))' -g")
            .replacingOccurrences(of: "/usr/bin/pmset", with: sandbox.path("bin/pmset"))
            .replacingOccurrences(of: "/bin/launchctl", with: sandbox.path("bin/launchctl"))
            .replacingOccurrences(of: "/Library/LaunchDaemons", with: sandbox.path("Library/LaunchDaemons"))
            .replacingOccurrences(
                of: "/Library/Application Support/MacStayOn",
                with: sandbox.path("Library/Application Support/MacStayOn")
            )
            .replacingOccurrences(of: "/tmp/MacStayOn-*", with: sandbox.path("tmp") + "/MacStayOn-*")
            .replacingOccurrences(of: "/usr/bin/logger", with: "/usr/bin/true")
            .replacingOccurrences(of: "REQUIRE_ROOT = True", with: "REQUIRE_ROOT = False")
    }

    private var sleepDisabledFlag: String {
        (sandbox.read("pmset.state") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recordedCalls: String {
        sandbox.read("calls.log") ?? ""
    }

    private var safetyPlistPath: String {
        "Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist"
    }

    private func installFakeSafetyDaemonFiles() {
        sandbox.write("plist", to: safetyPlistPath)
        sandbox.write("script", to: "Library/Application Support/MacStayOn/sleep-safety.sh")
    }

    /// A live process whose arguments contain "watchdog.py", like the real watchdog.
    private func spawnProcessThatLooksLikeWatchdog() -> Process {
        let scriptURL = sandbox.write("while :; do sleep 1; done\n", to: "fake/watchdog.py", permissions: 0o755)
        let process = spawnDetached("/bin/bash", [scriptURL.path])
        spawnedProcesses.append(process)
        return process
    }

    private func spawnUnrelatedProcess() -> Process {
        let process = spawnDetached("/bin/sleep", ["300"])
        spawnedProcesses.append(process)
        return process
    }

    private func writeSandboxedWatchdog() -> URL {
        sandbox.write(sandboxed(PrivilegedScripts.watchdogPython), to: "state/watchdog.py", permissions: 0o755)
    }

    /// Starts the sandboxed watchdog the way the Turn On script does.
    private func startWatchdog(appProcessIdentifier: Int32, session: String) -> Process {
        let watchdogURL = writeSandboxedWatchdog()
        sandbox.write(session, to: "state/session.id")
        let process = spawnDetached(
            "/usr/bin/python3",
            [watchdogURL.path, sandbox.path("state"), String(appProcessIdentifier), session]
        )
        spawnedProcesses.append(process)
        waitUntil(timeout: 15, "watchdog ready file") { self.sandbox.exists("state/watchdog.ready") }
        return process
    }

    private func enableScriptText(appProcessIdentifier: Int32, session: String = "session-1") -> String {
        let staged = try! SleepSafetyResources.writeStagingFiles(to: sandbox.url("state"))
        return sandboxed(PrivilegedScripts.enableScript(
            stateDirectoryPath: sandbox.path("state"),
            appProcessIdentifier: appProcessIdentifier,
            sessionID: session,
            stagedSafetyScriptPath: staged.script.path,
            stagedSafetyPlistPath: staged.plist.path
        ))
    }

    // MARK: - Static checks on the exact shipping text

    func testSafetyScriptIsValidBash() {
        let scriptURL = sandbox.write(SleepSafetyResources.script, to: "lint/sleep-safety.sh")
        let result = runTool("/bin/bash", ["-n", scriptURL.path])
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testSafetyPlistIsValidAndRunsTheInstalledScript() throws {
        let plistURL = sandbox.write(SleepSafetyResources.plist, to: "lint/sleep-safety.plist")
        XCTAssertEqual(runTool("/usr/bin/plutil", ["-lint", plistURL.path]).status, 0)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, SleepSafetyResources.launchdLabel)
        // macOS lists the background item under MacStayOn (not "bash") in Login Items & Extensions.
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? String, "com.markdebartolo.MacStayOn")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/bin/bash", "/Library/Application Support/MacStayOn/sleep-safety.sh"]
        )
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StartInterval"] as? Int, 60)
    }

    func testSupportFolderMirrorsMatchEmbeddedResources() throws {
        let supportURL = repositoryRootURL.appendingPathComponent("support")
        let mirroredScript = try String(contentsOf: supportURL.appendingPathComponent("sleep-safety.sh"), encoding: .utf8)
        let mirroredPlist = try String(contentsOf: supportURL.appendingPathComponent("sleep-safety.plist"), encoding: .utf8)
        XCTAssertEqual(
            mirroredScript.trimmingCharacters(in: .newlines),
            SleepSafetyResources.script.trimmingCharacters(in: .newlines)
        )
        XCTAssertEqual(
            mirroredPlist.trimmingCharacters(in: .newlines),
            SleepSafetyResources.plist.trimmingCharacters(in: .newlines)
        )
    }

    func testWatchdogIsValidPython() {
        let watchdogURL = sandbox.write(PrivilegedScripts.watchdogPython, to: "lint/watchdog.py")
        let result = runTool("/usr/bin/python3", ["-c", "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')", watchdogURL.path])
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testEnableScriptIsValidBashEvenWithAwkwardPaths() {
        let script = PrivilegedScripts.enableScript(
            stateDirectoryPath: "/tmp/MacStayOn-o'brien user",
            appProcessIdentifier: 4242,
            sessionID: "4242-1-2",
            stagedSafetyScriptPath: "/tmp/MacStayOn-o'brien user/sleep-safety.sh",
            stagedSafetyPlistPath: "/tmp/MacStayOn-o'brien user/sleep-safety.plist"
        )
        let scriptURL = sandbox.write(script, to: "lint/enable.sh")
        let result = runTool("/bin/bash", ["-n", scriptURL.path])
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testRestoreCommandIsValidShell() {
        let result = runTool("/bin/sh", ["-n", "-c", PrivilegedScripts.restoreCommand])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(PrivilegedScripts.restoreCommand.contains("/usr/bin/pmset -a disablesleep 0"))
    }

    // MARK: - Restore command

    func testRestoreCommandClearsFlagAndRemovesSafetyDaemon() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()

        let result = runTool("/bin/sh", ["-c", sandboxed(PrivilegedScripts.restoreCommand)])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(sleepDisabledFlag, "0")
        XCTAssertFalse(sandbox.exists(safetyPlistPath))
        XCTAssertFalse(sandbox.exists("Library/Application Support/MacStayOn"))
        XCTAssertTrue(recordedCalls.contains("launchctl bootout system/com.markdebartolo.MacStayOn.sleep-safety"))
    }

    func testRestoreCommandFailsWhenPmsetFails() {
        sandbox.write("1", to: "pmset.state")
        sandbox.write("", to: "pmset.fail")
        let result = runTool("/bin/sh", ["-c", sandboxed(PrivilegedScripts.restoreCommand)])
        XCTAssertNotEqual(result.status, 0, "a failed pmset must not be reported as a successful restore")
        XCTAssertEqual(sleepDisabledFlag, "1")
    }

    /// The same quoting the app uses for the admin prompt, minus the privileges.
    func testRestoreCommandSurvivesAppleScriptQuoting() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()
        let shellCommand = (["/bin/sh", "-c", sandboxed(PrivilegedScripts.restoreCommand)])
            .map(SleepAssertionManager.shellQuote)
            .joined(separator: " ")
        let source = "do shell script \(SleepAssertionManager.appleStringLiteral(shellCommand))"

        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        XCTAssertNotNil(script)
        _ = script?.executeAndReturnError(&errorInfo)

        XCTAssertNil(errorInfo, "\(String(describing: errorInfo))")
        XCTAssertEqual(sleepDisabledFlag, "0")
        XCTAssertFalse(sandbox.exists(safetyPlistPath))
    }

    // MARK: - Watchdog

    func testWatchdogRestoresSleepWhenSentinelAppears() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()
        let app = spawnUnrelatedProcess()
        let watchdog = startWatchdog(appProcessIdentifier: app.processIdentifier, session: "s1")
        sandbox.write(String(watchdog.processIdentifier), to: "state/watchdog.pid")
        XCTAssertEqual(sleepDisabledFlag, "1", "watchdog must not restore while the app is up and no sentinel exists")

        sandbox.write("", to: "state/restore.sentinel")

        waitUntil("watchdog exit") { !watchdog.isRunning }
        XCTAssertEqual(sleepDisabledFlag, "0")
        XCTAssertFalse(sandbox.exists(safetyPlistPath), "Off must remove the safety LaunchDaemon")
        XCTAssertFalse(sandbox.exists("Library/Application Support/MacStayOn"))
        XCTAssertFalse(sandbox.exists("state/restore.sentinel"))
        XCTAssertFalse(sandbox.exists("state/watchdog.pid"))
        XCTAssertFalse(sandbox.exists("state/watchdog.ready"))
    }

    func testWatchdogRestoresSleepWhenAppDies() {
        sandbox.write("1", to: "pmset.state")
        let app = spawnUnrelatedProcess()
        let watchdog = startWatchdog(appProcessIdentifier: app.processIdentifier, session: "s1")

        kill(app.processIdentifier, SIGKILL)
        app.waitUntilExit()

        waitUntil("watchdog exit") { !watchdog.isRunning }
        XCTAssertEqual(sleepDisabledFlag, "0")
    }

    func testWatchdogRestoresSleepOnSigterm() {
        sandbox.write("1", to: "pmset.state")
        let app = spawnUnrelatedProcess()
        let watchdog = startWatchdog(appProcessIdentifier: app.processIdentifier, session: "s1")
        let watchdogProcessIdentifier = Int32(
            (sandbox.read("state/watchdog.ready") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? watchdog.processIdentifier

        kill(watchdogProcessIdentifier, SIGTERM)

        waitUntil("flag restored") { self.sleepDisabledFlag == "0" }
    }

    func testWatchdogSkipsRestoreWhenSessionWasSuperseded() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()
        let app = spawnUnrelatedProcess()
        let watchdog = startWatchdog(appProcessIdentifier: app.processIdentifier, session: "old-session")

        // A newer Turn On claimed the session; the old watchdog is then told to restore.
        sandbox.write("new-session", to: "state/session.id")
        sandbox.write("", to: "state/restore.sentinel")

        waitUntil("watchdog exit") { !watchdog.isRunning }
        XCTAssertEqual(sleepDisabledFlag, "1", "an old watchdog must not undo a newer Stay Awake session")
        XCTAssertTrue(sandbox.exists(safetyPlistPath))
    }

    func testWatchdogKeepsSafetyDaemonWhenPmsetFails() {
        sandbox.write("1", to: "pmset.state")
        sandbox.write("", to: "pmset.fail")
        installFakeSafetyDaemonFiles()
        let app = spawnUnrelatedProcess()
        let watchdog = startWatchdog(appProcessIdentifier: app.processIdentifier, session: "s1")

        sandbox.write("", to: "state/restore.sentinel")

        waitUntil(timeout: 20, "watchdog exit") { !watchdog.isRunning }
        XCTAssertEqual(sleepDisabledFlag, "1")
        XCTAssertTrue(
            sandbox.exists(safetyPlistPath),
            "when the restore failed, the LaunchDaemon is the only remaining backstop and must stay"
        )
    }

    func testWatchdogRefusesToRunWithoutRoot() {
        let watchdogURL = sandbox.write(PrivilegedScripts.watchdogPython, to: "state/strict-watchdog.py")
        sandbox.write("s1", to: "state/session.id")
        let result = runTool("/usr/bin/python3", [watchdogURL.path, sandbox.path("state"), "1", "s1"])
        XCTAssertEqual(result.status, 2)
        XCTAssertFalse(sandbox.exists("state/watchdog.ready"))
        XCTAssertTrue(sandbox.exists("state/watchdog.notroot"))
    }

    // MARK: - Turn On script

    func testEnableScriptSetsFlagStartsWatchdogAndInstallsSafetyDaemon() throws {
        let app = spawnUnrelatedProcess()
        writeSandboxedWatchdog()
        let scriptURL = sandbox.write(enableScriptText(appProcessIdentifier: app.processIdentifier), to: "state/enable-watchdog.sh", permissions: 0o755)

        let result = runTool("/bin/bash", [scriptURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("watchdog_ok"))
        XCTAssertEqual(sleepDisabledFlag, "1")
        XCTAssertEqual(sandbox.read("state/session.id"), "session-1")
        let watchdogPID = try XCTUnwrap(Int32((sandbox.read("state/watchdog.pid") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isProcessAlive(watchdogPID))
        XCTAssertTrue(sandbox.exists(safetyPlistPath))
        XCTAssertEqual(
            sandbox.read("Library/Application Support/MacStayOn/sleep-safety.sh"),
            SleepSafetyResources.script
        )
        XCTAssertTrue(recordedCalls.contains("launchctl bootstrap system"))

        // And the watchdog it started really does restore on Off.
        sandbox.write("", to: "state/restore.sentinel")
        waitUntil("flag restored") { self.sleepDisabledFlag == "0" }
        waitUntil("watchdog gone") { !isProcessAlive(watchdogPID) }
    }

    func testEnableScriptRollsBackWhenWatchdogDoesNotStart() {
        let app = spawnUnrelatedProcess()
        // A watchdog that dies immediately (as it does when it is not root).
        sandbox.write("import sys\nsys.exit(2)\n", to: "state/watchdog.py")
        installFakeSafetyDaemonFiles()
        let scriptURL = sandbox.write(enableScriptText(appProcessIdentifier: app.processIdentifier), to: "state/enable-watchdog.sh", permissions: 0o755)

        let result = runTool("/bin/bash", [scriptURL.path], timeout: 30)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("watchdog_failed"))
        XCTAssertEqual(sleepDisabledFlag, "0", "a failed Turn On must never leave SleepDisabled=1")
        XCTAssertFalse(sandbox.exists(safetyPlistPath))
    }

    func testEnableScriptReplacesPreviousWatchdog() {
        let app = spawnUnrelatedProcess()
        let previousWatchdog = spawnProcessThatLooksLikeWatchdog()
        writeSandboxedWatchdog()
        sandbox.write(String(previousWatchdog.processIdentifier), to: "state/watchdog.pid")
        let scriptURL = sandbox.write(enableScriptText(appProcessIdentifier: app.processIdentifier), to: "state/enable-watchdog.sh", permissions: 0o755)

        let result = runTool("/bin/bash", [scriptURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        waitUntil("previous watchdog killed") { !previousWatchdog.isRunning }
        XCTAssertEqual(sleepDisabledFlag, "1")
    }

    /// The pid file can outlive its watchdog and the pid can be recycled. The script
    /// runs as root, so it must not SIGKILL whatever now owns that pid.
    func testEnableScriptNeverKillsAnUnrelatedProcessFromAStalePidFile() {
        let app = spawnUnrelatedProcess()
        let bystander = spawnUnrelatedProcess()
        writeSandboxedWatchdog()
        sandbox.write(String(bystander.processIdentifier), to: "state/watchdog.pid")
        let scriptURL = sandbox.write(enableScriptText(appProcessIdentifier: app.processIdentifier), to: "state/enable-watchdog.sh", permissions: 0o755)

        let result = runTool("/bin/bash", [scriptURL.path])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(bystander.isRunning, "an unrelated process named in a stale pid file was killed")
    }

    func testEnableScriptIgnoresGarbagePidFile() {
        let app = spawnUnrelatedProcess()
        writeSandboxedWatchdog()
        for garbage in ["1", "01", "-1", "0", "abc", "12 34", ""] {
            sandbox.write(garbage, to: "state/watchdog.pid")
            let scriptURL = sandbox.write(enableScriptText(appProcessIdentifier: app.processIdentifier), to: "state/enable-watchdog.sh", permissions: 0o755)
            let result = runTool("/bin/bash", [scriptURL.path])
            XCTAssertEqual(result.status, 0, "pid file \"\(garbage)\": \(result.stderr)")
            if let pidText = sandbox.read("state/watchdog.pid"),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - LaunchDaemon safety script

    private func runSafetyScript() -> ShellResult {
        let scriptURL = sandbox.write(sandboxed(SleepSafetyResources.script), to: "run/sleep-safety.sh", permissions: 0o755)
        return runTool("/bin/bash", [scriptURL.path])
    }

    func testSafetyScriptRestoresSleepWhenNoWatchdogIsAlive() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()

        XCTAssertEqual(runSafetyScript().status, 0)

        XCTAssertEqual(sleepDisabledFlag, "0")
    }

    func testSafetyScriptLeavesAnActiveSessionAlone() {
        sandbox.write("1", to: "pmset.state")
        installFakeSafetyDaemonFiles()
        let watchdog = spawnProcessThatLooksLikeWatchdog()
        sandbox.write(String(watchdog.processIdentifier), to: "tmp/MacStayOn-someone/watchdog.pid")

        XCTAssertEqual(runSafetyScript().status, 0)

        XCTAssertEqual(sleepDisabledFlag, "1")
        XCTAssertTrue(sandbox.exists(safetyPlistPath))
    }

    func testSafetyScriptTreatsRecycledPidAsDeadWatchdog() {
        sandbox.write("1", to: "pmset.state")
        let bystander = spawnUnrelatedProcess()
        sandbox.write(String(bystander.processIdentifier), to: "tmp/MacStayOn-someone/watchdog.pid")

        XCTAssertEqual(runSafetyScript().status, 0)

        XCTAssertEqual(sleepDisabledFlag, "0", "a stale pid file pointing at an unrelated process must not block the restore")
    }

    func testSafetyScriptUninstallsItselfOnceSleepIsNormal() {
        sandbox.write("0", to: "pmset.state")
        installFakeSafetyDaemonFiles()

        XCTAssertEqual(runSafetyScript().status, 0)

        XCTAssertFalse(sandbox.exists(safetyPlistPath))
        XCTAssertFalse(sandbox.exists("Library/Application Support/MacStayOn"))
        XCTAssertTrue(recordedCalls.contains("launchctl bootout system/com.markdebartolo.MacStayOn.sleep-safety"))
    }

    /// launchd kills a job the moment it boots itself out. The files must already be
    /// gone by then, or the plist survives and the daemon reloads at every boot.
    func testSafetyScriptRemovesItsFilesEvenThoughBootoutKillsIt() {
        sandbox.write("0", to: "pmset.state")
        sandbox.write("", to: "bootout.kills.caller")
        installFakeSafetyDaemonFiles()

        let result = runSafetyScript()

        XCTAssertNotEqual(result.status, 0, "the fake launchctl should have killed the script, as launchd does")
        XCTAssertFalse(sandbox.exists(safetyPlistPath))
        XCTAssertFalse(sandbox.exists("Library/Application Support/MacStayOn"))
    }

    func testSafetyScriptStaysInstalledWhileAWatchdogIsStillShuttingDown() {
        sandbox.write("0", to: "pmset.state")
        installFakeSafetyDaemonFiles()
        let watchdog = spawnProcessThatLooksLikeWatchdog()
        sandbox.write(String(watchdog.processIdentifier), to: "tmp/MacStayOn-someone/watchdog.ready")

        XCTAssertEqual(runSafetyScript().status, 0)

        XCTAssertTrue(sandbox.exists(safetyPlistPath))
    }
}
