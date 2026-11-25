import AppKit
import Combine
import XCTest

final class LampOverlayTests: XCTestCase {
    private final class FakePresenter: LampPresenting {
        private(set) var calls: [String] = []
        func turnOn() { calls.append("on") }
        func turnOff() { calls.append("off") }
        func hide() { calls.append("hide") }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var presenter: FakePresenter!
    private var stayAwake: CurrentValueSubject<Bool, Never>!

    override func setUp() {
        super.setUp()
        suiteName = "LampOverlayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        presenter = FakePresenter()
        stayAwake = CurrentValueSubject(false)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> LampOverlayController {
        let controller = LampOverlayController(presenter: presenter, defaults: defaults)
        controller.bind(isEnabled: stayAwake.eraseToAnyPublisher())
        return controller
    }

    func testLampLightsOnTurnOnAndPullsOffOnTurnOff() {
        let controller = makeController()
        XCTAssertTrue(controller.showLamp, "the glow is on by default")
        XCTAssertEqual(presenter.calls, [], "nothing shows while Off")

        stayAwake.send(true)
        XCTAssertEqual(presenter.calls, ["on"])
        stayAwake.send(false)
        XCTAssertEqual(presenter.calls, ["on", "off"])
    }

    func testRepeatedStatesDoNotReplayTheAnimation() {
        let controller = makeController()
        // A failed Turn On publishes Off again while already Off.
        stayAwake.send(false)
        stayAwake.send(true)
        stayAwake.send(true)
        stayAwake.send(false)
        stayAwake.send(false)
        XCTAssertEqual(presenter.calls, ["on", "off"])
        withExtendedLifetime(controller) {}
    }

    func testResumedSessionShowsTheLampAtLaunch() {
        stayAwake.send(true)
        let controller = makeController()
        XCTAssertEqual(presenter.calls, ["on"])
        withExtendedLifetime(controller) {}
    }

    func testHiddenLampNeverShows() {
        defaults.set(false, forKey: LampOverlayController.showLampKey)
        let controller = makeController()
        XCTAssertFalse(controller.showLamp)
        stayAwake.send(true)
        stayAwake.send(false)
        XCTAssertEqual(presenter.calls, [])
    }

    func testSwitchingTheGlowOffStopsItAndNothingPlaysUntilTheNextChange() {
        let controller = makeController()
        stayAwake.send(true)
        controller.setShowLamp(false)
        XCTAssertEqual(presenter.calls, ["on", "hide"], "switching it off stops a confirmation mid-play")
        XCTAssertEqual(defaults.object(forKey: LampOverlayController.showLampKey) as? Bool, false)

        // Hidden: turning off confirms nothing.
        stayAwake.send(false)
        XCTAssertEqual(presenter.calls, ["on", "hide"])
        // Switching it back on is silent; the next real change confirms again.
        controller.setShowLamp(true)
        XCTAssertEqual(presenter.calls, ["on", "hide"])
        stayAwake.send(true)
        XCTAssertEqual(presenter.calls, ["on", "hide", "on"])
    }

    func testPullChainClickIsAValidWav() throws {
        let data = PullChainClick.wavData()
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        let sampleBytes = data.count - 44
        XCTAssertEqual(sampleBytes, Int(44_100 * 0.14) * 2)
        // Header sizes must match the payload or players truncate / reject it.
        let riffSize = data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), 36 + sampleBytes)
        XCTAssertEqual(Int(dataSize), sampleBytes)
        let sound = try XCTUnwrap(NSSound(data: data))
        XCTAssertGreaterThan(sound.duration, 0.1)
        XCTAssertLessThan(sound.duration, 0.2)
    }

    func testChainGeometryHidesFullyBehindTheMenuBar() {
        let geometry = LampGeometry(topInset: 37)
        XCTAssertGreaterThan(geometry.knobCenter.y, geometry.topInset + geometry.chainVisibleLength)
        XCTAssertLessThan(geometry.knobCenter.y + geometry.knobSize.height, geometry.height)
        XCTAssertEqual(geometry.knobCenter.x, geometry.chainX)
        // The chain's hidden length covers the whole pull, so its top never shows.
        XCTAssertGreaterThan(geometry.chainHiddenLength, geometry.pullDistance)
        // Drawn all the way up, the knob is back behind the menu bar.
        XCTAssertLessThan(geometry.knobCenter.y + geometry.knobSize.height / 2 - geometry.dropDistance, geometry.topInset)
    }
}
