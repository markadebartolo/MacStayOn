import AppKit
import Foundation

/// Ensures only one MacStayOn GUI instance owns `/tmp/MacStayOn-$USER` state.
enum SingleInstance {
    /// If another non-terminated instance of this bundle is already running,
    /// activate it and return `false` (caller should exit). Otherwise `true`.
    @discardableResult
    static func claimOrActivateExisting() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.markdebartolo.MacStayOn"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != myPID }
        guard let existing = others.first else { return true }
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return false
    }
}
