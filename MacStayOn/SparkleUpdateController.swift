import AppKit
import Combine
import Foundation
import Sparkle
import UserNotifications

/// Notification id for gentle “update available” nudges (menu-bar apps stay unfocused).
enum SparkleUpdateNotificationID {
    nonisolated static let updateAvailable = "com.markdebartolo.MacStayOn.sparkle.updateAvailable"
}

/// Surfaces a pending Sparkle update in the menu strip (one-click Install).
@MainActor
final class SparkleUpdateReminderStore: ObservableObject {
    static let shared = SparkleUpdateReminderStore()

    @Published private(set) var pendingUpdateDisplayVersion: String?

    private init() {}

    func setPendingUpdate(displayVersion: String) {
        pendingUpdateDisplayVersion = displayVersion
    }

    func clearPendingUpdate() {
        pendingUpdateDisplayVersion = nil
    }

    func postUpdateNotification(displayVersion: String) {
        let content = UNMutableNotificationContent()
        content.title = "MacStayOn"
        content.subtitle = "Update available"
        content.body = "Version \(displayVersion) is ready — open MacStayOn and tap Update."
        content.userInfo = ["sparkleUpdate": true]

        let request = UNNotificationRequest(
            identifier: SparkleUpdateNotificationID.updateAvailable,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Sparkle delegate — methods are `nonisolated` (protocol requirements) and hop to the main actor.
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Required for LSUIElement / menu-bar apps — silences Sparkle’s gentle-reminder warning.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Launch may show an update in focus; later background checks stay gentle.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// Automatic updates: Sparkle has downloaded one and would install it on
    /// quit. Hand the "install now" action to the gate, which runs it once
    /// Stay Awake is off (installing restarts the app, and quitting turns
    /// Stay Awake off). If the gate never runs it, it still installs on quit.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            SparkleUpdateController.installGate?.updateReady(install: immediateInstallHandler)
        }
        return true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let displayVersion = update.displayVersionString
        Task { @MainActor in
            SparkleUpdateReminderStore.shared.setPendingUpdate(displayVersion: displayVersion)
            SparkleUpdateReminderStore.shared.postUpdateNotification(displayVersion: displayVersion)
            _ = handleShowingUpdate
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        _ = update
        Task { @MainActor in
            SparkleUpdateReminderStore.shared.clearPendingUpdate()
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [SparkleUpdateNotificationID.updateAvailable]
            )
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            SparkleUpdateReminderStore.shared.clearPendingUpdate()
        }
    }
}

/// Release-oriented Sparkle wiring. Debug builds skip auto-start so Xcode runs
/// don’t hit the production feed; manual check still works once configured.
@MainActor
enum SparkleUpdateController {
    private static var updaterController: SPUStandardUpdaterController?
    /// Holds a downloaded automatic update until Stay Awake is off.
    static var installGate: UpdateInstallGate?

    /// "Install updates automatically" (Sparkle's automatic downloads). On by
    /// default from Info.plist; the guide's Updates step can switch it off.
    static var installsAutomatically: Bool {
        get {
            updaterController?.updater.automaticallyDownloadsUpdates
                ?? (UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true)
        }
        set {
            if let updater = updaterController?.updater {
                updater.automaticallyDownloadsUpdates = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: "SUAutomaticallyUpdate")
            }
        }
    }
    private static let updaterDelegate = SparkleUpdaterDelegate()

    /// Feed URL + public EdDSA key present and not placeholders.
    static var isConfigured: Bool {
        guard let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURLString.isEmpty,
              feedURLString.contains("appcast.xml") else {
            return false
        }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty,
              !publicKey.hasPrefix("REPLACE") else {
            return false
        }
        return true
    }

    /// `askForNotifications` is false on first launch: the guide's Permissions
    /// step explains and asks instead of a cold prompt on top of the guide.
    static func startIfConfigured(askForNotifications: Bool = true) {
        #if DEBUG
        return
        #else
        guard isConfigured, updaterController == nil else { return }
        // Soft-ask so gentle reminders can post when a background check finds an update.
        if askForNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: updaterDelegate
        )
        updaterController = controller
        #endif
    }

    /// Menu “Check for Updates…” / pending Update chip — always user-initiated UI.
    static func checkForUpdates() {
        guard isConfigured else {
            presentConfigurationAlert()
            return
        }
        #if DEBUG
        // Allow manual smoke-tests from Debug when keys + feed are present.
        if updaterController == nil {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: updaterDelegate
            )
            updaterController = controller
        }
        #else
        if updaterController == nil {
            startIfConfigured()
        }
        #endif
        updaterController?.checkForUpdates(nil)
    }

    private static func presentConfigurationAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates aren’t configured"
        alert.informativeText = "This build is missing a Sparkle feed URL or public key. Download the latest release from GitHub, or rebuild after running scripts/generate-sparkle-keys.sh."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
