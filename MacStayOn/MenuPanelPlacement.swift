import AppKit

/// Where the menu panel goes along the menu bar.
enum MenuPanelPlacement {
    /// Space kept between the panel and the screen edges.
    static let margin: CGFloat = 8

    /// The panel's left edge: centered under the menu bar icon and kept on
    /// screen. Without a usable icon position (none yet, or on another
    /// screen), it sits at the right edge, where menu bar extras live.
    static func x(width: CGFloat, iconFrame: NSRect?, screenFrame: NSRect) -> CGFloat {
        let minX = screenFrame.minX + margin
        let maxX = screenFrame.maxX - width - margin
        guard maxX > minX else { return screenFrame.midX - width / 2 }
        guard let icon = iconFrame, icon.width > 0,
              icon.midX >= screenFrame.minX, icon.midX <= screenFrame.maxX else {
            return maxX
        }
        return min(max(icon.midX - width / 2, minX), maxX)
    }
}
