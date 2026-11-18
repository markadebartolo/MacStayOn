import Foundation
import XCTest

/// A throwaway directory tree plus small helpers shared by the test cases.
final class TestSandbox {
    let rootURL: URL

    init(name: String = "sandbox") {
        // Resolve /var → /private/var so paths match what `ps` and the scripts print.
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("MacStayOnTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func path(_ relativePath: String) -> String {
        url(relativePath).path
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) -> URL {
        let directoryURL = url(relativePath)
        try! FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    @discardableResult
    func write(_ text: String, to relativePath: String, permissions: Int = 0o644) -> URL {
        let fileURL = url(relativePath)
        try! FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! Data(text.utf8).write(to: fileURL)
        try! FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
        return fileURL
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relativePath))
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

@discardableResult
func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice
    try! process.run()

    var stdoutData = Data()
    var stderrData = Data()
    let readGroup = DispatchGroup()
    readGroup.enter()
    DispatchQueue.global().async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global().async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    process.waitUntilExit()
    killer.cancel()
    // Background children may keep the pipes open; do not wait on them forever.
    _ = readGroup.wait(timeout: .now() + 2)
    return ShellResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

/// Starts a long-lived child and returns it; the caller terminates it.
func spawnDetached(_ executable: String, _ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try! process.run()
    return process
}

func isProcessAlive(_ processIdentifier: Int32) -> Bool {
    kill(processIdentifier, 0) == 0
}

extension XCTestCase {
    /// Spins the main run loop until `condition` holds (main-queue work keeps flowing).
    @discardableResult
    func waitUntil(
        timeout: TimeInterval = 10,
        _ description: String = "condition",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
        return false
    }

    /// Lets queued main-thread work run for a fixed time.
    func spinMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

/// Repository root, located from this source file.
let repositoryRootURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
