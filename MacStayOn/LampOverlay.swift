import AppKit
import Combine
import SwiftUI

/// Shows and animates the glow and pull chain. Split out so the On/Off logic in
/// `LampOverlayController` can be tested without windows.
protocol LampPresenting: AnyObject {
    /// The user clicked the pull chain.
    var onPull: (() -> Void)? { get set }
    /// Drop the chain down, pull it, light the glow.
    func turnOn()
    /// Pull the chain, click the glow off, draw the chain back up.
    func turnOff()
    /// Take it all away without the pull (the user hid it).
    func hide()
}

/// While Stay Awake is On, a warm glow spills from under the menu bar with a
/// pull chain hanging through it. Turning Stay Awake off (shortcut, menu, or
/// clicking the chain) pulls the chain and clicks the light off.
final class LampOverlayController: ObservableObject {
    static let showLampKey = "macStayOnShowLamp"

    @Published private(set) var showLamp: Bool

    /// Clicking the pull chain — wired to "turn Stay Awake off".
    var onPull: (() -> Void)? {
        get { presenter.onPull }
        set { presenter.onPull = newValue }
    }

    private let presenter: LampPresenting
    private let defaults: UserDefaults
    private var isStayAwakeOn = false
    private var subscription: AnyCancellable?

    init(presenter: LampPresenting = LampWindowPresenter(), defaults: UserDefaults = .standard) {
        self.presenter = presenter
        self.defaults = defaults
        showLamp = defaults.object(forKey: Self.showLampKey) as? Bool ?? true
    }

    /// Follow Stay Awake. `isEnabled` only turns true once Turn On has fully
    /// succeeded, so the glow never lights for a canceled or failed attempt.
    func bind(isEnabled: AnyPublisher<Bool, Never>) {
        subscription = isEnabled
            .removeDuplicates()
            .sink { [weak self] on in self?.stayAwakeChanged(on) }
    }

    func setShowLamp(_ show: Bool) {
        guard show != showLamp else { return }
        showLamp = show
        defaults.set(show, forKey: Self.showLampKey)
        guard isStayAwakeOn else { return }
        if show {
            presenter.turnOn()
        } else {
            presenter.hide()
        }
    }

    private func stayAwakeChanged(_ on: Bool) {
        let wasOn = isStayAwakeOn
        isStayAwakeOn = on
        guard showLamp, on != wasOn else { return }
        if on {
            presenter.turnOn()
        } else {
            presenter.turnOff()
        }
    }
}

// MARK: - Windows

/// Two borderless panels at the top-right of the screen: the glow and chain,
/// which clicks pass straight through, and a small one over the pull knob that
/// takes the click. Both float above full-screen apps and follow every Space.
final class LampWindowPresenter: LampPresenting {
    var onPull: (() -> Void)?

