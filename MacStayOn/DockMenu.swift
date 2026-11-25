import Foundation

/// What the Dock icon's right-click menu offers (Quit is added by macOS).
enum DockMenuItem: Equatable {
    case stayAwake, turnOff, openMenu, guide

    var title: String {
        switch self {
        case .stayAwake: return "Stay Awake…"
        case .turnOff: return "Turn Off"
        case .openMenu: return "Open MacStayOn Menu"
        case .guide: return "Guide"
        }
    }

    /// While the Touch ID / password prompt is up, offer no on/off toggle.
    static func items(isOn: Bool, isAwaitingApproval: Bool) -> [DockMenuItem] {
        var items: [DockMenuItem] = []
        if !isAwaitingApproval { items.append(isOn ? .turnOff : .stayAwake) }
        items.append(contentsOf: [.openMenu, .guide])
        return items
    }
}
