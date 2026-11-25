import AppKit
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
/// Uses a *listen-only* Quartz event tap, which needs **Input Monitoring**
/// access. (It used to use NSEvent global monitors, which need Accessibility —
/// on current macOS only assistive apps can be added to that list, so the
/// shortcut could never be approved.) Event-driven, no polling; the keys still
/// reach the frontmost app because a listen-only tap cannot swallow them.
final class KeyboardShortcutController: ObservableObject {
    @Published private(set) var needsPermission = false

    var onToggle: (() -> Void)?

    private var chord = ArrowSpaceChord { keyCode in
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private static let promptedKey = "macStayOnInputMonitoringPrompted"

    func start() {
        refreshPermission(promptIfNeeded: true)
    }

    /// Re-check after the user may have granted access in System Settings.
    func refreshPermission(promptIfNeeded: Bool = false) {
        guard eventTap == nil else {
            needsPermission = false
            return
        }
        let defaults = UserDefaults.standard
        if !CGPreflightListenEventAccess(), promptIfNeeded, !defaults.bool(forKey: Self.promptedKey) {
            defaults.set(true, forKey: Self.promptedKey)
            // Shows the system prompt and adds MacStayOn (switched off) to the
            // Input Monitoring list, so the user only has to flip it on.
            _ = CGRequestListenEventAccess()
        }
        // Creating the tap is the real test: it fails until access is granted.
        if installEventTap() {
            needsPermission = false
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            needsPermission = true
            if permissionTimer == nil {
                // Notice a grant without a relaunch; stops as soon as the tap exists.
                let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
                timer.tolerance = 2
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installEventTap() -> Bool {
        if eventTap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let controller = Unmanaged<KeyboardShortcutController>.fromOpaque(userInfo).takeUnretainedValue()
                    controller.handleTapEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    /// Main run loop (the tap's source is on it).
    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS pauses taps that stall; turn it back on.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .keyDown, .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if chord.handle(isKeyUp: type == .keyUp, keyCode: keyCode) {
                onToggle?()
            }
        default:
            break
        }
    }

    deinit {
        permissionTimer?.invalidate()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }
}
