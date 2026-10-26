import Foundation
import ServiceManagement

/// Login Items via `SMAppService.mainApp` (macOS 13+).
/// Persists in System Settings → General → Login Items; independent of Stay Awake.
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var needsApproval: Bool = false
    @Published private(set) var statusNote: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        needsApproval = (status == .requiresApproval)
        switch status {
        case .requiresApproval:
            statusNote = "Approve MacStayOn under System Settings → Login Items."
        case .notFound:
            statusNote = "Login item unavailable for this copy — try the installed app."
        default:
            statusNote = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status == .enabled {
                    refresh()
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                if status == .notRegistered {
                    refresh()
                    return
                }
                try SMAppService.mainApp.unregister()
            }
            refresh()
            if needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let message = error.localizedDescription
            refresh()
            statusNote = message
        }
    }
}
