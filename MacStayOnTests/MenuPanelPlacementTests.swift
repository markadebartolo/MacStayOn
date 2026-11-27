import XCTest

final class MenuPanelPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let width: CGFloat = 308

    func testCenteredUnderTheIcon() {
        let icon = NSRect(x: 1100, y: 944, width: 30, height: 24)
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: icon, screenFrame: screen), 1115 - 154)
    }

    func testKeptOnScreenNearTheRightEdge() {
        let icon = NSRect(x: 1480, y: 944, width: 30, height: 24)
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: icon, screenFrame: screen), 1512 - 308 - 8)
    }

    func testKeptOnScreenNearTheLeftEdge() {
        let icon = NSRect(x: 4, y: 944, width: 30, height: 24)
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: icon, screenFrame: screen), 8)
    }

    func testRightEdgeWhenTheIconIsUnknownOrElsewhere() {
        let expected = 1512 - 308 - 8.0
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: nil, screenFrame: screen), expected)
        let onAnotherScreen = NSRect(x: 2000, y: 944, width: 30, height: 24)
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: onAnotherScreen, screenFrame: screen), expected)
    }

    func testSecondScreenToTheLeft() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let icon = NSRect(x: -400, y: 1080, width: 30, height: 24)
        XCTAssertEqual(MenuPanelPlacement.x(width: width, iconFrame: icon, screenFrame: left), -385 - 154)
    }
}
