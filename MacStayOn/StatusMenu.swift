import AppKit
import Combine
import SwiftUI

/// The menu bar item (moon / sun) and the panel it opens, centered just under
/// the menu bar. Built on NSStatusItem + NSPanel instead of SwiftUI's
/// MenuBarExtra so other places — the Dock icon, the Dock menu, the app menu —
/// can open the same panel; MenuBarExtra can't be opened from code.
@MainActor
final class StatusMenuController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let content: () -> AnyView
    private var panel: MenuPanel?
    private var hosting: NSHostingController<AnyView>?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var iconWatch: AnyCancellable?

    var isOpen: Bool { panel?.isVisible == true }
    /// Runs each time the panel opens (refresh login-item and shortcut status).
    var onOpen: (() -> Void)?

    init(isEnabled: AnyPublisher<Bool, Never>, content: @escaping () -> AnyView) {
        self.content = content
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        iconWatch = isEnabled.sink { [weak self] on in self?.showState(on) }
    }

    @objc private func statusItemClicked() {
        isOpen ? close() : open()
    }

    func open() {
        onOpen?()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        installMonitors()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        removeMonitors()
    }

    private func showState(_ on: Bool) {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: on ? "sun.max.fill" : "moon.zzz.fill",
            accessibilityDescription: on ? "MacStayOn On" : "MacStayOn Off"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = on ? "MacStayOn: stays awake, no screensaver" : "MacStayOn: normal sleep"
    }

    // MARK: Panel

    private func makePanel() -> MenuPanel {
        let hosting = NSHostingController(rootView: content())
        // The window follows the strip's size as confirms and notes come and go.
        hosting.sizingOptions = .preferredContentSize
        self.hosting = hosting
        let panel = MenuPanel(contentViewController: hosting)
        panel.styleMask = [.borderless]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Opens over full-screen apps, on whichever Space is active.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        return panel
    }

    /// Centered horizontally, just under the menu bar (or the notch band in
    /// full-screen apps), on the screen with the menu bar item.
    private func position(_ panel: NSPanel) {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - 6
        panel.setFrameOrigin(NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: top - size.height))
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the top edge and the centering when the strip grows or shrinks.
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Like a menu: clicking anywhere else (or the Touch ID sheet taking focus) closes it.
        close()
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isOpen == true else { return event }   // Esc
            self?.close()
            return nil
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }
}

/// Borderless, but can take keyboard focus (Return for the default button,
/// switches, the battery menu).
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
