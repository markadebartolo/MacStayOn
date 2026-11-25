import AppKit
import Combine
import SwiftUI

/// Plays the on/off confirmation. Split out so the On/Off logic in
/// `LampOverlayController` can be tested without windows.
protocol LampPresenting: AnyObject {
    /// Chain drops, gets a tug, the glow flickers on — then it all tucks away.
    func turnOn()
    /// Chain drops with the glow lit, gets a tug, the glow goes out — then it tucks away.
    func turnOff()
    /// Stop anything that is playing (the user switched the glow off).
    func hide()
}

/// A quick confirmation that Stay Awake really turned on or off — handy with
/// the keyboard shortcut, where there is no menu open to look at. A pull chain
/// drops from under the menu bar, gets a tug, and a warm glow comes on (or
/// goes out); then it tucks away. It is a signal only: nothing stays on
/// screen and there is nothing to click.
final class LampOverlayController: ObservableObject {
    static let showLampKey = "macStayOnShowLamp"

    @Published private(set) var showLamp: Bool

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
    /// succeeded, so the glow never confirms a canceled or failed attempt.
    func bind(isEnabled: AnyPublisher<Bool, Never>) {
        subscription = isEnabled
            .removeDuplicates()
            .sink { [weak self] on in self?.stayAwakeChanged(on) }
    }

    func setShowLamp(_ show: Bool) {
        guard show != showLamp else { return }
        showLamp = show
        defaults.set(show, forKey: Self.showLampKey)
        if !show {
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

// MARK: - Window

/// A borderless, click-through panel at the top right of the screen that
/// floats above full-screen apps and follows every Space. It is only on
/// screen while a confirmation plays.
final class LampWindowPresenter: LampPresenting {
    /// How long the lit glow stays after turning on, before it tucks away.
    static let holdAfterOn: TimeInterval = 1.2
    /// How long the dark chain stays after turning off.
    static let holdAfterOff: TimeInterval = 0.35

    private let model = LampModel()
    private var geometry = LampGeometry(topInset: 30)
    private var panel: NSPanel?
    /// Bumped by every turnOn/turnOff/hide so steps from an older sequence never run.
    private var generation = 0
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel?.isVisible == true else { return }
            self.layoutPanel()
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
        let token = begin()
        if reduceMotion {
            fadeConfirmation(token, lit: true)
            return
        }
        dropChain(token) {
            self.pullChain(token) {
                // The glow catches, flickers once, then holds.
                withAnimation(.easeOut(duration: 0.05)) { self.model.lit = 1 }
                self.after(0.06, token) {
                    withAnimation(.easeIn(duration: 0.04)) { self.model.lit = 0.45 }
                }
                self.after(0.11, token) {
                    withAnimation(.easeOut(duration: 0.18)) { self.model.lit = 1 }
                }
                self.after(0.11 + Self.holdAfterOn, token) { self.tuckAway(token) }
            }
        }
    }

    func turnOff() {
        let token = begin()
        if reduceMotion {
            fadeConfirmation(token, lit: false)
            return
        }
        // Show it as it was (lit), then tug it off.
        withAnimation(.easeOut(duration: 0.2)) { model.lit = 1 }
        dropChain(token) {
            self.pullChain(token) {
                withAnimation(.easeIn(duration: 0.12)) { self.model.lit = 0 }
                self.after(Self.holdAfterOff, token) { self.tuckAway(token) }
            }
        }
    }

    func hide() {
        generation &+= 1
        let token = generation
        guard panel?.isVisible == true else { return }
        withAnimation(.easeIn(duration: 0.2)) { model.opacity = 0 }
        after(0.25, token) { self.orderOut() }
    }

    // MARK: Steps

    /// Starts a new confirmation, cancelling any step still pending from the last one.
    private func begin() -> Int {
        generation &+= 1
        layoutPanel()
        if panel?.isVisible != true || model.opacity < 0.01 {
            // Start with the chain drawn up behind the menu bar and no glow.
            model.drop = -geometry.dropDistance
            model.lit = 0
            model.pull = 0
            model.sway = 0
            model.opacity = 1
        }
        panel?.orderFrontRegardless()
        return generation
    }

    /// Lower the chain out from under the menu bar (already down: carry on).
    private func dropChain(_ token: Int, then next: @escaping () -> Void) {
        guard model.drop != 0 else {
            after(0.02, token, next)
            return
        }
        // Let the starting state render once so the drop animates from it.
        after(0.02, token) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { self.model.drop = 0 }
        }
        after(0.32, token, next)
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

    /// Glow off and the chain draws back up under the menu bar.
    private func tuckAway(_ token: Int) {
        withAnimation(.easeIn(duration: 0.22)) {
            model.drop = -geometry.dropDistance
            model.lit = 0
        }
        after(0.26, token) { self.orderOut() }
    }

    /// Reduce Motion: no drop or swing, just the glow fading with the click.
    private func fadeConfirmation(_ token: Int, lit: Bool) {
        model.drop = 0
        model.lit = lit ? 0 : 1
        PullChainClick.play()
        withAnimation(.easeOut(duration: 0.25)) { model.lit = lit ? 1 : 0 }
        after(lit ? Self.holdAfterOn : Self.holdAfterOff, token) {
            withAnimation(.easeIn(duration: 0.25)) { self.model.opacity = 0 }
            self.after(0.3, token) { self.orderOut() }
        }
    }

    private func after(_ delay: TimeInterval, _ token: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            work()
        }
    }

    private func orderOut() {
        panel?.orderOut(nil)
        model.opacity = 0
        model.lit = 0
        model.pull = 0
        model.sway = 0
        model.drop = 0
    }

    // MARK: Layout

    private func layoutPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Menu bar (or notch) height, so the chain seems to come out from under it.
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let newGeometry = LampGeometry(topInset: menuBar)
        let size = CGSize(width: newGeometry.width, height: newGeometry.height)
        // Top-right, clear of the centered notch and the MacStayOn menu panel.
        let origin = NSPoint(x: screen.frame.maxX - size.width - 44, y: screen.frame.maxY - size.height)

        let panel = self.panel ?? Self.makePanel()
        if self.panel == nil || newGeometry != geometry {
            geometry = newGeometry
            panel.contentView = NSHostingView(rootView: LampView(model: model, geometry: newGeometry))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        self.panel = panel
    }

    private static func makePanel() -> NSPanel {
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
        // A signal only: every click goes straight through to what's underneath.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        return panel
    }
}

private final class LampPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would push the panel below the menu bar; the chain is meant to run up behind it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
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
