import AppKit
import Combine
import SwiftUI

/// The menu bar item (moon / sun) and the panel it opens, just under the icon
/// like a menu. Built on NSStatusItem + NSPanel instead of SwiftUI's
/// MenuBarExtra so other places — the Dock icon, the Dock menu, the app menu —
/// can open the same panel; MenuBarExtra can't be opened from code.
@MainActor
final class StatusMenuController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let content: () -> AnyView
    private var panel: MenuPanel?
    private var hosting: SizingHostingView?
    private var resizeScheduled = false
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
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
        fit()
        // A non-activating panel takes keyboard focus without pulling the whole
        // app forward (macOS may refuse that), like a menu.
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
        // Fixed size on both axes, and the panel is sized here rather than by
        // SwiftUI: letting the hosting view resize its own window looped (each
        // layout resized the window, which laid out again) until the stack ran out.
        let hosting = SizingHostingView(rootView: AnyView(content().fixedSize()))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onContentSizeChange = { [weak self] in self?.scheduleFit() }
        self.hosting = hosting
        let panel = MenuPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
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

    /// Size the panel to its content (prompts and notes change its height).
    /// Always deferred to the next run loop turn and only when it changed.
    private func scheduleFit() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.fit()
        }
    }

    private func fit() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        if abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
            // The shadow follows the rounded corners; recompute it for the new size.
            panel.invalidateShadow()
        }
        position(panel)
    }

    /// Just under the menu bar (or the notch band in full-screen apps), centered
    /// on the menu bar icon like a menu and kept on screen. From the Dock it
    /// opens in the same place, so it's always clear where it comes from.
    private func position(_ panel: NSPanel) {
        let iconFrame = statusItem.button?.window?.frame
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - 6
        let origin = NSPoint(
            x: MenuPanelPlacement.x(width: size.width, iconFrame: iconFrame, screenFrame: screen.visibleFrame).rounded(),
            y: (top - size.height).rounded()
        )
        // Only move when it actually changes: every move is a layout pass.
        guard abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 else { return }
        panel.setFrameOrigin(origin)
    }

    /// Closes like a menu: a click in another app, Esc, the menu bar item again,
    /// or switching to another app. (Not on losing key focus — that also
    /// happens when macOS declines to bring the app forward, which closed the
    /// panel the moment it opened.)
    private func installMonitors() {
        removeMonitors()
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
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
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        clickMonitor = nil
        keyMonitor = nil
        deactivateObserver = nil
    }
}

/// Hosting view that reports when the panel's natural size changes.
private final class SizingHostingView: NSHostingView<AnyView> {
    var onContentSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}

/// Borderless, but can take keyboard focus (Return for the default button,
/// switches, the battery menu).
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
