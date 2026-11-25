import AppKit
import ServiceManagement
import UserNotifications

/// Notifications permission, used for "update available" reminders.
class NotificationPermission: ObservableObject {
    enum Status { case unknown, notAsked, allowed, denied, unavailable }

    @Published var status: Status = .unknown

    /// Only a real app bundle can use the notification center.
    private var bundleID: String? { Bundle.main.bundleIdentifier }

    func refresh() {
        guard bundleID != nil else {
            status = .unavailable
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status
            switch settings.authorizationStatus {
            case .notDetermined: status = .notAsked
            case .denied: status = .denied
            default: status = .allowed
            }
            DispatchQueue.main.async { self.status = status }
        }
    }

    func request() {
        guard bundleID != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Ask once, only if the user hasn't answered yet.
    func requestIfNotAsked() {
        guard bundleID != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            DispatchQueue.main.async { self.request() }
        }
    }

    func openSettings() {
        let id = bundleID ?? "com.markdebartolo.MacStayOn"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The sleep-safety LaunchDaemon installed while Stay Awake is on. macOS shows
/// it as a background item ("Background Items Added"); if the user switches it
/// off in Login Items & Extensions, the safety net can't run.
enum SafetyNetPermission {
    enum Status { case allowed, blocked, notInstalled }

    static var plistURL: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/\(SleepSafetyResources.launchdLabel).plist")
    }

    static func status() -> Status {
        switch SMAppService.statusForLegacyPlist(at: plistURL) {
        case .enabled:
            return .allowed
        case .requiresApproval:
            return .blocked
        default:
            return .notInstalled
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
