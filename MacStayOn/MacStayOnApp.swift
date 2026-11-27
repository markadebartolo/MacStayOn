import AppKit
import Combine
import SwiftUI

@main
struct MacStayOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item and its panel are AppKit (StatusMenuController), so the
    // Dock icon can open them too. This scene only supplies the app menu.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Open MacStayOn Menu") { [appDelegate] in appDelegate.statusMenu?.open() }
                        .keyboardShortcut(",")
                }
                CommandGroup(replacing: .help) {
                    Button("MacStayOn Guide") { [appDelegate] in appDelegate.guide.showGuide() }
                }
            }
    }
}

/// Runs on the main thread (AppKit delegate callbacks); marked so it can own
/// main-actor objects like the guide window and the updater settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sleepManager = SleepAssertionManager()
    let launchAtLogin = LaunchAtLoginController()
    let keyboardShortcut = KeyboardShortcutController()
    let lamp = LampOverlayController()
    private(set) lazy var guide = GuideWindowController(
        sleepManager: sleepManager,
        keyboardShortcut: keyboardShortcut,
        launchAtLogin: launchAtLogin,
        checkForUpdates: { Task { @MainActor in SparkleUpdateController.checkForUpdates() } },
        autoInstall: (
            get: { SparkleUpdateController.installsAutomatically },
            set: { SparkleUpdateController.installsAutomatically = $0 }
        )
    )
    /// A downloaded update installs only when it can't interrupt a session.
    private(set) lazy var updateGate = UpdateInstallGate(isBusy: { [sleepManager] in
        sleepManager.isEnabled || sleepManager.isAwaitingAdminApproval
            || sleepManager.pendingEnableConfirm || sleepManager.pendingLidOpenChoice
    })
    private var updateGateWatch: AnyCancellable?
    private var isSecondCopy = false
    /// Moon / sun in the menu bar and the panel it opens (also opened from the Dock).
    private(set) var statusMenu: StatusMenuController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies (dist + Debug) share /tmp state and can fight the watchdog.
        if !SingleInstance.claimOrActivateExisting() {
            // This copy must not run any Off/quit cleanup: it would drop the restore
            // sentinel and switch the already-running copy's Stay Awake off.
            sleepManager.becomeInertSecondaryInstance()
            isSecondCopy = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isSecondCopy else { return }
        // Decide before anything else writes settings, so a first install still looks like one.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let launchGuide = LaunchGuideDecider.onLaunch(currentVersion: version, defaults: .standard)
        // In the Dock as well as the menu bar.
        _ = NSApp.setActivationPolicy(.regular)
        let statusMenu = StatusMenuController(isEnabled: sleepManager.$isEnabled.eraseToAnyPublisher()) { [unowned self] in
            AnyView(
                PopoverRoot(
                    sleepManager: sleepManager,
                    analytics: sleepManager.analytics,
                    launchAtLogin: launchAtLogin,
                    keyboardShortcut: keyboardShortcut,
                    lamp: lamp,
                    openGuide: { [weak self] in
                        self?.statusMenu?.close()
                        self?.guide.showGuide()
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            )
        }
        statusMenu.onOpen = { [launchAtLogin, keyboardShortcut] in
            launchAtLogin.refresh()
            keyboardShortcut.refreshPermission()
        }
        self.statusMenu = statusMenu
        HardwareProfile.warmCache { [sleepManager] in
            sleepManager.refreshMachineLabel()
        }
        // Refresh Login Items status; never auto-enables Stay Awake.
        launchAtLogin.refresh()
        // Off / no auto admin at login — Stay Awake only if an existing session resumes.
        sleepManager.applyPersistedStateIfNeeded()
        // Sparkle daily check (Release only); menu “Check for Updates…” always available.
        // Automatic updates wait for Stay Awake to be off. @Published fires before
        // the value changes, so re-check on the next run loop turn.
        SparkleUpdateController.installGate = updateGate
        updateGateWatch = Publishers.CombineLatest(sleepManager.$isEnabled, sleepManager.$isAwaitingAdminApproval)
            .receive(on: RunLoop.main)
            .sink { [updateGate] _ in updateGate.stateChanged() }
        let guideWillAsk = launchGuide == .welcome || launchGuide == .resumeAfterMove
        SparkleUpdateController.startIfConfigured(askForNotifications: !guideWillAsk)
        // A glow and pull chain briefly confirm each turn on / off (shortcut included).
        lamp.bind(isEnabled: sleepManager.$isEnabled.eraseToAnyPublisher())
        // ←→↑↓ + Space toggles Stay Awake from any app (needs Input Monitoring).
        keyboardShortcut.onToggle = { [sleepManager, lamp] in
            let wasOn = sleepManager.isEnabled
            sleepManager.toggleFromKeyboardShortcut()
            // With the glow shown, its pull-chain click is the Off sound.
            if wasOn, !sleepManager.isEnabled, !lamp.showLamp {
                NSSound(named: "Pop")?.play()
            }
        }
        keyboardShortcut.start()
        // First launch: the walkthrough. After an update: what's new.
        guide.show(launchGuide)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepManager.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Dock

    /// Clicking the Dock icon opens the MacStayOn menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusMenu?.open()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for item in DockMenuItem.items(isOn: sleepManager.isEnabled, isAwaitingApproval: sleepManager.isAwaitingAdminApproval) {
            let entry = NSMenuItem(title: item.title, action: #selector(dockMenuChose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.title
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func dockMenuChose(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        switch title {
        case DockMenuItem.stayAwake.title:
            // Same path as the menu's button: heat note in the panel, then Touch ID.
            sleepManager.requestEnableFromUser()
            statusMenu?.open()
        case DockMenuItem.turnOff.title:
            sleepManager.setEnabled(false)
        case DockMenuItem.openMenu.title:
            statusMenu?.open()
        case DockMenuItem.guide.title:
            guide.showGuide()
        default:
            break
        }
    }
}

// MARK: - Menu panel

/// The menu: a small panel under the menu bar icon, in the app icon's two
/// colors. A status card on top (night navy when off, warm amber when on) holds
/// the main button; below it, settings in two groups and app actions.
struct PopoverRoot: View {
    @ObservedObject var sleepManager: SleepAssertionManager
    @ObservedObject var analytics: SessionAnalytics
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var keyboardShortcut: KeyboardShortcutController
    @ObservedObject var lamp: LampOverlayController
    let openGuide: () -> Void
    @ObservedObject private var updateReminders = SparkleUpdateReminderStore.shared

    /// Fixed width, like a menu; only the height follows the content.
    static let width: CGFloat = 308

    private var isOn: Bool {
        #if DEBUG
        // Debug builds only: preview the On look without turning anything on.
        if UserDefaults.standard.bool(forKey: "MacStayOnDebugPreviewOn") { return true }
        #endif
        return sleepManager.isEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sleepManager.isSleepStuckWhileOff {
                criticalBanner
            }
            statusCard
            notes
            group("While Stay Awake is on") {
                darkenRow
                rowDivider
                guardRow
            }
            group("App") {
                glowRow
                rowDivider
                loginRow
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.panelEdge, lineWidth: 1)
        )
        .onAppear {
            launchAtLogin.refresh()
            keyboardShortcut.refreshPermission()
            #if DEBUG
            // Debug builds only: check the light or dark look without changing System Settings.
            switch UserDefaults.standard.string(forKey: "MacStayOnDebugAppearance") {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            #endif
        }
    }

    // MARK: Status card

    /// Colors on the status card: white on navy when off, dark ink on amber when on.
    private var cardText: Color { isOn ? Palette.ink : .white }
    private var cardSubtext: Color { isOn ? Palette.ink.opacity(0.78) : Palette.onNavySoft }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isOn ? Palette.ink.opacity(0.12) : Color.white.opacity(0.14))
                        .frame(width: 34, height: 34)
                    // Same symbols as the menu bar icon: sun when on, moon when off.
                    Image(systemName: isOn ? "sun.max.fill" : "moon.zzz.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isOn ? Palette.ink : Palette.amber)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusHeadline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cardText)
                        .lineLimit(1)
                    Text(statusDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(cardSubtext)
                        .lineLimit(1)
                    if let lastSession {
                        Text(lastSession)
                            .font(.system(size: 11.5))
                            .foregroundStyle(cardSubtext)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(cardText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(isOn ? Palette.ink.opacity(0.12) : Color.white.opacity(0.16)))
            }
            if sleepManager.pendingEnableConfirm {
                enableConfirm
            } else if sleepManager.pendingLidOpenChoice {
                lidOpenChoice
            } else {
                VStack(spacing: 7) {
                    primaryAction
                    actionHint
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? Palette.amber : Palette.navy)
        )
    }

    private var statusHeadline: String {
        if sleepManager.isAwaitingAdminApproval { return "Waiting for approval" }
        if sleepManager.pendingEnableConfirm { return "Turn on Stay Awake?" }
        if sleepManager.pendingLidOpenChoice { return "Lid opened" }
        if !isOn { return "Normal sleep" }
        return sleepManager.darkenDisplay ? "Staying awake, screen dark" : "Staying awake"
    }

    private var statusDetail: String {
        if sleepManager.isAwaitingAdminApproval { return "Use Touch ID or your password" }
        if isOn, analytics.isLive {
            return "For \(SessionAnalytics.formatDuration(analytics.elapsed)) · \(powerText)"
        }
        let machine = sleepManager.machineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        // "MacBook Pro · M5 Max" → "M5 Max"
        let chip = machine.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return chip.isEmpty ? powerText : "\(chip) · \(powerText)"
    }

    private var lastSession: String? {
        guard !isOn, !sleepManager.isAwaitingAdminApproval, analytics.hasSummary else { return nil }
        return "Last session: \(SessionAnalytics.formatDuration(analytics.elapsed))"
    }

    private var powerText: String {
        if sleepManager.onACPower { return "Power adapter" }
        if let percent = sleepManager.batteryPercent { return "Battery \(percent)%" }
        return "Battery"
    }

    private var primaryAction: some View {
        Button {
            if isOn {
                sleepManager.setEnabled(false)
            } else {
                sleepManager.requestEnableFromUser()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "moon.zzz.fill" : "bolt.fill")
                Text(primaryActionTitle)
            }
        }
        // Off: an amber button on the navy card. On: a navy button on the amber card.
        .buttonStyle(CardButtonStyle(kind: isOn ? .navy : .amber, large: true))
        .keyboardShortcut(.defaultAction)
        .disabled(sleepManager.isAwaitingAdminApproval)
        .opacity(sleepManager.isAwaitingAdminApproval ? 0.7 : 1)
        .help(isOn ? "Turn Stay Awake off and restore normal sleep and the screensaver"
                   : "Stay awake with the lid open or closed")
    }

    private var primaryActionTitle: String {
        if isOn { return "Restore Normal Sleep" }
        if sleepManager.isAwaitingAdminApproval { return "Approve…" }
        return sleepManager.needsUserReEnable ? "Turn On" : "Stay Awake"
    }

    @ViewBuilder
    private var actionHint: some View {
        if keyboardShortcut.needsPermission {
            Button {
                keyboardShortcut.openPermissionSettings()
            } label: {
                Text("Set up the ← → ↑ ↓ + Space shortcut")
                    .underline()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isOn ? Palette.ink : Palette.amber)
            .frame(maxWidth: .infinity)
            .help("Needs Input Monitoring: System Settings → Privacy & Security → Input Monitoring → MacStayOn")
        } else {
            Text(isOn ? "Keeps running with the lid closed" : "or hold ← → ↑ ↓ + Space")
                .font(.system(size: 11.5))
                .foregroundStyle(cardSubtext)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Prompts (in the status card, in place of the main button)

    private var enableConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.amber)
                Text(HardwareProfile.enableHeatWarningTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(HardwareProfile.enableHeatWarningBody)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.onNavySoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("Next: approve with Touch ID or your password.")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Button("Cancel") { sleepManager.cancelEnableFromMenu() }
                    .buttonStyle(CardButtonStyle(kind: .clearOnNavy))
                Button("Turn On") { sleepManager.confirmEnableFromMenu() }
                    .buttonStyle(CardButtonStyle(kind: .amber))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private var lidOpenChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn Stay Awake off?")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(cardText)
            Text("It was on for \(sleepManager.lidOpenSessionDuration) with the lid closed. Turn it off for normal lid sleep, or keep it on.")
                .font(.system(size: 11.5))
                .foregroundStyle(cardSubtext)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep On") { sleepManager.confirmKeepOnAfterLidOpen() }
                    .buttonStyle(CardButtonStyle(kind: isOn ? .clearOnAmber : .clearOnNavy))
                Button("Turn Off") { sleepManager.confirmTurnOffAfterLidOpen() }
                    .buttonStyle(CardButtonStyle(kind: isOn ? .navy : .amber))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private var criticalBanner: some View {
        Button {
            sleepManager.requestRestoreSleepNow()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep is stuck off")
                        .fontWeight(.semibold)
                    Text("Click to restore lid sleep now (approve with Touch ID). Unsafe in a bag until fixed.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.dangerFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        let error = isOn ? nil : sleepManager.lastError
        let foreign = sleepManager.foreignSleepNote.flatMap { $0.isEmpty ? nil : $0 }
        if !sleepManager.pendingEnableConfirm, !sleepManager.pendingLidOpenChoice, error != nil || foreign != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    noteLine(symbol: "exclamationmark.circle.fill", tint: Palette.dangerText, text: error, emphasized: true)
                }
                if let foreign {
                    noteLine(symbol: "info.circle", tint: Palette.secondary, text: foreign, emphasized: false)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func noteLine(symbol: String, tint: Color, text: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? tint : Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Settings

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.cardEdge, lineWidth: 1)
            )
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Palette.cardEdge)
            .frame(height: 1)
            .padding(.leading, 34)
    }

    private enum Tile { case navy, amber }

    private func settingRow<Detail: View>(
        _ title: String,
        symbol: String,
        tile: Tile,
        isOn: Binding<Bool>,
        enabled: Bool = true,
        help: String,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // Icon tile, like System Settings: navy for night things, amber for heat and light.
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tile == .navy ? Palette.amber : Palette.ink)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tile == .navy ? Palette.navy : Palette.amber)
                )
                .saturation(enabled ? 1 : 0)
                .opacity(enabled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(enabled ? Palette.text : Palette.secondary)
                detail()
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.toggle)
                .disabled(!enabled)
        }
        .padding(.vertical, 8)
        .help(help)
    }

    private func detailText(_ text: String, tint: Color = Palette.secondary) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var darkenRow: some View {
        settingRow(
            "Darken screen",
            symbol: "moon.fill",
            tile: .navy,
            isOn: Binding(get: { sleepManager.darkenDisplay }, set: { sleepManager.setDarkenDisplay($0) }),
            enabled: isOn,
            help: "A black cover over the screen while Stay Awake is on. The Mac stays awake; any key or click brings the screen back."
        ) {
            detailText(isOn ? "A key or click brings it back" : "Available once it's on")
        }
    }

    private var guardRow: some View {
        settingRow(
            "Heat and battery guard",
            symbol: "thermometer.medium",
            tile: .amber,
            isOn: Binding(get: { sleepManager.guardEnabled }, set: { sleepManager.setGuardEnabled($0) }),
            help: "Turns Stay Awake off on low battery (on battery power) or serious heat."
        ) {
            Menu {
                ForEach(Array(stride(from: 10, through: 50, by: 5)), id: \.self) { percent in
                    Button("\(percent)% battery") { sleepManager.setBatteryFloor(percent) }
                }
            } label: {
                Text("Off at \(sleepManager.batteryFloor)% battery")
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.secondary)
            .fixedSize()
            .disabled(!sleepManager.guardEnabled)
            .help("Battery level that turns Stay Awake off (on battery power). Serious heat always does.")
        }
    }

    private var glowRow: some View {
        settingRow(
            "Glow confirmation",
            symbol: "lightbulb.fill",
            tile: .amber,
            isOn: Binding(get: { lamp.showLamp }, set: { lamp.setShowLamp($0) }),
            help: "A quick glow and pull-chain confirmation at the top of the screen whenever Stay Awake turns on or off."
        ) {
            detailText("Plays as it turns on or off")
        }
    }

    private var loginRow: some View {
        settingRow(
            "Open at login",
            symbol: "sunrise.fill",
            tile: .navy,
            isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }),
            help: "Open MacStayOn when you log in. Stay Awake stays off until you turn it on."
        ) {
            if let note = launchAtLogin.statusNote, !note.isEmpty {
                detailText(note, tint: Palette.warningText)
            } else {
                detailText("Stay Awake still starts off")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: openGuide) {
                Label("Guide", systemImage: "questionmark.circle")
            }
            .buttonStyle(FooterButtonStyle())
            .help("Guide: setup, the glow, the keyboard shortcut, permissions and updates")
            Spacer(minLength: 4)
            updateControl
            Spacer(minLength: 4)
            Button {
                sleepManager.prepareForTermination()
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(FooterButtonStyle())
            .keyboardShortcut("q")
            .help("Restore normal sleep and quit MacStayOn")
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var updateControl: some View {
        if let pending = updateReminders.pendingUpdateDisplayVersion {
            Button {
                SparkleUpdateController.checkForUpdates()
            } label: {
                Label("Update \(pending)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(FooterButtonStyle(highlighted: true))
            .help("Install the available MacStayOn update")
        } else {
            Button {
                SparkleUpdateController.checkForUpdates()
            } label: {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(FooterButtonStyle())
            .help("Check for updates. They also install by themselves while Stay Awake is off.")
        }
    }
}

// MARK: - Styles

private struct CardButtonStyle: ButtonStyle {
    enum Kind {
        /// Amber with dark ink text: the action on the navy (off) card.
        case amber
        /// Navy with white text: the action on the amber (on) card.
        case navy
        /// Quiet secondary buttons on each card.
        case clearOnNavy, clearOnAmber
    }
    var kind: Kind
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13.5 : 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, large ? 9 : 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .amber, .clearOnAmber: return Palette.ink
        case .navy, .clearOnNavy: return .white
        }
    }

    private var fill: Color {
        switch kind {
        case .amber: return Palette.amber
        case .navy: return Palette.navy
        case .clearOnNavy: return Color.white.opacity(0.14)
        case .clearOnAmber: return Palette.ink.opacity(0.10)
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(highlighted ? Palette.ink : Palette.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? Palette.amber : (configuration.isPressed ? Palette.card : .clear))
            )
            .contentShape(Rectangle())
    }
}

/// Two colors from the app icon, night navy and warm amber, plus neutrals.
/// Every text color here reads at 5:1 contrast or better on what it sits on.
private enum Palette {
    static let navy = Color.dynamic(light: 0x223154, dark: 0x2A3B63)
    static let amber = Color(hex: 0xF6A23C)
    /// Dark brown text on amber.
    static let ink = Color(hex: 0x2E1A05)
    /// Secondary text on navy.
    static let onNavySoft = Color(hex: 0xCFD3DC)

    static let panel = Color.dynamic(light: 0xF1F1F3, dark: 0x1E1E20)
    static let panelEdge = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.12)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x2B2B2E)
    static let cardEdge = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.07)

    static let text = Color(nsColor: .labelColor)
    static let secondary = Color.dynamic(light: 0x5E5E63, dark: 0xA8A8AE)
    static let toggle = Color(hex: 0xE8892A)
    static let warningText = Color.dynamic(light: 0x9A4D00, dark: 0xF5B25A)
    static let dangerText = Color.dynamic(light: 0xB3261E, dark: 0xFF7A70)
    static let dangerFill = Color(hex: 0xC9372C)
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    /// Follows light and dark mode.
    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
