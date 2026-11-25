import XCTest

final class ParsingTests: XCTestCase {
    // MARK: - pmset -g

    func testParsesSleepDisabledFromSystemWideSettings() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
        """
        XCTAssertEqual(SleepAssertionManager.parseSleepDisabled(pmsetOutput: output), 1)
    }

    func testParsesZeroAndLegacyKeyName() {
        XCTAssertEqual(SleepAssertionManager.parseSleepDisabled(pmsetOutput: " SleepDisabled\t\t0\n"), 0)
        XCTAssertEqual(SleepAssertionManager.parseSleepDisabled(pmsetOutput: " disablesleep         1\n"), 1)
    }

    /// Bag safety: a missing key is "unknown", never "sleep is normal".
    func testMissingKeyIsUnknownNotZero() {
        XCTAssertNil(SleepAssertionManager.parseSleepDisabled(pmsetOutput: "Currently in use:\n standby 1\n"))
        XCTAssertNil(SleepAssertionManager.parseSleepDisabled(pmsetOutput: ""))
        XCTAssertNil(SleepAssertionManager.parseSleepDisabled(pmsetOutput: " SleepDisabled\t\tyes\n"))
    }

    func testReadsTheRealPmsetOnThisMac() throws {
        let result = try XCTUnwrap(ProcessRunner.run(executable: "/usr/bin/pmset", arguments: ["-g"], timeout: 5))
        XCTAssertEqual(result.status, 0)
        let value = SleepAssertionManager.parseSleepDisabled(pmsetOutput: String(decoding: result.stdout, as: UTF8.self))
        XCTAssertNotNil(value, "this macOS no longer prints SleepDisabled in `pmset -g` — the app could not verify lid sleep")
    }

    // MARK: - pmset -g assertions

    func testForeignSleepHoldersAreNamedAndOwnOnesSkipped() {
        let output = """
        Assertion status system-wide:
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 707(Claude): [0x0001] 00:10:00 PreventUserIdleSystemSleep named: "Electron"
           pid 900(MacStayOn): [0x0002] 00:10:00 PreventSystemSleep named: "MacStayOn: keep system awake"
           pid 4321(xctest): [0x0003] 00:10:00 PreventSystemSleep named: "other"
           pid 88(powerd): [0x0004] 00:10:00 PreventUserIdleSystemSleep named: "Powerd"
           pid 55(caffeinate): [0x0005] 00:10:00 NoIdleSleepAssertion named: "caffeinate"
        """
        let note = SleepAssertionManager.foreignSleepHoldersNote(assertionsOutput: output, ownProcessIdentifier: 4321)
        XCTAssertEqual(note, "Also preventing idle sleep (not MacStayOn): Claude, caffeinate")
    }

    func testNoForeignHoldersMeansNoNote() {
        XCTAssertNil(SleepAssertionManager.foreignSleepHoldersNote(
            assertionsOutput: "Assertion status system-wide:\n   PreventUserIdleSystemSleep     0\n",
            ownProcessIdentifier: 1
        ))
    }

    // MARK: - Messages and quoting

    func testEnableFailureMessages() {
        XCTAssertEqual(
            SleepAssertionManager.userFacingEnableFailure("watchdog_failed"),
            "Couldn't start the sleep watchdog after admin approval — stayed Off. Try Turn On again."
        )
        XCTAssertEqual(
            SleepAssertionManager.userFacingEnableFailure("The administrator user name or password was incorrect. Not authorized."),
            "Admin authorization failed — stayed Off."
        )
        XCTAssertEqual(SleepAssertionManager.userFacingEnableFailure("  "), "Admin authorization failed — stayed Off.")
        XCTAssertEqual(
            SleepAssertionManager.userFacingEnableFailure("disk full"),
            "Couldn't enable Stay Awake — stayed Off. disk full"
        )
        XCTAssertEqual(
            SleepAssertionManager.userFacingEnableFailure(String(repeating: "x", count: 200)),
            "Couldn't enable Stay Awake after admin approval — stayed Off."
        )
    }

    func testShellQuotingRoundTripsThroughARealShell() {
        for value in ["plain", "with space", "o'brien", "a\"b", "$HOME `id` \\ ; rm -rf /", ""] {
            let result = runTool("/bin/sh", ["-c", "printf %s \(SleepAssertionManager.shellQuote(value))"])
            XCTAssertEqual(result.stdout, value)
        }
        let escaped = PrivilegedScripts.singleQuoteEscaped("o'brien $x")
        XCTAssertEqual(runTool("/bin/sh", ["-c", "printf %s '\(escaped)'"]).stdout, "o'brien $x")
    }

    func testAppleScriptLiteralRoundTrips() {
        for value in ["plain", "quote \" inside", "back\\slash", "both \\\" mixed"] {
            var errorInfo: NSDictionary?
            let descriptor = NSAppleScript(source: "return \(SleepAssertionManager.appleStringLiteral(value))")?
                .executeAndReturnError(&errorInfo)
            XCTAssertNil(errorInfo)
            XCTAssertEqual(descriptor?.stringValue, value)
        }
    }

    func testBatteryFloorClamp() {
        XCTAssertEqual(SleepAssertionManager.clampFloor(-5), 10)
        XCTAssertEqual(SleepAssertionManager.clampFloor(10), 10)
        XCTAssertEqual(SleepAssertionManager.clampFloor(35), 35)
        XCTAssertEqual(SleepAssertionManager.clampFloor(50), 50)
        XCTAssertEqual(SleepAssertionManager.clampFloor(51), 50)
    }

    // MARK: - Session analytics / hardware / lid sensor

    func testDurationFormatting() {
        XCTAssertEqual(SessionAnalytics.formatDuration(0), "0s")
        XCTAssertEqual(SessionAnalytics.formatDuration(-4), "0s")
        XCTAssertEqual(SessionAnalytics.formatDuration(59.4), "59s")
        XCTAssertEqual(SessionAnalytics.formatDuration(61), "1m 01s")
        XCTAssertEqual(SessionAnalytics.formatDuration(3600), "1h 00m")
        XCTAssertEqual(SessionAnalytics.formatDuration(3 * 3600 + 7 * 60 + 59), "3h 07m")
    }

    func testSessionAnalyticsLifecycle() {
        let analytics = SessionAnalytics()
        analytics.start()
        XCTAssertTrue(analytics.isLive)
        XCTAssertFalse(analytics.hasSummary)

        spinMainRunLoop(for: 2.3)
        XCTAssertGreaterThan(analytics.elapsed, 1.5, "the session clock is not advancing")

        analytics.stopAndRetainSummary()
        XCTAssertFalse(analytics.isLive)
        XCTAssertTrue(analytics.hasSummary)
        let frozenElapsed = analytics.elapsed
        spinMainRunLoop(for: 1.2)
        XCTAssertEqual(analytics.elapsed, frozenElapsed, "a finished session's clock kept running")

        analytics.clear()
        XCTAssertFalse(analytics.hasSummary)
        XCTAssertEqual(analytics.elapsed, 0)
        XCTAssertFalse(analytics.isLive)
    }

    func testFanlessDetection() {
        XCTAssertTrue(HardwareProfile.matchesFanlessPortable(modelIdentifier: "Mac15,12", marketingName: "MacBook Air"))
        XCTAssertTrue(HardwareProfile.matchesFanlessPortable(modelIdentifier: "MacBookAir10,1", marketingName: ""))
        XCTAssertTrue(HardwareProfile.matchesFanlessPortable(modelIdentifier: "Mac17,5", marketingName: ""))
        XCTAssertFalse(HardwareProfile.matchesFanlessPortable(modelIdentifier: "Mac16,5", marketingName: "MacBook Pro"))
    }

    func testMenuLabel() {
        XCTAssertEqual(
            HardwareProfile.Info(modelIdentifier: "Mac16,5", marketingName: "MacBook Pro", chipName: "Apple M5 Max").menuLabel,
            "MacBook Pro · M5 Max"
        )
        XCTAssertEqual(HardwareProfile.Info(modelIdentifier: "Mac16,5", marketingName: "", chipName: "").menuLabel, "Mac16,5")
        XCTAssertEqual(HardwareProfile.Info(modelIdentifier: "", marketingName: "", chipName: "").menuLabel, "Mac")
    }

    /// The UI asks for the hardware profile on the main thread; that must be instant
    /// even before the slow `system_profiler` warm-up has finished.
    func testHardwareProfileNeverBlocksTheMainThread() {
        let started = Date()
        let info = HardwareProfile.current
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(info.modelIdentifier.isEmpty)
        _ = HardwareProfile.enableHeatWarningTitle
        _ = HardwareProfile.enableHeatWarningBody
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testHardwareProfileWarmUpCompletes() {
        let warmed = expectation(description: "warm cache completion")
        HardwareProfile.warmCache { warmed.fulfill() }
        wait(for: [warmed], timeout: 30)
        XCTAssertFalse(HardwareProfile.current.menuLabel.isEmpty)
    }
}
