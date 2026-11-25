import XCTest

final class UpdateInstallGateTests: XCTestCase {
    /// Scheduled work runs only when the test says time has passed.
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var busy = false
    private var installs = 0

    private func makeGate() -> UpdateInstallGate {
        UpdateInstallGate(gracePeriod: 10, isBusy: { [unowned self] in self.busy }) { [unowned self] delay, work in
            self.scheduled.append((delay, work))
        }
    }

    private func runScheduled() {
        let due = scheduled
        scheduled = []
        due.forEach { $0.work() }
    }

    func testInstallsAfterTheGracePeriodWhenStayAwakeIsOff() {
        let gate = makeGate()
        gate.updateReady { self.installs += 1 }
        XCTAssertEqual(installs, 0, "never installs on the spot")
        XCTAssertEqual(scheduled.map(\.delay), [10])
        runScheduled()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(gate.hasPendingUpdate)
    }

    func testWaitsWhileStayAwakeIsOnThenInstallsAfterItTurnsOff() {
        busy = true
        let gate = makeGate()
        gate.updateReady { self.installs += 1 }
        XCTAssertTrue(scheduled.isEmpty, "nothing is even scheduled during a session")
        XCTAssertTrue(gate.hasPendingUpdate)

        busy = false
        gate.stateChanged()
        runScheduled()
        XCTAssertEqual(installs, 1)
    }

    func testTurningOnDuringTheGracePeriodCancelsTheInstall() {
        let gate = makeGate()
        gate.updateReady { self.installs += 1 }
        // Stay Awake goes on (or Touch ID opens) before the 10 s pass.
        busy = true
        gate.stateChanged()
        runScheduled()
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(gate.hasPendingUpdate, "still waiting for the next Off")

        busy = false
        gate.stateChanged()
        runScheduled()
        XCTAssertEqual(installs, 1)
    }

    func testOnlyTheLatestScheduledCheckCanInstallAndOnlyOnce() {
        let gate = makeGate()
        gate.updateReady { self.installs += 1 }
        gate.stateChanged()
        gate.stateChanged()
        XCTAssertEqual(scheduled.count, 3)
        runScheduled()
        XCTAssertEqual(installs, 1)
        gate.stateChanged()
        runScheduled()
        XCTAssertEqual(installs, 1, "nothing left to install")
    }

    func testAutomaticUpdatesAreOnInTheShippedSettings() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacStayOn/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
        XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
    }
}
