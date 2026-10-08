import AppKit
import SwiftUI

@main
struct MacStayOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(
                sleepManager: appDelegate.sleepManager,
                analytics: appDelegate.sleepManager.analytics
            )
        } label: {
            MenuBarLabel(sleepManager: appDelegate.sleepManager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sleepManager = SleepAssertionManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies (dist + Debug) share /tmp state and can fight the watchdog.
        if !SingleInstance.claimOrActivateExisting() {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep menu-bar-only presentation; accidental .regular activation
        // can leave a full app menu and confuse MenuBarExtra window opens.
        if NSApp.activationPolicy() != .accessory {
            _ = NSApp.setActivationPolicy(.accessory)
        }
        HardwareProfile.warmCache { [sleepManager] in
            sleepManager.refreshMachineLabel()
        }
        sleepManager.applyPersistedStateIfNeeded()
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
    @State private var sessionAppsExpanded = false

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
            if sessionAppsExpanded, analytics.isLive || analytics.hasSummary {
                Divider().overlay(Palette.line)
                sessionExpandedStrip
            }
            if showsSecondaryNote {
                Divider().overlay(Palette.line)
                secondaryNoteStrip
            }
        }
        .frame(width: barWidth)
        .background(Palette.panel.ignoresSafeArea())
        // MenuBarExtra anchors near the status item; pin to screen-top center instead.
        .background(CenterTopMenuPanel())
    }

    /// Wide short strip under the menu bar (not a tall centered card).
    private var barWidth: CGFloat { 920 }

    private var showsSecondaryNote: Bool {
        if sleepManager.pendingEnableConfirm || sleepManager.pendingLidOpenChoice { return false }
        if let err = sleepManager.lastError, !isOn { return true }
        if let note = sleepManager.foreignSleepNote, !note.isEmpty { return true }
        return false
    }

    // MARK: Main horizontal strip

    private var mainStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            brandCluster
            thinDivider
            statusCluster
            Spacer(minLength: 6)
            if !sleepManager.pendingEnableConfirm && !sleepManager.pendingLidOpenChoice {
                primaryAction
            }
            thinDivider
            darkenControl
            thinDivider
            guardControl
            thinDivider
            sessionChip
            thinDivider
            quitControl
        }
        .padding(.horizontal, 12)
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
            Text(powerLine)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 140, maxWidth: 200, alignment: .leading)
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
                Text(isOn
                      ? "Restore sleep"
                      : (sleepManager.needsUserReEnable ? "Turn On again" : "Stay Awake"))
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? Palette.iconFill : Palette.orange)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .fixedSize()
    }

    private var darkenControl: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Darken display")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.text : Palette.secondary)
                Text(sleepManager.darkenDisplay ? "Black screen" : "Display lit")
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

    private var guardControl: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Heat & battery")
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
                        Text("Off at \(sleepManager.batteryFloor)%")
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
        .help("Turns Stay Awake off on low battery or serious heat.")
    }

    private var sessionChip: some View {
        Group {
            if analytics.isLive || analytics.hasSummary {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        sessionAppsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(sessionAppsExpanded ? 90 : 0))
                        Text(analytics.isLive ? "Session" : "Last")
                            .font(.system(size: 11, weight: .semibold))
                        Text(SessionAnalytics.formatDuration(analytics.elapsed))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if !analytics.topApps.isEmpty {
                            Text("· \(analytics.topApps.count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.chip)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Text("No session")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize()
            }
        }
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

    private var sessionExpandedStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            if analytics.topApps.isEmpty {
                Text(analytics.isLive
                      ? "Apps doing work will show up — including agents behind other windows."
                      : "No app activity recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            } else {
                // Compact multi-column rows
                ForEach(analytics.topApps.prefix(8)) { row in
                    HStack(spacing: 10) {
                        Text(row.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .frame(width: 140, alignment: .leading)
                        Text(rowStatus(row))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(row.isActiveNow ? Palette.orange : Palette.secondary)
                            .frame(width: 120, alignment: .leading)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(SessionAnalytics.formatDuration(row.duration))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.secondary)
                            .monospacedDigit()
                    }
                }
            }
            HStack {
                if !analytics.isLive && analytics.hasSummary {
                    Button("Clear last session") { analytics.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text("Local only — you’ll be asked to turn Off when the lid opens.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxHeight: 180)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Copy helpers

    private var statusHeadline: String {
        if sleepManager.pendingEnableConfirm { return "Confirm Stay Awake" }
        if sleepManager.pendingLidOpenChoice { return "Lid opened" }
        if !isOn { return "Normal sleep & screensaver" }
        if sleepManager.darkenDisplay { return "Stays awake · black screen" }
        return "Stays awake · no screensaver"
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

    private func rowStatus(_ row: AppUsageRow) -> String {
        if row.isActiveNow {
            return row.wasBackgroundWork ? "working in background" : "working now"
        }
        if analytics.isLive {
            return row.isRunning ? "idle" : "stopped"
        }
        return row.wasBackgroundWork ? "background work" : "this session"
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
