import Darwin
import Foundation

/// Local Mac identity for warnings and the menu status line.
enum HardwareProfile {
    struct Info: Equatable {
        var modelIdentifier: String
        var marketingName: String
        var chipName: String

        /// Compact label for the menu, e.g. "MacBook Pro · M5 Max".
        var menuLabel: String {
            let name = marketingName.isEmpty ? (modelIdentifier.isEmpty ? "Mac" : modelIdentifier) : marketingName
            let chip = HardwareProfile.shortChip(chipName)
            if chip.isEmpty { return name }
            return "\(name) · \(chip)"
        }
    }

    private static var cached: Info?
    private static let lock = NSLock()
    private static var warmCompletions: [() -> Void] = []

    /// Prefetch model info off the critical path (system_profiler can take a moment).
    static func warmCache(completion: (() -> Void)? = nil) {
        if let completion {
            lock.lock()
            if cached != nil {
                lock.unlock()
                DispatchQueue.main.async(execute: completion)
                return
            }
            warmCompletions.append(completion)
            lock.unlock()
        }
        DispatchQueue.global(qos: .utility).async {
            _ = current
            let callbacks: [() -> Void]
            lock.lock()
            callbacks = warmCompletions
            warmCompletions.removeAll()
            lock.unlock()
            if !callbacks.isEmpty {
                DispatchQueue.main.async {
                    callbacks.forEach { $0() }
                }
            }
        }
    }

    static var current: Info {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let profile = readProfile()
        let info = Info(
            modelIdentifier: profile.modelIdentifier.isEmpty ? readModelIdentifier() : profile.modelIdentifier,
            marketingName: profile.marketingName,
            chipName: profile.chipName
        )
        cached = info
        return info
    }

    /// Fanless portables (MacBook Air, MacBook Neo) — closed-lid work heats/throttles faster.
    static var isFanlessPortable: Bool {
        matchesFanlessPortable(modelIdentifier: current.modelIdentifier, marketingName: current.marketingName)
    }

    /// Known fanless model ids when marketing name is missing (Neo = Mac17,5).
    private static let knownFanlessModelIdentifiers: Set<String> = [
        "Mac17,5", // MacBook Neo (A18 Pro, fanless)
    ]

    static func matchesFanlessPortable(modelIdentifier: String, marketingName: String) -> Bool {
        let name = marketingName.lowercased()
        if name.contains("macbook air") || name.contains("macbook neo") {
            return true
        }
        // Older Air identifiers were MacBookAir10,1; Neo uses Mac17,5-style ids.
        if modelIdentifier.localizedCaseInsensitiveContains("MacBookAir") {
            return true
        }
        if knownFanlessModelIdentifiers.contains(modelIdentifier) {
            return true
        }
        return false
    }

    /// Turn On heat copy. Fanless Air / Neo get a shorter closed-lid advisory.
    static var enableHeatWarningBody: String {
        let common = """
        Stay Awake keeps the Mac from sleeping and blocks the screensaver with the lid open or closed, so agents and other work can keep running.

        A closed Mac can overheat in a confined space. Do not put it in a bag, under a blanket, or in another enclosed space while this is on.
        """
        guard isFanlessPortable else { return common }

        let name: String
        if !current.marketingName.isEmpty {
            name = current.marketingName
        } else if knownFanlessModelIdentifiers.contains(current.modelIdentifier) {
            name = "MacBook Neo"
        } else {
            name = "MacBook Air"
        }
        return """
        \(common)

        This Mac is a \(name) (fanless). Closed-lid work can heat up and throttle sooner than on a MacBook Pro — prefer shorter closed sessions, keep it on a hard cool surface, and open the lid if it feels hot or performance drops.
        """
    }

    // MARK: - Readers

    private static func shortChip(_ chip: String) -> String {
        var s = chip.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        // "Apple M5 Max" → "M5 Max"
        if s.lowercased().hasPrefix("apple ") {
            s = String(s.dropFirst(6))
        }
        return s
    }

    /// Fast path for menu before `system_profiler` finishes (model id only).
    static func readModelIdentifierForDisplay() -> String {
        readModelIdentifier()
    }

    private static func readModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return "" }
        return String(cString: buffer)
    }

    private struct RawProfile {
        var modelIdentifier: String = ""
        var marketingName: String = ""
        var chipName: String = ""
    }

    /// Marketing name / chip from `system_profiler` JSON.
    private static func readProfile() -> RawProfile {
        var raw = RawProfile()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPHardwareDataType", "-json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return raw
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["SPHardwareDataType"] as? [[String: Any]],
            let first = rows.first
        else {
            return raw
        }
        if let name = first["machine_name"] as? String {
            raw.marketingName = name
        }
        if let model = first["machine_model"] as? String {
            raw.modelIdentifier = model
        }
        if let chip = first["chip_type"] as? String {
            raw.chipName = chip
        }
        return raw
    }
}
