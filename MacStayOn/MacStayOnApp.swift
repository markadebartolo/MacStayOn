import AppKit
import SwiftUI

@main
struct MacStayOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sleepManager: appDelegate.sleepManager)
        } label: {
            MenuBarLabel(sleepManager: appDelegate.sleepManager)
        }
        .menuBarExtraStyle(.menu)
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

private struct MenuBarLabel: View {
    @ObservedObject var sleepManager: SleepAssertionManager

    var body: some View {
        Label {
            Text(sleepManager.isEnabled ? "MacStayOn On" : "MacStayOn Off")
        } icon: {
            Image(systemName: sleepManager.isEnabled ? "sun.max.fill" : "moon.zzz")
        }
        .help(sleepManager.isEnabled
              ? "Lid closed: stays awake"
              : "Lid closed: normal sleep")
    }
}

private struct MenuContent: View {
    @ObservedObject var sleepManager: SleepAssertionManager

    var body: some View {
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
            if sleepManager.isEnabled {
                sleepManager.setEnabled(false)
            } else {
                sleepManager.requestEnableFromUser()
            }
        }

        Divider()

        Button("Quit MacStayOn") {
            sleepManager.prepareForTermination()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
