import AppKit
import SwiftUI

/// Pins the MenuBarExtra `.window` panel to the horizontal center of the screen,
/// just under the menu bar — regardless of where the status item sits.
struct CenterTopMenuPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.scheduleCenter()
    }

    final class AnchorView: NSView {
        private var moveObserver: NSObjectProtocol?
        private var resizeObserver: NSObjectProtocol?
        private var isCentering = false
        private var centerWorkItem: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDownObservers()
            guard let window else { return }
            scheduleCenter()
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleCenter()
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleCenter()
            }
        }

        deinit {
            tearDownObservers()
            centerWorkItem?.cancel()
        }

        func scheduleCenter() {
            centerWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.centerIfNeeded()
            }
            centerWorkItem = item
            // Defer so MenuBarExtra can finish its own placement first, then we override.
            DispatchQueue.main.async(execute: item)
        }

        private func tearDownObservers() {
            if let moveObserver {
                NotificationCenter.default.removeObserver(moveObserver)
                self.moveObserver = nil
            }
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
        }

        private func centerIfNeeded() {
            guard !isCentering, let window else { return }
            let screen = window.screen
                ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main
            guard let screen else { return }

            let visible = screen.visibleFrame
            var frame = window.frame
            // Keep the measured size; only relocate — top-centered under the menu bar.
            let targetX = visible.midX - frame.width / 2
            let targetY = visible.maxY - frame.height
            if abs(frame.origin.x - targetX) < 0.5, abs(frame.origin.y - targetY) < 0.5 {
                return
            }
            frame.origin = NSPoint(x: targetX, y: targetY)
            isCentering = true
            window.setFrame(frame, display: true)
            isCentering = false
        }
    }
}
