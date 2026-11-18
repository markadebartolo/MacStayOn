import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testReturnsStatusAndOutput() {
        let result = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf hello; exit 3"], timeout: 5)
        XCTAssertEqual(result?.status, 3)
        XCTAssertEqual(result.map { String(decoding: $0.stdout, as: UTF8.self) }, "hello")
    }

    func testMissingExecutableReturnsNil() {
        XCTAssertNil(ProcessRunner.run(executable: "/nonexistent/tool", arguments: [], timeout: 1))
    }

    /// A hung helper must cost at most its timeout — this is what froze the menu bar.
    func testHungProcessIsAbandonedAtTheTimeoutOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        let started = Date()
        let result = ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3)
    }

    func testHungProcessIsAbandonedAtTheTimeoutOffTheMainThread() {
        let finished = expectation(description: "background run finished")
        var result: ProcessRunner.Output? = ProcessRunner.Output(status: 0, stdout: Data())
        var elapsed: TimeInterval = 0
        DispatchQueue.global().async {
            let started = Date()
            result = ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
            elapsed = Date().timeIntervalSince(started)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3)
    }

    func testProcessThatIgnoresSigtermIsStillAbandoned() {
        let started = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
            timeout: 0.5
        )
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    /// Output larger than the pipe buffer used to be able to deadlock (wait-then-read).
    func testLargeOutputDoesNotDeadlock() {
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 400000 /dev/zero | tr '\\0' 'x'"],
            timeout: 10
        )
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.stdout.count, 400_000)
    }

    func testMainThreadKeepsServicingItsQueueWhileWaiting() {
        var mainQueueRan = false
        DispatchQueue.main.async { mainQueueRan = true }
        _ = ProcessRunner.run(executable: "/bin/sleep", arguments: ["0.3"], timeout: 5)
        XCTAssertTrue(mainQueueRan, "the main thread was blocked instead of spinning its run loop")
    }
}
