import AppKit
import Foundation

/// What the guide window should show when MacStayOn launches.
enum LaunchGuide: Equatable {
    case none
    /// First launch on this Mac: the full walkthrough.
    case welcome
    /// Launched on a newer version than last time. `from` is nil when the
    /// earlier version predates this screen.
    case updated(from: String?, to: String, stayAwakeWasOn: Bool)
    /// Relaunched from Applications after "Move to Applications": carry on with the walkthrough.
    case resumeAfterMove
}

enum LaunchGuideDecider {
    static let lastVersionKey = "macStayOnLastLaunchedVersion"
    /// Set when MacStayOn quits while Stay Awake was on (an update restarts the app).
    static let wasOnAtQuitKey = "macStayOnWasOnAtQuit"
    static let resumeAfterMoveKey = "macStayOnResumeGuideAfterMove"
    /// Settings any earlier version would have written; their presence means
    /// this isn't a first install even though no version was recorded.
    static let earlierInstallKeys = [
        "macStayOnEnabled", "macStayOnGuardEnabled", "macStayOnBatteryFloor",
        "macStayOnDarkenDisplay", "macStayOnInputMonitoringPrompted",
        "SUHasLaunchedBefore", "SULastCheckTime",
    ]

    /// Decide once per launch, and record this launch. Call before anything
    /// else writes settings, so a first install still looks like one.
    static func onLaunch(currentVersion: String, defaults: UserDefaults) -> LaunchGuide {
        let last = defaults.string(forKey: lastVersionKey)
        let wasOn = defaults.bool(forKey: wasOnAtQuitKey)
        let resume = defaults.bool(forKey: resumeAfterMoveKey)
        let earlierInstall = earlierInstallKeys.contains { defaults.object(forKey: $0) != nil }
        defaults.removeObject(forKey: wasOnAtQuitKey)
        defaults.removeObject(forKey: resumeAfterMoveKey)
        defaults.set(currentVersion, forKey: lastVersionKey)

        if resume { return .resumeAfterMove }
        if let last {
            guard isVersion(last, olderThan: currentVersion) else { return .none }
            return .updated(from: last, to: currentVersion, stayAwakeWasOn: wasOn)
        }
        return earlierInstall ? .updated(from: nil, to: currentVersion, stayAwakeWasOn: wasOn) : .welcome
    }

    static func isVersion(_ a: String, olderThan b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}

/// Highlights shown on the "updated" screen, newest first.
enum WhatsNew {
    static let releases: [(version: String, notes: [String])] = [
        ("1.5.5", [
            "MacStayOn is in the Dock too. Click its icon to open the menu, or right-click for Stay Awake, Turn Off and the guide.",
        ]),
        ("1.5.4", [
            "A new app icon: a laptop with the lid open and its screen glowing over the keyboard. Still awake.",
        ]),
        ("1.5.3", [
            "Automatic updates: new versions download in the background and install only while Stay Awake is off, so a session is never interrupted. Then MacStayOn reopens and shows what's new.",
            "Prefer to install yourself? Turn off Install updates automatically in the guide's Updates step.",
        ]),
        ("1.5.2", [
            "The guide's Turn On step now shows both ways in: the menu, and the ← → ↑ ↓ + Space shortcut (with whether it's ready to use).",
        ]),
        ("1.5.1", [
            "The glow and pull chain are now a quick confirmation: they show while Stay Awake turns on or off, then tuck away, instead of staying on screen.",
            "To turn off, use Restore in the menu, the ← → ↑ ↓ + Space shortcut, or Quit.",
        ]),
        ("1.5.0", [
            "A built-in guide walks you through setup, permissions, the keyboard shortcut and updates. Open it any time with the ? button in the menu.",
            "The Permissions step shows what MacStayOn may ask for and why, with live status and a button to fix each one.",
            "macOS now lists MacStayOn's background safety net under its own name instead of \"bash\".",
            "If MacStayOn is running from Downloads, it offers to move itself to Applications.",
        ]),
        ("1.4.0", [
            "A warm glow and pull chain drop from the menu bar to confirm when Stay Awake turns on or off.",
        ]),
    ]

    /// Notes for every release newer than `from` (the latest two when unknown).
    static func notes(since from: String?) -> [String] {
        let newer = releases.filter { release in
            guard let from else { return true }
            return LaunchGuideDecider.isVersion(from, olderThan: release.version)
        }
        let picked = from == nil ? Array(newer.prefix(2)) : newer
        return picked.flatMap(\.notes)
    }
}

// MARK: - Install location

enum InstallLocation {
    static func isInApplicationsFolder(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// macOS runs a downloaded app from a hidden, read-only copy ("App
    /// Translocation") until it is moved. Those paths contain this folder name.
    static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// The user's actual copy (e.g. in Downloads), even when macOS is running a translocated one.
    static func originalURL(of url: URL) -> URL {
        guard isTranslocated(url),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return url
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        guard let original = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }

    /// Friendly name of the folder holding the app ("Downloads", "Desktop", …).
    static func folderName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }
}

/// Moves MacStayOn into Applications, replacing an older copy there, so there
/// is exactly one copy and updates install where the user expects.
struct AppMover {
    var applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    var fileManager = FileManager.default
    /// What happens to an older copy already in Applications (Trash, so it can be recovered).
    var discardExisting: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Returns the app's new location.
    func moveIntoApplications(_ source: URL) throws -> URL {
        let destination = applicationsFolder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        if source.standardizedFileURL == destination.standardizedFileURL { return destination }
        if fileManager.fileExists(atPath: destination.path) {
            try discardExisting(destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Read-only source (a disk image, a locked folder): copy instead.
            try fileManager.copyItem(at: source, to: destination)
        }
        Self.clearQuarantine(destination)
        return destination
    }

    /// The user already opened this notarized app; clear the download flag so
    /// the moved copy opens directly instead of being translocated again.
    static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Open the moved copy once this process has fully exited, then quit.
    static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
            "macstayon-relaunch",
            url.path,
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}
