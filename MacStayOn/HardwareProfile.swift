import Darwin
import Foundation

/// Local Mac identity for warnings (model id + marketing name).
enum HardwareProfile {
    struct Info: Equatable {
        var modelIdentifier: String
        var marketingName: String
    }

    private static var cached: Info?
    private static let lock = NSLock()

    /// Prefetch model info off the critical path (system_profiler can take a moment).
    static func warmCache() {
        DispatchQueue.global(qos: .utility).async {
            _ = current
        }
    }

    static var current: Info {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let info = Info(
            modelIdentifier: readModelIdentifier(),
            marketingName: readMarketingName() ?? ""
        )
        cached = info
        return info
    }

    /// Fanless MacBook Air — closed-lid work heats and throttles faster.
    static var isMacBookAir: Bool {
        matchesMacBookAir(modelIdentifier: current.modelIdentifier, marketingName: current.marketingName)
    }

    static func matchesMacBookAir(modelIdentifier: String, marketingName: String) -> Bool {
        if marketingName.localizedCaseInsensitiveContains("MacBook Air") {
            return true
        }
        // Older identifiers were MacBookAir10,1; keep the prefix check.
        if modelIdentifier.localizedCaseInsensitiveContains("MacBookAir") {
            return true
        }
        return false
    }

    /// Turn On heat copy. Air gets a shorter closed-lid advisory.
    static var enableHeatWarningBody: String {
        let common = """
        MacStayOn will prevent sleep when you close the lid so agents and other work can keep running.

        A closed Mac can overheat in a confined space. Do not put it in a bag, under a blanket, or in another enclosed space while this is on.
        """
        guard isMacBookAir else { return common }

        let name = current.marketingName.isEmpty ? "MacBook Air" : current.marketingName
        return """
        \(common)

        This Mac is a \(name) (fanless). Closed-lid work can heat up and throttle sooner than on a MacBook Pro — prefer shorter closed sessions, keep it on a hard cool surface, and open the lid if it feels hot or performance drops.
        """
    }

    // MARK: - Readers

    private static func readModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return "" }
        return String(cString: buffer)
    }

    /// Marketing name from `system_profiler` JSON (`machine_name`), e.g. "MacBook Air".
    private static func readMarketingName() -> String? {
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
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["SPHardwareDataType"] as? [[String: Any]],
            let first = rows.first
        else {
            return nil
        }
        // Key is machine_name in JSON output.
        if let name = first["machine_name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

}