    private let model = LampModel()
    private var geometry = LampGeometry(topInset: 30)
    private var lampPanel: NSPanel?
    private var knobPanel: NSPanel?
    private var isShowing = false
    /// Bumped by every turnOn/turnOff/hide so steps from an older sequence never run.
    private var generation = 0
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isShowing else { return }
            self.layoutPanels()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func turnOn() {
        generation &+= 1
        let token = generation
        isShowing = true
        layoutPanels()
        knobPanel?.orderOut(nil)

        if reduceMotion {
            model.drop = 0
            model.pull = 0
            model.sway = 0
            lampPanel?.orderFrontRegardless()
            withAnimation(.easeOut(duration: 0.3)) {
                model.opacity = 1
                model.lit = 1
            }
            PullChainClick.play()
            after(0.3, token) { self.showKnob() }
            return
        }

        // Start with the chain drawn up behind the menu bar and no glow —
        // unless it is already hanging there.
        if model.opacity < 0.01 {
            model.drop = -geometry.dropDistance
            model.lit = 0
            model.opacity = 1
        }
        model.pull = 0
        model.sway = 0
        lampPanel?.orderFrontRegardless()
        // Let the starting state render once so the drop animates from it.
        after(0.02, token) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                self.model.drop = 0
            }
        }
        after(0.34, token) {
            self.pullChain(token) {
                // The glow catches, flickers once, then holds.
                withAnimation(.easeOut(duration: 0.05)) { self.model.lit = 1 }
                self.after(0.06, token) {
                    withAnimation(.easeIn(duration: 0.04)) { self.model.lit = 0.45 }
                }
                self.after(0.11, token) {
                    withAnimation(.easeOut(duration: 0.18)) { self.model.lit = 1 }
                }
            }
        }
        after(0.7, token) { self.showKnob() }
    }

    func turnOff() {
        guard isShowing else { return }
        generation &+= 1
        let token = generation
        isShowing = false
        knobPanel?.orderOut(nil)

        if reduceMotion {
            PullChainClick.play()
            withAnimation(.easeIn(duration: 0.2)) {
                model.lit = 0
                model.opacity = 0
            }
            after(0.25, token) { self.orderOutPanels() }
            return
        }

        pullChain(token) {
            withAnimation(.easeIn(duration: 0.12)) { self.model.lit = 0 }
        }
        // Then the chain draws back up under the menu bar.
        after(0.45, token) {
            withAnimation(.easeIn(duration: 0.22)) {
                self.model.drop = -self.geometry.dropDistance
            }
        }
        after(0.72, token) { self.orderOutPanels() }
    }

    func hide() {
        generation &+= 1
        let token = generation
        isShowing = false
        knobPanel?.orderOut(nil)
        withAnimation(.easeIn(duration: 0.25)) { model.opacity = 0 }
        after(0.3, token) { self.orderOutPanels() }
    }

    /// Chain down (with a slight angle), click at the bottom, spring back and swing.
    private func pullChain(_ token: Int, atBottom: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.08)) {
            model.pull = 1
            model.sway = -4
        }
        after(0.08, token) {
            PullChainClick.play()
            atBottom()
            withAnimation(.interpolatingSpring(stiffness: 380, damping: 15)) { self.model.pull = 0 }
            withAnimation(.interpolatingSpring(stiffness: 110, damping: 5)) { self.model.sway = 0 }
        }
    }

    private func after(_ delay: TimeInterval, _ token: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            work()
        }
    }

    private func showKnob() {
        guard isShowing else { return }
        knobPanel?.orderFrontRegardless()
    }

    private func orderOutPanels() {
        lampPanel?.orderOut(nil)
        knobPanel?.orderOut(nil)
        model.opacity = 0
        model.lit = 0
        model.pull = 0
        model.sway = 0
        model.drop = 0
    }

    // MARK: Layout

    private func layoutPanels() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Menu bar (or notch) height, so the chain seems to come out from under it.
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let newGeometry = LampGeometry(topInset: menuBar)
        let size = CGSize(width: newGeometry.width, height: newGeometry.height)
        // Top-right, clear of the centered notch and the MacStayOn menu panel.
        let origin = NSPoint(x: screen.frame.maxX - size.width - 44, y: screen.frame.maxY - size.height)

        let lamp = lampPanel ?? Self.makePanel(clickThrough: true)
        if lampPanel == nil || newGeometry != geometry {
            geometry = newGeometry
            lamp.contentView = NSHostingView(rootView: LampView(model: model, geometry: newGeometry))
        }
        lamp.setFrame(NSRect(origin: origin, size: size), display: false)
        lampPanel = lamp

        let knob = knobPanel ?? Self.makePanel(clickThrough: false)
        if knobPanel == nil {
            let hit = KnobHitView(frame: .zero)
            hit.onPull = { [weak self] in self?.onPull?() }
            knob.contentView = hit
        }
        // Generous target around the knob (screen coordinates are y-up).
        let k = newGeometry.knobCenter
        let hitSize = CGSize(width: 26, height: 34)
        knob.setFrame(NSRect(
            x: origin.x + k.x - hitSize.width / 2,
            y: origin.y + size.height - k.y - hitSize.height / 2,
            width: hitSize.width,
            height: hitSize.height
        ), display: false)
        knobPanel = knob
    }

    private static func makePanel(clickThrough: Bool) -> NSPanel {
        let panel = LampPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // Explicitly false makes even the transparent knob target take clicks.
        panel.ignoresMouseEvents = clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private final class LampPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would push the panel below the menu bar; the cord is meant to run up behind it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Invisible click target over the pull knob.
private final class KnobHitView: NSView {
    var onPull: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPull?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Pull chain: turn Stay Awake off" }
    override func accessibilityPerformPress() -> Bool {
        onPull?()
        return true
    }
}

// MARK: - Sound

/// The pull-chain switch: a sharp click, then a softer clack as the chain
/// springs back. Synthesized, so the app ships no audio files.
enum PullChainClick {
    private static let sound: NSSound? = {
        let sound = NSSound(data: wavData())
        sound?.volume = 0.7
        return sound
    }()

    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }

    /// 16-bit mono PCM WAV.
    static func wavData(sampleRate: Int = 44_100) -> Data {
        let count = Int(Double(sampleRate) * 0.14)
        var buffer = [Double](repeating: 0, count: count)
        var seed: UInt32 = 0x2545_F491
        func noise() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed >> 8) / Double(1 << 24) * 2 - 1
        }
        func transient(at start: Double, gain: Double, tone: Double, noiseDecay: Double, toneDecay: Double) {
            let first = Int(start * Double(sampleRate))
            for i in first..<count {
                let t = Double(i - first) / Double(sampleRate)
                buffer[i] += gain * (0.6 * noise() * exp(-t / noiseDecay)
                    + 0.8 * sin(2 * .pi * tone * t) * exp(-t / toneDecay))
            }
        }
        transient(at: 0, gain: 0.55, tone: 3_200, noiseDecay: 0.0012, toneDecay: 0.004)
        transient(at: 0, gain: 0.25, tone: 180, noiseDecay: 0.0005, toneDecay: 0.012)
        transient(at: 0.045, gain: 0.35, tone: 1_800, noiseDecay: 0.002, toneDecay: 0.007)

        let samples = buffer.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }
        let byteCount = samples.count * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))           // fmt chunk size
        append(UInt16(1))            // PCM
        append(UInt16(1))            // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2))            // block align
        append(UInt16(16))           // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        samples.forEach { append($0) }
        return data
    }
}
