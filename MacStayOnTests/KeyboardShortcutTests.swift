import XCTest

final class KeyboardShortcutTests: XCTestCase {
    private let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126, space: UInt16 = 49

    /// Simulated keyboard: which keys are physically held.
    private var held: Set<UInt16> = []

    private func makeChord() -> ArrowSpaceChord {
        ArrowSpaceChord { [unowned self] in self.held.contains($0) }
    }

    private func press(_ key: UInt16, _ chord: inout ArrowSpaceChord) -> Bool {
        held.insert(key)
        return chord.handle(isKeyUp: false, keyCode: key)
    }

    private func release(_ key: UInt16, _ chord: inout ArrowSpaceChord) {
        held.remove(key)
        _ = chord.handle(isKeyUp: true, keyCode: key)
    }

    func testFiresWhenAllFourArrowsAndSpaceAreDown() {
        var chord = makeChord()
        XCTAssertFalse(press(left, &chord))
        XCTAssertFalse(press(right, &chord))
        XCTAssertFalse(press(up, &chord))
        XCTAssertFalse(press(down, &chord))
        XCTAssertTrue(press(space, &chord), "fifth key should complete the chord")
    }

    func testOrderDoesNotMatter() {
        var chord = makeChord()
        for key in [space, down, left, up] { XCTAssertFalse(press(key, &chord)) }
        XCTAssertTrue(press(right, &chord))
    }

    func testPartialChordsNeverFire() {
        var chord = makeChord()
        for key in [left, right, up, space] { XCTAssertFalse(press(key, &chord)) }
        // A non-chord key in the mix is ignored.
        XCTAssertFalse(chord.handle(isKeyUp: false, keyCode: 0))
    }

    func testKeyRepeatWhileHeldFiresOnlyOnce() {
        var chord = makeChord()
        for key in [left, right, up, down] { _ = press(key, &chord) }
        XCTAssertTrue(press(space, &chord))
        // macOS auto-repeat keeps sending key-downs while held.
        for _ in 0..<10 {
            XCTAssertFalse(chord.handle(isKeyUp: false, keyCode: space))
        }
    }

    func testReleasingAKeyRearmsTheShortcut() {
        var chord = makeChord()
        for key in [left, right, up, down] { _ = press(key, &chord) }
        XCTAssertTrue(press(space, &chord))
        release(space, &chord)
        XCTAssertTrue(press(space, &chord), "second deliberate press should toggle again")
    }

    func testTheEventsOwnKeyCountsEvenIfSystemStateLags() {
        // keyState may not yet report the key whose key-down we are handling.
        let arrowsOnly: Set<UInt16> = [123, 124, 125, 126]
        var chord = ArrowSpaceChord { arrowsOnly.contains($0) }
        XCTAssertTrue(chord.handle(isKeyUp: false, keyCode: 49))
    }
}
