import AppKit
import SwiftUI

@main
struct MacStayOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(
                sleepManager: appDelegate.sleepManager,
                analytics: appDelegate.sleepManager.analytics,
                launchAtLogin: appDelegate.launchAtLogin,
                keyboardShortcut: appDelegate.keyboardShortcut,
                lamp: appDelegate.lamp
            )
        } label: {
            MenuBarLabel(sleepManager: appDelegate.sleepManager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sleepManager = SleepAssertionManager()
    let launchAtLogin = LaunchAtLoginController()
    let keyboardShortcut = KeyboardShortcutController()
    let lamp = LampOverlayController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies (dist + Debug) share /tmp state and can fight the watchdog.
        if !SingleInstance.claimOrActivateExisting() {
            // This copy must not run any Off/quit cleanup: it would drop the restore
            // sentinel and switch the already-running copy's Stay Awake off.
            sleepManager.becomeInertSecondaryInstance()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep menu-bar-only presentation; accidental .regular activation
        // can leave a full app menu and confuse MenuBarExtra window opens.
        if NSApp.activationPolicy() != .accessory {
            _ = NSApp.setActivationPolicy(.accessory)
        }
        MenuPanelCentering.shared.start()
        HardwareProfile.warmCache { [sleepManager] in
            sleepManager.refreshMachineLabel()
        }
        // Refresh Login Items status; never auto-enables Stay Awake.
        launchAtLogin.refresh()
        // Off / no auto admin at login — Stay Awake only if an existing session resumes.
        sleepManager.applyPersistedStateIfNeeded()
        // Sparkle daily check (Release only); menu “Check for Updates…” always available.
        SparkleUpdateController.startIfConfigured()
        // While On, a lamp hangs from the top of the screen; its pull chain turns Off.
        lamp.onPull = { [sleepManager] in
            sleepManager.setEnabled(false)
        }
        lamp.bind(isEnabled: sleepManager.$isEnabled.eraseToAnyPublisher())
        // ←→↑↓ + Space toggles Stay Awake from any app (needs Input Monitoring).
        keyboardShortcut.onToggle = { [sleepManager, lamp] in
            let wasOn = sleepManager.isEnabled
            sleepManager.toggleFromKeyboardShortcut()
            // With the lamp shown, its pull-chain click is the Off sound.
            if wasOn, !sleepManager.isEnabled, !lamp.showLamp {
                NSSound(named: "Pop")?.play()
            }
        }
        keyboardShortcut.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepManager.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Menu bar glyph

private struct MenuBarLabel: View {
    @ObservedObject var sleepManager: SleepAssertionManager

    var body: some View {
        Image(systemName: sleepManager.isEnabled ? "sun.max.fill" : "moon.zzz.fill")
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(sleepManager.isEnabled ? "MacStayOn On" : "MacStayOn Off")
            .help(sleepManager.isEnabled
                  ? "MacStayOn: stays awake, no screensaver"
                  : "MacStayOn: normal sleep")
    }
}

// MARK: - Horizontal top bar

private struct PopoverRoot: View {
    @ObservedObject var sleepManager: SleepAssertionManager
    @ObservedObject var analytics: SessionAnalytics
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var keyboardShortcut: KeyboardShortcutController
    @ObservedObject var lamp: LampOverlayController
    @ObservedObject private var updateReminders = SparkleUpdateReminderStore.shared

    private var isOn: Bool { sleepManager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainStrip
            if sleepManager.isSleepStuckWhileOff {
                criticalStrip
            }
            if sleepManager.pendingEnableConfirm {
                Divider().overlay(Palette.line)
                enableConfirmStrip
            } else if sleepManager.pendingLidOpenChoice {
                Divider().overlay(Palette.line)
                lidOpenChoiceStrip
            }
            if showsSecondaryNote {
                Divider().overlay(Palette.line)
                secondaryNoteStrip
            }
        }
        .onAppear {
            launchAtLogin.refresh()
            keyboardShortcut.refreshPermission()
        }
        // Size to content so ON (longer button/session) never clips Quit;
        // CenterTopMenuPanel recenters after the window width changes.
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.panel.ignoresSafeArea())
        .background(CenterTopMenuPanel())
    }

    private var showsSecondaryNote: Bool {
        if sleepManager.pendingEnableConfirm || sleepManager.pendingLidOpenChoice { return false }
        if let err = sleepManager.lastError, !isOn { return true }
        if let note = sleepManager.foreignSleepNote, !note.isEmpty { return true }
        if let note = launchAtLogin.statusNote, !note.isEmpty { return true }
        if keyboardShortcut.needsPermission { return true }
        return false
    }

    // MARK: Main horizontal strip

    private var mainStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            brandCluster
            thinDivider
            statusCluster
            if !sleepManager.pendingEnableConfirm && !sleepManager.pendingLidOpenChoice {
                primaryAction
            }
            thinDivider
            darkenControl
            thinDivider
            lampControl
            thinDivider
            guardControl
            thinDivider
            launchAtLoginControl
            thinDivider
            sessionChip
            thinDivider
            updateControl
            thinDivider
            quitControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private var brandCluster: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isOn ? Palette.orange : Palette.iconFill)
                    .frame(width: 28, height: 28)
                Image(systemName: isOn ? "bolt.fill" : "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("MacStayOn")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isOn ? Palette.orange : Palette.secondary)
            }
        }
        .fixedSize()
    }

    private var statusCluster: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusHeadline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(powerLineShort)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize()
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
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Keep Off/On capsules the same width so the strip doesn’t jump.
            .frame(minWidth: 128)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? Palette.iconFill : Palette.orange)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(sleepManager.isAwaitingAdminApproval)
        .opacity(sleepManager.isAwaitingAdminApproval ? 0.7 : 1)
        .help(isOn ? "Restore normal sleep & screensaver" : "Stay awake with lid open or closed")
        .fixedSize()
    }

    private var primaryActionTitle: String {
        if isOn { return "Restore" }
        if sleepManager.isAwaitingAdminApproval { return "Approve…" }
        return sleepManager.needsUserReEnable ? "Turn On" : "Stay Awake"
    }

    private var darkenControl: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Darken")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.text : Palette.secondary)
                Text(sleepManager.darkenDisplay ? "Black" : "Lit")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
            Toggle("", isOn: Binding(
                get: { sleepManager.darkenDisplay },
                set: { sleepManager.setDarkenDisplay($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!isOn)
        }
        .fixedSize()
        .help(isOn
              ? (sleepManager.darkenDisplay
                 ? "Black screen — Mac stays awake. Key/click restores."
                 : "Optional black cover (does not sleep the display).")
              : "Turn Stay Awake on first, then darken.")
    }

    private var lampControl: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lamp")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(lamp.showLamp ? "Shown" : "Hidden")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
            Toggle("", isOn: Binding(
                get: { lamp.showLamp },
                set: { lamp.setShowLamp($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .fixedSize()
        .help("While Stay Awake is on, a lamp hangs at the top of the screen. Click its pull chain to turn off.")
    }

    private var guardControl: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Heat & batt.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Menu {
                    ForEach(Array(stride(from: 10, through: 50, by: 5)), id: \.self) { percent in
                        Button("\(percent)% battery") {
                            sleepManager.setBatteryFloor(percent)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("≤\(sleepManager.batteryFloor)%")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(sleepManager.guardEnabled ? Palette.secondary : Palette.secondary.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .disabled(!sleepManager.guardEnabled)
                .fixedSize()
            }
            Toggle("", isOn: Binding(
                get: { sleepManager.guardEnabled },
                set: { sleepManager.setGuardEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .fixedSize()
        .help("Turns Stay Awake off on low battery or serious heat. Off at the chosen battery %.")
    }

    private var launchAtLoginControl: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("At login")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(launchAtLogin.isEnabled ? "Open" : "Off")
                    .font(.system(size: 10))
                    .foregroundStyle(launchAtLogin.needsApproval ? Palette.orange : Palette.secondary)
            }
            Toggle("", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .fixedSize()
        .help("Open MacStayOn when you log in. Stay Awake stays Off until you turn it on.")
    }

    private var sessionChip: some View {
        Group {
            if analytics.isLive || analytics.hasSummary {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                    Text(SessionAnalytics.formatDuration(analytics.elapsed))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.chip)
                )
                .help(analytics.isLive ? "This Stay Awake session" : "Last Stay Awake session")
                .fixedSize()
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .frame(minWidth: 28)
                    .help("No session yet")
                    .fixedSize()
            }
        }
    }

    private var updateControl: some View {
        Button {
            SparkleUpdateController.checkForUpdates()
        } label: {
            if let pending = updateReminders.pendingUpdateDisplayVersion {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Update \(pending)")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous).fill(Palette.orange)
                )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Updates")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous).fill(Palette.chip)
                )
            }
        }
        .buttonStyle(.plain)
        .help(updateReminders.pendingUpdateDisplayVersion == nil
              ? "Check for Updates…"
              : "Install the available MacStayOn update")
        .fixedSize()
        .accessibilityLabel(updateReminders.pendingUpdateDisplayVersion == nil
                            ? "Check for Updates"
                            : "Update MacStayOn")
    }

    private var quitControl: some View {
        Button {
            sleepManager.prepareForTermination()
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                Text("Quit")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous).fill(Palette.chip)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .help("Quit MacStayOn")
        .fixedSize()
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(width: 1, height: 28)
    }

    // MARK: Expandable strips

    private var criticalStrip: some View {
        Button {
            sleepManager.requestRestoreSleepNow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("CRITICAL: Restore lid sleep now — approve admin (bag risk)")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Palette.danger)
        }
        .buttonStyle(.plain)
    }

    private var enableConfirmStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(HardwareProfile.enableHeatWarningTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(HardwareProfile.enableHeatWarningBody)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                    Text("Next: approve admin / Touch ID for lid-sleep settings.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("Cancel") { sleepManager.cancelEnableFromMenu() }
                        .buttonStyle(BarChipButtonStyle())
                    Button("Turn On") { sleepManager.confirmEnableFromMenu() }
                        .buttonStyle(BarPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var lidOpenChoiceStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lid opened — turn Stay Awake off?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text("Was on for \(sleepManager.lidOpenSessionDuration) while closed. Turn off for normal lid sleep, or keep on.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Keep On") { sleepManager.confirmKeepOnAfterLidOpen() }
                .buttonStyle(BarChipButtonStyle())
            Button("Turn Off") { sleepManager.confirmTurnOffAfterLidOpen() }
                .buttonStyle(BarDarkButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var secondaryNoteStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let err = sleepManager.lastError, !isOn {
                Text(err)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
            }
            if let note = sleepManager.foreignSleepNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            if let note = launchAtLogin.statusNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.orange)
                    .lineLimit(2)
            }
            if keyboardShortcut.needsPermission {
                Button {
                    keyboardShortcut.openPermissionSettings()
                } label: {
                    Text("Shortcut ←→↑↓ + Space needs Input Monitoring — open Settings")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.orange)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("System Settings → Privacy & Security → Input Monitoring → turn on MacStayOn")
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Copy helpers

    private var statusHeadline: String {
        if sleepManager.isAwaitingAdminApproval { return "Waiting for Touch ID" }
        if sleepManager.pendingEnableConfirm { return "Confirm Stay Awake" }
        if sleepManager.pendingLidOpenChoice { return "Lid opened" }
        if !isOn { return "Normal sleep" }
        if sleepManager.darkenDisplay { return "Awake · black" }
        return "Awake · no screensaver"
    }

    /// Short machine + power line so the ON strip stays one tidy row.
    private var powerLineShort: String {
        let power: String
        if sleepManager.onACPower {
            power = "AC"
        } else if let percent = sleepManager.batteryPercent {
            power = "Batt \(percent)%"
        } else {
            power = "Battery"
        }
        let machine = sleepManager.machineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if machine.isEmpty { return power }
        // Prefer chip name only (e.g. "M5 Max") when label is "MacBook Pro · M5 Max"
        let chip = machine.split(separator: "·").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.last ?? machine
        return "\(chip) · \(power)"
    }

    private var powerLine: String {
        let power: String
        if sleepManager.onACPower {
            power = "On AC power"
        } else if let percent = sleepManager.batteryPercent {
            power = "On battery · \(percent)%"
        } else {
            power = "On battery"
        }
        let machine = sleepManager.machineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if machine.isEmpty { return power }
        return "\(machine) · \(power)"
    }
}

// MARK: - Button styles

private struct BarPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Palette.orange.opacity(configuration.isPressed ? 0.85 : 1)))
    }
}

private struct BarChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Palette.chip.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

private struct BarDarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Palette.iconFill.opacity(configuration.isPressed ? 0.85 : 1)))
    }
}

private enum Palette {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let chip = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor).opacity(0.45)
    static let iconFill = Color(red: 0.22, green: 0.27, blue: 0.38)
    static let orange = Color(red: 0.96, green: 0.55, blue: 0.18)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.24)
}
