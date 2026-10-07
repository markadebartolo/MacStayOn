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

// MARK: - Popover

private struct PopoverRoot: View {
    @ObservedObject var sleepManager: SleepAssertionManager
    @ObservedObject var analytics: SessionAnalytics
    /// Session app rows stay collapsed by default so the menu stays short.
    @State private var sessionAppsExpanded = false

    private var isOn: Bool { sleepManager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.line)
            statusBlock
            if sleepManager.isSleepStuckWhileOff {
                Button {
                    sleepManager.requestRestoreSleepNow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Restore lid sleep now")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.danger)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            if sleepManager.pendingEnableConfirm {
                enableConfirmBlock
            } else if sleepManager.pendingLidOpenChoice {
                lidOpenChoiceBlock
            } else {
                actionButton
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            Divider().overlay(Palette.line)
            displayModeBlock
            Divider().overlay(Palette.line)
            guardBlock
            if analytics.isLive || analytics.hasSummary {
                Divider().overlay(Palette.line)
                sessionBlock
            }
            Divider().overlay(Palette.line)
            quitButton
        }
        .frame(width: 340)
        .background(Palette.panel.ignoresSafeArea())
    }

    /// Heat/bag safety ack inside the popover — then Touch ID / admin only.
    private var enableConfirmBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.orange)
                Text(HardwareProfile.enableHeatWarningTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
            Text(HardwareProfile.enableHeatWarningBody)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Next: approve admin / Touch ID so MacStayOn can change lid-sleep settings.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
            HStack(spacing: 8) {
                Button {
                    sleepManager.cancelEnableFromMenu()
                } label: {
                    Text("Cancel")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Palette.chip)
                        )
                        .foregroundStyle(Palette.text)
                }
                .buttonStyle(.plain)
                Button {
                    sleepManager.confirmEnableFromMenu()
                } label: {
                    Text("Turn On")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Palette.orange)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// After lid reopen — choose in the menu, not a center alert.
    private var lidOpenChoiceBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lid opened — turn Stay Awake off?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("Stay Awake was on for \(sleepManager.lidOpenSessionDuration) while the lid was closed. Turn it off to restore normal lid sleep, or keep it on.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    sleepManager.confirmKeepOnAfterLidOpen()
                } label: {
                    Text("Keep On")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Palette.chip)
                        )
                        .foregroundStyle(Palette.text)
                }
                .buttonStyle(.plain)
                Button {
                    sleepManager.confirmTurnOffAfterLidOpen()
                } label: {
                    Text("Turn Off")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Palette.iconFill)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isOn ? Palette.orange : Palette.iconFill)
                    .frame(width: 36, height: 36)
                Image(systemName: isOn ? "bolt.fill" : "moon.zzz.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("MacStayOn")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)

            Spacer(minLength: 0)

            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Palette.orange : Palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? Palette.orange.opacity(0.12) : Palette.chip)
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusHeadline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)

            Text(powerLine)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)

            if let err = sleepManager.lastError, !isOn {
                Text(err)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if let note = sleepManager.foreignSleepNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var statusHeadline: String {
        if sleepManager.pendingEnableConfirm {
            return "Confirm Stay Awake"
        }
        if sleepManager.pendingLidOpenChoice {
            return "Lid opened"
        }
        if !isOn { return "Normal sleep & screensaver" }
        if sleepManager.darkenDisplay {
            return "Stays awake · black screen"
        }
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

    private var actionButton: some View {
        Button {
            if isOn {
                sleepManager.setEnabled(false)
            } else {
                sleepManager.requestEnableFromUser()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "moon.zzz.fill" : "bolt.fill")
                Text(isOn
                      ? "Restore normal sleep"
                      : (sleepManager.needsUserReEnable
                         ? "Turn On again"
                         : "Stay Awake"))
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Palette.iconFill : Palette.orange)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private var sessionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    sessionAppsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .rotationEffect(.degrees(sessionAppsExpanded ? 90 : 0))

                    Text(analytics.isLive ? "This session" : "Last session")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.secondary)

                    if !analytics.topApps.isEmpty {
                        Text("· \(analytics.topApps.count) app\(analytics.topApps.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(SessionAnalytics.formatDuration(analytics.elapsed))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sessionAppsExpanded ? "Hide session apps" : "Show session apps")

            if sessionAppsExpanded {
                if analytics.topApps.isEmpty {
                    Text(analytics.isLive
                          ? "Apps doing work will show up — including agents behind other windows."
                          : "No app activity recorded.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(analytics.topApps) { row in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Palette.text)
                                        .lineLimit(1)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundStyle(Palette.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(rowStatus(row))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(row.isActiveNow ? Palette.orange : Palette.secondary)
                                    ForEach(row.timeline, id: \.self) { line in
                                        Text(line)
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundStyle(Palette.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(SessionAnalytics.formatDuration(row.duration))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Palette.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !analytics.isLive && analytics.hasSummary {
                    Button {
                        analytics.clear()
                    } label: {
                        Text("Clear last session")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("Timeline is clock time for working, stalled, and stopped. Rows stay once seen. Local only — you’ll be asked to turn Off when the lid opens.")
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Palette.secondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private var displayModeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Darken display")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? Palette.text : Palette.secondary)
                    Text(sleepManager.darkenDisplay
                          ? "Black screen now — Mac stays awake. Press a key or click to restore."
                          : "Optional black cover while Stay Awake is on (does not sleep the display).")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { sleepManager.darkenDisplay },
                    set: { sleepManager.setDarkenDisplay($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isOn)
            }
            if !isOn {
                Text("Turn Stay Awake on first, then darken.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var guardBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heat & battery guard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text("Applies when MacStayOn is on")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { sleepManager.guardEnabled },
                    set: { sleepManager.setGuardEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                Text("Restore normal sleep at")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sleepManager.guardEnabled ? Palette.text : Palette.secondary)
                Spacer(minLength: 8)
                batteryMenu
            }

            Text("Also turns off if serious heat is detected.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var batteryMenu: some View {
        Menu {
            ForEach(Array(stride(from: 10, through: 50, by: 5)), id: \.self) { percent in
                Button("\(percent)% battery") {
                    sleepManager.setBatteryFloor(percent)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(sleepManager.batteryFloor)% battery")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(sleepManager.guardEnabled ? Palette.text : Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.chip)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!sleepManager.guardEnabled)
    }

    private var quitButton: some View {
        Button {
            sleepManager.prepareForTermination()
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "power")
                Text("Quit MacStayOn")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
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
