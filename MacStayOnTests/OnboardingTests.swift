import XCTest

final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: What to show at launch

    func testFirstInstallShowsTheWelcomeOnce() {
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .welcome)
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .none)
    }

    func testUpdateShowsWhatsNewAndWhetherStayAwakeWasOn() {
        defaults.set("1.4.0", forKey: LaunchGuideDecider.lastVersionKey)
        defaults.set(true, forKey: LaunchGuideDecider.wasOnAtQuitKey)
        XCTAssertEqual(
            LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults),
            .updated(from: "1.4.0", to: "1.5.0", stayAwakeWasOn: true)
        )
        XCTAssertNil(defaults.object(forKey: LaunchGuideDecider.wasOnAtQuitKey), "the flag is used once")
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .none)
    }

    func testUpdatingFromAVersionBeforeTheGuideStillCountsAsAnUpdate() {
        // 1.4.0 and earlier never recorded a version, but they did leave settings behind.
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        XCTAssertEqual(
            LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults),
            .updated(from: nil, to: "1.5.0", stayAwakeWasOn: false)
        )
    }

    func testSameOrOlderVersionShowsNothing() {
        defaults.set("1.5.0", forKey: LaunchGuideDecider.lastVersionKey)
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .none)
        defaults.set("1.6.0", forKey: LaunchGuideDecider.lastVersionKey)
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .none)
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(LaunchGuideDecider.isVersion("1.4.9", olderThan: "1.4.10"))
        XCTAssertTrue(LaunchGuideDecider.isVersion("1.9.0", olderThan: "1.10.0"))
        XCTAssertFalse(LaunchGuideDecider.isVersion("1.10.0", olderThan: "1.9.0"))
    }

    func testRelaunchAfterMovingResumesTheWalkthrough() {
        defaults.set("1.5.0", forKey: LaunchGuideDecider.lastVersionKey)
        defaults.set(true, forKey: LaunchGuideDecider.resumeAfterMoveKey)
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .resumeAfterMove)
        XCTAssertEqual(LaunchGuideDecider.onLaunch(currentVersion: "1.5.0", defaults: defaults), .none)
    }

    func testWhatsNewListsOnlyNewerReleases() {
        let fromPrevious = WhatsNew.notes(since: "1.4.0")
        XCTAssertFalse(fromPrevious.isEmpty)
        XCTAssertFalse(fromPrevious.contains { $0.contains("warm glow") }, "1.4.0 notes are old news")
        XCTAssertTrue(WhatsNew.notes(since: "1.3.9").contains { $0.contains("warm glow") })
        XCTAssertFalse(WhatsNew.notes(since: nil).isEmpty)
    }

    func testTheCurrentReleaseHasNotes() throws {
        // Every shipped version should say what's new on the update screen.
        let projectYML = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectYML, encoding: .utf8)
        let version = try XCTUnwrap(text.range(of: #"MARKETING_VERSION: "([^"]+)""#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: "MARKETING_VERSION: ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        XCTAssertEqual(WhatsNew.releases.first?.version, version)
    }

    // MARK: Install location

    func testApplicationsFolderDetection() {
        XCTAssertTrue(InstallLocation.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/MacStayOn.app")))
        XCTAssertTrue(InstallLocation.isInApplicationsFolder(
            URL(fileURLWithPath: "/Users/pat/Applications/MacStayOn.app"), home: "/Users/pat"))
        XCTAssertFalse(InstallLocation.isInApplicationsFolder(URL(fileURLWithPath: "/Users/pat/Downloads/MacStayOn.app"), home: "/Users/pat"))
        XCTAssertFalse(InstallLocation.isInApplicationsFolder(URL(fileURLWithPath: "/Applications Old/MacStayOn.app")))
    }

    func testTranslocationDetection() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/MacStayOn.app")
        XCTAssertTrue(InstallLocation.isTranslocated(translocated))
        let downloads = URL(fileURLWithPath: "/Users/pat/Downloads/MacStayOn.app")
        XCTAssertFalse(InstallLocation.isTranslocated(downloads))
        XCTAssertEqual(InstallLocation.originalURL(of: downloads), downloads, "a normal path is its own original")
    }

    // MARK: Move to Applications

    private func makeFakeApp(at url: URL, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    }

    private func marker(in app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    private func makeMover(discarded: @escaping (URL) -> Void = { _ in }) -> AppMover {
        var mover = AppMover()
        mover.applicationsFolder = scratch.appendingPathComponent("Applications", isDirectory: true)
        mover.discardExisting = { url in
            discarded(url)
            try FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.createDirectory(at: mover.applicationsFolder, withIntermediateDirectories: true)
        return mover
    }

    func testMovesTheAppIntoApplications() throws {
        let source = scratch.appendingPathComponent("Downloads/MacStayOn.app", isDirectory: true)
        try makeFakeApp(at: source, marker: "new")
        let mover = makeMover()

        let destination = try mover.moveIntoApplications(source)

        XCTAssertEqual(destination.lastPathComponent, "MacStayOn.app")
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, mover.applicationsFolder.standardizedFileURL)
        XCTAssertEqual(marker(in: destination), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "no copy left behind in Downloads")
    }

    func testReplacesAnOlderCopyInApplications() throws {
        let source = scratch.appendingPathComponent("Downloads/MacStayOn.app", isDirectory: true)
        try makeFakeApp(at: source, marker: "new")
        var discarded: [URL] = []
        let mover = makeMover { discarded.append($0) }
        let existing = mover.applicationsFolder.appendingPathComponent("MacStayOn.app", isDirectory: true)
        try makeFakeApp(at: existing, marker: "old")

        let destination = try mover.moveIntoApplications(source)

        XCTAssertEqual(discarded.map(\.lastPathComponent), ["MacStayOn.app"], "the older copy goes to the Trash")
        XCTAssertEqual(marker(in: destination), "new")
    }

    func testAlreadyInApplicationsIsANoOp() throws {
        var discarded: [URL] = []
        let mover = makeMover { discarded.append($0) }
        let installed = mover.applicationsFolder.appendingPathComponent("MacStayOn.app", isDirectory: true)
        try makeFakeApp(at: installed, marker: "same")

        XCTAssertEqual(try mover.moveIntoApplications(installed).standardizedFileURL, installed.standardizedFileURL)
        XCTAssertEqual(discarded, [], "never trash the copy that is running")
        XCTAssertEqual(marker(in: installed), "same")
    }
}
