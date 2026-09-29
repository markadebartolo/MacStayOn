import AppKit

/// Brief full-screen orange pulse while the lid is closing — cancels if the lid finishes shutting.
enum ScreenFlashAlert {
    private static var windows: [NSWindow] = []
    private static var isFlashing = false
    private static var cancelled = false
    private static var pulseToken = 0
    private static let logURL = URL(fileURLWithPath: "/tmp/macstayon-lid.log")

    static func flashStayAwakeWarning() {
        DispatchQueue.main.async {
            cancelLocked()
            isFlashing = true
            cancelled = false
            pulseToken += 1
            let token = pulseToken
            appendLog("flash begin")
            NSSound.beep()
            NSApp.activate(ignoringOtherApps: true)

            var created: [NSWindow] = []
            let screens = NSScreen.screens
            appendLog("flash screens=\(screens.count)")
            for screen in screens {
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

            // Hard on/off toggles (no animation dependency).
            pulse(step: 0, token: token)
        }
    }

    static func cancel() {
        DispatchQueue.main.async {
            cancelLocked()
        }
    }

    private static func cancelLocked() {
        cancelled = true
        pulseToken += 1
        tearDownWindows()
        isFlashing = false
        appendLog("flash cancel")
    }

    private static func pulse(step: Int, token: Int) {
        guard !cancelled, token == pulseToken else { return }
        let show = step % 2 == 0
        for win in windows {
            win.alphaValue = show ? 1 : 0
            win.orderFrontRegardless()
        }
        if step < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                pulse(step: step + 1, token: token)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard !cancelled, token == pulseToken else { return }
                tearDownWindows()
                isFlashing = false
                appendLog("flash end")
            }
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
