import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Holds an IOKit `PreventSystemSleep` assertion so closing the MacBook lid
/// does not put the machine to sleep (the approach used by apps like
/// KeepingYouAwake / Amphetamine — not idle-only `caffeinate -i`).
///
/// Apple typically honors this while on AC power. On battery, macOS may still
/// sleep on lid close for thermal/safety policy.
final class SleepAssertionManager: ObservableObject {
    private static let defaultsKey = "lidStayAwakeEnabled"
    private static let assertionName = "LidAwake: keep system awake with lid closed" as CFString

    @Published private(set) var isEnabled: Bool
    @Published private(set) var statusDetail: String?
    @Published private(set) var lastError: String?

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    init() {
        let saved = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        self.isEnabled = false
        if saved {
            setEnabled(true)
        } else {
            refreshStatusDetail()
        }
    }

    deinit {
        // Best-effort release if the process is torn down while enabled.
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            activateAssertion()
        } else {
            releaseAssertion()
        }
    }

    private func activateAssertion() {
        if hasAssertion {
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            refreshStatusDetail()
            return
        }

        var newID: IOPMAssertionID = 0
        // PreventSystemSleep blocks system sleep including lid-close sleep
        // (when macOS policy allows — generally on AC power).
        let type = kIOPMAssertionTypePreventSystemSleep as CFString
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName,
            &newID
        )

        if result == kIOReturnSuccess {
            assertionID = newID
            hasAssertion = true
            isEnabled = true
            lastError = nil
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
        } else {
            isEnabled = false
            lastError = "Could not create sleep assertion (IOReturn \(result))."
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        }
        refreshStatusDetail()
    }

    private func releaseAssertion() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            hasAssertion = false
        }
        isEnabled = false
        lastError = nil
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        refreshStatusDetail()
    }

    private func refreshStatusDetail() {
        if let lastError {
            statusDetail = lastError
            return
        }

        let onAC = Self.isOnACPower()
        if isEnabled {
            statusDetail = onAC
                ? "Power assertion active · AC power"
                : "Power assertion active · on battery (lid-close sleep may still apply)"
        } else {
            statusDetail = onAC ? "AC power · assertion off" : "On battery · assertion off"
        }
    }

    private static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any],
              let state = desc[kIOPSPowerSourceStateKey] as? String
        else {
            return false
        }
        return state == kIOPSACPowerValue
    }
}
