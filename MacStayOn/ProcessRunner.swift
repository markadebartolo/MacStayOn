import Foundation

/// Runs short helper tools (`pmset`, `ps`, `system_profiler`) with a hard timeout.
///
/// A hung `pmset` previously froze the menu bar forever via `waitUntilExit` on the
/// main RunLoop (MSO-7). Rules this type enforces:
/// - never wait without a deadline;
/// - never `DispatchGroup.wait` / semaphore-wait on the main thread (the UI would
///   freeze for the whole timeout) — spin the RunLoop instead;
/// - drain stdout *before* waiting for exit, so output larger than the pipe buffer
///   cannot deadlock the child.
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: Data
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let resultBox = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            resultBox.finish(Output(status: process.terminationStatus, stdout: data))
        }

        if wait(for: resultBox, timeout: timeout) {
            return resultBox.output
        }
        process.terminate()
        if !wait(for: resultBox, timeout: 1) {
            // SIGTERM ignored — do not leave a stuck helper behind.
            kill(process.processIdentifier, SIGKILL)
        }
        return nil
    }

    private static func wait(for resultBox: ResultBox, timeout: TimeInterval) -> Bool {
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(timeout)
            while !resultBox.isFinished, Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return resultBox.isFinished
        }
        return resultBox.waitUntilFinished(timeout: timeout)
    }

    /// Holds the child-process result so either thread kind can wait on it safely.
    private final class ResultBox: @unchecked Sendable {
        private let condition = NSCondition()
        private var storedOutput: Output?

        var isFinished: Bool {
            condition.lock(); defer { condition.unlock() }
            return storedOutput != nil
        }

        var output: Output? {
            condition.lock(); defer { condition.unlock() }
            return storedOutput
        }

        func finish(_ output: Output) {
            condition.lock()
            storedOutput = output
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilFinished(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock(); defer { condition.unlock() }
            while storedOutput == nil {
                if !condition.wait(until: deadline) { break }
            }
            return storedOutput != nil
        }
    }
}
