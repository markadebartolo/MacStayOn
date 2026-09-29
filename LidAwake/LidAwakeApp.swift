import SwiftUI

@main
struct LidAwakeApp: App {
    @StateObject private var sleepManager = SleepAssertionManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sleepManager: sleepManager)
        } label: {
            Label {
                Text(sleepManager.isEnabled ? "LidAwake On" : "LidAwake Off")
            } icon: {
                Image(systemName: sleepManager.isEnabled ? "sun.max.fill" : "moon.zzz")
            }
            .help(sleepManager.isEnabled
                  ? "Lid closed: stays awake"
                  : "Lid closed: normal sleep")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @ObservedObject var sleepManager: SleepAssertionManager

    var body: some View {
        // Clear current-state line (not a toggle itself)
        Text(sleepManager.isEnabled
             ? "Status: Lid closed stays awake"
             : "Status: Normal lid sleep")
            .font(.headline)

        if let detail = sleepManager.statusDetail {
            Text(detail)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button(sleepManager.isEnabled ? "Turn Off (resume normal lid sleep)" : "Turn On (lid closed stays awake)") {
            sleepManager.setEnabled(!sleepManager.isEnabled)
        }

        Divider()

        Button("Quit LidAwake") {
            sleepManager.setEnabled(false)
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
