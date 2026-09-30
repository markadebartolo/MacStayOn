import AppKit

/// Orange screen pulse while the lid is closing past the warn angle — runs until cancelled (lid shut).
enum ScreenFlashAlert {
    private static var windows: [NSWindow] = []
    private static var isFlashing = false
    private static var cancelled = false
    private static var pulseToken = 0
    private static var showPhase = true
    private static let logURL = URL(fileURLWithPath: "/tmp/macstayon-lid.log")

    static func flashStayAwakeWarning() {
        // Avoid a second main-queue hop when the lid callback is already on main —
        // that delay was the bulk of “flash feels late after the warn angle.”
        if Thread.isMainThread {
            beginFlash()
        } else {
            DispatchQueue.main.async(execute: beginFlash)
        }
    }

    /// Stop pulsing (lid fully shut / Stay Awake off).
    static func cancel() {
        if Thread.isMainThread {
            cancelLocked()
        } else {
            DispatchQueue.main.async(execute: cancelLocked)
        }
    }

    private static func beginFlash() {
        // Already looping — leave it alone.
        if isFlashing, !cancelled { return }

        cancelLocked()
        isFlashing = true
        cancelled = false
        pulseToken += 1
        let token = pulseToken
        showPhase = true
        appendLog("flash loop begin")

        // Paint overlays first so the warn is visible immediately; beep/activate after.
        var created: [NSWindow] = []
        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            win.isReleasedWhenClosed = false
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            win.isOpaque = false
            win.hasShadow = false
            win.backgroundColor = NSColor(red: 0.96, green: 0.55, blue: 0.18, alpha: 0.65)
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.alphaValue = 1
            win.orderFrontRegardless()
            created.append(win)
        }
        windows = created

        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        tick(token: token)
    }

    private static func cancelLocked() {
        cancelled = true
        pulseToken += 1
        tearDownWindows()
        isFlashing = false
        appendLog("flash cancel")
    }

    private static func tick(token: Int) {
        guard !cancelled, token == pulseToken else { return }

        for win in windows {
            win.alphaValue = showPhase ? 1 : 0
            if showPhase {
                win.orderFrontRegardless()
            }
        }
        showPhase.toggle()

        // Keep pulsing until cancel() — about 3–4 Hz.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            tick(token: token)
        }
    }

    private static func tearDownWindows() {
        for win in windows {
            win.alphaValue = 0
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
    }

    private static func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
