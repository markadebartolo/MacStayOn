import AppKit

/// Brief full-screen orange pulse while the lid is closing — cancels if the lid finishes shutting.
enum ScreenFlashAlert {
    private static var windows: [NSWindow] = []
    private static var isFlashing = false
    private static var cancelled = false
    private static var pulseToken = 0

    /// Pulses orange a few times. Call `cancel()` when the lid is fully shut.
    static func flashStayAwakeWarning() {
        DispatchQueue.main.async {
            // Restart a fresh brief warn if somehow mid-flash.
            cancel()
            isFlashing = true
            cancelled = false
            pulseToken += 1
            let token = pulseToken
            NSSound.beep()

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
                win.level = .screenSaver
                win.isOpaque = false
                win.backgroundColor = NSColor(red: 0.96, green: 0.55, blue: 0.18, alpha: 0.55)
                win.ignoresMouseEvents = true
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                win.alphaValue = 0
                win.orderFrontRegardless()
                created.append(win)
            }
            windows = created
            pulse(step: 0, token: token)
        }
    }

    /// Tear down immediately (lid fully closed, Stay Awake turned off, etc.).
    static func cancel() {
        DispatchQueue.main.async {
            cancelled = true
            pulseToken += 1
            tearDownWindows()
            isFlashing = false
        }
    }

    private static func pulse(step: Int, token: Int) {
        guard !cancelled, token == pulseToken else { return }
        // Even steps: show; odd: hide. 6 steps = 3 brief flashes, then done.
        let show = step % 2 == 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            for win in windows {
                win.animator().alphaValue = show ? 1 : 0
            }
        }, completionHandler: {
            guard !cancelled, token == pulseToken else { return }
            if step < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    pulse(step: step + 1, token: token)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard !cancelled, token == pulseToken else { return }
                    tearDownWindows()
                    isFlashing = false
                }
            }
        })
    }

    private static func tearDownWindows() {
        for win in windows {
            win.alphaValue = 0
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
    }
}
