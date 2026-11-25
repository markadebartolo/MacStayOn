import XCTest

final class DockMenuTests: XCTestCase {
    func testOffOffersStayAwakeWithTheHeatNote() {
        let items = DockMenuItem.items(isOn: false, isAwaitingApproval: false)
        XCTAssertEqual(items, [.stayAwake, .openMenu, .guide])
        XCTAssertEqual(DockMenuItem.stayAwake.title, "Stay Awake…", "the ellipsis says more follows (heat note, Touch ID)")
    }

    func testOnOffersTurnOff() {
        XCTAssertEqual(DockMenuItem.items(isOn: true, isAwaitingApproval: false), [.turnOff, .openMenu, .guide])
    }

    func testNoToggleWhileTouchIDIsUp() {
        XCTAssertEqual(DockMenuItem.items(isOn: false, isAwaitingApproval: true), [.openMenu, .guide])
    }

    func testTitlesAreUniqueSoChoicesMapBack() {
        let all: [DockMenuItem] = [.stayAwake, .turnOff, .openMenu, .guide]
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
    }

    func testTheAppIsInTheDock() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacStayOn/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
        XCTAssertEqual(plist["LSUIElement"] as? Bool, false, "LSUIElement true would hide the Dock icon")
    }
}
