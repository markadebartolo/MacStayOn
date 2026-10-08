import AppKit
import SwiftUI

/// Forces the MenuBarExtra panel to the horizontal center of the screen,
/// just under the menu bar — MenuBarExtra otherwise anchors beside the status item.
enum MenuPanelCentering {
    static let shared = MenuPanelCenteringController()
}

final class MenuPanelCenteringController {
    private var observers: [NSObjectProtocol] = []
    private var burstTimer: Timer?
    private var isCentering = false

    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSApplication.didChangeScreenParametersNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let self else { return }
                    if let window = note.object as? NSWindow {
                        self.handle(window)
                    } else {
                        self.centerAllPanels()
                        self.startBurst()
                    }
                }
            )
        }
    }

    /// Call when the SwiftUI panel attaches or updates.
    func ping(window: NSWindow? = nil) {
        if let window, isPanelCandidate(window) {
            center(window)
        }
        centerAllPanels()
        startBurst()
    }

    private func handle(_ window: NSWindow) {
        guard isPanelCandidate(window) else { return }
        center(window)
        // MenuBarExtra often repositions after first layout — burst-force for a short window.
        startBurst()
    }

    private func startBurst() {
        burstTimer?.invalidate()
        var ticks = 0
        burstTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.centerAllPanels()
            ticks += 1
            if ticks >= 45 { // ~0.75s
                timer.invalidate()
                self.burstTimer = nil
            }
        }
        if let burstTimer {
            RunLoop.main.add(burstTimer, forMode: .common)
        }
    }

    private func centerAllPanels() {
        for window in NSApp.windows where isPanelCandidate(window) {
            center(window)
        }
    }

    private func isPanelCandidate(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let frame = window.frame
        // Horizontal menu strip (~920×56–200). Skip full-screen overlays / flash windows.
        guard frame.width >= 500, frame.width <= 1200 else { return false }
        guard frame.height >= 40, frame.height <= 360 else { return false }
        return true
    }

    private func center(_ window: NSWindow) {
        guard !isCentering else { return }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        var frame = window.frame
        let targetX = visible.midX - frame.width / 2
        let targetY = visible.maxY - frame.height
        if abs(frame.origin.x - targetX) < 0.5, abs(frame.origin.y - targetY) < 0.5 {
            return
        }
        frame.origin = NSPoint(x: targetX, y: targetY)
        isCentering = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        window.setFrame(frame, display: true, animate: false)
        NSAnimationContext.endGrouping()
        isCentering = false
    }
}

/// Also attach inside the SwiftUI hierarchy so we get `viewDidMoveToWindow` promptly.
struct CenterTopMenuPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        MenuPanelCentering.shared.start()
        return AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.ping()
    }

    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MenuPanelCentering.shared.start()
            ping()
        }

        func ping() {
            MenuPanelCentering.shared.ping(window: window)
            if window == nil {
                DispatchQueue.main.async { [weak self] in
                    MenuPanelCentering.shared.ping(window: self?.window)
                }
            }
        }
    }
}
