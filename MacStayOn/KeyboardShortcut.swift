import AppKit
import ApplicationServices
import Combine

/// Detects the On/Off chord: all four arrow keys + Space held at the same time.
/// Pure logic (no AppKit monitors) so it can be unit tested.
struct ArrowSpaceChord {
    /// ← → ↓ ↑ and Space (virtual key codes, layout independent).
    static let keyCodes: Set<UInt16> = [123, 124, 125, 126, 49]

    /// Reports whether a key is physically down right now.
    let isKeyDown: (UInt16) -> Bool
    /// Fires once per hold: key repeat while the chord stays down must not toggle again.
    private(set) var isLatched = false

    init(isKeyDown: @escaping (UInt16) -> Bool) {
        self.isKeyDown = isKeyDown
    }

    /// Feed every key event. Returns true when this key-down completes the chord.
    mutating func handle(isKeyUp: Bool, keyCode: UInt16) -> Bool {
        guard Self.keyCodes.contains(keyCode) else { return false }
        if isKeyUp {
            // Releasing any chord key re-arms the shortcut.
            isLatched = false
            return false
        }
        guard !isLatched else { return false }
        // The key in this event is down even if the system state lags behind it.
        let allDown = Self.keyCodes.allSatisfy { $0 == keyCode || isKeyDown($0) }
        guard allDown else { return false }
        isLatched = true
        return true
    }
}

/// Global ←→↑↓ + Space shortcut that toggles Stay Awake from any app.
///
/// Watching keys typed in *other* apps needs Accessibility permission. The
/// monitors are event-driven — no polling — so there is no cost while idle.
/// The keys still reach the frontmost app (MacStayOn only listens).
final class KeyboardShortcutController: ObservableObject {
    @Published private(set) var needsPermission = false

    var onToggle: (() -> Void)?

    private var chord = ArrowSpaceChord { keyCode in
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private static let promptedKey = "macStayOnShortcutPermissionPrompted"

    func start() {
        // Our own panel (global monitors never see this app's events).
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
        refreshPermission(promptIfNeeded: true)
    }

    /// Re-check after the user may have granted access in System Settings.
    func refreshPermission(promptIfNeeded: Bool = false) {
        let defaults = UserDefaults.standard
        let shouldPrompt = promptIfNeeded && !defaults.bool(forKey: Self.promptedKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if shouldPrompt { defaults.set(true, forKey: Self.promptedKey) }

        needsPermission = !trusted
        if trusted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            installGlobalMonitor()
        } else if permissionTimer == nil {
            // Notice a grant without a relaunch; stops as soon as access is given.
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                self?.refreshPermission()
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        if chord.handle(isKeyUp: event.type == .keyUp, keyCode: event.keyCode) {
            onToggle?()
        }
    }

    deinit {
        permissionTimer?.invalidate()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
