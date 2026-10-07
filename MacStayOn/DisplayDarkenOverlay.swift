import AppKit

/// Full-screen black cover while Stay Awake keeps the Mac running.
/// Does **not** allow display sleep — overlays only. Key or click dismisses.
enum DisplayDarkenOverlay {
    private static var windows: [NSWindow] = []
    private static var localMonitor: Any?
    private static var globalMonitor: Any?
    private static var isActive = false
    private static var onDismiss: (() -> Void)?

    static var isDarkened: Bool { isActive }

    /// Paint black over all displays immediately. `onDismiss` runs once on key/click.
    static func activate(onDismiss: @escaping () -> Void) {
        if Thread.isMainThread {
            activateLocked(onDismiss: onDismiss)
        } else {
            DispatchQueue.main.async { activateLocked(onDismiss: onDismiss) }
        }
    }

    static func deactivate() {
        if Thread.isMainThread {
            deactivateLocked()
        } else {
            DispatchQueue.main.async(execute: deactivateLocked)
        }
    }

    private static func activateLocked(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        if isActive {
            // Already up — refresh screens (docked display change).
            tearDownWindows()
            buildWindows()
            return
        }
        isActive = true
        buildWindows()
        installMonitors()
    }

    private static func deactivateLocked() {
        guard isActive || !windows.isEmpty else { return }
        isActive = false
        removeMonitors()
        tearDownWindows()
        onDismiss = nil
    }

    private static func buildWindows() {
        var created: [DismissWindow] = []
        for screen in NSScreen.screens {
            let win = DismissWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
            win.isOpaque = true
            win.hasShadow = false
            win.backgroundColor = .black
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.alphaValue = 1
            win.onDismissRequest = { requestDismiss() }
            win.orderFrontRegardless()
            win.makeKey()
            created.append(win)
        }
        windows = created
        // Ensure first window can receive key events.
        created.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func tearDownWindows() {
        for win in windows {
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
    }

    private static func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]) { event in
            requestDismiss()
            return nil
        }
        // Mouse works globally without Accessibility; keyDown may require trust — local covers our windows.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
        ]) { _ in
            requestDismiss()
        }
    }

    private static func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private static func requestDismiss() {
        guard isActive else { return }
        let callback = onDismiss
        deactivateLocked()
        callback?()
    }

    /// Black window that forwards clicks to dismiss.
    private final class DismissWindow: NSWindow {
        var onDismissRequest: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onDismissRequest?()
        }

        override func keyDown(with event: NSEvent) {
            onDismissRequest?()
        }

        override func rightMouseDown(with event: NSEvent) {
            onDismissRequest?()
        }
    }
}
