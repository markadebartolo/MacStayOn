import AppKit
import SwiftUI

@main
struct MacStayOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(sleepManager: appDelegate.sleepManager)
        } label: {
            MenuBarLabel(sleepManager: appDelegate.sleepManager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sleepManager = SleepAssertionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                  ? "MacStayOn: lid closed stays awake"
                  : "MacStayOn: normal lid sleep")
    }
}

// MARK: - Popover

private struct PopoverRoot: View {
    @ObservedObject var sleepManager: SleepAssertionManager

    private var isOn: Bool { sleepManager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            statusBlock
            Divider().opacity(0.35)
            controls
        }
        .frame(width: 280)
        .background(Palette.panel.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isOn
                                ? [Palette.sunTop, Palette.sunBottom]
                                : [Palette.moonTop, Palette.moonBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: (isOn ? Palette.sunBottom : Palette.moonBottom).opacity(0.35), radius: 8, y: 2)

                Image(systemName: isOn ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("MacStayOn")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(isOn ? "Stay awake with lid closed" : "Normal lid sleep")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary)
            }

            Spacer(minLength: 0)

            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Palette.sunBottom : Palette.secondary)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? Palette.sunBottom.opacity(0.14) : Palette.chip)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isOn ? "Agents can keep running" : "Laptop will sleep when closed")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)

            Text(sleepManager.statusDetail ?? (isOn
                  ? "Power assertion active"
                  : "Toggle on when you need a closed-lid session"))
                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = sleepManager.lastError, !isOn {
                Text(err)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                if isOn {
                    sleepManager.setEnabled(false)
                } else {
                    sleepManager.requestEnableFromUser()
                }
            } label: {
                HStack {
                    Image(systemName: isOn ? "moon.zzz.fill" : "bolt.fill")
                    Text(isOn ? "Turn Off" : "Turn On")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isOn
                                    ? [Palette.moonTop, Palette.moonBottom]
                                    : [Palette.sunTop, Palette.sunBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Button {
                sleepManager.prepareForTermination()
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit MacStayOn")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.chip)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(14)
    }
}

private enum Palette {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let chip = Color(nsColor: .controlBackgroundColor)
    static let sunTop = Color(red: 1.0, green: 0.78, blue: 0.28)
    static let sunBottom = Color(red: 0.95, green: 0.52, blue: 0.12)
    static let moonTop = Color(red: 0.35, green: 0.42, blue: 0.58)
    static let moonBottom = Color(red: 0.18, green: 0.22, blue: 0.34)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.24)
}
